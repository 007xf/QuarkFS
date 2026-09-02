import Foundation

public struct QuarkQRCodeSession: Sendable, Equatable {
    public let requestID: String
    public let token: String
    public let scanURL: URL

    public init(requestID: String, token: String, scanURL: URL) {
        self.requestID = requestID
        self.token = token
        self.scanURL = scanURL
    }
}

public enum QuarkLoginPollResult: Sendable, Equatable {
    case waitingForScan
    case waitingForConfirmation
    case authorized(serviceTicket: String)
}

public enum QuarkLoginError: LocalizedError {
    case invalidResponse
    case provider(status: Int, message: String)
    case missingToken
    case missingServiceTicket
    case missingCookie
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "夸克登录接口返回了无法识别的数据"
        case .provider(let status, let message): "夸克登录失败（\(status)）：\(message)"
        case .missingToken: "夸克登录接口没有返回二维码令牌"
        case .missingServiceTicket: "扫码成功，但没有返回登录票据"
        case .missingCookie: "登录完成，但没有取得夸克会话信息"
        case .httpStatus(let status): "夸克登录接口返回 HTTP \(status)"
        }
    }
}

public final class QuarkLoginClient: @unchecked Sendable {
    private let storage: HTTPCookieStorage
    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/127.0.0.0 Safari/537.36"

    private let uop = URL(string: "https://uop.quark.cn")!
    private let pan = URL(string: "https://pan.quark.cn")!
    private let drive = URL(string: "https://drive-pc.quark.cn")!

    public init() {
        storage = .sharedCookieStorage(forGroupContainerIdentifier: "com.holmes.QuarkFS.Login")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
    }

    public func start() async throws -> QuarkQRCodeSession {
        let requestID = Self.randomString(length: 32)
        var components = URLComponents(
            url: uop.appendingPathComponent("cas/ajax/getTokenForQrcodeLogin"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "532"),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: requestID)
        ]
        let response: QRResponse = try await getJSON(components.url!, origin: pan)
        guard response.status == 2_000_000 else {
            throw QuarkLoginError.provider(status: response.status, message: response.message ?? "未知错误")
        }
        guard let token = response.data?.members?.token, !token.isEmpty else {
            throw QuarkLoginError.missingToken
        }

        var scan = URLComponents(string: "https://su.quark.cn/4_eMHBJ")!
        scan.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: "532"),
            URLQueryItem(name: "ssb", value: "weblogin"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "uc_biz_str", value: "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0")
        ]
        guard let scanURL = scan.url else { throw QuarkLoginError.invalidResponse }
        return QuarkQRCodeSession(requestID: requestID, token: token, scanURL: scanURL)
    }

    public func poll(_ login: QuarkQRCodeSession) async throws -> QuarkLoginPollResult {
        var components = URLComponents(
            url: uop.appendingPathComponent("cas/ajax/getServiceTicketByQrcodeToken"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "532"),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "token", value: login.token),
            URLQueryItem(name: "request_id", value: login.requestID)
        ]
        let response: QRResponse = try await getJSON(components.url!, origin: pan)
        switch response.status {
        case 50_004_001:
            return .waitingForScan
        case 50_004_002:
            return .waitingForConfirmation
        case 2_000_000:
            guard let ticket = response.data?.members?.serviceTicket, !ticket.isEmpty else {
                throw QuarkLoginError.missingServiceTicket
            }
            return .authorized(serviceTicket: ticket)
        default:
            throw QuarkLoginError.provider(status: response.status, message: response.message ?? "未知错误")
        }
    }

    public func finish(serviceTicket: String) async throws -> String {
        var account = URLComponents(
            url: pan.appendingPathComponent("account/info"),
            resolvingAgainstBaseURL: false
        )!
        account.queryItems = [
            URLQueryItem(name: "st", value: serviceTicket),
            URLQueryItem(name: "lw", value: "scan")
        ]
        let accountResponse: AccountResponse = try await getJSON(account.url!, origin: pan)
        guard accountResponse.success == true else {
            throw QuarkLoginError.provider(status: -1, message: accountResponse.message ?? "账号验证失败")
        }

        var listing = URLComponents(
            url: drive.appendingPathComponent("1/clouddrive/file/sort"),
            resolvingAgainstBaseURL: false
        )!
        listing.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "pdir_fid", value: "0"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "1")
        ]
        let _: GenericResponse = try await getJSON(listing.url!, origin: pan)

        var values: [String] = []
        var seen: Set<String> = []
        for base in [uop, pan, drive] {
            for cookie in storage.cookies(for: base) ?? [] {
                let value = "\(cookie.name)=\(cookie.value)"
                if seen.insert(value).inserted {
                    values.append(value)
                }
            }
        }
        guard !values.isEmpty else { throw QuarkLoginError.missingCookie }
        return values.sorted().joined(separator: "; ")
    }

    private func getJSON<T: Decodable>(_ url: URL, origin: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(origin.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuarkLoginError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw QuarkLoginError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}

private struct QRResponse: Decodable {
    let status: Int
    let message: String?
    let data: QRData?
}

private struct QRData: Decodable {
    let members: QRMembers?
}

private struct QRMembers: Decodable {
    let token: String?
    let serviceTicket: String?

    enum CodingKeys: String, CodingKey {
        case token
        case serviceTicket = "service_ticket"
    }
}

private struct AccountResponse: Decodable {
    let success: Bool?
    let message: String?
}

private struct GenericResponse: Decodable {
    let code: Int?
    let status: Int?
    let message: String?
}
