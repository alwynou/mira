import Foundation

/// The response metadata and byte stream exposed by an HTTP transport.
public struct HTTPTransportResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Events emitted by ``HTTPStreamingTransport``. A transport must emit `.end`
/// for a successful HTTP response; merely ending the AsyncSequence is an EOF.
public enum HTTPTransportEvent: Sendable, Equatable {
    case response(HTTPTransportResponse)
    case bytes(Data)
    case end
}

/// Injectable transport boundary used by provider adapters and deterministic tests.
public protocol HTTPStreamingTransport: Sendable {
    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error>
}

/// Optional per-request cancellation hook used when a protocol terminal arrives
/// before the HTTP peer closes its socket.
public protocol HTTPStreamingTransportCancellation: HTTPStreamingTransport {
    func cancel(request: URLRequest)
}

public struct HTTPTransportTimeouts: Sendable, Equatable {
    public let connect: TimeInterval
    public let resource: TimeInterval

    public init(connect: TimeInterval = 15, resource: TimeInterval = 120) {
        self.connect = connect
        self.resource = resource
    }
}

/// Foundation URLSession transport. It uses an ephemeral session and declines
/// every redirect, so credentials cannot be forwarded to another origin.
public final class URLSessionStreamingTransport: NSObject, HTTPStreamingTransportCancellation, @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            let continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation
            let response: URLSessionDataTask
            let request: URLRequest
        }

        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(_ task: URLSessionDataTask, continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation) {
            lock.lock()
            pending[task.taskIdentifier] = Pending(continuation: continuation, response: task, request: task.originalRequest ?? task.currentRequest ?? URLRequest(url: URL(string: "about:blank")!))
            lock.unlock()
        }

        private func remove(_ id: Int) -> Pending? {
            lock.lock()
            defer { lock.unlock() }
            return pending.removeValue(forKey: id)
        }

        private func get(_ id: Int) -> Pending? {
            lock.lock()
            defer { lock.unlock() }
            return pending[id]
        }

        func cancel(_ id: Int) {
            _ = remove(id)
        }

        func cancel(request: URLRequest) {
            guard let requestID = request.value(forHTTPHeaderField: "X-Mira-Request-ID"), !requestID.isEmpty else { return }
            lock.lock()
            let tasks = pending.values.filter {
                $0.request.url == request.url &&
                $0.request.httpMethod == request.httpMethod &&
                $0.request.value(forHTTPHeaderField: "X-Mira-Request-ID") == requestID
            }.map(\.response)
            lock.unlock()
            tasks.forEach { $0.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Never follow redirects. In particular, this prevents an API key
            // header from being sent to a host outside the frozen route.
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, let item = get(dataTask.taskIdentifier) else {
                completionHandler(.cancel)
                return
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
            }
            if case .dropped = item.continuation.yield(.response(HTTPTransportResponse(statusCode: http.statusCode, headers: headers))) {
                item.continuation.finish(throwing: HTTPTransportOverflowError())
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let item = get(dataTask.taskIdentifier) else { return }
            guard data.count <= 2_097_152 else {
                item.continuation.finish(throwing: HTTPTransportOverflowError())
                return
            }
            if case .dropped = item.continuation.yield(.bytes(data)) {
                item.continuation.finish(throwing: HTTPTransportOverflowError())
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let item = remove(task.taskIdentifier) else { return }
            if let error {
                item.continuation.finish(throwing: error)
            } else {
                item.continuation.yield(.end)
                item.continuation.finish()
            }
        }
    }

    private let session: URLSession
    private let delegate: Delegate
    private let timeouts: HTTPTransportTimeouts

    public init(timeouts: HTTPTransportTimeouts = HTTPTransportTimeouts(), protocolClasses: [AnyClass]? = nil) {
        self.timeouts = timeouts
        self.delegate = Delegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.timeoutIntervalForRequest = timeouts.connect
        configuration.timeoutIntervalForResource = timeouts.resource
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    public convenience init(connectTimeout: TimeInterval, resourceTimeout: TimeInterval) {
        self.init(timeouts: HTTPTransportTimeouts(connect: connectTimeout, resource: resourceTimeout))
    }

    public func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        var request = request
        // URLRequest controls the bounded idle/request interval; the session
        // configuration separately bounds the complete resource lifetime.
        request.timeoutInterval = timeouts.connect
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = session.dataTask(with: request)
            delegate.register(task, continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                self.delegate.cancel(task.taskIdentifier)
            }
            task.resume()
        }
        return stream
    }

    public func cancel(request: URLRequest) {
        delegate.cancel(request: request)
    }
}

// Convenient names for clients that prefer the shorter terminology.
public typealias HTTPResponse = HTTPTransportResponse
public typealias HTTPStreamEvent = HTTPTransportEvent

private struct HTTPTransportOverflowError: Error {}
