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
                                   "--predicate", LogEngine.predicate],
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
        print(ReportExporter.summary(events))
        exit(0)
    }
}
