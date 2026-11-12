import Foundation
import SwiftUI

enum OutcomeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case failures = "Failures"
    case browserFailures = "Browser failures"
    case successes = "Successes"
    var id: String { rawValue }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case m15 = "15m", h1 = "1h", h6 = "6h", h24 = "24h", d3 = "3d", d7 = "7d"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .m15: return "Last 15 minutes"
        case .h1: return "Last hour"
        case .h6: return "Last 6 hours"
        case .h24: return "Last 24 hours"
        case .d3: return "Last 3 days"
        case .d7: return "Last 7 days"
        }
    }
}

final class MonitorStore: ObservableObject {
    @Published private(set) var events: [LogEvent] = []
    @Published var isLive = false
    @Published var isLoadingHistory = false
    @Published var status = "Idle — start live monitoring or load history."
    @Published var ssoState = ""
    @Published var showState = false

    @Published var searchText = ""
    @Published var filter: OutcomeFilter = .all
    @Published var hideNoise = true
    @Published var selection: LogEvent.ID?

    static let maxEvents = 50_000
    /// A failure with no browser of its own is tied to a browser whose SSO request was seen this recently.
    static let correlationWindow: TimeInterval = 10

    private let live = LogEngine()
    private let history = LogEngine()
    private var nextID = 0
    private var pending: [LogEvent] = []
    private let pendingLock = NSLock()
    private var flushTimer: Timer?
    private var lastBrowser: (name: String, date: Date)?

    init() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.flush() }
        refreshState()
    }

    // MARK: Derived

    var filtered: [LogEvent] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            switch filter {
            case .all: break
            case .failures: if e.outcome != .failure { return false }
            case .browserFailures: if e.outcome != .failure || e.browser == nil { return false }
            case .successes: if e.outcome != .success { return false }
            }
            if hideNoise && e.outcome == .info && Self.isNoise(e) { return false }
            if q.isEmpty { return true }
            return e.message.lowercased().contains(q) || e.process.lowercased().contains(q)
                || e.category.lowercased().contains(q) || (e.browser ?? "").lowercased().contains(q)
        }
    }

    var failureCount: Int { events.reduce(0) { $0 + ($1.outcome == .failure ? 1 : 0) } }
    var browserFailureCount: Int { events.reduce(0) { $0 + ($1.outcome == .failure && $1.browser != nil ? 1 : 0) } }
    var lastFailure: LogEvent? { events.last { $0.outcome == .failure } }

    /// XPC plumbing every app emits just by linking AppSSO; not sign-in activity.
    static func isNoise(_ e: LogEvent) -> Bool {
        e.message.contains("new XPC connection") || e.message.hasSuffix(" on <private>")
            || e.category == "SOExtensionFinder" || e.category == "SOExtensionManager"
    }

    // MARK: Control

    func toggleLive() { isLive ? stopLive() : startLive() }

    func startLive() {
        isLive = true
        status = "Live — watching Platform SSO logs…"
        live.run(arguments: ["stream", "--style", "ndjson", "--level", "debug", "--predicate", LogEngine.predicate],
                 onLines: { [weak self] in self?.ingest($0) },
                 onExit: { [weak self] code, err in
                     DispatchQueue.main.async {
                         self?.isLive = false
                         self?.status = "Live stream stopped (exit \(code)). \(Self.explain(err))"
                     }
                 })
    }

    func stopLive() {
        live.stop()
        isLive = false
        status = "Live monitoring stopped."
    }

    func loadHistory(_ range: HistoryRange) {
        isLoadingHistory = true
        status = "Loading \(range.label.lowercased())…"
        var loaded = 0
        history.run(arguments: ["show", "--last", range.rawValue, "--style", "ndjson", "--info", "--debug",
                                "--predicate", LogEngine.predicate],
                    onLines: { [weak self] lines in loaded += self?.ingest(lines) ?? 0 },
                    onExit: { [weak self] code, err in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isLoadingHistory = false
                            self.status = code == 0
                                ? "Loaded \(loaded) events from \(range.label.lowercased())."
                                : "History load failed (exit \(code)). \(Self.explain(err))"
                        }
                    })
    }

    func clear() {
        pendingLock.lock(); pending.removeAll(); pendingLock.unlock()
        events.removeAll()
        selection = nil
        lastBrowser = nil
    }

    func refreshState() {
        DispatchQueue.global().async {
            let s = LogEngine.platformSSOState()
            DispatchQueue.main.async { self.ssoState = s }
        }
    }

    private static func explain(_ err: String) -> String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return "" }
        if e.lowercased().contains("admin") || e.lowercased().contains("permission") {
            return "\(e) — reading the unified log requires an administrator account."
        }
        return e
    }

    // MARK: Ingest

    @discardableResult
    private func ingest(_ lines: [Data]) -> Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        var n = 0
        for line in lines {
            if let e = LogParser.parse(line: line, id: nextID) {
                nextID += 1; n += 1
                pending.append(e)
            }
        }
        return n
    }

    private func flush() {
        pendingLock.lock()
        let batch = pending
        pending.removeAll()
        pendingLock.unlock()
        guard !batch.isEmpty else { return }

        var merged = events
        // History can arrive after live events; keep the list chronological.
        let needsSort = (merged.last?.date ?? .distantPast) > (batch.first?.date ?? .distantFuture)
        merged.append(contentsOf: batch)
        if needsSort {
            merged.sort { $0.date < $1.date }
            var seen = Set<String>()
            merged = merged.filter { seen.insert("\($0.timestamp)|\($0.pid)|\($0.message.hashValue)").inserted }
            correlate(&merged, from: 0)
        } else {
            correlate(&merged, from: merged.count - batch.count)
        }
        if merged.count > Self.maxEvents { merged.removeFirst(merged.count - Self.maxEvents) }
        events = merged
    }

    /// Ties SSO-agent/extension failures to the browser whose request immediately preceded them.
    private func correlate(_ list: inout [LogEvent], from start: Int) {
        if start == 0 { lastBrowser = nil }
        for i in start..<list.count {
            let e = list[i]
            if let b = e.browser, e.attribution == .direct {
                lastBrowser = (b, e.date)
            } else if e.outcome == .failure, let lb = lastBrowser,
                      e.date.timeIntervalSince(lb.date) >= 0,
                      e.date.timeIntervalSince(lb.date) <= Self.correlationWindow {
                list[i].browser = lb.name
                list[i].attribution = .inferred
            }
        }
    }
}
