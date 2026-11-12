import AppKit
import Foundation
import UniformTypeIdentifiers

/// Everything a sign-in capture export needs.
struct CaptureSession {
    let start: Date
    let end: Date
    let attempts: [Attempt]
    let events: [LogEvent]
    let startEnv: EnvironmentSnapshot
    let endEnv: EnvironmentSnapshot
    let sites: [SiteRow]
    let activity: [ActivityEvent]
    let notes: [String]

    var passed: Int { attempts.filter { $0.result == .pass }.count }
    var failed: Int { attempts.filter { $0.result == .fail }.count }
    var noResult: Int { attempts.filter { $0.result == .noResult }.count }
    var pivUsed: Bool { attempts.contains { $0.method == "Smart card / PIV" } }

    /// e.g. "PIV inserted · Office network"; both ends if conditions changed during the capture.
    var scenario: String {
        startEnv.label == endEnv.label ? startEnv.label : "\(startEnv.label) → \(endEnv.label)"
    }

    /// One chronological story: browsers opened, pages visited, sign-in results.
    var timeline: [(date: Date, kind: String, browser: String, text: String)] {
        var t: [(date: Date, kind: String, browser: String, text: String)] = []
        t.append((start, "Capture", "", "Capture started — \(startEnv.label)"))
        for a in activity { t.append((a.date, "Browser", a.browser, a.what)) }
        for s in sites {
            let v = s.visit
            t.append((v.date, v.isSignInPage ? "Sign-in page" : "Page", v.browser,
                      "Visited \(v.host)" + (v.title.isEmpty ? "" : " — \(v.title)")))
        }
        for a in attempts {
            var line = "Sign-in attempt \(a.id): \(a.result.rawValue.uppercased())"
            if !a.reason.isEmpty { line += " — \(a.reason)" }
            if !a.site.isEmpty { line += " at \(a.site)" }
            line += " (\(a.method))"
            t.append((a.start, "Result: \(a.result.rawValue)", a.browser, line))
        }
        t.append((end, "Capture", "", "Capture stopped — \(endEnv.label)"))
        return t.sorted { $0.date < $1.date }
    }

    /// Distinct pass/fail messages with counts, most common first.
    var commonResponses: [(count: Int, outcome: Outcome, reason: String, source: String, message: String)] {
        var groups: [String: (count: Int, outcome: Outcome, reason: String, source: String, message: String)] = [:]
        let volatile = try! NSRegularExpression(pattern: #"0x[0-9a-fA-F]+|\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}\b|\b\d{4,}\b"#)
        for e in events where e.outcome != .info {
            let msg = String(e.message.prefix(400))
            let norm = volatile.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "#")
            let key = "\(e.outcome.rawValue)|\(norm)"
            if groups[key] != nil { groups[key]!.count += 1 } else {
                groups[key] = (1, e.outcome, e.outcome == .failure ? FailureReason.classify(msg) : "Signed in", e.source, norm)
            }
        }
        return groups.values.sorted { $0.count > $1.count }
    }
}

enum CaptureFormat: String, CaseIterable, Identifiable {
    case xlsx = "Excel workbook (.xlsx)", html = "Visual report (HTML)"
    var id: String { rawValue }
    var ext: String { self == .html ? "html" : "xlsx" }
}

