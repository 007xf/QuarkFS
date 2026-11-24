import Foundation

/// SemVer precedence for QuarkFS releases. A leading `v` is accepted, missing
/// trailing numeric components count as zero, pre-release identifiers follow
/// SemVer precedence rules, and build metadata is ignored for precedence.
public struct ReleaseVersion: Comparable, Sendable {
    public let display: String
    private let numbers: [UInt64]
    private let prerelease: [String]?

    public init?(_ tag: String) {
        guard tag.utf8.count <= 128 else { return nil }
        let display = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !display.isEmpty else { return nil }

        let build = display.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let withoutBuild = build.first,
              build.count == 1 || Self.identifiers(build[1], allowLeadingZeroNumeric: true) != nil else {
            return nil
        }

        let release = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = release.first else { return nil }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [UInt64] = []
        numbers.reserveCapacity(components.count)
        for component in components {
            guard Self.isValidNumericIdentifier(component), let value = UInt64(component) else {
                return nil
            }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        while numbers.count > 1 && numbers.last == 0 {
            numbers.removeLast()
        }

        let prerelease: [String]?
        if release.count == 2 {
            guard let parsed = Self.identifiers(release[1], allowLeadingZeroNumeric: false) else { return nil }
            prerelease = parsed
        } else {
            prerelease = nil
        }

        self.display = display
        self.numbers = numbers
        self.prerelease = prerelease
    }

    /// The version string without build metadata, which never affects precedence.
    public var withoutBuildMetadata: String {
        String(display.split(separator: "+", maxSplits: 1).first ?? "")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers {
            return lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
        }
        guard let left = lhs.prerelease else { return false }
        guard let right = rhs.prerelease else { return true }
        return left.lexicographicallyPrecedes(right, by: Self.identifierPrecedes)
    }

    private static func identifiers(_ text: Substring, allowLeadingZeroNumeric: Bool) -> [String]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            guard !part.isEmpty, part.utf8.allSatisfy({ byte in
                byte == 45
                    || (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
            }) else {
                return false
            }
            if !allowLeadingZeroNumeric, isNumeric(part), part.count > 1, part.first == "0" {
                return false
            }
            return true
        }) else {
            return nil
        }
        return parts.map(String.init)
    }

    private static func isValidNumericIdentifier<S: StringProtocol>(_ text: S) -> Bool {
        isNumeric(text) && !(text.count > 1 && text.first == "0")
    }

    private static func isNumeric<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func identifierPrecedes(_ left: String, _ right: String) -> Bool {
        let leftNumeric = isNumeric(left)
        let rightNumeric = isNumeric(right)
        if leftNumeric && rightNumeric {
            let leftDigits = left.drop(while: { $0 == "0" })
            let rightDigits = right.drop(while: { $0 == "0" })
            if leftDigits.count != rightDigits.count {
                return leftDigits.count < rightDigits.count
            }
            return leftDigits < rightDigits
        }
        if leftNumeric != rightNumeric {
            return leftNumeric
        }
        return left < right
    }
}

/// Persistent update-check timestamps, announcement state, and last known
/// newer release stored separately from `AppSettings`.
public struct UpdateRecord: Codable, Equatable, Sendable {
    public struct KnownRelease: Codable, Equatable, Sendable {
        public var version: String
        public var pageURL: String
        public var publishedAt: Date

        public init(version: String, pageURL: String, publishedAt: Date) {
            self.version = version
            self.pageURL = pageURL
            self.publishedAt = publishedAt
        }
    }

    public var lastCheck: Date?
    public var lastAnnouncedVersion: String?
    public var latestKnownRelease: KnownRelease?
    public var lastOfflineAutomaticAttempt: Date?
    public var offlineAutomaticRetryCount: Int

    public init(
        lastCheck: Date? = nil,
        lastAnnouncedVersion: String? = nil,
        latestKnownRelease: KnownRelease? = nil,
        lastOfflineAutomaticAttempt: Date? = nil,
        offlineAutomaticRetryCount: Int = 0
    ) {
        self.lastCheck = lastCheck
        self.lastAnnouncedVersion = lastAnnouncedVersion
        self.latestKnownRelease = latestKnownRelease
        self.lastOfflineAutomaticAttempt = lastOfflineAutomaticAttempt
        self.offlineAutomaticRetryCount = offlineAutomaticRetryCount
    }

