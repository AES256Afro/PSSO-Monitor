import Foundation

enum Shell {
    /// Runs a tool and returns its combined output, or nil if it is missing, fails to start or times out.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return timedOut ? nil : String(data: data, encoding: .utf8)
    }
}

/// The machine's sign-in conditions at one moment: smart card, VPN, network.
struct EnvironmentSnapshot {
    let date: Date
    let pivInserted: Bool
    let pivTokens: [String]
    let ciscoInstalled: Bool
    let ciscoConnected: Bool
    let otherVPN: String          // name of another connected VPN, "" if none
    let dnsDomains: [String]
    let atOffice: Bool
    let interfaces: String
    let ssoRegistered: Bool
    let ssoState: String

    var pivLabel: String { pivInserted ? "PIV inserted" : "No PIV" }

    var locationLabel: String {
        if ciscoConnected { return "Remote on Cisco VPN" }
        if atOffice { return "Office network" }
        return otherVPN.isEmpty ? "Home/remote, no VPN" : "Home/remote, no Cisco VPN (\(otherVPN) connected)"
    }

    /// e.g. "PIV inserted · Office network"
    var label: String { "\(pivLabel) · \(locationLabel)" }

    var ciscoLabel: String {
        !ciscoInstalled ? "Not installed" : (ciscoConnected ? "Connected" : "Installed, not connected")
    }
}

enum EnvironmentProbe {
    static let ciscoCLIs = ["/opt/cisco/secureclient/bin/vpn", "/opt/cisco/anyconnect/bin/vpn"]

    static func snapshot(officeDomains: [String]) -> EnvironmentSnapshot {
        // Smart cards: one line per token, e.g. "com.apple.pivtoken:0123ABCD…"
        let cards = (Shell.run("/usr/bin/security", ["list-smartcards"]) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("no smartcard") }

        // Cisco Secure Client / AnyConnect
        let cli = ciscoCLIs.first { FileManager.default.isExecutableFile(atPath: $0) }
        let ciscoOut = cli.flatMap { Shell.run($0, ["state"], timeout: 6) } ?? ""
        let ciscoConnected = ciscoOut.range(of: #"state:\s*Connected"#, options: [.regularExpression, .caseInsensitive]) != nil

        // Other VPNs known to the system, then any tunnel carrying IPv4
        var other = ""
        for line in (Shell.run("/usr/sbin/scutil", ["--nc", "list"]) ?? "").split(separator: "\n")
        where line.contains("(Connected)") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2 { other = String(parts[1]); break }
        }
        var ifaces: [String] = []
        var current = ""
        let nwi = Shell.run("/usr/sbin/scutil", ["--nwi"]) ?? ""
        for line in nwi.components(separatedBy: "IPv6 network interface").first?.split(separator: "\n") ?? [] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains(": flags"), let name = t.split(separator: " ").first { current = String(name) }
            if t.hasPrefix("address"), let addr = t.split(separator: ":").last {
                ifaces.append("\(current) \(addr.trimmingCharacters(in: .whitespaces))")
            }
        }
        if other.isEmpty && !ciscoConnected, let tun = ifaces.first(where: { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") }) {
            other = "tunnel \(tun)"
        }

        // DNS domains handed out by the network
        var domains: [String] = []
        for line in (Shell.run("/usr/sbin/scutil", ["--dns"]) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("search domain") || t.hasPrefix("domain"), let v = t.split(separator: ":").last else { continue }
            var d = v.trimmingCharacters(in: .whitespaces).lowercased()
            if d.hasSuffix(".") { d.removeLast() }
            if d.isEmpty || d == "local" || d.hasSuffix(".arpa") || domains.contains(d) { continue }
            domains.append(d)
        }
        let office = officeDomains.map { $0.lowercased() }.filter { !$0.isEmpty }
        let atOffice = !ciscoConnected && domains.contains { d in office.contains { d == $0 || d.hasSuffix("." + $0) } }

        let sso = LogEngine.platformSSOState()
        let registered = !sso.isEmpty && !sso.contains("Device Configuration:\n (null)") && !sso.hasPrefix("Could not run")

        return EnvironmentSnapshot(date: Date(), pivInserted: !cards.isEmpty, pivTokens: cards,
                                   ciscoInstalled: cli != nil, ciscoConnected: ciscoConnected, otherVPN: other,
                                   dnsDomains: domains, atOffice: atOffice, interfaces: ifaces.joined(separator: ", "),
                                   ssoRegistered: registered, ssoState: sso)
    }
}
