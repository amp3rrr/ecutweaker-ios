import Foundation
import Network

/// ELM327 over Wi-Fi (TCP, default 192.168.0.10:35000) — port of ElmWifi.java.
final class WiFiLink: ElmLink {
    let host: String
    let port: UInt16
    var displayName: String { "Wi-Fi \(host):\(port)" }
    var onReceive: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "ecutweaker.wifi")
    private var connection: NWConnection?
    private var opened = false
    private var completion: ((Error?) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func open(completion: @escaping (Error?) -> Void) {
        queue.async {
            self.completion = completion
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                self.finish(ElmLinkError("Invalid port"))
                return
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.connectionTimeout = 6
            let params = NWParameters(tls: nil, tcp: tcp)
            params.requiredInterfaceType = .wifi
            let c = NWConnection(host: NWEndpoint.Host(self.host), port: nwPort, using: params)
            self.connection = c
            c.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            c.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.finish(ElmLinkError("Wi-Fi connection timeout (\(self?.host ?? ""))"))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil
        if error == nil {
            opened = true
            receive()
        } else {
            connection?.cancel()
            connection = nil
        }
        completion(error)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finish(nil)
        case .failed(let error):
            if completion != nil { finish(error) } else { lost(error) }
        case .waiting(let error):
            if completion != nil { finish(error) }
        case .cancelled:
            lost(nil)
        default:
            break
        }
    }

    private func lost(_ error: Error?) {
        guard opened else { return }
        opened = false
        onClosed?(error)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if isComplete || error != nil {
                self.lost(error)
                return
            }
            self.receive()
        }
    }

    func send(_ data: Data) {
        queue.async {
            self.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func close() {
        queue.async {
            self.opened = false
            self.connection?.cancel()
            self.connection = nil
        }
    }
}
