#if os(macOS)
import Foundation
import KumoneCore

/// Adapts upstream #115's host policy to APlay's URLSession transport.
/// The outer request/cache identity remains unchanged. Every retry preserves
/// Range, query signature and headers; after any response the existing APlay
/// reconnect/resume logic owns recovery, never a second copy of audio bytes.
class NeteaseCDNRetryProtocol: URLProtocol, @unchecked Sendable {
    // Synchronous Foundation callbacks and stopLoading may arrive concurrently.
    // All mutable state and client emissions are serialized by this recursive
    // lock (client cancellation can reenter). No async suspension under lock.
    private let lock = NSRecursiveLock()
    private var session: URLSession?
    private var activeTask: URLSessionDataTask?
    private var stopped = false
    private var receivedResponse = false
    private var retried = false
    private var activeURL: URL?
    // Per-instance seam for deterministic transport tests, set before start.
    var transportConfiguration = URLSessionConfiguration.default

    deinit { session?.invalidateAndCancel() }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [Self.self] + (config.protocolClasses ?? [])
        config.urlCache = nil // APlay owns the bounded song cache, not URLCache.
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return NeteaseCDNHost.alternate(for: url) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let url = request.url else { return }
        let config = transportConfiguration.copy() as! URLSessionConfiguration
        // Inner transport must never recursively select this protocol.
        config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != Self.self }
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // URLSession can retain its delegate past cancellation. It must never
        // retain this request owner (the same lifecycle trap fixed in APlay).
        session = URLSession(configuration: config, delegate: WeakCDNDelegate(owner: self), delegateQueue: queue)
        begin(url: NeteaseCDNHost.preferred(for: url))
    }

    private func begin(url: URL) {
        var copy = request
        copy.url = url
        if copy.value(forHTTPHeaderField: "Host") != nil { copy.setValue(url.host, forHTTPHeaderField: "Host") }
        activeURL = url
        receivedResponse = false
        activeTask = session?.dataTask(with: copy)
        activeTask?.resume()
    }

    override func stopLoading() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        activeTask?.cancel()
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, dataTask === activeTask else { completionHandler(.cancel); return }
        receivedResponse = true
        if let url = activeURL { NeteaseCDNHost.markReachable(url) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(stopped ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, dataTask === activeTask else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task redirected: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, redirected === activeTask else { completionHandler(nil); return }
        // A redirect proves the original host answered. A later failure of
        // its target must not poison the original CDN host's reachability.
        receivedResponse = true
        if let url = activeURL { NeteaseCDNHost.markReachable(url) }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, task completed: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, completed === activeTask else { return }
        if let error, !receivedResponse, let url = activeURL {
            let twin = NeteaseCDNHost.failover(from: url, after: error)
            if !retried, let twin {
                retried = true
                KumoneLogger.player.notice("CDN retry host=\(url.host ?? "", privacy: .public) twin=\(twin.host ?? "", privacy: .public) range=\(self.request.value(forHTTPHeaderField: "Range") ?? "none", privacy: .public)")
                begin(url: twin)
                return
            }
        }
        // Break URLSession -> delegate ownership on every terminal path.
        stopped = true
        self.activeTask = nil
        self.session = nil
        session.finishTasksAndInvalidate()
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
}

/// Owner assigned once before task creation; weak ARC access is thread-safe.
/// The owner's lock protects all state and client callbacks, not this bridge.
private final class WeakCDNDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var owner: NeteaseCDNRetryProtocol?
    init(owner: NeteaseCDNRetryProtocol) { self.owner = owner }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner else { completionHandler(.cancel); return }
        owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.urlSession(session, task: task, didCompleteWithError: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let owner else { completionHandler(nil); return }
        owner.urlSession(session, task: task, willPerformHTTPRedirection: response,
                         newRequest: request, completionHandler: completionHandler)
    }
}
#endif
