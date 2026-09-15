import Foundation
import Network
import Testing
@testable import MiraProviders

private final class OperationCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var closeCount = 0
    private var started = Set<String>()
    private var stopped = Set<String>()
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var stopWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func close() { lock.lock(); closeCount += 1; lock.unlock() }
    func closeCountValue() -> Int { lock.lock(); defer { lock.unlock() }; return closeCount }
    func markStart(_ id: String) { lock.lock(); started.insert(id); let waiters = startWaiters.removeValue(forKey: id) ?? []; lock.unlock(); waiters.forEach { $0.resume() } }
    func markStop(_ id: String) { lock.lock(); stopped.insert(id); let waiters = stopWaiters.removeValue(forKey: id) ?? []; lock.unlock(); waiters.forEach { $0.resume() } }
    func hasStarted(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return started.contains(id) }
    func hasStopped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(id) }
    func waitForStart(_ id: String) async { await wait(for: id, kind: .start) }
    func waitForStop(_ id: String) async { await wait(for: id, kind: .stop) }
    private enum WaitKind { case start, stop }
    private func wait(for id: String, kind: WaitKind) async {
        if (kind == .start && hasStarted(id)) || (kind == .stop && hasStopped(id)) { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            let already = kind == .start ? started.contains(id) : stopped.contains(id)
            if already { lock.unlock(); continuation.resume(); return }
            if kind == .start { startWaiters[id, default: []].append(continuation) }
            else { stopWaiters[id, default: []].append(continuation) }
            lock.unlock()
        }
    }
}

@Suite(.serialized)
struct HTTPTransportOperationTests {
    @Test func operationCloseCoalesces() async {
        let probe = OperationCloseProbe()
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { $0.finish() }
        let operation = HTTPTransportOperation(events: stream) { probe.close() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await operation.close() } }
        }
        #expect(probe.closeCountValue() == 1)
    }

    @Test func urlSessionClosesExactStartedTaskAndDrainsCompletion() async throws {
        let probe = OperationCloseProbe(); NativeTransportURLProtocol.probe = probe
        defer { NativeTransportURLProtocol.probe = nil }
        let transport = URLSessionStreamingTransport(protocolClasses: [NativeTransportURLProtocol.self])
        var first = URLRequest(url: URL(string: "https://fixture.test/held")!); first.setValue("one", forHTTPHeaderField: "X-Test-ID")
        var second = URLRequest(url: URL(string: "https://fixture.test/held")!); second.setValue("two", forHTTPHeaderField: "X-Test-ID")
        let a = transport.stream(request: first), b = transport.stream(request: second)
        await probe.waitForStart("one"); await probe.waitForStart("two")
        async let firstClose: Void = a.close()
        async let secondClose: Void = a.close()
        _ = await (firstClose, secondClose)
        await probe.waitForStop("one")
        #expect(!probe.hasStopped("two"))
        await b.close(); await probe.waitForStop("two")
    }

    @Test func urlSessionOverflowDrainsAfterRealDataCallback() async throws {
        let probe = OperationCloseProbe(); NativeTransportURLProtocol.probe = probe
        defer { NativeTransportURLProtocol.probe = nil }
        let transport = URLSessionStreamingTransport(protocolClasses: [NativeTransportURLProtocol.self])
        var request = URLRequest(url: URL(string: "https://fixture.test/overflow")!); request.setValue("overflow", forHTTPHeaderField: "X-Test-ID")
        let operation = transport.stream(request: request)
        await probe.waitForStart("overflow")
        var sawError = false
        do { for try await _ in operation.events {} } catch { sawError = true }
        await operation.close(); await probe.waitForStop("overflow")
        #expect(sawError)
    }

    @Test(.timeLimit(.minutes(1))) func urlSessionRefusesRedirectWithoutForwardingHeaders() async throws {
        let server = try await LoopbackHTTPServer.start()
        defer { server.stop() }
        let transport = URLSessionStreamingTransport()
        var request = URLRequest(url: server.startURL)
        request.setValue("secret", forHTTPHeaderField: "Authorization")
        let operation = transport.stream(request: request)
        var status: Int?
        var ended = false
        for try await event in operation.events {
            switch event {
            case .response(let response): status = response.statusCode
            case .end: ended = true
            case .bytes: break
            }
        }
        await operation.close()
        #expect(server.startRequestCount == 1)
        #expect(status == 302)
        #expect(ended)
        #expect(server.targetRequestCount == 0)
        #expect(server.targetAuthorization == nil)
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var targetCount = 0
    private var targetAuth: String?
    private var startCount = 0
    private(set) var port: UInt16
    var startURL: URL { URL(string: "http://127.0.0.1:\(port)/start")! }
    var targetRequestCount: Int { lock.lock(); defer { lock.unlock() }; return targetCount }
    var targetAuthorization: String? { lock.lock(); defer { lock.unlock() }; return targetAuth }
    var startRequestCount: Int { lock.lock(); defer { lock.unlock() }; return startCount }

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }
    static func start() async throws -> LoopbackHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let server = LoopbackHTTPServer(listener: listener, port: 0)
        let resumeGate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.claim() else { return }
                    server.port = listener.port?.rawValue ?? 0
                    continuation.resume(returning: server)
                case .failed(let error):
                    guard resumeGate.claim() else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
            listener.start(queue: DispatchQueue(label: "mira.loopback.server"))
        }
    }
    func stop() { listener.cancel() }
    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        receiveHeader(connection, buffer: Data())
    }
    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data)
            guard buffer.count <= 64 * 1024 else { connection.cancel(); return }
            guard let marker = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receiveHeader(connection, buffer: buffer); return
            }
            guard let request = String(data: buffer[..<marker.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let first = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path == "/target" {
                let auth = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("authorization:") }).map(String.init)
                self.lock.lock(); self.targetCount += 1; self.targetAuth = auth; self.lock.unlock()
                self.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            } else if path == "/start" {
                self.lock.lock(); self.startCount += 1; self.lock.unlock()
                self.send("HTTP/1.1 302 Found\r\nLocation: /target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            } else { connection.cancel() }
        }
    }
    private func send(_ value: String, on connection: NWConnection) {
        connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
}

private final class NativeTransportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var probe: OperationCloseProbe?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? "unknown"
        Self.probe?.markStart(id)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/overflow" { client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 2_097_153)) }
        else { client?.urlProtocol(self, didLoad: Data("held".utf8)) }
    }
    override func stopLoading() {
        let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? "unknown"
        Self.probe?.markStop(id)
    }
}
