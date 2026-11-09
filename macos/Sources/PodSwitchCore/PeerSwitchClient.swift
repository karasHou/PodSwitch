import Foundation

public enum PeerCheckResult: Equatable {
    case success
    case forbidden
    case unauthorizedLegacy
    case notFound
    case serverError(Int, String)
    case unreachable(String)
    case invalidResponse

    public var message: String {
        switch self {
        case .success:
            return "连接成功：对端 Tailscale 身份验证通过。"
        case .forbidden:
            return "对端拒绝请求：请确认对端的 Peer MagicDNS 配置指向本机。"
        case .unauthorizedLegacy:
            return "对端仍使用旧版 Token 认证，请更新两台电脑的 PodSwitch。"
        case .notFound:
            return "对端服务可达，但 API 路径不存在，请更新两台电脑的 PodSwitch。"
        case .serverError(let status, let detail):
            return "收到 HTTP \(status)。\(detail)"
        case .unreachable(let reason):
            return "无法连接对端：\(reason)"
        case .invalidResponse:
            return "对端响应格式异常，请检查两端 PodSwitch 版本。"
        }
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Dedicated session for the private Tailscale peer API.
/// An empty proxy dictionary prevents system HTTP/SOCKS/PAC proxies from intercepting Tailnet traffic.
public struct PeerSwitchClient: PeerSwitching {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func releasePeer(host: String, port: UInt16) async -> Bool {
        let result = await request(host: host, port: port, path: "/api/release", method: "POST")
        return result.isSuccess
    }

    public func checkPeer(host: String, port: UInt16) async -> Bool {
        let result = await diagnose(host: host, port: port)
        return result.isSuccess
    }

    public func diagnose(host: String, port: UInt16) async -> PeerCheckResult {
        await request(host: host, port: port, path: "/health", method: "GET")
    }

    private func request(host: String, port: UInt16, path: String, method: String) async -> PeerCheckResult {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty,
              let url = URL(string: "http://\(cleanHost):\(port)\(path)") else {
            return .unreachable("Peer MagicDNS 为空或格式错误")
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .invalidResponse }
            switch http.statusCode {
            case 200:
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["success"] as? Bool == true else { return .invalidResponse }
                return .success
            case 401:
                return .unauthorizedLegacy
            case 403:
                return .forbidden
            case 404:
                return .notFound
            default:
                return .serverError(http.statusCode, Self.responseDetails(http, data: data))
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private static func responseDetails(_ response: HTTPURLResponse, data: Data) -> String {
        var details: [String] = []
        if let server = response.value(forHTTPHeaderField: "Server"), !server.isEmpty {
            details.append("Server: \(server)")
        }
        if let via = response.value(forHTTPHeaderField: "Via"), !via.isEmpty {
            details.append("Via: \(via)")
        }
        if let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            details.append("响应：\(String(body.prefix(220)))")
        }
        return details.isEmpty ? "请检查对端服务、代理和网络路径。" : details.joined(separator: "；")
    }
}
