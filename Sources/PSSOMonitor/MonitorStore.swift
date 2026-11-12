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

enum AppTab: String, CaseIterable, Identifiable {
    case logs = "Logs"
    case capture = "Sign-in Capture"
    var id: String { rawValue }
}

/// Thread-safe holding area between the log reader and the main-thread flush.
private final class Inbox {
    private var items: [LogEvent] = []
    private let lock = NSLock()
    private var nextID = 0

    func add(_ lines: [Data], keep: (LogEvent) -> Bool = { _ in true }) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for line in lines {
            if let e = LogParser.parse(line: line, id: nextID), keep(e) {
                nextID += 1; n += 1
                items.append(e)
            }
        }
        return n
    }

    func drain() -> [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items.removeAll()
        return out
    }
}

final class MonitorStore: ObservableObject {
    @Published var tab: AppTab = .logs

    // Logs tab
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

    // Sign-in capture tab
    @Published private(set) var captureEvents: [LogEvent] = []
    @Published private(set) var attempts: [Attempt] = []
    @Published var isCapturing = false
    @Published var captureStart: Date?
    @Published var captureEnd: Date?
    @Published var captureStatus = "Not started. Press Start Capture, reproduce the sign-in, then press Stop."
    @Published var attemptSelection: Attempt.ID?
    @Published private(set) var isFinishing = false
    @Published private(set) var startEnv: EnvironmentSnapshot?
    @Published private(set) var endEnv: EnvironmentSnapshot?
    @Published private(set) var sites: [SiteRow] = []
    @Published private(set) var activity: [ActivityEvent] = []
    @Published private(set) var captureNotes: [String] = []
    /// Networks whose DNS domain ends with one of these count as "Office". Comma separated.
    @Published var officeDomains: String = UserDefaults.standard.string(forKey: "officeDomains") ?? "nasa.gov" {
        didSet { UserDefaults.standard.set(officeDomains, forKey: "officeDomains") }
    }
    @Published var now = Date()

    static let maxEvents = 50_000
    /// A failure with no browser of its own is tied to a browser whose request was seen this recently.
    static let correlationWindow: TimeInterval = 10

    private let live = LogEngine()
    private let history = LogEngine()
    private let capture = LogEngine()
    private let logInbox = Inbox()
    private let captureInbox = Inbox()
    private let watcher = BrowserWatcher()
    private var rawAttempts: [Attempt] = []
    private var flushTimer: Timer?

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

    var passCount: Int { attempts.filter { $0.result == .pass }.count }
    var failCount: Int { attempts.filter { $0.result == .fail }.count }
    var captureElapsed: TimeInterval {
        guard let s = captureStart else { return 0 }
        return (captureEnd ?? now).timeIntervalSince(s)
    }

    /// XPC plumbing every app emits just by linking AppSSO; not sign-in activity.
    static func isNoise(_ e: LogEvent) -> Bool {
        e.message.contains("new XPC connection") || e.message.hasSuffix(" on <private>")
            || e.category == "SOExtensionFinder" || e.category == "SOExtensionManager"
    }

    // MARK: Logs control

    func toggleLive() { isLive ? stopLive() : startLive() }

