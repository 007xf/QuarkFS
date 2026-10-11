import Foundation
import Darwin

public enum WebDAVHealth: Equatable, Sendable {
    case ready
    case waiting
    case failed(String)

    public static func isPortAvailable(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    public static func check(
        url: URL = URL(string: "http://127.0.0.1:8686/")!,
        session: URLSession
    ) async -> WebDAVHealth {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .waiting }
            return evaluate(status: http.statusCode, data: data)
        } catch { return .waiting }
    }

    public static func evaluate(status: Int, data: Data) -> WebDAVHealth {
        if status == 207 {
            let parser = XMLParser(data: data)
            let properties = WebDAVPropertiesParser()
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = properties
            if parser.parse(), properties.hasSuccessfulPropstat { return .ready }
        }
        if status == 401 || status == 403 {
            return .failed("本机连接无权读取目录，请检查登录状态或端口是否被占用")
        }
        return .failed("本机目录检查失败（HTTP \(status)），请检查登录状态或连接端口")
    }
}

/// A file name or error message can contain "200 OK". Only a complete DAV
/// multistatus document with a successful property status establishes readiness.
private final class WebDAVPropertiesParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var status = ""
    private let statusPath = ["multistatus", "response", "propstat", "status"]
    private(set) var hasSuccessfulPropstat = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]
    ) {
        path.append(namespaceURI == "DAV:" ? elementName : "")
        if path == statusPath { status = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path == statusPath { status += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        if path == statusPath {
            let parts = status.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0].hasPrefix("HTTP/"), parts[1] == "200" {
                hasSuccessfulPropstat = true
            }
        }
        path.removeLast()
    }
}