enum CaptureReport {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Asks where to save, writes the file, returns a status line (nil if cancelled).
    static func export(_ session: CaptureSession, format: CaptureFormat) -> String? {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let slug = session.startEnv.label.replacingOccurrences(of: " · ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        panel.nameFieldStringValue = "SignIn-Capture_\(slug)_\(stamp.string(from: session.start)).\(format.ext)"
        if let t = UTType(filenameExtension: format.ext) { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            switch format {
            case .html: try html(session).write(to: url, atomically: true, encoding: .utf8)
            case .xlsx: try XLSXWriter.write(workbook(session), to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Exported \(session.attempts.count) attempts and \(session.sites.count) site visits to \(url.lastPathComponent)."
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    private static func envRows(_ s: CaptureSession) -> [(String, String, String)] {
        let a = s.startEnv, b = s.endEnv
        func yn(_ v: Bool) -> String { v ? "Yes" : "No" }
        return [
            ("PIV / smart card inserted", yn(a.pivInserted), yn(b.pivInserted)),
            ("Smart card tokens", a.pivTokens.joined(separator: "; "), b.pivTokens.joined(separator: "; ")),
            ("Cisco VPN", a.ciscoLabel, b.ciscoLabel),
            ("Other VPN connected", a.otherVPN.isEmpty ? "None" : a.otherVPN, b.otherVPN.isEmpty ? "None" : b.otherVPN),
            ("Location", a.locationLabel, b.locationLabel),
            ("On office network", yn(a.atOffice), yn(b.atOffice)),
            ("DNS domains", a.dnsDomains.joined(separator: ", "), b.dnsDomains.joined(separator: ", ")),
            ("Network interfaces", a.interfaces, b.interfaces),
            ("Platform SSO registered", yn(a.ssoRegistered), yn(b.ssoRegistered)),
        ]
    }

    // MARK: Excel

    static func workbook(_ s: CaptureSession) -> [XLSXWriter.Sheet] {
        typealias C = XLSXWriter.Cell
        func style(_ result: String) -> XLSXWriter.Style {
            switch result {
            case "Pass", "Success": return .pass
            case "Fail", "Failure": return .fail
            case "No result": return .neutral
            default: return .plain
            }
        }
        func header(_ titles: [String]) -> [C] { titles.map { C($0, .header) } }

        var summary: [[C]] = [
            [C("Sign-in capture report", .bold)],
            [C("Scenario", .bold), C(s.scenario, .bold)],
            [C("Computer", .bold), C(Host.current().localizedName ?? "")],
            [C("macOS", .bold), C(ProcessInfo.processInfo.operatingSystemVersionString)],
            [C("Capture started", .bold), C(time.string(from: s.start))],
            [C("Capture stopped", .bold), C(time.string(from: s.end))],
            [C("Duration (s)", .bold), C(String(Int(s.end.timeIntervalSince(s.start))))],
            [],
            [C("Sign-in attempts", .bold), C(String(s.attempts.count))],
            [C("Passed", .bold), C(String(s.passed), .pass)],
            [C("Failed", .bold), C(String(s.failed), s.failed > 0 ? .fail : .plain)],
            [C("No result logged", .bold), C(String(s.noResult), .neutral)],
            [C("PIV used in an attempt", .bold), C(s.pivUsed ? "Yes" : "No")],
            [C("Sites visited", .bold), C(String(s.sites.count))],
            [C("Log events captured", .bold), C(String(s.events.count))],
            [],
            header(["Conditions", "At start", "At stop"]),
        ]
        summary += envRows(s).map { [C($0.0, .bold), C($0.1), C($0.2, $0.1 == $0.2 ? .plain : .neutral)] }
        summary += [[], [C("Notes", .bold)]]
        summary += (s.notes + [
            "Fail = at least one error was logged during the attempt. Pass = a success message and no errors.",
            "Sites are matched to attempts by browser and timing; a browser shown with ~ was inferred from timing.",
        ]).map { [C($0)] }
        summary += [[], [C("Platform SSO state (app-sso platform -s)", .bold)]]
        summary += s.startEnv.ssoState.split(separator: "\n", omittingEmptySubsequences: false).map { [C(String($0))] }

        var attempts = [header(["#", "Result", "Reason", "Scenario", "Browser", "Site", "Method", "Started", "Duration (s)", "Events", "Errors", "Deciding message", "Page URL"])]
        for a in s.attempts {
            attempts.append([
                C(String(a.id)), C(a.result.rawValue, style(a.result.rawValue)), C(a.reason), C(s.scenario),
                C(a.browser), C(a.site), C(a.method), C(time.string(from: a.start)), C(String(format: "%.1f", a.duration)),
                C(String(a.events.count)), C(String(a.events.filter { $0.outcome == .failure }.count)),
                C(a.detail, .wrap), C(a.siteURL),
            ])
        }

        var sites = [header(["Time", "Browser", "Site", "Type", "Result", "Reason", "Attempts", "Scenario", "Page title", "URL"])]
        for r in s.sites {
            let v = r.visit
            sites.append([
                C(time.string(from: v.date)), C(v.browser), C(v.host), C(v.isSignInPage ? "Sign-in page" : "Page"),
                C(r.result.isEmpty ? "No sign-in activity" : r.result, style(r.result)), C(r.reason),
                C(r.attemptIDs.map(String.init).joined(separator: ", ")), C(s.scenario), C(v.title), C(v.url),
            ])
        }

        var timeline = [header(["Time", "Kind", "Browser", "What happened"])]
        for t in s.timeline {
            let st: XLSXWriter.Style = t.kind.hasSuffix("Pass") ? .pass : t.kind.hasSuffix("Fail") ? .fail : .plain
            timeline.append([C(time.string(from: t.date)), C(t.kind, st), C(t.browser), C(t.text, .wrap)])
        }

        var responses = [header(["Count", "Outcome", "Reason", "Source", "Message (numbers and IDs replaced with #)"])]
        for r in s.commonResponses.prefix(1000) {
            responses.append([C(String(r.count)), C(r.outcome.rawValue, style(r.outcome.rawValue)), C(r.reason), C(r.source), C(r.message, .wrap)])
        }

        var attemptOf: [Int: Int] = [:]
        for a in s.attempts { for e in a.events { attemptOf[e.id] = a.id } }
        var events = [header(["Attempt", "Time", "Outcome", "Browser", "Source", "Level", "Process", "Category", "Message"])]
        for e in s.events {
            events.append([
                C(attemptOf[e.id].map(String.init) ?? ""), C(e.timestamp), C(e.outcome.rawValue, style(e.outcome.rawValue)),
                C(e.browserLabel), C(e.source), C(e.level), C(e.process), C(e.category), C(e.message, .wrap),
            ])
        }

        return [
            XLSXWriter.Sheet(name: "Summary", widths: [30, 50, 50], rows: summary, hasHeader: false),
            XLSXWriter.Sheet(name: "Attempts", widths: [5, 11, 26, 38, 11, 30, 22, 20, 12, 8, 8, 100, 60], rows: attempts),
            XLSXWriter.Sheet(name: "Sites", widths: [20, 11, 34, 14, 18, 26, 10, 38, 40, 70], rows: sites),
            XLSXWriter.Sheet(name: "Timeline", widths: [20, 16, 11, 110], rows: timeline),
            XLSXWriter.Sheet(name: "Common responses", widths: [8, 10, 28, 22, 130], rows: responses),
            XLSXWriter.Sheet(name: "Events", widths: [9, 30, 10, 12, 22, 9, 24, 26, 120], rows: events),
        ]
    }

    // MARK: HTML

    static func html(_ s: CaptureSession) -> String {
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func cls(_ r: String) -> String {
            switch r { case "Pass": return "pass"; case "Fail": return "fail"; default: return "none" }
        }
        let total = max(s.attempts.count, 1)
        func pct(_ n: Int) -> String { String(format: "%.1f", Double(n) / Double(total) * 100) }

        let env = envRows(s).map {
            "<tr><th>\(esc($0.0))</th><td>\(esc($0.1))</td><td\($0.1 == $0.2 ? "" : " class=\"changed\"")>\(esc($0.2))</td></tr>"
        }.joined()

        let story = s.timeline.map { t -> String in
            let c = t.kind.hasSuffix("Pass") ? "pass" : t.kind.hasSuffix("Fail") ? "fail" : (t.kind == "Sign-in page" ? "signin" : "")
            return "<li class=\"\(c)\"><time>\(clock.string(from: t.date))</time>"
                + (t.browser.isEmpty ? "" : "<span class=\"br\">\(esc(t.browser))</span>") + "\(esc(t.text))</li>"
        }.joined(separator: "\n")

        let siteRows = s.sites.map { r -> String in
            let v = r.visit
            return "<tr><td class=\"nw\">\(clock.string(from: v.date))</td><td>\(esc(v.browser))</td>"
                + "<td><b>\(esc(v.host))</b><div class=\"sub\">\(esc(v.title))</div></td>"
                + "<td>\(v.isSignInPage ? "Sign-in page" : "Page")</td>"
                + "<td>\(r.result.isEmpty ? "<span class=\"sub\">No sign-in activity</span>" : "<span class=\"badge \(cls(r.result))\">\(r.result.uppercased())</span>")</td>"
                + "<td>\(esc(r.reason))</td></tr>"
        }.joined(separator: "\n")

        let cards = s.attempts.map { a -> String in
            let rows = a.events.map { e in
                "<tr class=\"\(e.outcome.rawValue.lowercased())\"><td class=\"nw\">\(clock.string(from: e.date))</td>"
                + "<td>\(e.outcome.rawValue)</td><td>\(esc(e.browserLabel))</td><td>\(esc(e.source))</td>"
                + "<td>\(esc(e.process))</td><td class=\"msg\">\(esc(e.message))</td></tr>"
            }.joined(separator: "\n")
            let c = cls(a.result.rawValue)
            let head = [a.browser.isEmpty ? "No browser identified" : a.browser, a.site, a.method].filter { !$0.isEmpty }
            return """
            <details class="card \(c)"\(a.result == .fail ? " open" : "")>
            <summary>
              <span class="badge \(c)">\(a.result.rawValue.uppercased())</span>
              <span class="title">Attempt \(a.id) · \(esc(head.joined(separator: " · ")))</span>
              <span class="when">\(clock.string(from: a.start)) · \(String(format: "%.1f", a.duration))s · \(a.events.count) events</span>
              \(a.reason.isEmpty ? "" : "<div class=\"reason\">\(esc(a.reason))</div>")
              <div class="why">\(esc(a.detail))</div>
            </summary>
            <div class="scroll"><table><tr><th>Time</th><th>Outcome</th><th>Browser</th><th>Source</th><th>Process</th><th>Message</th></tr>
            \(rows)</table></div>
            </details>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Sign-in Capture Report</title>
        <style>
        :root{--bg:#f4f5f7;--card:#fff;--ink:#16181d;--muted:#667085;--line:#e4e7ec;--accent:#2f5bd8;--accentbg:#e9effd;
          --pass:#12805c;--passbg:#e7f6ef;--fail:#c4320a;--failbg:#fdece7;--none:#667085;--nonebg:#eef0f3}
        @media (prefers-color-scheme:dark){:root{--bg:#111318;--card:#1a1d24;--ink:#eceef2;--muted:#98a2b3;--line:#2b303a;
          --accent:#8eabff;--accentbg:#1c2748;--pass:#4cc38a;--passbg:#12301f;--fail:#ff8a65;--failbg:#3a1a12;--none:#98a2b3;--nonebg:#252932}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        main{max-width:1100px;margin:0 auto;padding:32px 16px 64px}
        h1{font-size:26px;margin:0 0 4px;letter-spacing:-.01em} h2{font-size:16px;margin:32px 0 12px}
        .meta,.sub{color:var(--muted)} .sub{font-size:12px}
        .scenario{display:inline-block;margin:14px 0 0;padding:8px 14px;border-radius:10px;background:var(--accentbg);color:var(--accent);font-weight:700;font-size:16px}
        .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin:20px 0 12px}
        .tile,.panel{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
        .panel{padding:4px 0;overflow-x:auto}
        .tile b{display:block;font-size:30px;line-height:1.1;font-variant-numeric:tabular-nums}
        .tile span{color:var(--muted)} .tile.pass b{color:var(--pass)} .tile.fail b{color:var(--fail)}
        .bar{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--nonebg);margin-bottom:8px}
        .bar i{display:block} .bar .p{background:var(--pass)} .bar .f{background:var(--fail)}
        ol.story{list-style:none;margin:0;padding:6px 16px;background:var(--card);border:1px solid var(--line);border-radius:12px}
        ol.story li{padding:7px 0 7px 14px;border-left:3px solid var(--line);margin:2px 0;overflow-wrap:anywhere}
        ol.story li.pass{border-left-color:var(--pass);color:var(--pass);font-weight:600}
        ol.story li.fail{border-left-color:var(--fail);color:var(--fail);font-weight:600}
        ol.story li.signin{border-left-color:var(--accent)}
        time{font-variant-numeric:tabular-nums;color:var(--muted);margin-right:10px;font-weight:400}
        .br{display:inline-block;font-size:11px;font-weight:600;padding:1px 7px;border-radius:999px;background:var(--nonebg);color:var(--ink);margin-right:8px}
        .card{background:var(--card);border:1px solid var(--line);border-left:5px solid var(--none);border-radius:10px;margin:10px 0;overflow:hidden}
        .card.pass{border-left-color:var(--pass)} .card.fail{border-left-color:var(--fail)}
        summary{cursor:pointer;padding:12px 16px;list-style:none} summary::-webkit-details-marker{display:none}
        .badge{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.04em;padding:2px 8px;border-radius:999px;margin-right:8px;
          background:var(--nonebg);color:var(--none)}
        .badge.pass{background:var(--passbg);color:var(--pass)} .badge.fail{background:var(--failbg);color:var(--fail)}
        .title{font-weight:600} .when{color:var(--muted);float:right}
        .reason{margin-top:6px;font-weight:600} .card.fail .reason{color:var(--fail)} .card.pass .reason{color:var(--pass)}
        .why{margin-top:4px;font:12px ui-monospace,Menlo,monospace;color:var(--muted);overflow-wrap:anywhere}
        .scroll{overflow-x:auto}
        table{border-collapse:collapse;width:100%;font-size:12px}
        th,td{text-align:left;vertical-align:top;padding:6px 12px;border-top:1px solid var(--line)}
        tr:first-child th,tr:first-child td{border-top:0}
        th{color:var(--muted);font-weight:600} .nw{white-space:nowrap} td.changed{color:var(--fail);font-weight:600}
        .msg{font-family:ui-monospace,Menlo,monospace;font-size:11px;overflow-wrap:anywhere}
        tr.failure td{background:var(--failbg)} tr.success td{background:var(--passbg)}
        @media (max-width:640px){.when{float:none;display:block}}
        @media print{details{break-inside:avoid}}
        </style></head><body><main>
        <h1>Sign-in Capture Report</h1>
        <div class="meta">\(esc(Host.current().localizedName ?? "")) · \(esc(ProcessInfo.processInfo.operatingSystemVersionString))<br>
        Captured \(time.string(from: s.start)) → \(time.string(from: s.end)) (\(Int(s.end.timeIntervalSince(s.start)))s)</div>
        <div class="scenario">\(esc(s.scenario))</div>
        <div class="tiles">
          <div class="tile"><b>\(s.attempts.count)</b><span>Sign-in attempts</span></div>
          <div class="tile pass"><b>\(s.passed)</b><span>Passed</span></div>
          <div class="tile fail"><b>\(s.failed)</b><span>Failed</span></div>
          <div class="tile"><b>\(s.noResult)</b><span>No result logged</span></div>
          <div class="tile"><b>\(s.sites.count)</b><span>Sites visited</span></div>
        </div>
        <div class="bar"><i class="p" style="width:\(pct(s.passed))%"></i><i class="f" style="width:\(pct(s.failed))%"></i></div>
        <h2>Conditions</h2>
        <div class="panel"><table><tr><th></th><th>At start</th><th>At stop</th></tr>\(env)</table></div>
        <h2>What happened</h2>
        <ol class="story">
        \(story)
        </ol>
        <h2>Sites visited</h2>
        \(s.sites.isEmpty ? "<p class=\"meta\">No site visits were found in browser history for this capture.</p>"
          : "<div class=\"panel\"><table><tr><th>Time</th><th>Browser</th><th>Site</th><th>Type</th><th>Result</th><th>Reason</th></tr>\(siteRows)</table></div>")
        <h2>Sign-in attempts</h2>
        \(s.attempts.isEmpty ? "<p class=\"meta\">No sign-in attempts were seen during this capture.</p>" : cards)
        <h2>Notes</h2>
        <ul class="meta">
        \((s.notes + ["Fail = at least one error was logged during the attempt. Pass = a success message and no errors.",
                      "Sites are matched to attempts by browser and timing; a browser shown with ~ was inferred from timing."])
            .map { "<li>\(esc($0))</li>" }.joined())
        </ul>
        </main></body></html>
        """
    }
}
