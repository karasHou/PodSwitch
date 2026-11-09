import Foundation
import Network
import Darwin

/// HTTP release endpoint bound to Tailscale IPv4 and restricted to the configured peer MagicDNS IP.
@MainActor
public final class PeerSwitchServer {
    private var listener: NWListener?
    private let peerHostProvider: () -> String
    private let releaseHandler: () async -> Bool
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    public var onStateChange: (() -> Void)?
    private var releaseInProgress = false

    public init(peerHostProvider: @escaping () -> String, releaseHandler: @escaping () async -> Bool) {
        self.peerHostProvider = peerHostProvider
        self.releaseHandler = releaseHandler
    }

    public func start(port: UInt16 = 8765) {
        guard listener == nil else { return }
        guard let address = Self.tailscaleIPv4(), let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Tailscale IPv4 address not found"
            onStateChange?()
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
                        await self?.handle(data ?? Data(), remoteEndpoint: connection.endpoint, connection: connection)
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
            onStateChange?()
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ data: Data, remoteEndpoint: NWEndpoint, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8) else {
            send(status: "400 Bad Request", success: false, on: connection)
            return
        }

        guard Self.isAuthorizedPeer(remoteEndpoint, configuredPeerHost: peerHostProvider()) else {
            send(status: "403 Forbidden", success: false, on: connection)
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.dropFirst().first.map(String.init) ?? ""

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

    private static func isAuthorizedPeer(_ endpoint: NWEndpoint, configuredPeerHost: String) -> Bool {
        guard case let .hostPort(host, _) = endpoint,
              case let .ipv4(remoteAddress) = host else { return false }
        let remote = String(describing: remoteAddress)
        guard isTailscaleIPv4(remote) else { return false }
        return resolvedTailscaleIPv4(configuredPeerHost).contains(remote)
    }

    private static func resolvedTailscaleIPv4(_ hostname: String) -> Set<String> {
        let cleanHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return [] }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = cleanHost.withCString { getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            if let address = item.pointee.ai_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, item.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if isTailscaleIPv4(value) { addresses.insert(value) }
                }
            }
            current = item.pointee.ai_next
        }
        return addresses
    }

    private static func isTailscaleIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
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
            guard isTailscaleIPv4(value), let ipv4 = IPv4Address(value) else { continue }
            return ipv4
        }
        return nil
    }
}
