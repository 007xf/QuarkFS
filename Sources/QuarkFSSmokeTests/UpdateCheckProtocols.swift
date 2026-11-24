import Foundation

final class UpdateStubProtocol: URLProtocol {
    enum Action {
        case response(statusCode: Int, headers: [String: String], chunks: [Data])
        case gatedStream(statusCode: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL)
        case error(Error)
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Action)?
    private static var _capturedRequests: [URLRequest] = []
    private static var _chunksSentBeforeStop = 0
    private static var _activeGate: DispatchSemaphore?

    static func configure(_ handler: @escaping (URLRequest) -> Action) {
        lock.lock()
        _handler = handler
        _capturedRequests = []
        _chunksSentBeforeStop = 0
        _activeGate = nil
        lock.unlock()
    }

    /// Releases the next chunk of an active `gatedStream` response after the
    /// client has processed the previous chunk (no timing/sleep).
    static func releaseNextChunk() {
        lock.lock()
        let gate = _activeGate
        lock.unlock()
        gate?.signal()
    }

    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    static var chunksSentBeforeStop: Int {
        lock.lock()
        defer { lock.unlock() }
        return _chunksSentBeforeStop
    }

    private let stopLock = NSLock()
    private var stopped = false
    private var instanceGate: DispatchSemaphore?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._capturedRequests.append(request)
        let handler = Self._handler
        Self.lock.unlock()

        guard let action = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        switch action {
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .redirect(let target):
            let redirectResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirectResponse)
        case .response(let statusCode, let headers, let chunks):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                stopLock.lock()
                let isStopped = stopped
                stopLock.unlock()
                if isStopped { return }
                Self.lock.lock()
                Self._chunksSentBeforeStop += 1
                Self.lock.unlock()
                client?.urlProtocol(self, didLoad: chunk)
            }
            stopLock.lock()
            let isStopped = stopped
            stopLock.unlock()
            if !isStopped {
                client?.urlProtocolDidFinishLoading(self)
            }
        case .gatedStream(let statusCode, let headers, let chunks):
            let gate = DispatchSemaphore(value: 0)
            stopLock.lock()
            instanceGate = gate
            stopLock.unlock()
            Self.lock.lock()
            Self._activeGate = gate
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                for chunk in chunks {
                    self.stopLock.lock()
                    let isStopped = self.stopped
                    self.stopLock.unlock()
                    if isStopped { return }
                    Self.lock.lock()
                    Self._chunksSentBeforeStop += 1
                    Self.lock.unlock()
                    self.client?.urlProtocol(self, didLoad: chunk)
                    gate.wait()
                }
                self.stopLock.lock()
                let isStopped = self.stopped
                self.stopLock.unlock()
                if !isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        let gate = instanceGate
        stopLock.unlock()
        gate?.signal()
    }
}
