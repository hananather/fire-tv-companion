import CryptoKit
import Darwin
import Foundation
import Security

struct PairingConfiguration: Codable, Equatable {
    var host: String
    var certificateSha256: String
    var token: String?
    var deviceID: String? = nil
    var name: String? = nil

    static var location: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fire TV Companion/pairing.json")
    }

    static func load(from location: URL = Self.location) throws -> PairingConfiguration? {
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        do {
            let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: location))
            try configuration.validate()
            return configuration
        } catch {
            throw CompanionError.invalidConfiguration
        }
    }

    func validate(requireCertificate: Bool = true) throws {
        guard LocalTVHost.isAllowed(host) else { throw CompanionError.hostNotLocal }
        if requireCertificate && !CertificateFingerprint.isValid(certificateSha256) {
            throw CompanionError.missingCertificate
        }
    }

    func save(to location: URL = Self.location) throws {
        try validate()
        let manager = FileManager.default
        let directory = location.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".pairing-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CompanionError.cannotSave }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try handle.write(contentsOf: encoder.encode(self))
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, location.path) == 0 else {
                throw CompanionError.cannotSave
            }
        } catch {
            try? handle.close()
            try? manager.removeItem(at: temporary)
            throw CompanionError.cannotSave
        }
    }
}

enum CompanionError: LocalizedError {
    case invalidConfiguration, cannotSave, invalidResponse, pinPending
    case hostNotLocal, missingCertificate, unpaired, identityChanged
    case tvUnavailable, connectionTimeout, connectionLost, cancelled, invalidRequest
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The saved pairing settings could not be read."
        case .cannotSave: return "The pairing settings could not be saved."
        case .invalidResponse: return "The TV returned an unexpected response."
        case .pinPending: return "The TV did not complete pairing. Show a new TV code and try again."
        case .hostNotLocal: return "Choose a TV on your local network."
        case .missingCertificate: return "Show a TV code to verify this TV before pairing."
        case .unpaired: return "Show a TV code and pair this Mac first."
        case .identityChanged: return "The TV's identity changed, so the connection was blocked. Pair again to verify the TV."
        case .tvUnavailable: return "The TV could not be reached. Check its power and Wi-Fi, then try Wake TV."
        case .connectionTimeout: return "The TV did not respond in time. Check its power and Wi-Fi."
        case .connectionLost: return "The connection was interrupted. The command was not repeated."
        case .cancelled: return "The connection was cancelled."
        case .invalidRequest: return "This TV command could not be sent."
        case .http(let code) where code == 401 || code == 403:
            return "The TV rejected this pairing. Show a new TV code to pair again."
        case .http(let code): return "The TV returned HTTP \(code)."
        }
    }
}

enum LocalTVHost {
    static func normalized(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("["), result.hasSuffix("]") { result = String(result.dropFirst().dropLast()) }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    static func isAllowed(_ value: String) -> Bool {
        let host = normalized(value)
        guard !host.isEmpty, host == value || host + "." == value || "[\(host)]" == value,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@\r\n \t")) == nil else { return false }
        if host.lowercased().hasSuffix(".local") {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            return labels.count >= 2 && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return isPrivateIPv4(bytes)
        }
        let pieces = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if pieces.count == 2 {
            guard !pieces[1].isEmpty,
                  pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return false }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, String(pieces[0]), &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isPrivateIPv4(Array(bytes.suffix(4)))
        }
        return false
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        bytes.count == 4 && (bytes[0] == 10 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 169 && bytes[1] == 254))
    }
}

