import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var store: MonitorStore

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        let selected = store.attempts.first { $0.id == store.attemptSelection }
        VStack(spacing: 0) {
            controls
            scenarioBar
            Divider()
            VSplitView {
                attemptsTable.frame(minHeight: 160)
                eventsTable(selected).frame(minHeight: 140)
            }
            Divider()
            HStack {
                if store.isCapturing { Circle().fill(.red).frame(width: 8, height: 8) }
                Text(store.captureStatus).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(store.captureEvents.count) events captured")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { store.toggleCapture() } label: {
                Label(store.isCapturing ? "Stop Capture" : "Start Capture",
                      systemImage: store.isCapturing ? "stop.circle.fill" : "record.circle")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .tint(store.isCapturing ? .red : .accentColor)
            .buttonStyle(.borderedProminent)

            tile("Elapsed", elapsed, .primary)
            tile("Attempts", "\(store.attempts.count)", .primary)
            tile("Passed", "\(store.passCount)", store.passCount > 0 ? .green : .primary)
            tile("Failed", "\(store.failCount)", store.failCount > 0 ? .red : .primary)
            Spacer()
            Menu {
                ForEach(CaptureFormat.allCases) { f in
                    Button(f.rawValue) { export(f) }
                }
            } label: { Label("Export Capture", systemImage: "square.and.arrow.up") }
            .controlSize(.large)
            .fixedSize()
            .disabled(store.session == nil)
        }
        .padding(10)
    }

    private var scenarioBar: some View {
        HStack(spacing: 8) {
            if let env = store.startEnv {
                chip(env.pivInserted ? "PIV inserted" : "No PIV", env.pivInserted ? "creditcard.fill" : "creditcard")
                chip("Cisco VPN: \(env.ciscoLabel)", "lock.shield")
                chip(env.locationLabel, "network")
                chip(env.ssoRegistered ? "Platform SSO registered" : "Platform SSO not registered", "person.badge.key")
            } else {
                Text("PIV, VPN and network state are recorded automatically when you start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Office domains").font(.caption).foregroundStyle(.secondary)
            TextField("nasa.gov, example.org", text: $store.officeDomains)
                .textFieldStyle(.roundedBorder).frame(width: 190)
                .help("A network whose DNS domain ends with one of these is labelled Office")
                .disabled(store.isCapturing)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var elapsed: String {
        let s = Int(store.captureElapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func export(_ format: CaptureFormat) {
        guard let session = store.session else { return }
        if let msg = CaptureReport.export(session, format: format) { store.captureStatus = msg }
    }

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(width: 90, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var attemptsTable: some View {
        Table(store.attempts, selection: $store.attemptSelection) {
            TableColumn("#") { a in Text("\(a.id)").monospacedDigit() }.width(30)
            TableColumn("Result") { a in
                Label(a.result.rawValue, systemImage: icon(a.result)).foregroundStyle(color(a.result))
            }.width(min: 80, ideal: 95, max: 110)
            TableColumn("Started") { a in Text(Self.timeFormat.string(from: a.start)).monospacedDigit() }
                .width(min: 90, ideal: 100, max: 120)
            TableColumn("Browser") { a in Text(a.browser.isEmpty ? "—" : a.browser) }.width(min: 70, ideal: 90, max: 120)
            TableColumn("Site") { a in Text(a.site.isEmpty ? "—" : a.site) }.width(min: 90, ideal: 170, max: 260)
            TableColumn("Method") { a in Text(a.method) }.width(min: 110, ideal: 140, max: 200)
            TableColumn("Reason") { a in Text(a.reason) }.width(min: 90, ideal: 140, max: 200)
            TableColumn("Events") { a in Text("\(a.events.count)").monospacedDigit() }.width(50)
            TableColumn("Deciding message") { a in
                Text(a.detail).lineLimit(1).font(.system(.body, design: .monospaced))
            }
        }
    }

    private func eventsTable(_ attempt: Attempt?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(attempt.map { "Events in attempt \($0.id)" } ?? "All captured events — select an attempt to narrow down")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
            Table(attempt?.events ?? store.captureEvents) {
                TableColumn("Time") { e in Text(Self.timeFormat.string(from: e.date)).monospacedDigit() }
                    .width(min: 90, ideal: 100, max: 120)
                TableColumn("Outcome") { e in
                    Text(e.outcome.rawValue)
                        .foregroundStyle(e.outcome == .failure ? Color.red : e.outcome == .success ? Color.green : Color.secondary)
                }.width(min: 60, ideal: 70, max: 80)
                TableColumn("Browser") { e in Text(e.browserLabel) }.width(min: 60, ideal: 80, max: 110)
                TableColumn("Source") { e in Text(e.source) }.width(min: 100, ideal: 140, max: 180)
                TableColumn("Process") { e in Text(e.process) }.width(min: 90, ideal: 130, max: 200)
                TableColumn("Message") { e in
                    Text(e.message).lineLimit(1).font(.system(.body, design: .monospaced)).help(e.message)
                }
            }
        }
    }

    private func icon(_ r: AttemptResult) -> String {
        switch r {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .noResult: return "questionmark.circle"
        }
    }

    private func color(_ r: AttemptResult) -> Color {
        switch r {
        case .pass: return .green
        case .fail: return .red
        case .noResult: return .secondary
        }
    }
}
