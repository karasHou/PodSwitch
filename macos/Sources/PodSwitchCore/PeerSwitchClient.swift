import Foundation

public enum PeerCheckResult: Equatable {
    case success
    case unauthorized
    case notFound
    case serverError(Int)
    case unreachable(String)
    case invalidResponse

    public var message: String {
        switch self {
        case .success:
            return "连接成功：对端服务可达，Token 验证通过。"
        case .unauthorized:
            return "对端服务可达，但 Token 不匹配（HTTP 401）。请检查两端 Token 是否完全一致。"
        case .notFound:
            return "对端服务可达，但 API 路径不存在（HTTP 404）。请更新两端 PodSwitch。"
        case .serverError(let status):
            return "对端返回 HTTP \(status)，请检查对端服务状态。"
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

/// HTTP client for the peer endpoint over the private Tailscale network.
public struct PeerSwitchClient: PeerSwitching {
    public init() {}

    public func releasePeer(host: String, port: UInt16, token: String) async -> Bool {
        let result = await request(host: host, port: port, token: token, path: "/api/release", method: "POST")
        return result.isSuccess
    }

    public func checkPeer(host: String, port: UInt16, token: String) async -> Bool {
        let result = await diagnose(host: host, port: port, token: token)
        return result.isSuccess
    }

    public func diagnose(host: String, port: UInt16, token: String) async -> PeerCheckResult {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !token.isEmpty,
              let url = URL(string: "http://\(cleanHost):\(port)/health") else {
            return .unreachable("MagicDNS 地址或 Token 为空")
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .invalidResponse }
            switch http.statusCode {
            case 200:
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["success"] as? Bool == true else { return .invalidResponse }
                return .success
            case 401:
                return .unauthorized
            case 404:
                return .notFound
            default:
                return .serverError(http.statusCode)
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private func request(host: String, port: UInt16, token: String, path: String, method: String) async -> PeerCheckResult {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !token.isEmpty,
              let url = URL(string: "http://\(cleanHost):\(port)\(path)") else {
            return .unreachable("MagicDNS 地址或 Token 为空")
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .invalidResponse }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 { return .unauthorized }
                if http.statusCode == 404 { return .notFound }
                return .serverError(http.statusCode)
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["success"] as? Bool == true else { return .invalidResponse }
            return .success
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}