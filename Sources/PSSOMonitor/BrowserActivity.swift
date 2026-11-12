import AppKit
import Foundation

/// A browser being opened, brought forward or quit during a capture.
struct ActivityEvent {
    let date: Date
    let browser: String
    let what: String
}

/// One page visit read from a browser's history.
struct SiteVisit {
    let date: Date
    let browser: String
    let url: String     // query string and fragment removed
    let host: String
    let title: String

    private static let signInPattern = try! NSRegularExpression(
        pattern: #"log-?in|sign-?in|sso|saml|oauth|openid|adfs|auth[./]|okta|launchpad|microsoftonline|accounts\.google|idp|duosecurity|/piv|/cac|smartcard"#,
        options: [.caseInsensitive])

    var isSignInPage: Bool {
        Self.signInPattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}

/// Watches which browsers are opened and used while a capture runs.
final class BrowserWatcher {
    private(set) var events: [ActivityEvent] = []
    private var tokens: [NSObjectProtocol] = []
    private var lastActive = ""

    private func browser(_ app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        return Browsers.match(processPath: (app.bundleURL?.path ?? "") + "/", message: app.bundleIdentifier ?? "")
    }

    func start() {
        stop()
        events.removeAll()
        lastActive = ""
        for app in NSWorkspace.shared.runningApplications {
            if let b = browser(app), !events.contains(where: { $0.browser == b }) {
                events.append(ActivityEvent(date: Date(), browser: b, what: "\(b) was already open"))
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ verb: String) {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let b = self.browser(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                else { if verb == "Switched to" { self?.lastActive = "" }; return }
                if verb == "Switched to" {
                    if self.lastActive == b { return }
                    self.lastActive = b
                }
                self.events.append(ActivityEvent(date: Date(), browser: b, what: "\(verb) \(b)"))
            })
        }
        watch(NSWorkspace.didLaunchApplicationNotification, "Opened")
        watch(NSWorkspace.didActivateApplicationNotification, "Switched to")
        watch(NSWorkspace.didTerminateApplicationNotification, "Quit")
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
    }
}

/// Reads page visits for a time window from each browser's history database (copied first, never modified).
enum HistoryReader {
    static func visits(from start: Date, to end: Date) -> (visits: [SiteVisit], notes: [String]) {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var visits: [SiteVisit] = []
        var notes: [String] = []
        let s = start.timeIntervalSince1970 - 1, e = end.timeIntervalSince1970 + 1

        let chromium = [("Chrome", "Google/Chrome"), ("Edge", "Microsoft Edge"), ("Brave", "BraveSoftware/Brave-Browser"),
                        ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi")]
        for (name, dir) in chromium {
            let base = support.appendingPathComponent(dir)
            for profile in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                let db = base.appendingPathComponent(profile).appendingPathComponent("History")
                guard fm.fileExists(atPath: db.path) else { continue }
                visits += query(db, browser: name, notes: &notes, sql: """
                    SELECT (v.visit_time/1000000.0 - 11644473600) AS t, u.url AS url, u.title AS title
                    FROM visits v JOIN urls u ON u.id = v.url WHERE t >= \(s) AND t <= \(e) ORDER BY t
                    """)
            }
        }
        let ffBase = support.appendingPathComponent("Firefox/Profiles")
        for profile in (try? fm.contentsOfDirectory(atPath: ffBase.path)) ?? [] {
            let db = ffBase.appendingPathComponent(profile).appendingPathComponent("places.sqlite")
            guard fm.fileExists(atPath: db.path) else { continue }
            visits += query(db, browser: "Firefox", notes: &notes, sql: """
                SELECT h.visit_date/1000000.0 AS t, p.url AS url, p.title AS title
                FROM moz_historyvisits h JOIN moz_places p ON p.id = h.place_id WHERE t >= \(s) AND t <= \(e) ORDER BY t
                """)
        }
        let safari = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")
        if fm.isReadableFile(atPath: safari.path) {
            visits += query(safari, browser: "Safari", notes: &notes, sql: """
                SELECT (v.visit_time + 978307200) AS t, i.url AS url, v.title AS title
                FROM history_visits v JOIN history_items i ON i.id = v.history_item WHERE t >= \(s) AND t <= \(e) ORDER BY t
                """)
        } else {
            notes.append("Safari sites not included: give PSSO Monitor Full Disk Access in System Settings › Privacy & Security to read Safari history.")
        }
        notes.append("Sites come from browser history, so private/incognito windows are not included.")
        return (visits.sorted { $0.date < $1.date }, notes)
    }

    private static func query(_ db: URL, browser: String, notes: inout [String], sql: String) -> [SiteVisit] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("psso-hist-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.copyItem(at: db, to: tmp.appendingPathComponent("db"))
            // Recent visits may still be in the write-ahead log.
            let wal = URL(fileURLWithPath: db.path + "-wal")
            if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: tmp.appendingPathComponent("db-wal")) }
        } catch {
            notes.append("\(browser) sites not included: could not read its history (\(error.localizedDescription)).")
            return []
        }
        guard let out = Shell.run("/usr/bin/sqlite3", ["-json", tmp.appendingPathComponent("db").path, sql], timeout: 20),
              let rows = try? JSONSerialization.jsonObject(with: Data((out.isEmpty ? "[]" : out).utf8)) as? [[String: Any]]
        else {
            notes.append("\(browser) sites not included: its history database could not be queried.")
            return []
        }
        return rows.compactMap { r in
            guard let t = (r["t"] as? NSNumber)?.doubleValue, let raw = r["url"] as? String,
                  var c = URLComponents(string: raw), let scheme = c.scheme, scheme.hasPrefix("http"),
                  let host = c.host else { return nil }
            c.query = nil      // query strings can carry tokens; keep them out of reports
            c.fragment = nil
            return SiteVisit(date: Date(timeIntervalSince1970: t), browser: browser, url: c.string ?? raw,
                             host: host, title: r["title"] as? String ?? "")
        }
    }
}
