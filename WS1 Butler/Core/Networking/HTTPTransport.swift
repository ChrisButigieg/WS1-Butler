import Foundation

/// Abstraction over the network so the UEM client can be tested without a server.
protocol HTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, fromFile fileURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse)
}

nonisolated enum TransportError: LocalizedError, Sendable {
    case nonHTTPResponse

    var errorDescription: String? { "The server returned a non-HTTP response." }
}

/// Production transport backed by an ephemeral `URLSession`.
///
/// Security posture:
/// - Ephemeral configuration: no cookies, cache, or credentials persisted to disk.
/// - TLS 1.2 minimum; App Transport Security remains fully enabled (no exceptions).
/// - Redirects are only followed when they stay on HTTPS and the same host, so an
///   `Authorization` header can never be forwarded to a third party.
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: SameHostRedirectPolicy(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.nonHTTPResponse }
        return (data, http)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw TransportError.nonHTTPResponse }
        return (data, http)
    }
}

/// Rejects any redirect that changes scheme or host.
private nonisolated final class SameHostRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url,
              let target = request.url,
              target.scheme?.lowercased() == "https",
              original.host()?.lowercased() == target.host()?.lowercased()
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Reports upload progress for a single task.
private nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
