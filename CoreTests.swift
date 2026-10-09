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
        checkDiscoveryLifecycle()
        checkClientLifetime(configuration)
        print("Core checks passed: host boundaries, certificate format, retry safety, pairing persistence, permissions and idle lifecycle.")
    }

    static func checkClientLifetime(_ configuration: PairingConfiguration) {
        weak var released: FireTVClient?
        autoreleasepool {
            let client = FireTVClient(configuration)
            released = client
        }
        require(released == nil, "Idle URLSession must not retain its client through its delegate")
        let invalidated = FireTVClient(configuration)
        invalidated.invalidate()
        var callbacks = 0
        invalidated.request("POST", "/v1/FireTV?action=home") { result in
            require(Thread.isMainThread, "Invalidated request callback stays on the main thread")
            if case .failure(let error) = result, let error = error as? CompanionError,
               case .cancelled = error { callbacks += 1 }
        }
        let deadline = Date().addingTimeInterval(1)
        while callbacks == 0 && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        require(callbacks == 1, "Invalidated clients reject commands without starting a network task")
    }

    static func checkDiscoveryLifecycle() {
        var browsers: [FixtureBrowser] = []
        var snapshots: [[DiscoveredTV]] = []
        var stopDuringPublish = false
        weak var callbackOwner: TVDiscovery?
        var discovery: TVDiscovery? = TVDiscovery(makeBrowser: {
            let browser = FixtureBrowser()
            browsers.append(browser)
            return browser
        }, callback: { values in
            snapshots.append(values)
            if stopDuringPublish { callbackOwner?.stop() }
        })
        callbackOwner = discovery
        discovery?.start()
        let firstBrowser = browsers[0]
        require(firstBrowser.searches == 1, "An active discovery starts one browser")
        let oldService = FixtureService()
        discovery?.netServiceBrowser(firstBrowser, didFind: oldService, moreComing: false)
        discovery?.netServiceDidResolveAddress(oldService)
        require(oldService.resolves == 1 && oldService.monitors == 1, "Active discovery resolves and monitors a service")
        require(snapshots.last?.count == 1, "Resolved fixture publishes one TV")
        discovery?.stop()
        let stoppedSnapshotCount = snapshots.count
        require(firstBrowser.delegate == nil && oldService.delegate == nil, "Stopped discovery detaches delegates")
        require(oldService.monitorStops == 1 && oldService.stops == 1, "Stopped discovery quiesces the TXT monitor and resolver")
        let lateService = FixtureService()
        discovery?.netServiceBrowser(firstBrowser, didFind: lateService, moreComing: false)
        discovery?.netServiceDidResolveAddress(oldService)
        discovery?.netServiceBrowser(firstBrowser, didRemove: oldService, moreComing: false)
        discovery?.netService(oldService, didUpdateTXTRecord: oldService.record)
        require(lateService.resolves == 0 && oldService.monitors == 1, "Late callbacks cannot restart network work after stop")
        require(snapshots.count == stoppedSnapshotCount, "Stop preserves the last UI snapshot and late callbacks stay silent")

        discovery?.start()
        let secondBrowser = browsers[1]
        require(secondBrowser !== firstBrowser && snapshots.last?.isEmpty == true, "Restart uses a fresh browser and cleared internal entries")
        let restartSnapshotCount = snapshots.count
        discovery?.netServiceBrowser(firstBrowser, didFind: lateService, moreComing: false)
        discovery?.netServiceBrowser(firstBrowser, didRemove: oldService, moreComing: false)
        require(lateService.resolves == 0 && snapshots.count == restartSnapshotCount, "Prior browser callbacks cannot enter a new discovery run")
        let currentService = FixtureService()
        discovery?.netServiceBrowser(secondBrowser, didFind: currentService, moreComing: false)
        discovery?.netServiceDidResolveAddress(oldService)
        require(oldService.monitors == 1, "Replaced service callbacks cannot reactivate TXT monitoring")
        discovery?.netServiceDidResolveAddress(currentService)
        require(currentService.monitors == 1 && snapshots.last?.count == 1, "Current service still publishes after restart")

        discovery?.stop()
        stopDuringPublish = true
        discovery?.start()
        require(browsers[2].searches == 0, "A stop requested by the initial callback prevents browser startup")
        weak var released = discovery
        discovery = nil
        require(released == nil, "Discovery has no browser delegate retain cycle")

        let activeBrowser = FixtureBrowser()
        let activeService = FixtureService()
        var activeDiscovery: TVDiscovery? = TVDiscovery(makeBrowser: { activeBrowser }, callback: { _ in })
        activeDiscovery?.start()
        activeDiscovery?.netServiceBrowser(activeBrowser, didFind: activeService, moreComing: false)
        activeDiscovery?.netServiceDidResolveAddress(activeService)
        weak var releasedActive = activeDiscovery
        activeDiscovery = nil
        require(releasedActive == nil, "An active browser must not retain discovery through its delegate")
        require(activeBrowser.delegate == nil && activeService.delegate == nil, "Discovery deinit detaches unsafe delegates")
        require(activeBrowser.stops == 1 && activeService.monitorStops == 1 && activeService.stops == 1,
                "Discovery deinit quiesces an active browser, monitor and resolver")
    }
}

private final class FixtureBrowser: NetServiceBrowser {
    var searches = 0
    var stops = 0
    override func searchForServices(ofType type: String, inDomain domain: String) { searches += 1 }
    override func stop() { stops += 1 }
}

private final class FixtureService: NetService {
    var resolves = 0
    var monitors = 0
    var monitorStops = 0
    var stops = 0
    let record = NetService.data(fromTXTRecord: ["model": Data("AFTFixture".utf8), "deviceid": Data("fixture-tv".utf8)])
    init() { super.init(domain: "local.", type: "_airplay._tcp.", name: "Fixture Fire TV", port: 7000) }
    override var hostName: String? { "fixture.local" }
    override var addresses: [Data]? { [] }
    override func txtRecordData() -> Data? { record }
    override func resolve(withTimeout timeout: TimeInterval) { resolves += 1 }
    override func startMonitoring() { monitors += 1 }
    override func stopMonitoring() { monitorStops += 1 }
    override func stop() { stops += 1 }
}
