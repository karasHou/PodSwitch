import Foundation
import Network
import Darwin

/// Authenticated HTTP release endpoint bound only to this Mac's Tailscale IPv4 address.
@MainActor
public final class PeerSwitchServer {
    private var listener: NWListener?
    private let tokenProvider: () -> String
    private let releaseHandler: () async -> Bool
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    public var onStateChange: (() -> Void)?
    private var releaseInProgress = false

    public init(tokenProvider: @escaping () -> String, releaseHandler: @escaping () async -> Bool) {
        self.tokenProvider = tokenProvider
        self.releaseHandler = releaseHandler
    }

    public func start(port: UInt16 = 8765) {
        guard listener == nil else { return }
        guard let address = Self.tailscaleIPv4(), let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Tailscale IPv4 address not found"
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: nwPort)

        do {
            let server = try NWListener(using: parameters)
            server.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    Task { @MainActor [weak self] in
                        await self?.handle(data ?? Data(), connection: connection)
                    }
                }
            }
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                        self?.onStateChange?()
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                        self?.onStateChange?()
                    case .cancelled:
                        self?.isRunning = false
                        self?.onStateChange?()
                    default:
                        break
                    }
                }
            }
            listener = server
            server.start(queue: .global(qos: .userInitiated))
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ data: Data, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8) else {
            send(status: "400 Bad Request", success: false, on: connection)
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.dropFirst().first.map(String.init) ?? ""
        let authorization = lines.first(where: {
            $0.lowercased().hasPrefix("authorization:")
        }).map {
            $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
        } ?? ""
        let expected = "Bearer \(tokenProvider())"

        guard !tokenProvider().isEmpty, authorization == expected else {
            send(status: "401 Unauthorized", success: false, on: connection)
            return
        }

        if method == "GET", path == "/health" {
            send(status: "200 OK", success: true, on: connection)
            return
        }

        if method == "POST", path == "/api/release" {
            guard !releaseInProgress else {
                send(status: "409 Conflict", success: false, on: connection)
                return
            }
            releaseInProgress = true
            let released = await releaseHandler()
            releaseInProgress = false
            send(status: released ? "200 OK" : "409 Conflict", success: released, on: connection)
            return
        }

        send(status: "404 Not Found", success: false, on: connection)
    }

    private func send(status: String, success: Bool, on connection: NWConnection) {
        let body = "{\"success\":\(success ? "true" : "false")}"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func tailscaleIPv4() -> IPv4Address? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: host)
            let octets = value.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]),
                  let ipv4 = IPv4Address(value) else { continue }
            return ipv4
        }
        return nil
    }
}