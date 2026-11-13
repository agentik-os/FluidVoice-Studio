//
//  RemoteMicLink.swift
//  FluidVoice Studio
//
//  One private TCP connection. Encryption happens before the bytes get here.
//

import Foundation
import Network

nonisolated enum RemoteMicNetworking {
    static let queue = DispatchQueue(label: "com.fluidvoice.studio.remotemic")

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 4
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return "\(address)"
        case let .ipv6(address):
            return "\(address)"
        case let .name(name, _):
            return name
        @unknown default:
            return ""
        }
    }
}

final nonisolated class RemoteMicRouteBox: @unchecked Sendable {
    var peerID: String
    var peerName: String
    var address: String
    var interfaceName: String?
    var kind: RemoteMicPathKind
    var endpoint: NWEndpoint
    var deviceUID: String
    var deviceName: String

    init(
        peerID: String,
        peerName: String,
        address: String,
        interfaceName: String?,
        kind: RemoteMicPathKind,
        endpoint: NWEndpoint
    ) {
        self.peerID = peerID
        self.peerName = peerName
        self.address = address
        self.interfaceName = interfaceName
        self.kind = kind
        self.endpoint = endpoint
        self.deviceUID = ""
        self.deviceName = ""
    }
}

nonisolated enum RemoteMicTailscaleCLI {
    static func readStatus() -> Data? {
        guard let binary = self.binary() else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    private static func binary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

nonisolated enum RemoteMicBrowserDecoding {
    static func routes(from results: Set<NWBrowser.Result>, selfPeerID: String) -> [RemoteMicRouteBox] {
        var boxes: [RemoteMicRouteBox] = []
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let record = self.record(result)
            let identifier = record["id"] ?? ""
            let peerID = identifier.isEmpty ? "bonjour:\(name)" : identifier
            if peerID == selfPeerID { continue }
            let peerName = (record["name"]?.isEmpty == false) ? (record["name"] ?? name) : name
            let interfaces: [NWInterface?] = result.interfaces.isEmpty ? [nil] : result.interfaces.map { Optional($0) }
            for interface in interfaces {
                let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                let kind = RemoteMicPath.classify(address: name, interfaceName: interface?.name)
                guard kind != .rejected else { continue }
                let box = RemoteMicRouteBox(
                    peerID: peerID,
                    peerName: peerName,
                    address: name,
                    interfaceName: interface?.name,
                    kind: kind,
                    endpoint: endpoint
                )
                box.deviceUID = record["duid"] ?? ""
                box.deviceName = record["dev"] ?? ""
                boxes.append(box)
            }
        }
        return boxes
    }

    private static func record(_ result: NWBrowser.Result) -> [String: String] {
        guard case let .bonjour(record) = result.metadata else { return [:] }
        var values: [String: String] = [:]
        for key in ["id", "name", "pk", "duid", "dev"] {
            if let value = record[key] {
                values[key] = value
            }
        }
        return values
    }
}

final nonisolated class RemoteMicLink: @unchecked Sendable {
    let token: UUID
    let connection: NWConnection
    let isInitiator: Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false
    private var ready = false
    var onFrame: @Sendable (UUID, RemoteMicFrame) -> Void = { _, _ in }
    var onState: @Sendable (UUID, String) -> Void = { _, _ in }

    init(token: UUID, connection: NWConnection, isInitiator: Bool, queue: DispatchQueue) {
        self.token = token
        self.connection = connection
        self.isInitiator = isInitiator
        self.queue = queue
    }

    var isReady: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.ready && self.stopped == false
    }

    func start() {
        self.connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        self.connection.start(queue: self.queue)
    }

    func send(_ frame: RemoteMicFrame) {
        guard let data = frame.encoded() else { return }
        self.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        self.lock.lock()
        self.stopped = true
        self.ready = false
        self.lock.unlock()
        self.connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            self.lock.lock()
            self.ready = true
            self.lock.unlock()
            self.onState(self.token, "ready")
            self.receive()
        case .waiting:
            self.onState(self.token, "waiting")
        case .failed:
            self.onState(self.token, "failed")
            self.cancel()
        case .cancelled:
            self.onState(self.token, "cancelled")
        default:
            break
        }
    }

    private func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.isEmpty == false {
                self.consume(data)
            }
            if isComplete || error != nil {
                self.onState(self.token, "failed")
                self.cancel()
                return
            }
            self.lock.lock()
            let stopped = self.stopped
            self.lock.unlock()
            if stopped == false {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        self.lock.lock()
        self.buffer.append(data)
        if self.buffer.count > RemoteMicProtocol.maxPayload * 4 {
            self.buffer.removeAll()
            self.lock.unlock()
            self.onState(self.token, "failed")
            self.cancel()
            return
        }
        var frames: [RemoteMicFrame] = []
        var invalid = false
        while true {
            switch RemoteMicFrame.peel(from: &self.buffer) {
            case .needMore:
                self.lock.unlock()
                if invalid == false {
                    for frame in frames {
                        self.onFrame(self.token, frame)
                    }
                }
                return
            case .invalid:
                invalid = true
                self.buffer.removeAll()
                self.lock.unlock()
                self.onState(self.token, "failed")
                self.cancel()
                return
            case let .frame(frame):
                frames.append(frame)
            }
        }
    }
}