    private enum CodingKeys: String, CodingKey {
        case lastCheck, lastAnnouncedVersion, latestKnownRelease, lastOfflineAutomaticAttempt, offlineAutomaticRetryCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastCheck: try values.decodeIfPresent(Date.self, forKey: .lastCheck),
            lastAnnouncedVersion: try values.decodeIfPresent(String.self, forKey: .lastAnnouncedVersion),
            latestKnownRelease: try values.decodeIfPresent(KnownRelease.self, forKey: .latestKnownRelease),
            lastOfflineAutomaticAttempt: try values.decodeIfPresent(Date.self, forKey: .lastOfflineAutomaticAttempt),
            offlineAutomaticRetryCount: max(0, try values.decodeIfPresent(Int.self, forKey: .offlineAutomaticRetryCount) ?? 0)
        )
    }
}

/// Checks GitHub's public latest-release feed for QuarkFS and reports whether a
/// newer version exists. Never downloads or installs an update.
@MainActor
public final class UpdateChecker {
    public struct Release: Equatable, Sendable {
        public var version: String { parsedVersion.display }
        public let pageURL: URL
        public let publishedAt: Date
        /// The beginning of the release notes as sanitized plain text.
        public let notes: String
        public let parsedVersion: ReleaseVersion

        public init(parsedVersion: ReleaseVersion, pageURL: URL, publishedAt: Date, notes: String) {
            self.parsedVersion = parsedVersion
            self.pageURL = pageURL
            self.publishedAt = publishedAt
            self.notes = notes
        }

        public init?(version: String, pageURL: URL, publishedAt: Date, notes: String) {
            guard let parsed = ReleaseVersion(version) else { return nil }
            self.init(parsedVersion: parsed, pageURL: pageURL, publishedAt: publishedAt, notes: notes)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case offline
        case rateLimited
        case noPublicRelease
        case repositoryUnavailable
        case invalidResponse
        case responseTooLarge
        case invalidRunningVersion

        public var message: String {
            switch self {
            case .offline: "网络连接失败"
            case .rateLimited: "更新检查请求过于频繁，请稍后再试"
            case .noPublicRelease: "未找到 QuarkFS 的公开发行版"
            case .repositoryUnavailable: "暂时无法访问 QuarkFS 的发行仓库"
            case .invalidResponse: "服务器返回了无法识别的响应"
            case .responseTooLarge: "下载内容超过允许的大小"
            case .invalidRunningVersion: "无法识别当前 QuarkFS 的版本"
            }
        }
    }

    public enum Result: Equatable, Sendable {
        case upToDate
        case newerAvailable(Release)
        case couldNotCheck(Failure)

        public var message: String {
            switch self {
            case .upToDate: "已是最新版本"
            case .newerAvailable(let release): "发现新版本 \(release.version)"
            case .couldNotCheck(let failure): failure.message
            }
        }
    }

    public struct Schedule: Equatable, Sendable {
        public var automaticEnabled: Bool
        public var lastCheck: Date?
        public var lastAnnouncedVersion: String?
        public var lastOfflineAutomaticAttempt: Date?
        public var offlineAutomaticRetryCount: Int

        public init(
            automaticEnabled: Bool,
            lastCheck: Date?,
            lastAnnouncedVersion: String?,
            lastOfflineAutomaticAttempt: Date? = nil,
            offlineAutomaticRetryCount: Int = 0
        ) {
            self.automaticEnabled = automaticEnabled
            self.lastCheck = lastCheck
            self.lastAnnouncedVersion = lastAnnouncedVersion
            self.lastOfflineAutomaticAttempt = lastOfflineAutomaticAttempt
            self.offlineAutomaticRetryCount = offlineAutomaticRetryCount
        }
    }

    public struct HTTPResponse: Sendable {
        public let statusCode: Int
        public var data: Data
        public var remainingRateLimit: String?
        public var retryAfter: String?

        public init(
            statusCode: Int,
            data: Data = Data(),
            remainingRateLimit: String? = nil,
            retryAfter: String? = nil
        ) {
            self.statusCode = statusCode
            self.data = data
            self.remainingRateLimit = remainingRateLimit
            self.retryAfter = retryAfter
        }
    }

    public typealias Transport = @Sendable (URLRequest, Int) async throws -> HTTPResponse

