import Foundation

public struct HTTPTransportResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public init(statusCode: Int, headers: [String: String] = [:]) { self.statusCode = statusCode; self.headers = headers }
}

public enum HTTPTransportEvent: Sendable, Equatable {
    case response(HTTPTransportResponse)
    case bytes(Data)
    case end
}

public struct HTTPTransportOperation: Sendable {
    public let events: AsyncThrowingStream<HTTPTransportEvent, any Error>
    private let state: OperationState
    public init(events: AsyncThrowingStream<HTTPTransportEvent, any Error>, cancelAndDrain: @escaping @Sendable () async -> Void) {
        self.events = events; self.state = OperationState(cancelAndDrain: cancelAndDrain)
    }
    public func close() async { await state.close() }
}

private final class OperationState: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAndDrain: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    init(cancelAndDrain: @escaping @Sendable () async -> Void) { self.cancelAndDrain = cancelAndDrain }
    func close() async {
        let task = beginClose()
        await task.value
    }
    private func beginClose() -> Task<Void, Never> {
        lock.lock()
        if let task { lock.unlock(); return task }
        let task = Task { await cancelAndDrain() }; self.task = task; lock.unlock(); return task
    }
}

public protocol HTTPStreamingTransport: Sendable {
    func stream(request: URLRequest) -> HTTPTransportOperation
}

public struct HTTPTransportTimeouts: Sendable, Equatable {
    public let connect: TimeInterval
    public let resource: TimeInterval
    public init(connect: TimeInterval = 15, resource: TimeInterval = 120) { self.connect = connect; self.resource = resource }
}

public final class URLSessionStreamingTransport: NSObject, HTTPStreamingTransport, @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            let continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation
            let task: URLSessionDataTask
            var drainWaiters: [CheckedContinuation<Void, Never>]
        }
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]
        func register(_ task: URLSessionDataTask, continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation) {
            lock.lock(); pending[task.taskIdentifier] = Pending(continuation: continuation, task: task, drainWaiters: []); lock.unlock()
        }
        private func get(_ id: Int) -> Pending? { lock.lock(); defer { lock.unlock() }; return pending[id] }
        func cancelAndDrain(_ id: Int) async {
            guard let task = taskForCancellation(id) else { return }
            task.cancel()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                if self.pending[id] == nil { self.lock.unlock(); continuation.resume() }
                else { self.pending[id]?.drainWaiters.append(continuation); self.lock.unlock() }
            }
        }
        private func taskForCancellation(_ id: Int) -> URLSessionDataTask? { lock.lock(); defer { lock.unlock() }; return pending[id]?.task }
        func cancelLater(_ id: Int) { Task { await cancelAndDrain(id) } }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, let item = get(dataTask.taskIdentifier) else { completionHandler(.cancel); return }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in result[String(describing: pair.key).lowercased()] = String(describing: pair.value) }
            if case .dropped = item.continuation.yield(.response(.init(statusCode: http.statusCode, headers: headers))) { item.continuation.finish(throwing: HTTPTransportOverflowError()); cancelLater(dataTask.taskIdentifier) }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let item = get(dataTask.taskIdentifier) else { return }
            guard data.count <= 2_097_152 else { item.continuation.finish(throwing: HTTPTransportOverflowError()); cancelLater(dataTask.taskIdentifier); return }
            if case .dropped = item.continuation.yield(.bytes(data)) { item.continuation.finish(throwing: HTTPTransportOverflowError()); cancelLater(dataTask.taskIdentifier) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            lock.lock(); guard let item = pending.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }; let waiters = item.drainWaiters; lock.unlock()
            if let error { item.continuation.finish(throwing: error) } else { item.continuation.yield(.end); item.continuation.finish() }
            waiters.forEach { $0.resume() }
        }
    }
    private let session: URLSession
    private let delegate: Delegate
    private let timeouts: HTTPTransportTimeouts
    public init(timeouts: HTTPTransportTimeouts = .init(), protocolClasses: [AnyClass]? = nil) {
        self.timeouts = timeouts; self.delegate = Delegate(); let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData; configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }; configuration.timeoutIntervalForRequest = timeouts.connect; configuration.timeoutIntervalForResource = timeouts.resource
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil); super.init()
    }
    public convenience init(connectTimeout: TimeInterval, resourceTimeout: TimeInterval) { self.init(timeouts: .init(connect: connectTimeout, resource: resourceTimeout)) }
    public func stream(request: URLRequest) -> HTTPTransportOperation {
        var request = request; request.timeoutInterval = timeouts.connect
        let task = session.dataTask(with: request)
        let taskID = task.taskIdentifier
        let events = AsyncThrowingStream<HTTPTransportEvent, any Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            delegate.register(task, continuation: continuation)
            continuation.onTermination = { @Sendable _ in self.delegate.cancelLater(task.taskIdentifier) }; task.resume()
        }
        return HTTPTransportOperation(events: events) { [delegate] in await delegate.cancelAndDrain(taskID) }
    }
    deinit { session.invalidateAndCancel() }
}

private struct HTTPTransportOverflowError: Error {}
