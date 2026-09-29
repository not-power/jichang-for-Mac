import Foundation
import Darwin
import Network

@MainActor
final class LocalShareServer {
    private var listener: NWListener?
    private var config: String
    private var fileName: String
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "com.jichang.mac.share")

    init(config: String, fileName: String) { self.config = config; self.fileName = fileName }

    func update(config: String, fileName: String) { self.config = config; self.fileName = fileName }

    func start() async throws -> String {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.respond(to: connection) }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: ServiceError.invalidURL) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let address = Self.localAddress() else { stop(); throw ServiceError.invalidURL }
        return "http://\(address):\(port)/\(token)/config.yaml"
    }

    func stop() { listener?.cancel(); listener = nil }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.components(separatedBy: " ").dropFirst().first ?? ""
                let safeName = self.fileName.replacingOccurrences(of: "\"", with: "")
                let body: Data
                let status: String
                if path == "/\(self.token)/config.yaml" { body = Data(self.config.utf8); status = "200 OK" }
                else { body = Data("Not Found".utf8); status = "404 Not Found" }
                let header = "HTTP/1.1 \(status)\r\nContent-Type: application/yaml; charset=utf-8\r\nContent-Disposition: attachment; filename=\"\(safeName)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var response = Data(header.utf8); response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func localAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let interface = item.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) != "lo0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                   let terminator = host.firstIndex(of: 0) {
                    return String(decoding: host[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = interface.ifa_next
        }
        return nil
    }
}
