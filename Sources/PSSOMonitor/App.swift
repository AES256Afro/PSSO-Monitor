import AppKit
import SwiftUI

@main
struct PSSOMonitorApp: App {
    @StateObject private var store = MonitorStore()

    init() {
        // Lets the bare SwiftPM binary (`swift run`) show a window too.
        NSApplication.shared.setActivationPolicy(.regular)

        // Headless self-check: PSSOMonitor --export-test <last> <dir>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-test"), args.count > i + 2 {
            Self.exportTest(last: args[i + 1], dir: args[i + 2])
        }
    }

    var body: some Scene {
        WindowGroup("PSSO Monitor") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 560)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    private static func exportTest(last: String, dir: String) -> Never {
        let engine = LogEngine()
        var events: [LogEvent] = []
        let done = DispatchSemaphore(value: 0)
        var failure = ""
        if let fixture = FileManager.default.contents(atPath: last) {
            // A saved ndjson file instead of a time range.
            for l in fixture.split(separator: 0x0A) {
                if let e = LogParser.parse(line: Data(l), id: events.count) { events.append(e) }
            }
        } else {
            engine.run(arguments: ["show", "--last", last, "--style", "ndjson", "--info", "--debug",
                                   "--predicate", LogEngine.capturePredicate],
                       onLines: { lines in
                           for l in lines { if let e = LogParser.parse(line: l, id: events.count) { events.append(e) } }
                       },
                       onExit: { code, err in if code != 0 { failure = "log exit \(code): \(err)" }; done.signal() })
            done.wait()
        }
        if !failure.isEmpty { print(failure); exit(1) }
        let state = LogEngine.platformSSOState()
        let base = URL(fileURLWithPath: dir)
        try? ReportExporter.csv(events).write(to: base.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
        try? ReportExporter.json(events, ssoState: state).write(to: base.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
        try? ReportExporter.html(events, ssoState: state).write(to: base.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        Correlator.apply(&events, window: MonitorStore.correlationWindow)
        var attempts = AttemptBuilder.build(events)
        let start = events.first?.date ?? Date(), end = events.last?.date ?? Date()
        let env = EnvironmentProbe.snapshot(officeDomains: ["nasa.gov"])
        // Optional 4th argument: JSON list of {t, browser, url, title} standing in for browser history.
        var history = (visits: [SiteVisit](), notes: [String]())
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-test"), args.count > i + 3, let d = FileManager.default.contents(atPath: args[i + 3]),
           let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            history.visits = rows.compactMap { (r: [String: Any]) -> SiteVisit? in
                guard let t = r["t"] as? Double, let u = r["url"] as? String, let host = URL(string: u)?.host else { return nil }
                return SiteVisit(date: start.addingTimeInterval(t), browser: r["browser"] as? String ?? "", url: u,
                                 host: host, title: r["title"] as? String ?? "")
            }
        } else {
            history = HistoryReader.visits(from: start, to: end)
        }
        let sites = SiteLinker.link(&attempts, visits: history.visits)
        let session = CaptureSession(start: start, end: end, attempts: attempts, events: events, startEnv: env, endEnv: env,
                                     sites: sites, activity: [], notes: history.notes)
        try? CaptureReport.html(session).write(to: base.appendingPathComponent("capture.html"), atomically: true, encoding: .utf8)
        do { try XLSXWriter.write(CaptureReport.workbook(session), to: base.appendingPathComponent("capture.xlsx")) }
        catch { print(error.localizedDescription); exit(1) }
        print("scenario: \(session.scenario) | cisco: \(env.ciscoLabel) | dns: \(env.dnsDomains) | if: \(env.interfaces)")
        print("sites: \(sites.count) \(history.notes)")
        for a in attempts { print("attempt \(a.id): \(a.result.rawValue) [\(a.reason)] | \(a.browser) | \(a.site) | \(a.method) | \(a.events.count) events | \(a.detail.prefix(70))") }
        print(ReportExporter.summary(events))
        exit(0)
    }
}