    public nonisolated static let endpoint = URL(string: "https://api.github.com/repos/007xf/QuarkFS/releases/latest")!
    public nonisolated static let maximumResponseBytes = 256 * 1024
    public nonisolated static let maximumNotesScalars = 1_200
    public nonisolated static let maximumReleasePageBytes = 2_048
    public nonisolated static let requestTimeout: TimeInterval = 15
    public nonisolated static let resourceTimeout: TimeInterval = 30
    public nonisolated static let automaticInterval: TimeInterval = 24 * 60 * 60
    public nonisolated static let automaticOfflineRetryInterval: TimeInterval = 60 * 60
    public nonisolated static let maximumAutomaticOfflineRetries = 3

    private nonisolated static let liveConstructionCounter = LockedCounter()
    private nonisolated static let liveCallCounter = LockedCounter()

    /// Counts constructions of `liveTransport()`, allowing offline tests to
    /// fail immediately if any test constructs a model with the live transport.
    public nonisolated static var liveTransportConstructionCount: Int {
        liveConstructionCounter.value
    }

    /// Counts invocations of `liveTransport()`, allowing offline tests to prove
    /// no live update request left the process.
    public nonisolated static var liveTransportCallCount: Int {
        liveCallCounter.value
    }

    public private(set) var isChecking = false
    public private(set) var pendingAutomaticNotice: Release?

    private let runningVersion: ReleaseVersion?
    private let readSchedule: () -> Schedule
    private let recordCheck: (Date) -> Void
    private let recordOfflineAutomaticAttempt: ((Date, Int) -> Void)?
    private let recordAnnouncement: (String) -> Void
    private let clock: () -> Date
    private let onCheckingChanged: ((Bool) -> Void)?
    private let onCheckFinished: ((Result) -> Void)?
    private let transport: Transport
    private var inFlight: Task<Result, Never>?

    public init(
        runningVersion: String?,
        readSchedule: @escaping () -> Schedule,
        recordCheck: @escaping (Date) -> Void,
        recordOfflineAutomaticAttempt: ((Date, Int) -> Void)? = nil,
        recordAnnouncement: @escaping (String) -> Void,
        clock: @escaping () -> Date = { Date() },
        onCheckingChanged: ((Bool) -> Void)? = nil,
        onCheckFinished: ((Result) -> Void)? = nil,
        transport: @escaping Transport
    ) {
        self.runningVersion = runningVersion.flatMap(ReleaseVersion.init)
        self.readSchedule = readSchedule
        self.recordCheck = recordCheck
        self.recordOfflineAutomaticAttempt = recordOfflineAutomaticAttempt
        self.recordAnnouncement = recordAnnouncement
        self.clock = clock
        self.onCheckingChanged = onCheckingChanged
        self.onCheckFinished = onCheckFinished
        self.transport = transport
    }

    /// Manual checks ignore the automatic switch and the 24-hour interval. A
    /// check already in flight is shared with the caller.
    public func checkManually() async -> Result {
        let now = clock()
        let joinedInFlight = inFlight != nil
        let result = await check(at: now, isAutomatic: false)
        if joinedInFlight, case .couldNotCheck(.offline) = result {
            // Even when joining an in-flight automatic offline failure, a manual
            // check always starts the 24-hour automatic interval.
            recordCheck(now)
        }
        if case .newerAvailable(let release) = result {
            if isUnannounced(release, lastVersion: readSchedule().lastAnnouncedVersion) {
                recordAnnouncement(release.parsedVersion.withoutBuildMetadata)
            }
            if let pending = pendingAutomaticNotice, !(release.parsedVersion < pending.parsedVersion) {
                pendingAutomaticNotice = nil
            }
        }
        return result
    }

    /// Runs an automatic check when the switch is enabled and due.
    /// A `lastCheck` in the future (from a wrong clock) is treated as due.
    /// Offline automatic failures retry at most `maximumAutomaticOfflineRetries`
    /// times per cycle, spaced by at least `automaticOfflineRetryInterval` (1 h),
    /// before starting the 24-hour interval. Returns `nil` when skipped.
    @discardableResult
    public func checkAutomaticallyIfDue() async -> Result? {
        guard inFlight == nil else { return nil }
        let schedule = readSchedule()
        guard schedule.automaticEnabled else { return nil }
        let now = clock()
        if let lastCheck = schedule.lastCheck,
           lastCheck <= now,
           now.timeIntervalSince(lastCheck) < Self.automaticInterval {
            return nil
        }
        if let lastOffline = schedule.lastOfflineAutomaticAttempt,
           lastOffline <= now,
           now.timeIntervalSince(lastOffline) < Self.automaticOfflineRetryInterval {
            return nil
        }
        let result = await check(at: now, isAutomatic: true)
        guard case .newerAvailable(let release) = result else { return result }
        let current = readSchedule()
        if current.automaticEnabled,
           isUnannounced(release, lastVersion: current.lastAnnouncedVersion),
           pendingAutomaticNotice.map({ $0.parsedVersion < release.parsedVersion }) ?? true {
            pendingAutomaticNotice = release
        }
        return result
    }

