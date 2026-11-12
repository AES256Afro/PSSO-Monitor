import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MonitorStore

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $store.tab) {
                ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.vertical, 8)
            Divider()
            if store.tab == .logs { logs } else { CaptureView() }
        }
        .toolbar { toolbar(store.filtered) }
        .sheet(isPresented: $store.showState) { stateSheet }
    }

    private var logs: some View {
        let rows = store.filtered
        return VStack(spacing: 0) {
            summaryBar
            Divider()
            filterBar
            Divider()
            VSplitView {
                table(rows)
                    .frame(minHeight: 200)
                detail(rows.first { $0.id == store.selection })
                    .frame(minHeight: 90, idealHeight: 150)
            }
            Divider()
            HStack {
                if store.isLive { Circle().fill(.red).frame(width: 8, height: 8) }
                if store.isLoadingHistory { ProgressView().controlSize(.small) }
                Text(store.status).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(rows.count) shown / \(store.events.count) captured")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    // MARK: Pieces

    private var summaryBar: some View {
        HStack(spacing: 12) {
            tile("Events", "\(store.events.count)", .primary)
            tile("Failures", "\(store.failureCount)", store.failureCount > 0 ? .red : .primary)
            tile("Browser failures", "\(store.browserFailureCount)", store.browserFailureCount > 0 ? .red : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last failure").font(.caption).foregroundStyle(.secondary)
                if let f = store.lastFailure {
                    Text("\(Self.timeFormat.string(from: f.date))  \(f.browserLabel.isEmpty ? f.process : f.browserLabel)")
                        .font(.callout.weight(.medium))
                    Text(f.message).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                } else {
                    Text("None").font(.callout.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .onTapGesture { store.selection = store.lastFailure?.id }
        }
        .padding(10)
    }

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(width: 120, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filterBar: some View {
        HStack {
            Picker("", selection: $store.filter) {
                ForEach(OutcomeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Hide XPC noise", isOn: $store.hideNoise)
            Spacer()
            TextField("Filter message, process, category, browser", text: $store.searchText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func table(_ rows: [LogEvent]) -> some View {
        Table(rows, selection: $store.selection) {
            TableColumn("Time") { e in
                Text(Self.timeFormat.string(from: e.date)).monospacedDigit()
            }.width(min: 130, ideal: 150, max: 170)
            TableColumn("Outcome") { e in
                Label(e.outcome.rawValue, systemImage: icon(e.outcome))
                    .foregroundStyle(color(e.outcome))
            }.width(min: 80, ideal: 90, max: 100)
            TableColumn("Browser") { e in Text(e.browserLabel) }.width(min: 60, ideal: 80, max: 110)
            TableColumn("Process") { e in Text(e.process) }.width(min: 90, ideal: 130, max: 200)
            TableColumn("Category") { e in Text(e.category) }.width(min: 90, ideal: 150, max: 220)
            TableColumn("Message") { e in
                Text(e.message).lineLimit(1).font(.system(.body, design: .monospaced))
            }
        }
    }

    private func detail(_ e: LogEvent?) -> some View {
        ScrollView {
            if let e {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(e.timestamp) · \(e.level) · \(e.process) [\(e.pid)] · \(e.subsystem) / \(e.category)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let b = e.browser {
                        Text(e.attribution == .inferred
                             ? "Browser: \(b) (inferred — followed a \(b) SSO request within \(Int(MonitorStore.correlationWindow))s)"
                             : "Browser: \(b)")
                            .font(.caption)
                    }
                    Text(e.message).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(e.processPath).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } else {
                Text("Select an event to see the full message.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ rows: [LogEvent]) -> some ToolbarContent {
        ToolbarItemGroup {
          if store.tab == .logs {
            Button { store.toggleLive() } label: {
                Label(store.isLive ? "Stop" : "Start Live", systemImage: store.isLive ? "stop.fill" : "play.fill")
            }
            .help("Start or stop live monitoring")
            Menu {
                ForEach(HistoryRange.allCases) { r in Button(r.label) { store.loadHistory(r) } }
            } label: { Label("Load History", systemImage: "clock.arrow.circlepath") }
            .disabled(store.isLoadingHistory)
            Menu {
                ForEach(ReportFormat.allCases) { f in
                    Button("\(f.rawValue) — \(rows.count) shown events") {
                        if let msg = ReportExporter.export(events: rows, ssoState: store.ssoState, format: f) {
                            store.status = msg
                        }
                    }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(rows.isEmpty)
          }
            Button { store.refreshState(); store.showState = true } label: { Label("SSO State", systemImage: "person.badge.key") }
                .help("Show Platform SSO registration state")
            if store.tab == .logs {
                Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
            }
        }
    }

    private var stateSheet: some View {
        VStack(alignment: .leading) {
            Text("Platform SSO state").font(.headline)
            Text("app-sso platform -s").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(store.ssoState.isEmpty ? "Loading…" : store.ssoState)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { store.showState = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 640, height: 480)
    }

    private func icon(_ o: Outcome) -> String {
        switch o {
        case .failure: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ o: Outcome) -> Color {
        switch o {
        case .failure: return .red
        case .success: return .green
        case .info: return .secondary
        }
    }
}
