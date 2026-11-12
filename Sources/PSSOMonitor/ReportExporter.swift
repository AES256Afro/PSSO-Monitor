import AppKit
import Foundation
import UniformTypeIdentifiers

enum ReportFormat: String, CaseIterable, Identifiable {
    case html = "HTML report", csv = "CSV", json = "JSON"
    var id: String { rawValue }
    var ext: String {
        switch self { case .html: return "html"; case .csv: return "csv"; case .json: return "json" }
    }
    var type: UTType {
        switch self { case .html: return .html; case .csv: return .commaSeparatedText; case .json: return .json }
    }
}

enum ReportExporter {
    static func export(events: [LogEvent], ssoState: String, format: ReportFormat) -> String? {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "PSSO-Report-\(stamp.string(from: Date())).\(format.ext)"
        panel.allowedContentTypes = [format.type]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let text: String
        switch format {
        case .csv: text = csv(events)
        case .json: text = json(events, ssoState: ssoState)
        case .html: text = html(events, ssoState: ssoState)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "Exported \(events.count) events to \(url.lastPathComponent)."
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Formats

    static func csv(_ events: [LogEvent]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "timestamp,outcome,level,browser,browser_attribution,process,pid,subsystem,category,message\r\n"
        for e in events {
            out += [e.timestamp, e.outcome.rawValue, e.level, e.browser ?? "", e.attribution?.rawValue ?? "",
                    e.process, String(e.pid), e.subsystem, e.category, e.message].map(q).joined(separator: ",")
            out += "\r\n"
        }
        return out
    }

    private struct JSONReport: Encodable {
        let generated: Date
        let host: String
        let macOS: String
        let summary: [String: Int]
        let failuresByBrowser: [String: Int]
        let platformSSOState: String
        let events: [LogEvent]
    }

    static func json(_ events: [LogEvent], ssoState: String) -> String {
        let report = JSONReport(generated: Date(), host: Host.current().localizedName ?? "",
                                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                summary: summary(events), failuresByBrowser: byBrowser(events),
                                platformSSOState: ssoState, events: events)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? String(data: enc.encode(report), encoding: .utf8)) ?? "{}"
    }

    static func html(_ events: [LogEvent], ssoState: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let s = summary(events)
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .medium
        let span = events.isEmpty ? "No events"
            : "\(df.string(from: events.first!.date)) → \(df.string(from: events.last!.date))"

        func rows(_ list: [LogEvent]) -> String {
            list.map { e in
                "<tr class=\"\(e.outcome.rawValue.lowercased())\"><td class=\"nw\">\(esc(e.timestamp))</td>"
                + "<td>\(e.outcome.rawValue)</td><td>\(esc(e.browserLabel))</td><td>\(esc(e.process))</td>"
                + "<td>\(esc(e.category))</td><td class=\"msg\">\(esc(e.message))</td></tr>"
            }.joined(separator: "\n")
        }
        let head = "<tr><th>Time</th><th>Outcome</th><th>Browser</th><th>Process</th><th>Category</th><th>Message</th></tr>"
        let failures = events.filter { $0.outcome == .failure }
        let browsers = byBrowser(events).sorted { $0.value > $1.value }
            .map { "<tr><td>\(esc($0.key))</td><td>\($0.value)</td></tr>" }.joined()

        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Platform SSO Report</title>
        <style>
        body{font:13px -apple-system,Helvetica,sans-serif;margin:32px;color:#1d1d1f}
        h1{margin:0 0 4px} h2{margin-top:28px} .meta{color:#666}
        .tiles{display:flex;gap:12px;margin:18px 0}
        .tile{border:1px solid #ddd;border-radius:8px;padding:10px 16px;min-width:110px}
        .tile b{display:block;font-size:22px}
        table{border-collapse:collapse;width:100%} th,td{border-bottom:1px solid #e5e5e5;padding:4px 8px;text-align:left;vertical-align:top}
        th{background:#f5f5f7} .nw{white-space:nowrap} .msg{font-family:ui-monospace,Menlo,monospace;font-size:11px;word-break:break-word}
        tr.failure td{background:#fff1f0} tr.success td{background:#f0fff4}
        pre{background:#f5f5f7;padding:12px;border-radius:8px;overflow:auto}
        .small{width:auto}
        </style></head><body>
        <h1>Platform SSO Report</h1>
        <div class="meta">\(esc(Host.current().localizedName ?? "")) · \(esc(ProcessInfo.processInfo.operatingSystemVersionString)) · generated \(df.string(from: Date()))<br>Period: \(span)</div>
        <div class="tiles">
        <div class="tile"><b>\(s["total"] ?? 0)</b>Events</div>
        <div class="tile"><b>\(s["failures"] ?? 0)</b>Failures</div>
        <div class="tile"><b>\(s["browserFailures"] ?? 0)</b>Browser failures</div>
        <div class="tile"><b>\(s["successes"] ?? 0)</b>Successes</div>
        </div>
        <h2>Failures by browser</h2>
        \(browsers.isEmpty ? "<p>No browser-attributed failures.</p>" : "<table class=\"small\"><tr><th>Browser</th><th>Failures</th></tr>\(browsers)</table>")
        <p class="meta">A leading ~ means the browser was inferred: the failure followed that browser's SSO request within \(Int(MonitorStore.correlationWindow)) seconds.</p>
        <h2>Failures (\(failures.count))</h2>
        \(failures.isEmpty ? "<p>None.</p>" : "<table>\(head)\(rows(failures))</table>")
        <h2>Platform SSO state (app-sso platform -s)</h2>
        <pre>\(esc(ssoState))</pre>
        <h2>All events (\(events.count))</h2>
        <table>\(head)\(rows(events))</table>
        </body></html>
        """
    }

    // MARK: Aggregates

    static func summary(_ events: [LogEvent]) -> [String: Int] {
        var f = 0, bf = 0, s = 0
        for e in events {
            if e.outcome == .failure { f += 1; if e.browser != nil { bf += 1 } }
            if e.outcome == .success { s += 1 }
        }
        return ["total": events.count, "failures": f, "browserFailures": bf, "successes": s]
    }

    static func byBrowser(_ events: [LogEvent]) -> [String: Int] {
        var d: [String: Int] = [:]
        for e in events where e.outcome == .failure {
            if let b = e.browser { d[b, default: 0] += 1 }
        }
        return d
    }
}