    /// Consumes a pending automatic notice and records the version as announced.
    public func takeAutomaticNotice() -> Release? {
        guard let release = pendingAutomaticNotice else { return nil }
        pendingAutomaticNotice = nil
        guard isUnannounced(release, lastVersion: readSchedule().lastAnnouncedVersion) else { return nil }
        recordAnnouncement(release.parsedVersion.withoutBuildMetadata)
        return release
    }

    /// Marks a version as announced (for example if dismissed directly).
    public func markAnnounced(_ release: Release) {
        if isUnannounced(release, lastVersion: readSchedule().lastAnnouncedVersion) {
            recordAnnouncement(release.parsedVersion.withoutBuildMetadata)
        }
        if let pending = pendingAutomaticNotice, !(release.parsedVersion < pending.parsedVersion) {
            pendingAutomaticNotice = nil
        }
    }

    private func isUnannounced(_ release: Release, lastVersion: String?) -> Bool {
        guard let lastVersion = lastVersion.flatMap(ReleaseVersion.init) else { return true }
        return lastVersion < release.parsedVersion
    }

    private func check(at date: Date, isAutomatic: Bool) async -> Result {
        if let inFlight { return await inFlight.value }
        if !isAutomatic {
            recordCheck(date)
        }
        guard let runningVersion else {
            if isAutomatic { recordCheck(date) }
            let result: Result = .couldNotCheck(.invalidRunningVersion)
            onCheckFinished?(result)
            return result
        }
        let transport = self.transport
        let task = Task { await Self.fetch(runningVersion: runningVersion, transport: transport) }
        inFlight = task
        isChecking = true
        onCheckingChanged?(true)
        let result = await task.value
        inFlight = nil
        isChecking = false
        onCheckingChanged?(false)
        if isAutomatic {
            if case .couldNotCheck(.offline) = result {
                let nextRetry = readSchedule().offlineAutomaticRetryCount + 1
                if nextRetry < Self.maximumAutomaticOfflineRetries, let recordOfflineAutomaticAttempt {
                    recordOfflineAutomaticAttempt(date, nextRetry)
                } else {
                    recordCheck(date)
                }
            } else {
                recordCheck(date)
            }
        }
        onCheckFinished?(result)
        return result
    }

    /// Builds the live ephemeral, hardened HTTP transport. Only the real
    /// application entry point should call this.
    public nonisolated static func liveTransport() -> Transport {
        liveConstructionCounter.increment()
        let hardened = hardenedConfiguration(from: .ephemeral)
        return { request, maximumBytes in
            liveCallCounter.increment()
            let transfer = BoundedUpdateTransfer(configuration: hardened, maximumBytes: maximumBytes)
            return try await transfer.run(request)
        }
    }

    /// Builds the same hardened bounded HTTP transport on top of a caller-supplied
    /// `URLSessionConfiguration` (for offline `URLProtocol` tests).
    public nonisolated static func transport(
        configuration baseConfiguration: URLSessionConfiguration,
        onChunkAccepted: (@Sendable () -> Void)? = nil
    ) -> Transport {
        let hardened = hardenedConfiguration(from: baseConfiguration)
        return { request, maximumBytes in
            let transfer = BoundedUpdateTransfer(
                configuration: hardened,
                maximumBytes: maximumBytes,
                onChunkAccepted: onChunkAccepted
            )
            return try await transfer.run(request)
        }
    }

    public nonisolated static func hardenedConfiguration(
        from base: URLSessionConfiguration = .ephemeral
    ) -> URLSessionConfiguration {
        let config = base.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return config
    }

    private nonisolated static func fetch(
        runningVersion: ReleaseVersion,
        transport: Transport
    ) async -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = requestTimeout
        request.setValue("QuarkFS/\(runningVersion.display)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")