    func startLive() {
        isLive = true
        status = "Live — watching Platform SSO logs…"
        live.run(arguments: ["stream", "--style", "ndjson", "--level", "debug", "--predicate", LogEngine.predicate],
                 onLines: { [weak self] in _ = self?.logInbox.add($0) },
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
                    onLines: { [weak self] lines in loaded += self?.logInbox.add(lines) ?? 0 },
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
        _ = logInbox.drain()
        events.removeAll()
        selection = nil
    }

    func refreshState() {
        if isCapturing { return } // the query itself writes Platform SSO log entries
        DispatchQueue.global().async {
            let s = LogEngine.platformSSOState()
            DispatchQueue.main.async { self.ssoState = s }
        }
    }

    // MARK: Capture control

    func toggleCapture() { isCapturing ? stopCapture() : startCapture() }

    var officeDomainList: [String] {
        officeDomains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// e.g. "PIV inserted · Office network"; shows both ends if conditions changed mid-capture.
    var scenario: String {
        guard let s = startEnv else { return "" }
        if let e = endEnv, e.label != s.label { return "\(s.label) → \(e.label)" }
        return s.label
    }

    func startCapture() {
        guard !isCapturing, !isFinishing else { return }
        _ = captureInbox.drain()
        captureEvents.removeAll()
        attempts.removeAll()
        rawAttempts.removeAll()
        sites.removeAll()
        activity.removeAll()
        captureNotes.removeAll()
        attemptSelection = nil
        startEnv = nil
        endEnv = nil
        captureStart = Date()
        captureEnd = nil
        isCapturing = true
        captureStatus = "Checking PIV, VPN and network…"
        let domains = officeDomainList
        // Snapshot first: the state query writes its own Platform SSO log lines, which must not land in the capture.
        DispatchQueue.global().async {
            let env = EnvironmentProbe.snapshot(officeDomains: domains)
            DispatchQueue.main.async {
                guard self.isCapturing else { return }
                self.startEnv = env
                self.ssoState = env.ssoState
                self.captureStart = Date()
                self.watcher.start()
                self.captureStatus = "Capturing (\(env.label)) — reproduce the sign-in in your browser now."
                self.capture.run(arguments: ["stream", "--style", "ndjson", "--level", "debug",
                                             "--predicate", LogEngine.capturePredicate],
                                 onLines: { [weak self] in _ = self?.captureInbox.add($0) { !($0.outcome == .info && Self.isNoise($0)) } },
                                 onExit: { [weak self] code, err in
                                     DispatchQueue.main.async {
                                         guard let self, self.isCapturing else { return }
                                         self.stopCapture()
                                         self.captureStatus = "Capture stopped unexpectedly (exit \(code)). \(Self.explain(err))"
                                     }
                                 })
            }
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        capture.stop()
        watcher.stop()
        isCapturing = false
        captureEnd = Date()
        flush()
        activity = watcher.events
        guard let start = captureStart, let end = captureEnd, startEnv != nil else {
            captureStatus = "Capture cancelled before it started."
            return
        }
        isFinishing = true
        captureStatus = "Finishing — reading PIV/VPN state and the sites each browser visited…"
        let domains = officeDomainList
        // Browsers write history a moment after a page loads; give them time before reading it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            let env = EnvironmentProbe.snapshot(officeDomains: domains)
            let history = HistoryReader.visits(from: start, to: end)
            DispatchQueue.main.async {
                self.endEnv = env
                self.ssoState = env.ssoState
                self.captureNotes = history.notes
                var linked = self.rawAttempts
                self.sites = SiteLinker.link(&linked, visits: history.visits)
                self.attempts = linked
                self.isFinishing = false
                self.captureStatus = "Capture stopped (\(self.scenario)). \(linked.count) attempts: \(self.passCount) passed, "
                    + "\(self.failCount) failed; \(history.visits.count) site visits. Ready to export."
            }
        }
    }

    var session: CaptureSession? {
        guard let start = captureStart, let end = captureEnd, let s = startEnv, !isCapturing, !isFinishing else { return nil }
        return CaptureSession(start: start, end: end, attempts: attempts, events: captureEvents,
                              startEnv: s, endEnv: endEnv ?? s, sites: sites, activity: activity, notes: captureNotes)
    }

    private static func explain(_ err: String) -> String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return "" }
        if e.lowercased().contains("admin") || e.lowercased().contains("permission") {
            return "\(e) — reading the unified log requires an administrator account."
        }
        return e
    }

    // MARK: Flush

    private func flush() {
        if isCapturing { now = Date() }

        let batch = logInbox.drain()
        if !batch.isEmpty {
            var merged = events
            // History can arrive after live events; keep the list chronological and de-duplicated.
            let needsSort = (merged.last?.date ?? .distantPast) > (batch.first?.date ?? .distantFuture)
            merged.append(contentsOf: batch)
            if needsSort {
                merged.sort { $0.date < $1.date }
                var seen = Set<String>()
                merged = merged.filter { seen.insert("\($0.timestamp)|\($0.pid)|\($0.message.hashValue)").inserted }
            }
            if merged.count > Self.maxEvents { merged.removeFirst(merged.count - Self.maxEvents) }
            Correlator.apply(&merged, window: Self.correlationWindow)
            events = merged
        }

        let captured = captureInbox.drain()
        if !captured.isEmpty {
            var merged = captureEvents + captured
            if merged.count > Self.maxEvents { merged.removeFirst(merged.count - Self.maxEvents) }
            Correlator.apply(&merged, window: Self.correlationWindow)
            captureEvents = merged
            rawAttempts = AttemptBuilder.build(merged)
            attempts = rawAttempts
        }
    }
}
