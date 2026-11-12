import Foundation

enum AttemptResult: String {
    case pass = "Pass"
    case fail = "Fail"
    case noResult = "No result"
}

/// A burst of sign-in activity, judged as a whole.
struct Attempt: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    let result: AttemptResult
    let browser: String      // "" when none could be tied to it
    let method: String
    let detail: String       // the message that decided the result
    let events: [LogEvent]
    var site = ""            // host of the page the browser was on, when known
    var siteURL = ""

    /// Plain-language category for the result.
    var reason: String {
        switch result {
        case .pass: return "Signed in"
        case .noResult: return ""
        case .fail: return FailureReason.classify(detail)
        }
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

extension LogEvent {
    /// What part of the sign-in machinery logged this.
    var source: String {
        let sub = subsystem.lowercased(), proc = process.lowercased()
        if sub.contains("cryptotokenkit") || sub.contains("smartcard")
            || ["pivtoken", "ctkahp", "ctkd", "sc_auth", "com.apple.ifdreader"].contains(proc) {
            return "Smart card / PIV"
        }
        if sub == "com.apple.localauthentication" { return "Local authentication" }
        if sub.hasPrefix("com.apple.authenticationservices") { return "Authentication Services" }
        if sub.contains("ssoextension") || proc.contains("sso extension")
            || sub.hasPrefix("com.okta") || sub.hasPrefix("com.jamf") { return "IdP SSO extension" }
        if category.hasPrefix("PO") || sub == "com.apple.platformsso" { return "Platform SSO" }
        return "Extensible SSO"
    }
}

enum Correlator {
    /// Ties failures with no browser of their own to the browser whose request came just before.
    static func apply(_ list: inout [LogEvent], window: TimeInterval) {
        var last: (name: String, date: Date)?
        for i in list.indices {
            let e = list[i]
            if let b = e.browser, e.attribution == .direct {
                last = (b, e.date)
            } else if e.outcome == .failure, let lb = last {
                let dt = e.date.timeIntervalSince(lb.date)
                if dt >= 0 && dt <= window {
                    list[i].browser = lb.name
                    list[i].attribution = .inferred
                }
            }
        }
    }
}

enum AttemptBuilder {
    /// Events closer together than this belong to the same attempt.
    static let gap: TimeInterval = 5

    static func build(_ events: [LogEvent]) -> [Attempt] {
        var attempts: [Attempt] = []
        var cluster: [LogEvent] = []

        func close() {
            defer { cluster.removeAll() }
            guard let first = cluster.first, let last = cluster.last else { return }
            let failures = cluster.filter { $0.outcome == .failure }
            let successes = cluster.filter { $0.outcome == .success }
            let smartCard = cluster.contains { $0.source == "Smart card / PIV" }
            let browsers = cluster.compactMap { $0.browser }
            // Background chatter with no browser, no card and no verdict is not a sign-in attempt.
            guard !failures.isEmpty || !successes.isEmpty || !browsers.isEmpty || smartCard else { return }

            let result: AttemptResult = !failures.isEmpty ? .fail : (!successes.isEmpty ? .pass : .noResult)
            let counts = Dictionary(browsers.map { ($0, 1) }, uniquingKeysWith: +)
            let browser = counts.max { $0.value < $1.value }?.key ?? ""
            let sources = Set(cluster.map { $0.source })
            let method: String
            if smartCard { method = "Smart card / PIV" }
            else if sources.contains("Platform SSO") { method = "Platform SSO" }
            else if sources.contains("IdP SSO extension") { method = "IdP SSO extension" }
            else if sources.contains("Authentication Services") { method = "Authentication Services" }
            else if sources.contains("Extensible SSO") { method = "Extensible SSO" }
            else { method = "Local authentication" }
            let detail = failures.first?.message ?? successes.last?.message ?? "No pass or fail message was logged."
            attempts.append(Attempt(id: attempts.count + 1, start: first.date, end: last.date, result: result,
                                    browser: browser, method: method, detail: detail, events: cluster))
        }

        for e in events {
            if let prev = cluster.last, e.date.timeIntervalSince(prev.date) > gap { close() }
            cluster.append(e)
        }
        close()
        return attempts
    }
}

/// Sorts raw failure messages into the handful of reasons people actually act on.
enum FailureReason {
    private static let rules: [(String, NSRegularExpression)] = [
        ("PIN blocked", #"pin.{0,20}(blocked|locked)|\b6983\b"#),
        ("Wrong PIN", #"(wrong|incorrect|invalid|bad).{0,10}pin|pin.{0,20}(wrong|incorrect|invalid|failed)|\b63C[0-9A-F]\b"#),
        ("Smart card not found", #"no (smart ?card|token)|(token|card|smart ?card).{0,20}(removed|not found|not present|missing|unavailable)|reader.{0,20}(removed|not found)"#),
        ("Certificate error", #"certificate|\bcert\b|x509|ssl|tls|trust|revoked|errSecCert|CSSMERR_TP|client.?auth|-98[0-9]{2}\b"#),
        ("Cancelled by user", #"cancel|AuthorizationError Code=1001"#),
        ("Timed out", #"time[d]? ?out"#),
        ("Not registered / not configured", #"not registered|no device configuration|no user configuration|registration|not configured"#),
        ("User not found", #"user.{0,30}not found"#),
        ("Network problem", #"network|offline|unreachable|could not connect|cannot connect|NSURLErrorDomain|-100[0-9]\b|dns"#),
        ("Credential rejected", #"invalid_grant|expired|unauthori[sz]ed|denied|rejected|AADSTS|\b40[13]\b|password"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    static func classify(_ message: String) -> String {
        let r = NSRange(message.startIndex..., in: message)
        for (name, rx) in rules where rx.firstMatch(in: message, range: r) != nil { return name }
        return "Other error"
    }
}

/// A site visit plus what the sign-in logs say happened there.
struct SiteRow {
    let visit: SiteVisit
    let result: String      // Pass / Fail / No result / "" when no sign-in activity was logged
    let reason: String
    let attemptIDs: [Int]
}

enum SiteLinker {
    /// Gives each attempt the page its browser was on, and each page the worst result seen there.
    static func link(_ attempts: inout [Attempt], visits: [SiteVisit]) -> [SiteRow] {
        var byVisit: [Int: [Attempt]] = [:]
        for i in attempts.indices {
            let a = attempts[i]
            let match = visits.indices.last { j in
                let v = visits[j]
                return (a.browser.isEmpty || v.browser == a.browser)
                    && v.date <= a.end.addingTimeInterval(2) && v.date >= a.start.addingTimeInterval(-60)
            }
            if let j = match {
                attempts[i].site = visits[j].host
                attempts[i].siteURL = visits[j].url
                byVisit[j, default: []].append(attempts[i])
            }
        }
        return visits.enumerated().map { j, v in
            let linked = byVisit[j] ?? []
            let worst = linked.first { $0.result == .fail } ?? linked.first { $0.result == .pass } ?? linked.first
            return SiteRow(visit: v, result: worst?.result.rawValue ?? "", reason: worst?.reason ?? "",
                           attemptIDs: linked.map { $0.id })
        }
    }
}