        do {
            let response = try await transport(request, maximumResponseBytes)
            switch response.statusCode {
            case 404:
                return .couldNotCheck(.noPublicRelease)
            case 429:
                return .couldNotCheck(.rateLimited)
            case 403 where response.remainingRateLimit?.trimmingCharacters(in: .whitespaces) == "0"
                || response.retryAfter != nil:
                return .couldNotCheck(.rateLimited)
            case 200:
                let release = try parseRelease(response.data)
                return runningVersion < release.parsedVersion ? .newerAvailable(release) : .upToDate
            default:
                return .couldNotCheck(.repositoryUnavailable)
            }
        } catch let failure as Failure {
            return .couldNotCheck(failure)
        } catch {
            return .couldNotCheck(.offline)
        }
    }

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let published_at: Date
        let body: String?
    }

    public nonisolated static func parseRelease(_ data: Data) throws -> Release {
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              let version = ReleaseVersion(payload.tag_name),
              let pageURL = validateReleasePage(payload.html_url) else {
            throw Failure.invalidResponse
        }
        return Release(
            parsedVersion: version,
            pageURL: pageURL,
            publishedAt: payload.published_at,
            notes: cleanNotes(payload.body)
        )
    }

    /// Keeps at most 1200 Unicode scalars from the beginning of the notes and
    /// strips control characters other than newline and tab.
    public nonisolated static func cleanNotes(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        var result = ""
        for scalar in body.unicodeScalars.prefix(maximumNotesScalars) {
            if !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t" {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Accepts only `https://github.com/007xf/QuarkFS` or a clean path beneath
    /// it, with no credentials, port, empty port, query, fragment, empty path
    /// segment, traversal, percent-encoded host, or control chars, up to 2048 bytes.
    public nonisolated static func validateReleasePage(_ address: String) -> URL? {
        guard address.utf8.count <= maximumReleasePageBytes,
              let url = URL(string: address, encodingInvalidCharacters: false),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.user == nil,
              parts.password == nil,
              parts.port == nil,
              parts.query == nil,
              parts.fragment == nil else {
            return nil
        }

        // Compare the raw authority directly so percent-encoded hosts (e.g.
        // `git%68ub.com`) and empty ports (`github.com:`) are refused.
        let afterScheme = address.dropFirst("https://".count)
        let rawAuthority = afterScheme.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard rawAuthority.lowercased() == "github.com",
              parts.percentEncodedHost?.lowercased() == "github.com" else {
            return nil
        }

        let encodedPath = parts.percentEncodedPath
        let lowerPath = encodedPath.lowercased()
        let repository = "/007xf/quarkfs"
        guard lowerPath == repository || lowerPath.hasPrefix(repository + "/") else {
            return nil
        }

        let segments = encodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        for component in segments {
            guard let decoded = component.removingPercentEncoding,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.contains("%"),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return nil
            }
        }
        return url
    }
}

/// Thread-safe counter for tracking live transport invocations in offline tests.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// One bounded, ephemeral, redirect-refusing HTTP GET transfer used by
/// `UpdateChecker.liveTransport`.
private final class BoundedUpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let onChunkAccepted: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UpdateChecker.HTTPResponse, Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var received = 0
    private var cancelled = false

    init(
        configuration: URLSessionConfiguration,
        maximumBytes: Int,
        onChunkAccepted: (@Sendable () -> Void)? = nil
    ) {
        self.configuration = configuration
        self.maximumBytes = max(1, maximumBytes)
        self.onChunkAccepted = onChunkAccepted
    }

    func run(_ request: URLRequest) async throws -> UpdateChecker.HTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Swift.Result<UpdateChecker.HTTPResponse, Error>) {
        lock.lock()
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        lock.unlock()
        guard let continuation else { return }
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(UpdateChecker.Failure.repositoryUnavailable))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(UpdateChecker.Failure.invalidResponse))
            return
        }
        if !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.success(UpdateChecker.HTTPResponse(
                statusCode: http.statusCode,
                data: Data(),
                remainingRateLimit: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )))
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(UpdateChecker.Failure.responseTooLarge))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        guard chunk.count <= maximumBytes - received else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(UpdateChecker.Failure.responseTooLarge))
            return
        }
        received += chunk.count
        data.append(chunk)
        lock.unlock()
        onChunkAccepted?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(UpdateChecker.Failure.offline))
            }
            return
        }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        guard let response else {
            finish(.failure(UpdateChecker.Failure.invalidResponse))
            return
        }
        finish(.success(UpdateChecker.HTTPResponse(
            statusCode: response.statusCode,
            data: data,
            remainingRateLimit: response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )))
    }
}
