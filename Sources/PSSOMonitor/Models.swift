import Foundation

enum Outcome: String, Codable, CaseIterable {
    case failure = "Failure"
    case success = "Success"
    case info = "Info"
}

/// How a browser was tied to an event.
enum Attribution: String, Codable {
    case direct = "direct"      // logged by the browser process itself, or names its bundle ID
    case inferred = "inferred"  // SSO failure within a few seconds of that browser's SSO request
}

struct LogEvent: Identifiable, Codable {
    let id: Int
    let date: Date
    let timestamp: String
    let level: String
    let process: String
    let processPath: String
    let pid: Int
    let subsystem: String
    let category: String
    let message: String
    let outcome: Outcome
    var browser: String?
    var attribution: Attribution?

    var browserLabel: String {
        guard let browser else { return "" }
        return attribution == .inferred ? "~\(browser)" : browser
    }
}

enum Browsers {
    /// (display name, needles matched case-insensitively against process path and message)
    static let known: [(name: String, needles: [String])] = [
        ("Safari", ["com.apple.safari", "/safari.app/", "com.apple.webkit.networking", "safariviewservice"]),
        ("Chrome", ["com.google.chrome", "/google chrome", "/chromium.app/"]),
        ("Edge", ["com.microsoft.edgemac", "/microsoft edge"]),
        ("Firefox", ["org.mozilla.firefox", "/firefox.app/"]),
        ("Arc", ["company.thebrowser.browser", "/arc.app/"]),
        ("Brave", ["com.brave.browser", "/brave browser"]),
        ("Opera", ["com.operasoftware.opera", "/opera.app/"]),
        ("Vivaldi", ["com.vivaldi.vivaldi", "/vivaldi.app/"]),
        ("DuckDuckGo", ["com.duckduckgo.macos.browser", "/duckduckgo.app/"]),
        ("Orion", ["com.kagi.kagimacos", "/orion.app/"]),
    ]

    static func match(processPath: String, message: String) -> String? {
        let path = processPath.lowercased()
        let msg = message.lowercased()
        for b in known {
            for n in b.needles where path.contains(n) || msg.contains(n) { return b.name }
        }
        return nil
    }
}

enum Classifier {
    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// Phrases that contain "error"/"fail" words but mean nothing went wrong.
    private static let benign = rx(#"error\s*[:=]?\s*(\(null\)|nil|none|0\b)|no errors?\b|without errors?\b|error\s*handler|didFail\w*:\]\s+on"#)
    private static let failure = rx(#"\b(fail(ed|ure|ures|s|ing)?|errors?|denied|invalid|unable to|could not|couldn't|cannot|can't|time[d]? ?out|expired|not registered|unauthori[sz]ed|rejected|mismatch|cancel+ed|not found|incorrect|wrong|blocked|locked out|no (valid )?(token|credential|sso token|device configuration|user configuration)s?|Error Domain=)\b"#)
    private static let success = rx(#"\b(success(ful|fully)?|succeeded|authenticated|login complete[d]?|tokens? (received|refreshed|saved|updated)|registration complete[d]?)\b"#)

    static func outcome(level: String, message: String) -> Outcome {
        let full = NSRange(message.startIndex..., in: message)
        let cleaned = benign.stringByReplacingMatches(in: message, range: full, withTemplate: " ")
        let r = NSRange(cleaned.startIndex..., in: cleaned)
        if level == "Error" || level == "Fault" { return .failure }
        if failure.firstMatch(in: cleaned, range: r) != nil { return .failure }
        if success.firstMatch(in: cleaned, range: r) != nil { return .success }
        return .info
    }
}

enum LogParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// Parses one ndjson line from `log stream|show --style ndjson`. Returns nil for non-log lines.
    static func parse(line: Data, id: Int) -> LogEvent? {
        guard line.first == UInt8(ascii: "{"),
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["eventType"] as? String) == "logEvent",
              let message = obj["eventMessage"] as? String
        else { return nil }
        let ts = obj["timestamp"] as? String ?? ""
        let path = obj["processImagePath"] as? String ?? ""
        let process = (path as NSString).lastPathComponent
        if process == "app-sso" || process == "PSSOMonitor" { return nil } // our own state queries
        let level = obj["messageType"] as? String ?? "Default"
        let browser = Browsers.match(processPath: path, message: message)
        return LogEvent(
            id: id,
            date: formatter.date(from: ts) ?? Date(),
            timestamp: ts,
            level: level,
            process: process,
            processPath: path,
            pid: obj["processID"] as? Int ?? 0,
            subsystem: obj["subsystem"] as? String ?? "",
            category: obj["category"] as? String ?? "",
            message: message,
            outcome: Classifier.outcome(level: level, message: message),
            browser: browser,
            attribution: browser == nil ? nil : .direct
        )
    }
}
