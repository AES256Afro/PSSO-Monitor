import Foundation

/// Runs `/usr/bin/log` and delivers its ndjson output line by line.
final class LogEngine {
    /// Everything Platform SSO / Extensible SSO logs lands in com.apple.AppSSO (PO* categories are
    /// Platform SSO). The rest picks up the IdP's own SSO extension (Entra/Company Portal, Okta, Jamf).
    static let predicate = """
    subsystem == "com.apple.AppSSO" OR subsystem == "com.apple.PlatformSSO" \
    OR process == "AppSSODaemon" \
    OR subsystem CONTAINS[c] "ssoextension" OR process CONTAINS[c] "SSO Extension" \
    OR subsystem BEGINSWITH "com.okta.mobile" OR subsystem BEGINSWITH "com.jamf.connect"
    """

    /// Sign-in capture: Platform SSO plus smart card / PIV, Authentication Services (passkeys, web
    /// sign-in sheets) and local authentication. Local authentication is very chatty, so only its
    /// PSSO, browser and error entries are taken.
    static let capturePredicate = "(" + predicate + ") "
        + #"OR subsystem CONTAINS[c] "CryptoTokenKit" OR subsystem CONTAINS[c] "smartcard" "#
        + #"OR process IN {"pivtoken", "ctkahp", "sc_auth", "com.apple.ifdreader"} "#
        + #"OR subsystem BEGINSWITH "com.apple.AuthenticationServices" "#
        + #"OR (subsystem == "com.apple.LocalAuthentication" AND (category == "PSSO" "#
        + #"OR messageType == error OR messageType == fault "#
        + #"OR process CONTAINS[c] "Safari" OR process CONTAINS[c] "Chrome" OR process CONTAINS[c] "Edge" "#
        + #"OR process CONTAINS[c] "firefox" OR process == "Arc" OR process CONTAINS[c] "Brave" "#
        + #"OR process CONTAINS[c] "Opera" OR process CONTAINS[c] "Vivaldi"))"#

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "psso.log.reader")

    var isRunning: Bool { process?.isRunning ?? false }

    /// - Parameters:
    ///   - arguments: arguments for /usr/bin/log
    ///   - onLines: called on a background queue with complete lines
    ///   - onExit: called on a background queue with exit status and stderr text
    func run(arguments: [String],
             onLines: @escaping ([Data]) -> Void,
             onExit: @escaping (Int32, String) -> Void) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer.removeAll()

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { return }
            self.queue.async {
                self.buffer.append(chunk)
                let lines = self.drainLines()
                if !lines.isEmpty { onLines(lines) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let self else { return }
            self.queue.async {
                self.buffer.append(rest)
                var lines = self.drainLines()
                if !self.buffer.isEmpty { lines.append(self.buffer); self.buffer.removeAll() }
                if !lines.isEmpty { onLines(lines) }
                onExit(proc.terminationStatus, errText)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            onExit(-1, error.localizedDescription)
        }
    }

    func stop() {
        guard let p = process else { return }
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
        process = nil
    }

    private func drainLines() -> [Data] {
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// Output of `app-sso platform -s` (device / login / user registration state).
    static func platformSSOState() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/app-sso")
        p.arguments = ["platform", "-s"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Could not run app-sso: \(error.localizedDescription)"
        }
    }
}
