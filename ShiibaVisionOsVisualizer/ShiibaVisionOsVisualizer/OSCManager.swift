//
//  OSCManager.swift
//  ShiibaVisionOsVisualizer
//
//  Network.framework-based OSC UDP listener and sender.
//  Receives on port 9999, sends to 192.168.0.7:9998.
//

import Foundation
import Network

final class OSCManager: Sendable {
    static let receivePort: UInt16 = 9999
    static let sendHost = "192.168.0.7"
    static let sendPort: UInt16 = 9998

    private let listener: NWListener
    private let sendConnection: NWConnection
    private let queue = DispatchQueue(label: "com.shiiba.osc", qos: .userInteractive)
    let onMessage: @Sendable (OSCMessage) -> Void

    init(onMessage: @escaping @Sendable (OSCMessage) -> Void) {
        self.onMessage = onMessage

        // UDP listener on receive port
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        self.listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.receivePort)!)

        // UDP connection for sending
        let sendEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Self.sendHost),
            port: NWEndpoint.Port(rawValue: Self.sendPort)!
        )
        self.sendConnection = NWConnection(to: sendEndpoint, using: .udp)
    }

    func start() {
        // Start listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[OSC] Listener ready on port \(Self.receivePort)")
            case .failed(let error):
                print("[OSC] Listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)

        // Start send connection
        sendConnection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[OSC] Send connection failed: \(error)")
            }
        }
        sendConnection.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        sendConnection.cancel()
    }

    func send(_ message: OSCMessage) {
        let data = message.toData()
        sendConnection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[OSC] Send error: \(error)")
            }
        })
    }

    // MARK: - Private

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, let message = OSCMessage.parse(data: data) {
                self?.onMessage(message)
            }
            if let error {
                print("[OSC] Receive error: \(error)")
                return
            }
            // Continue receiving
            self?.receiveMessage(on: connection)
        }
    }
}