enum CertificateFingerprint {
    static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func leafHash(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct RequestEvidence {
    let requestStarted: Bool
    let responseStarted: Bool

    init(requestStarted: Bool, responseStarted: Bool = false) {
        self.requestStarted = requestStarted
        self.responseStarted = responseStarted
    }

    init(metrics: URLSessionTaskMetrics) {
        requestStarted = metrics.transactionMetrics.contains {
            $0.requestStartDate != nil || $0.countOfRequestHeaderBytesSent > 0 || $0.countOfRequestBodyBytesSent > 0
        }
        responseStarted = metrics.transactionMetrics.contains {
            $0.responseStartDate != nil || $0.countOfResponseHeaderBytesReceived > 0
        }
    }
}

enum TransportRecovery {
    static func mayWakeAndRetry(error: Error, method: String, authenticated: Bool, wake: Bool,
                               hasHTTPResponse: Bool, evidence: RequestEvidence?) -> Bool {
        guard authenticated, !wake, !hasHTTPResponse,
              evidence?.responseStarted != true,
              let error = error as? URLError else { return false }
        if error.code == .cannotConnectToHost {
            return evidence?.requestStarted != true
        }
        guard error.code == .timedOut else { return false }
        if method == "GET" || method == "HEAD" { return true }
        return evidence?.requestStarted == false
    }
}

private struct NetworkOutcome {
    let result: Result<Data, Error>
    let hasHTTPResponse: Bool
    let evidence: RequestEvidence?
}

private final class TaskIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return identifier }
        set { lock.lock(); identifier = newValue; lock.unlock() }
    }
}

final class FireTVClient {
    let configuration: PairingConfiguration
    private let delegate = ClientSessionDelegate()
    private var session: URLSession!
    private let evidenceLock = NSLock()
    private var evidence: [Int: RequestEvidence] = [:]
    private var activeTasks: Set<Int> = []
    private var pinRejected = false

    init(_ configuration: PairingConfiguration) {
        self.configuration = configuration
        delegate.owner = self
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 4
        settings.timeoutIntervalForResource = 6
        settings.waitsForConnectivity = false
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    func invalidate() { session.invalidateAndCancel() }

    func request(_ method: String, _ path: String, body: [String: String]? = nil,
                 authenticated: Bool = true, wake: Bool = false,
                 completion: @escaping (Result<Data, Error>) -> Void) {
        let verb = method.uppercased()
        perform(verb, path, body: body, authenticated: authenticated, wake: wake) { [self] outcome in
            if case .failure(let error) = outcome.result,
               TransportRecovery.mayWakeAndRetry(error: error, method: verb,
                   authenticated: authenticated, wake: wake, hasHTTPResponse: outcome.hasHTTPResponse,
                   evidence: outcome.evidence) {
                self.recover(verb, path, body: body, originalError: error, completion: completion)
            } else {
                completion(outcome.result.mapError { self.cleanError($0) })
            }
        }
    }

    static func probeCertificate(host: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard LocalTVHost.isAllowed(host) else {
            DispatchQueue.main.async { completion(.failure(CompanionError.hostNotLocal)) }
            return
        }
        CertificateProbe(host: LocalTVHost.normalized(host), completion: completion).start()
    }

    private func perform(_ method: String, _ path: String, body: [String: String]? = nil,
                         authenticated: Bool, wake: Bool,
                         completion: @escaping (NetworkOutcome) -> Void) {
        let request: URLRequest
        do {
            try configuration.validate(requireCertificate: !wake)
            guard ["GET", "HEAD", "POST"].contains(method),
                  path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"),
                  !path.contains("\r"), !path.contains("\n"),
                  (!wake || (method == "POST" && path == "/apps/FireTVRemote")) else {
                throw CompanionError.invalidRequest
            }
            if authenticated && !wake, configuration.token?.isEmpty != false { throw CompanionError.unpaired }
            var components = URLComponents()
            components.scheme = wake ? "http" : "https"
            let host = LocalTVHost.normalized(configuration.host)
            components.host = host.contains(":") ? "[\(host)]" : host
            components.port = wake ? 8009 : 8080
            let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            components.path = String(pieces[0])
            if pieces.count == 2 { components.query = String(pieces[1]) }
            guard let url = components.url else { throw CompanionError.invalidRequest }
            var prepared = URLRequest(url: url)
            prepared.httpMethod = method
            prepared.setValue("0987654321", forHTTPHeaderField: "X-Api-Key")
            prepared.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if authenticated && !wake { prepared.setValue(configuration.token, forHTTPHeaderField: "X-Client-Token") }
            if let body = body { prepared.httpBody = try JSONSerialization.data(withJSONObject: body) }
            else if method == "POST" { prepared.httpBody = Data() }
            request = prepared
        } catch {
            DispatchQueue.main.async { completion(NetworkOutcome(result: .failure(error), hasHTTPResponse: false, evidence: nil)) }
            return
        }
        let identifier = TaskIdentifier()
        let task = session.dataTask(with: request) { [self] data, response, error in
            evidenceLock.lock()
            let recorded = evidence.removeValue(forKey: identifier.value)
            activeTasks.remove(identifier.value)
            let rejected = pinRejected
            evidenceLock.unlock()
            let http = response as? HTTPURLResponse
            let result: Result<Data, Error>
            if rejected && error != nil { result = .failure(CompanionError.identityChanged) }
            else if let error = error { result = .failure(error) }
            else if let http = http {
                result = (200..<300).contains(http.statusCode)
                    ? .success(data ?? Data()) : .failure(CompanionError.http(http.statusCode))
            } else { result = .failure(CompanionError.invalidResponse) }
            DispatchQueue.main.async {
                completion(NetworkOutcome(result: result, hasHTTPResponse: http != nil, evidence: recorded))
            }
        }
        identifier.value = task.taskIdentifier
        evidenceLock.lock()
        activeTasks.insert(task.taskIdentifier)
        evidenceLock.unlock()
        task.resume()
    }

    private func recover(_ method: String, _ path: String, body: [String: String]?, originalError: Error,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        perform("POST", "/apps/FireTVRemote", authenticated: false, wake: true) { [self] outcome in
            guard case .success = outcome.result else {
                completion(.failure(self.cleanError(originalError)))
                return
            }
            self.waitUntilAwake(remaining: 6) { ready in
                guard ready else { completion(.failure(self.cleanError(originalError))); return }
                self.perform(method, path, body: body, authenticated: true, wake: false) { outcome in
                    completion(outcome.result.mapError { self.cleanError($0) })
                }
            }
        }
    }

    private func waitUntilAwake(remaining: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            self.perform("GET", "/v1/FireTV", authenticated: false, wake: false) { outcome in
                if outcome.hasHTTPResponse { completion(true) }
                else if remaining > 1 {
                    if case .failure(let error) = outcome.result,
                       let error = error as? URLError, error.code == .cannotConnectToHost {
                        self.waitUntilAwake(remaining: remaining - 1, completion: completion)
                    } else { completion(false) }
                } else { completion(false) }
            }
        }
    }

