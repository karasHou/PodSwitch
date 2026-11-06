import Foundation

/// HTTP client for the peer endpoint over the private Tailscale network.
public struct PeerSwitchClient: PeerSwitching {
    public init() {}

    public func releasePeer(host: String, port: UInt16, token: String) async -> Bool {
        await request(host: host, port: port, token: token, path: "/api/release", method: "POST")
    }

    public func checkPeer(host: String, port: UInt16, token: String) async -> Bool {
        await request(host: host, port: port, token: token, path: "/health", method: "GET")
    }

    private func request(host: String, port: UInt16, token: String, path: String, method: String) async -> Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !token.isEmpty,
              let url = URL(string: "http://\(cleanHost):\(port)\(path)") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return payload["success"] as? Bool == true
        } catch {
            return false
        }
    }
}