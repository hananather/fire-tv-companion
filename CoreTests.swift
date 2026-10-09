import Foundation

@main
struct CoreChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
    }

    static func main() throws {
        for host in ["192.168.50.2", "10.1.2.3", "172.16.0.2", "172.31.255.1", "169.254.2.3",
                     "television.local", "TELEVISION.local.", "fd12:3456::1", "fe80::1234%en0"] {
            require(LocalTVHost.isAllowed(host), "Local TV host should be accepted")
        }
        for host in ["8.8.8.8", "127.0.0.1", "172.15.0.2", "172.32.0.2", "192.168.1.999", "224.0.0.1",
                     "example.com", "television.local.attacker.example", "user@television.local", "bad..local",
                     "television.local/path", " television.local", "::1", "2001:4860:4860::8888"] {
            require(!LocalTVHost.isAllowed(host), "Non-local or malformed TV host should be rejected")
        }
        require(CertificateFingerprint.isValid(String(repeating: "a", count: 64)), "SHA-256 fingerprint accepted")
        require(!CertificateFingerprint.isValid(String(repeating: "a", count: 63)), "Short fingerprint rejected")
        require(!CertificateFingerprint.isValid(String(repeating: "g", count: 64)), "Non-hex fingerprint rejected")
        var ipv6URL = URLComponents()
        ipv6URL.scheme = "https"
        ipv6URL.host = "[fd12:3456::1]"
        ipv6URL.port = 8080
        require(ipv6URL.url != nil, "Private IPv6 endpoint must form a URL")

        let refused = URLError(.cannotConnectToHost)
        let timeout = URLError(.timedOut)
        let lost = URLError(.networkConnectionLost)
        func recover(_ error: Error, method: String = "POST", auth: Bool = true, wake: Bool = false,
                     http: Bool = false, evidence: RequestEvidence? = nil) -> Bool {
            TransportRecovery.mayWakeAndRetry(error: error, method: method, authenticated: auth,
                wake: wake, hasHTTPResponse: http, evidence: evidence)
        }
        require(recover(refused), "Connection refusal can trigger one wake recovery")
        require(recover(timeout, evidence: RequestEvidence(requestStarted: false)), "Timeout before write can recover")
        require(!recover(timeout), "Unknown write progress must suppress timeout retry")
        require(!recover(timeout, evidence: RequestEvidence(requestStarted: true)), "Ambiguous write must not repeat")
        require(!recover(refused, evidence: RequestEvidence(requestStarted: true)), "Reported request start must suppress retry")
        require(!recover(lost, evidence: RequestEvidence(requestStarted: false)), "Connection loss must not repeat a command")
        require(!recover(refused, http: true), "HTTP response must suppress recovery")
        require(!recover(refused, auth: false), "Pairing and probes must not auto-repeat")
        require(!recover(refused, wake: true), "Wake requests must not recover recursively")
        require(!recover(timeout, method: "GET", evidence: RequestEvidence(requestStarted: true, responseStarted: true)),
                "Started response must suppress read retry")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fire-tv-core-checks-\(UUID().uuidString)")
        let location = directory.appendingPathComponent("pairing.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = try PairingConfiguration.load(from: location)
        require(missing == nil, "Missing pairing returns nil")
        let configuration = PairingConfiguration(host: "192.168.50.2", certificateSha256: String(repeating: "a", count: 64),
            token: "synthetic-test-token", deviceID: "synthetic-test-device", name: "Test TV")
        try configuration.save(to: location)
        let loaded = try PairingConfiguration.load(from: location)
        require(loaded == configuration, "Pairing round-trip preserves identity metadata")
        let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Pairing file must be owner-only")
        require((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Pairing directory must be owner-only")
        let pending = PairingConfiguration(host: configuration.host, certificateSha256: configuration.certificateSha256, token: nil)
        try pending.save(to: location)
        let loadedPending = try PairingConfiguration.load(from: location)
        require(loadedPending != nil && loadedPending?.token == nil, "Selected TV with pending pairing remains readable")
        let legacy = try JSONSerialization.data(withJSONObject: ["host": "192.168.50.2",
            "certificateSha256": String(repeating: "a", count: 64), "token": "synthetic-test-token"])
        let migrated = try JSONDecoder().decode(PairingConfiguration.self, from: legacy)
        require(migrated.deviceID == nil && migrated.name == nil, "Older pairing files remain compatible")
        print("Core checks passed: host boundaries, certificate format, retry safety, pairing persistence and permissions.")
    }
}