    fileprivate func record(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        evidenceLock.lock()
        if activeTasks.contains(task.taskIdentifier) {
            evidence[task.taskIdentifier] = RequestEvidence(metrics: metrics)
        }
        evidenceLock.unlock()
    }

    fileprivate func checkTrust(_ challenge: URLAuthenticationChallenge,
                               completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              LocalTVHost.normalized(challenge.protectionSpace.host).caseInsensitiveCompare(
                LocalTVHost.normalized(configuration.host)) == .orderedSame,
              challenge.protectionSpace.port == 8080,
              let trust = challenge.protectionSpace.serverTrust,
              let digest = CertificateFingerprint.leafHash(trust),
              digest == configuration.certificateSha256.lowercased() else {
            evidenceLock.lock()
            pinRejected = true
            evidenceLock.unlock()
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        completion(.useCredential, URLCredential(trust: trust))
    }

    private func cleanError(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
            return CompanionError.tvUnavailable
        case .timedOut: return CompanionError.connectionTimeout
        case .networkConnectionLost: return CompanionError.connectionLost
        case .cancelled: return CompanionError.cancelled
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return CompanionError.identityChanged
        default: return CompanionError.tvUnavailable
        }
    }
}

private final class ClientSessionDelegate: NSObject, URLSessionTaskDelegate {
    weak var owner: FireTVClient?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner = owner else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        owner.checkTrust(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner = owner else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        owner.checkTrust(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        owner?.record(metrics, task: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class CertificateProbe: NSObject, URLSessionTaskDelegate {
    private let host: String
    private let completion: (Result<String, Error>) -> Void
    private var session: URLSession?
    private let lock = NSLock()
    private var finished = false

    init(host: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.host = host
        self.completion = completion
    }

    func start() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = 8080
        components.path = "/v1/FireTV"
        guard let url = components.url else { finish(.failure(CompanionError.hostNotLocal)); return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: url) { [self] _, _, error in
            let failure = (error as? URLError)?.code == .timedOut
                ? CompanionError.connectionTimeout : CompanionError.tvUnavailable
            finish(.failure(failure))
        }.resume()
    }

    private func inspect(_ challenge: URLAuthenticationChallenge,
                         completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              LocalTVHost.normalized(challenge.protectionSpace.host).caseInsensitiveCompare(host) == .orderedSame,
              challenge.protectionSpace.port == 8080,
              let trust = challenge.protectionSpace.serverTrust,
              let digest = CertificateFingerprint.leafHash(trust) else {
            completion(.cancelAuthenticationChallenge, nil)
            finish(.failure(CompanionError.invalidResponse))
            return
        }
        finish(.success(digest))
        completion(.cancelAuthenticationChallenge, nil)
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let activeSession = session
        session = nil
        lock.unlock()
        activeSession?.invalidateAndCancel()
        DispatchQueue.main.async { [completion] in completion(result) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        inspect(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        inspect(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct InstalledApp: Decodable {
    let appId: String
    let name: String
    let isInstalled: Bool
}

struct DiscoveredTV: Equatable {
    let deviceID: String
    let name: String
    let host: String
    let model: String
}

final class TVDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let callback: ([DiscoveredTV]) -> Void
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var entries: [String: DiscoveredTV] = [:]
    private var started = false

    init(callback: @escaping ([DiscoveredTV]) -> Void) {
        self.callback = callback
        super.init()
        browser.delegate = self
    }

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.start() }; return }
        guard !started else { return }
        started = true
        entries.removeAll()
        publish()
        browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
    }

    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.stop() }; return }
        browser.stop()
        services.values.forEach { $0.stopMonitoring(); $0.stop(); $0.delegate = nil }
        services.removeAll()
        started = false
    }

    private func key(_ service: NetService) -> String { "\(service.domain)|\(service.type)|\(service.name)" }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let identifier = key(service)
        services[identifier]?.stopMonitoring()
        services[identifier]?.stop()
        services[identifier] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let identifier = key(service)
        if let resolved = services.removeValue(forKey: identifier) {
            resolved.stopMonitoring()
            resolved.stop()
            resolved.delegate = nil
        }
        entries.removeValue(forKey: identifier)
        publish()
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        service.startMonitoring()
        update(service)
    }

    func netService(_ service: NetService, didUpdateTXTRecord data: Data) { update(service, txt: data) }

    private func update(_ service: NetService, txt: Data? = nil) {
        guard started, let active = services[key(service)], active === service else { return }
        guard let data = txt ?? service.txtRecordData() else { return }
        let record = NetService.dictionary(fromTXTRecord: data)
        func value(_ key: String) -> String { record[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let model = value("model")
        let manufacturer = value("manufacturer")
        guard model.uppercased().hasPrefix("AFT") || manufacturer.lowercased().contains("amazon") else { return }
        let identity = value("deviceid").uppercased()
        guard !identity.isEmpty else { return }
        var available: [String] = []
        for address in service.addresses ?? [] {
            let host: String? = address.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, address.count >= MemoryLayout<sockaddr>.size else { return nil }
                let socket = base.assumingMemoryBound(to: sockaddr.self)
                guard socket.pointee.sa_family == sa_family_t(AF_INET) || socket.pointee.sa_family == sa_family_t(AF_INET6) else { return nil }
                var output = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(socket, socklen_t(address.count), &output, socklen_t(output.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                let host = String(cString: output)
                return LocalTVHost.isAllowed(host) ? host : nil
            }
            if let host = host { available.append(host) }
        }
        let hostname = service.hostName.map(LocalTVHost.normalized)
        guard let host = available.first(where: { !$0.contains(":") }) ?? available.first ??
                hostname.flatMap({ LocalTVHost.isAllowed($0) ? $0 : nil }) else { return }
        let television = DiscoveredTV(deviceID: identity, name: service.name, host: host, model: model)
        entries[key(service)] = television
        publish()
    }

    private func publish() {
        let candidates = entries.values.sorted {
            if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
            if $0.host.contains(":") != $1.host.contains(":") { return !$0.host.contains(":") }
            return $0.host < $1.host
        }
        var seen: Set<String> = []
        let result = candidates.filter { seen.insert($0.deviceID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        callback(result)
    }
}
