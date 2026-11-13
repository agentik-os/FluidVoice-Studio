//
//  RemoteMicController.swift
//  FluidVoice Studio
//
//  Discovery, pairing, and the encrypted microphone session.
//  Runs inside FluidVoice. There is no separate LaunchAgent.
//

import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import Network
import ServiceManagement

extension Notification.Name {
    static let fluidVoiceStudioRemoteMicCatalog = Notification.Name("fluidVoiceStudioRemoteMicCatalog")
}

struct RemoteMicPrompt: Identifiable, Equatable {
    var id: UUID
    var peerName: String
    var code: String
    var deviceName: String
    var isIncoming: Bool
}

struct RemoteMicKnownPeer: Codable, Equatable {
    var peerID: String
    var name: String
    var deviceUID: String
    var deviceName: String
}

struct RemoteMicIdentity: Codable, Equatable {
    var peerID: String
    var signingPrivate: Data
    var signingPublic: Data
    var pinnedSigningKeys: [String: Data]
    var knownPeers: [RemoteMicKnownPeer]
}

final class RemoteMicSession {
    let token: UUID
    let link: RemoteMicLink
    let isInitiator: Bool
    var path: RemoteMicPathKind
    var interfaceName: String?
    var address: String
    var machine = RemoteMicSessionMachine()
    var agreementPrivate = Data()
    var agreementPublic = Data()
    var nonce = Data()
    var signature = Data()
    var key: Data?
    var remote: RemoteMicHello?
    var resumed = false
    var replaced = false
    var helloSent = false
    var lastPong = Date()
    var peerID: String?
    var peerName = ""

    init(link: RemoteMicLink, isInitiator: Bool, path: RemoteMicPathKind, address: String) {
        self.token = link.token
        self.link = link
        self.isInitiator = isInitiator
        self.path = path
        self.address = address
    }
}

final class RemoteMicController: ObservableObject {
    static let shared = RemoteMicController()

    @Published private(set) var peers: [RemoteMicPeer] = []
    @Published private(set) var incomingPrompt: RemoteMicPrompt?
    @Published private(set) var outgoingPrompt: RemoteMicPrompt?
    @Published private(set) var statusText = "Remote microphones are idle."
    @Published private(set) var localNetwork: RemoteMicPermissionState = .missing
    @Published private(set) var catalogRevision = 0

    private let capture = RemoteMicAUHALCapture()
    private var identity = RemoteMicIdentity(
        peerID: "",
        signingPrivate: Data(),
        signingPublic: Data(),
        pinnedSigningKeys: [:],
        knownPeers: []
    )
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var bonjourRoutes: [RemoteMicRouteBox] = []
    private var tailscaleRoutes: [RemoteMicRouteBox] = []
    private var tailscalePeers: [RemoteMicPeer] = []
    private var sessions: [RemoteMicSession] = []
    private var wantedNames: [String: String] = [:]
    private var backoff: [String: TimeInterval] = [:]
    private var recentFailures: [String: Date] = [:]
    private var selfAddresses: Set<String> = []
    private var pcmHandler: (@Sendable ([Float], Double) -> Void)?
    private var listeningPeerID: String?
    private var receivedAudio = false
    private var captureDeviceID: AudioObjectID?
    private var audioSequence: UInt32 = 0
    private var maintenance: Task<Void, Never>?
    private var tailscaleRefresh: Task<Void, Never>?
    private var started = false
    private var loggedTailscaleMiss = false
    private var maintainTicks = 0

    private var routes: [RemoteMicRouteBox] {
        self.bonjourRoutes + self.tailscaleRoutes
    }

    private var displayName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    private var bonjourName: String {
        String(self.displayName.replacingOccurrences(of: ".", with: " ").prefix(63))
    }

    static func shouldStartAutomatically() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if environment["FLUIDVOICE_DISABLE_REMOTE_MIC"] == "1" { return false }
        let arguments = ProcessInfo.processInfo.arguments.joined(separator: " ")
        if arguments.contains("XCTest") || arguments.contains("xctest") { return false }
        return true
    }

    private init() {
        self.capture.onPCM = { data in
            Task { @MainActor in
                RemoteMicController.shared.broadcast(data)
            }
        }
        self.capture.onFailure = { message in
            Task { @MainActor in
                RemoteMicController.shared.statusText = message
                DebugLogger.shared.error(message, source: "RemoteMic")
            }
        }
        self.loadIdentity()
    }

    func start() {
        guard self.started == false else { return }
        guard Self.shouldStartAutomatically() || self.startedFromUser else { return }
        self.started = true
        self.startBrowser()
        self.applySharingPreference()
        self.refreshTailscale()
        self.maintenance = Task { @MainActor [weak self] in
            while let self, Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.maintain()
            }
        }
        DebugLogger.shared.info("Remote microphone discovery started", source: "RemoteMic")
    }

    private var startedFromUser = false

    func stop() {
        self.maintenance?.cancel()
        self.maintenance = nil
        self.tailscaleRefresh?.cancel()
        self.tailscaleRefresh = nil
        self.browser?.cancel()
        self.browser = nil
        self.stopListener()
        for session in self.sessions {
            session.link.cancel()
        }
        self.sessions.removeAll()
        self.capture.stop()
        self.captureDeviceID = nil
        self.started = false
        self.incomingPrompt = nil
        self.outgoingPrompt = nil
    }

    func applySharingPreference() {
        guard self.started else { return }
        if SettingsStore.shared.shareLocalMicrophones {
            self.startListener()
        } else {
            self.stopListener()
        }
    }

    func applySharedDevice() {
        self.captureDeviceID = nil
        self.refreshCapture()
        self.listener?.service = self.serviceAdvertisement()
    }

    func useMicrophone(of peer: RemoteMicPeer) {
        self.startedFromUser = true
        if self.started == false { self.start() }
        self.wantedNames[peer.id] = peer.name
        self.statusText = "Connecting to \(peer.name) over \(peer.bestPath?.kind.label ?? "a private path")…"
        self.connect(peerID: peer.id, name: peer.name)
    }

    func approve(_ promptID: UUID) {
        guard let session = self.sessions.first(where: { $0.token == promptID }), let remote = session.remote else { return }
        if session.isInitiator == false {
            let device = self.currentSharedDevice()
            SettingsStore.shared.grantRemoteMic(
                peerID: remote.peerID,
                deviceUID: device?.uid ?? "",
                peerName: remote.name,
                deviceName: device?.name ?? "Microphone"
            )
        }
        session.machine.localAccept()
        self.sendSecure(.accept, payload: Data(), session: session)
        self.finishIfLive(session)
        self.refreshPrompts()
    }

    func deny(_ promptID: UUID) {
        guard let session = self.sessions.first(where: { $0.token == promptID }) else { return }
        self.sendSecure(.reject, payload: Data(), session: session)
        session.machine.reject()
        if let peerID = session.peerID { self.wantedNames[peerID] = nil }
        self.wantedNames = self.wantedNames.filter { $0.value.caseInsensitiveCompare(session.peerName) != .orderedSame }
        session.link.cancel()
        self.statusText = "Declined \(session.peerName)."
    }

    func revoke(peerID: String, deviceUID: String) {
        SettingsStore.shared.revokeRemoteMic(peerID: peerID, deviceUID: deviceUID)
    }

    func sendClipboard(to peerID: String) {
        guard SettingsStore.shared.remotePasteEnabled else {
            self.statusText = "Turn on send-text-to-remote before sending the clipboard."
            return
        }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let encoded = RemoteMicPasteCodec.encode(text) else {
            self.statusText = "The clipboard is empty or too long to send."
            return
        }
        guard let session = self.initiatorSession(peerID) ?? self.sessions.first(where: { $0.remote?.peerID == peerID }) else {
            self.statusText = "That Mac is not paired right now."
            return
        }
        self.sendSecure(.paste, payload: Data(encoded.dropFirst()), session: session)
        self.statusText = "Sent the clipboard to \(session.peerName)."
    }

    func selectableInputDevices() -> [AudioDevice.Device] {
        self.identity.knownPeers.map { known in
            let deviceUID = known.deviceUID.isEmpty ? "default" : known.deviceUID
            let uid = RemoteMicDeviceIdentity.makeUID(peerID: known.peerID, deviceUID: deviceUID)
            let alive = self.bestRoute(for: known.peerID, name: known.name) != nil || self.liveInitiator(known.peerID) != nil
            return RemoteMicAudioCatalog.makeDevice(
                uid: uid,
                name: RemoteMicDeviceIdentity.displayName(device: known.deviceName, computer: known.name),
                alive: alive
            )
        }
    }

    func startListening(
        peerID: String,
        deviceUID: String,
        onPCM: @escaping @Sendable ([Float], Double) -> Void
    ) async throws {
        let name = self.identity.knownPeers.first { $0.peerID == peerID }?.name ?? "the other Mac"
        self.pcmHandler = onPCM
        self.listeningPeerID = peerID
        self.receivedAudio = false
        self.wantedNames[peerID] = name
        if let session = self.initiatorSession(peerID) {
            if case .awaitingConsent = session.machine.phase {
                throw RemoteMicFailure.needsConsent(name)
            }
            if session.machine.acceptsAudio {
                session.resumed = true
                self.sendSecure(.resume, payload: Data(), session: session)
            }
        } else if self.bestRoute(for: peerID, name: name) != nil {
            self.connect(peerID: peerID, name: name)
        } else {
            throw RemoteMicFailure.unreachable(name)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if self.receivedAudio { return }
            try await Task.sleep(nanoseconds: 50_000_000)
            if let session = self.initiatorSession(peerID), case .awaitingConsent = session.machine.phase {
                throw RemoteMicFailure.needsConsent(name)
            }
        }
        if self.receivedAudio { return }
        throw RemoteMicFailure.timedOut(name)
    }

    func stopListening() {
        if let peerID = self.listeningPeerID, let session = self.liveInitiator(peerID) {
            session.resumed = false
            self.sendSecure(.pause, payload: Data(), session: session)
        }
        self.pcmHandler = nil
        self.listeningPeerID = nil
        self.receivedAudio = false
    }

    func noteLocalNetwork(_ state: RemoteMicPermissionState) {
        if self.localNetwork != state {
            self.localNetwork = state
        }
    }

    func broadcast(_ pcm: Data) {
        self.audioSequence &+= 1
        let payload = RemoteMicAudioCodec.encode(
            sequence: self.audioSequence,
            sampleRate: RemoteMicProtocol.sampleRate,
            pcm: pcm
        )
        for session in self.sessions where session.isInitiator == false && session.resumed && session.machine.acceptsAudio {
            self.sendSecure(.audio, payload: payload, session: session)
        }
    }

    private func maintain() {
        self.maintainTicks += 1
        let now = Date()
        for session in self.sessions where session.link.isReady {
            session.link.send(RemoteMicFrame(type: .ping, flags: 0, payload: Data()))
            if now.timeIntervalSince(session.lastPong) > 8 {
                session.link.cancel()
            }
        }
        self.preferFasterPaths()
        if self.listener == nil, SettingsStore.shared.shareLocalMicrophones {
            self.startListener()
        }
        if self.maintainTicks.isMultiple(of: 5) {
            self.refreshTailscale()
        }
    }

    private func preferFasterPaths() {
        for session in self.sessions where session.isInitiator && session.replaced == false && session.link.isReady {
            guard let peerID = session.peerID ?? session.remote?.peerID else { continue }
            guard let best = self.bestRoute(for: peerID, name: session.peerName) else { continue }
            guard best.kind < session.path else { continue }
            session.replaced = true
            self.recentFailures[session.address] = Date()
            session.link.cancel()
            self.connect(peerID: peerID, name: session.peerName)
            self.statusText = "Switching \(session.peerName) to \(best.kind.label)."
        }
    }

    private func startBrowser() {
        let parameters = RemoteMicNetworking.tcpParameters()
        let browser = NWBrowser(for: .bonjour(type: RemoteMicProtocol.serviceType, domain: nil), using: parameters)
        let selfID = self.identity.peerID
        browser.browseResultsChangedHandler = { results, _ in
            let boxes = RemoteMicBrowserDecoding.routes(from: results, selfPeerID: selfID)
            Task { @MainActor in
                RemoteMicController.shared.replaceBonjour(boxes)
            }
        }
        browser.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    RemoteMicController.shared.noteLocalNetwork(.granted)
                case let .waiting(error):
                    if case let .dns(code) = error, Int(code) == -65_570 {
                        RemoteMicController.shared.noteLocalNetwork(.denied)
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: RemoteMicNetworking.queue)
        self.browser = browser
    }

    private func replaceBonjour(_ boxes: [RemoteMicRouteBox]) {
        self.bonjourRoutes = boxes
        self.publishPeers()
    }

    private func startListener() {
        guard self.listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: RemoteMicProtocol.port) else { return }
        do {
            let listener = try NWListener(using: RemoteMicNetworking.tcpParameters(), on: port)
            listener.service = self.serviceAdvertisement()
            listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    RemoteMicController.shared.accept(connection)
                }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .failed = state {
                        RemoteMicController.shared.listener = nil
                    }
                }
            }
            listener.start(queue: RemoteMicNetworking.queue)
            self.listener = listener
            self.statusText = "Sharing is on. Nearby Macs can ask to use this microphone."
        } catch {
            self.statusText = "Could not listen for microphone requests on port \(RemoteMicProtocol.port)."
            DebugLogger.shared.error("Listener failed: \(error)", source: "RemoteMic")
        }
    }

    private func stopListener() {
        self.listener?.cancel()
        self.listener = nil
        for session in self.sessions where session.isInitiator == false {
            session.link.cancel()
        }
        self.capture.stop()
        self.captureDeviceID = nil
    }

    private func serviceAdvertisement() -> NWListener.Service {
        let device = self.currentSharedDevice()
        let record = NWTXTRecord([
            "id": self.identity.peerID,
            "name": self.displayName,
            "pk": self.identity.signingPublic.base64EncodedString(),
            "duid": device?.uid ?? "",
            "dev": device?.name ?? "",
        ])
        return NWListener.Service(
            name: self.bonjourName,
            type: RemoteMicProtocol.serviceType,
            domain: nil,
            txtRecord: record
        )
    }

    private func accept(_ connection: NWConnection) {
        guard SettingsStore.shared.shareLocalMicrophones else {
            connection.cancel()
            return
        }
        let link = RemoteMicLink(
            token: UUID(),
            connection: connection,
            isInitiator: false,
            queue: RemoteMicNetworking.queue
        )
        let session = self.makeSession(link: link, isInitiator: false, path: .lan, address: "")
        self.track(session)
    }

    private func connect(peerID: String, name: String) {
        if let existing = self.initiatorSession(peerID), existing.replaced == false, existing.link.isReady {
            return
        }
        guard let route = self.bestRoute(for: peerID, name: name) else {
            self.statusText = "\(name) is not reachable on Thunderbolt, the local network, or Tailscale."
            return
        }
        let connection = NWConnection(to: route.endpoint, using: RemoteMicNetworking.tcpParameters())
        let link = RemoteMicLink(token: UUID(), connection: connection, isInitiator: true, queue: RemoteMicNetworking.queue)
        let session = self.makeSession(link: link, isInitiator: true, path: route.kind, address: route.address)
        session.interfaceName = route.interfaceName
        session.peerName = name
        if peerID.hasPrefix(RemoteMicDiscovery.tailscaleIDPrefix) == false, peerID.hasPrefix("bonjour:") == false {
            session.peerID = peerID
        }
        self.track(session)
        DebugLogger.shared.info("Connecting to \(name) via \(route.kind.label) (\(route.address))", source: "RemoteMic")
    }

    private func makeSession(
        link: RemoteMicLink,
        isInitiator: Bool,
        path: RemoteMicPathKind,
        address: String
    ) -> RemoteMicSession {
        let session = RemoteMicSession(link: link, isInitiator: isInitiator, path: path, address: address)
        let agreement = RemoteMicPairing.generateAgreement()
        session.agreementPrivate = agreement.privateKey
        session.agreementPublic = agreement.publicKey
        session.nonce = RemoteMicPairing.randomBytes(count: 16)
        session.signature = (try? RemoteMicPairing.sign(agreement.publicKey, privateKey: self.identity.signingPrivate)) ?? Data()
        return session
    }

    private func track(_ session: RemoteMicSession) {
        session.link.onFrame = { token, frame in
            Task { @MainActor in
                RemoteMicController.shared.receive(frame, token: token)
            }
        }
        session.link.onState = { token, state in
            Task { @MainActor in
                RemoteMicController.shared.linkState(token, state)
            }
        }
        self.sessions.append(session)
        session.link.start()
    }

    private func linkState(_ token: UUID, _ state: String) {
        guard let session = self.sessions.first(where: { $0.token == token }) else { return }
        switch state {
        case "ready":
            self.linkReady(session)
        case "failed", "cancelled":
            self.linkClosed(session)
        default:
            break
        }
    }

    private func linkReady(_ session: RemoteMicSession) {
        guard self.allows(session) else {
            self.statusText = "Refused a connection that was not on a private network."
            session.link.cancel()
            return
        }
        session.lastPong = Date()
        guard session.helloSent == false else { return }
        session.helloSent = true
        self.sendHello(session)
    }

    private func linkClosed(_ session: RemoteMicSession) {
        let peerID = session.peerID
        let name = session.peerName
        let replaced = session.replaced
        let initiator = session.isInitiator
        let address = session.address
        self.sessions.removeAll { $0.token == session.token }
        if self.incomingPrompt?.id == session.token { self.incomingPrompt = nil }
        if self.outgoingPrompt?.id == session.token { self.outgoingPrompt = nil }
        self.refreshCapture()
        guard replaced == false, initiator, name.isEmpty == false else { return }
        self.recentFailures[address] = Date()
        let key = peerID ?? name
        guard self.wantedNames[key] != nil || self.wantedNames.values.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        self.scheduleReconnect(peerID ?? key, name: name)
    }

    private func scheduleReconnect(_ peerID: String, name: String) {
        let delay = min((self.backoff[peerID] ?? 0.4) * 2, 5)
        self.backoff[peerID] = delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.liveInitiator(peerID) == nil else {
                self.backoff[peerID] = 0.4
                return
            }
            guard self.wantedNames[peerID] != nil || self.wantedNames.values.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            self.connect(peerID: peerID, name: name)
        }
    }

    private func allows(_ session: RemoteMicSession) -> Bool {
        switch session.link.connection.endpoint {
        case let .hostPort(host, _):
            let address = RemoteMicNetworking.describe(host)
            if address.isEmpty == false {
                session.address = address
            }
            return RemoteMicPath.allows(address, interfaceName: session.interfaceName)
        case .service:
            return session.path != .rejected
        default:
            return false
        }
    }

    private func sendHello(_ session: RemoteMicSession) {
        let device = session.isInitiator ? (uid: "", name: "") : (self.currentSharedDevice() ?? (uid: "", name: ""))
        let hello = RemoteMicHello(
            peerID: self.identity.peerID,
            name: self.displayName,
            role: session.isInitiator ? "listen" : "share",
            agreementPublic: session.agreementPublic,
            signingPublic: self.identity.signingPublic,
            nonce: session.nonce,
            signature: session.signature,
            deviceUID: device.uid,
            deviceName: device.name
        )
        guard let payload = RemoteMicHello.encode(hello) else { return }
        session.link.send(RemoteMicFrame(type: .hello, flags: 0, payload: payload))
    }

    private func receive(_ frame: RemoteMicFrame, token: UUID) {
        guard let session = self.sessions.first(where: { $0.token == token }) else { return }
        switch frame.type {
        case .hello:
            self.receiveHello(frame.payload, session: session)
        case .ping:
            session.link.send(RemoteMicFrame(type: .pong, flags: 0, payload: Data()))
        case .pong:
            session.lastPong = Date()
        case .secure:
            self.receiveSecure(frame.payload, session: session)
        }
    }

    private func receiveHello(_ payload: Data, session: RemoteMicSession) {
        guard let hello = RemoteMicHello.decode(payload) else {
            session.link.cancel()
            return
        }
        if hello.peerID == self.identity.peerID {
            session.link.cancel()
            return
        }
        guard RemoteMicPairing.verify(signature: hello.signature, data: hello.agreementPublic, publicKey: hello.signingPublic) else {
            DebugLogger.shared.error("Rejected \(hello.name): identity signature did not match", source: "RemoteMic")
            session.link.cancel()
            return
        }
        do {
            session.key = try RemoteMicPairing.agreementKey(
                localPrivate: session.agreementPrivate,
                remotePublic: hello.agreementPublic,
                salt: RemoteMicPairing.salt(localNonce: session.nonce, remoteNonce: hello.nonce)
            )
        } catch {
            session.link.cancel()
            return
        }
        session.remote = hello
        session.peerID = hello.peerID
        session.peerName = hello.name
        self.rekeyRoutes(named: hello.name, to: hello.peerID)
        let code = RemoteMicPairing.confirmationCode(
            localPublic: session.agreementPublic,
            remotePublic: hello.agreementPublic,
            localNonce: session.nonce,
            remoteNonce: hello.nonce
        )
        let shared = self.sharedDevice(for: session, hello: hello)
        let pinned = self.identity.pinnedSigningKeys[hello.peerID] == hello.signingPublic
        session.machine.receiveHello(
            code: code,
            peerName: hello.name,
            deviceUID: shared.uid,
            deviceName: shared.name,
            pinned: pinned
        )
        let granted = shared.uid.isEmpty ? false : SettingsStore.shared.isRemoteMicGranted(peerID: hello.peerID, deviceUID: shared.uid)
        if RemoteMicApproval.shouldAutoAccept(isSharer: session.isInitiator == false, pinned: pinned, deviceGranted: granted) {
            session.machine.localAccept()
            self.sendSecure(.accept, payload: Data(), session: session)
            self.finishIfLive(session)
        }
        self.refreshPrompts()
        self.publishPeers()
    }

    private func receiveSecure(_ payload: Data, session: RemoteMicSession) {
        guard let key = session.key, let inner = try? RemoteMicPairing.open(payload, key: key), let typeByte = inner.first,
              let type = RemoteMicSecureType(rawValue: typeByte)
        else { return }
        let body = Data(inner.dropFirst())
        switch type {
        case .accept:
            session.machine.remoteAccept()
            self.finishIfLive(session)
            self.refreshPrompts()
        case .reject:
            session.machine.reject()
            if let peerID = session.peerID { self.wantedNames[peerID] = nil }
            self.statusText = "\(session.peerName) declined the microphone request."
            session.link.cancel()
        case .audio:
            self.receiveAudio(body, session: session)
        case .paste:
            self.receivePaste(body, session: session)
        case .resume:
            session.resumed = true
            self.refreshCapture()
        case .pause:
            session.resumed = false
            self.refreshCapture()
        }
    }

    private func receiveAudio(_ body: Data, session: RemoteMicSession) {
        guard session.isInitiator, session.machine.acceptsAudio, let decoded = RemoteMicAudioCodec.decode(body) else { return }
        let samples = RemoteMicAudioCodec.floatSamples(fromPCM16: decoded.pcm)
        guard samples.isEmpty == false else { return }
        self.receivedAudio = true
        self.pcmHandler?(samples, Double(decoded.sampleRate))
    }

    private func receivePaste(_ body: Data, session: RemoteMicSession) {
        guard session.machine.acceptsAudio, SettingsStore.shared.remotePasteEnabled else { return }
        var encoded = Data([RemoteMicSecureType.paste.rawValue])
        encoded.append(body)
        guard let text = RemoteMicPasteCodec.decode(encoded) else { return }
        RemoteMicPasteboard.deliver(text)
        self.statusText = "Pasted text from \(session.peerName)."
    }

    private func finishIfLive(_ session: RemoteMicSession) {
        guard session.machine.acceptsAudio, let remote = session.remote else { return }
        self.identity.pinnedSigningKeys[remote.peerID] = remote.signingPublic
        let shared = self.sharedDevice(for: session, hello: remote)
        self.remember(peerID: remote.peerID, name: remote.name, deviceUID: shared.uid, deviceName: shared.name)
        self.saveIdentity()
        session.peerID = remote.peerID
        self.rekeyRoutes(named: remote.name, to: remote.peerID)
        self.backoff[remote.peerID] = 0.4
        if session.isInitiator {
            self.wantedNames[remote.peerID] = remote.name
            let deviceUID = shared.uid.isEmpty ? "default" : shared.uid
            let uid = RemoteMicDeviceIdentity.makeUID(peerID: remote.peerID, deviceUID: deviceUID)
            let title = RemoteMicDeviceIdentity.displayName(device: shared.name, computer: remote.name)
            SettingsStore.shared.recordInputDeviceSelection(uid, name: title)
            if self.listeningPeerID == remote.peerID {
                session.resumed = true
                self.sendSecure(.resume, payload: Data(), session: session)
            }
        }
        self.refreshPrompts()
        self.refreshCapture()
        self.publishPeers()
        self.statusText = "Paired with \(remote.name) over \(session.path.label)."
        DebugLogger.shared.info("Paired with \(remote.name) path=\(session.path.label)", source: "RemoteMic")
    }

    private func refreshPrompts() {
        self.incomingPrompt = self.sessions.compactMap { session in
            guard session.isInitiator == false, case let .awaitingConsent(code, peerName, deviceName, _) = session.machine.phase else { return nil }
            return RemoteMicPrompt(id: session.token, peerName: peerName, code: code, deviceName: deviceName, isIncoming: true)
        }.first
        self.outgoingPrompt = self.sessions.compactMap { session in
            guard session.isInitiator, case let .awaitingConsent(code, peerName, deviceName, _) = session.machine.phase else { return nil }
            return RemoteMicPrompt(id: session.token, peerName: peerName, code: code, deviceName: deviceName, isIncoming: false)
        }.first
    }

    private func sendSecure(_ type: RemoteMicSecureType, payload: Data, session: RemoteMicSession) {
        guard let key = session.key else { return }
        var inner = Data([type.rawValue])
        inner.append(payload)
        guard let sealed = try? RemoteMicPairing.seal(inner, key: key) else { return }
        session.link.send(RemoteMicFrame(type: .secure, flags: 0, payload: sealed))
    }

    private func refreshCapture() {
        let needsCapture = self.sessions.contains { $0.isInitiator == false && $0.resumed && $0.machine.acceptsAudio }
        guard needsCapture else {
            self.capture.stop()
            self.captureDeviceID = nil
            return
        }
        guard let device = self.currentSharedDevice(), let deviceID = AudioDevice.getDeviceId(forUID: device.uid) else {
            self.statusText = "Choose a local microphone to share."
            return
        }
        guard self.captureDeviceID != deviceID else { return }
        self.capture.start(deviceID: deviceID)
        self.captureDeviceID = deviceID
        DebugLogger.shared.info("Sharing \(device.name) at 48 kHz", source: "RemoteMic")
    }

    private func currentSharedDevice() -> (uid: String, name: String)? {
        let selected = SettingsStore.shared.sharedMicrophoneUID
        if selected.isEmpty == false,
           RemoteMicDeviceIdentity.isRemote(selected) == false,
           let device = AudioDevice.getInputDevice(byUID: selected)
        {
            return (device.uid, device.name)
        }
        guard let device = AudioDevice.getDefaultInputDevice(), RemoteMicDeviceIdentity.isRemote(device.uid) == false else { return nil }
        return (device.uid, device.name)
    }

    private func sharedDevice(for session: RemoteMicSession, hello: RemoteMicHello) -> (uid: String, name: String) {
        if session.isInitiator {
            return (hello.deviceUID, hello.deviceName.isEmpty ? "Microphone" : hello.deviceName)
        }
        return self.currentSharedDevice() ?? (uid: "", name: "Microphone")
    }

    private func remember(peerID: String, name: String, deviceUID: String, deviceName: String) {
        self.identity.knownPeers.removeAll { $0.peerID == peerID }
        self.identity.knownPeers.append(
            RemoteMicKnownPeer(peerID: peerID, name: name, deviceUID: deviceUID, deviceName: deviceName)
        )
        self.catalogRevision += 1
        NotificationCenter.default.post(name: .fluidVoiceStudioRemoteMicCatalog, object: nil)
    }

    private func refreshTailscale() {
        guard self.tailscaleRefresh == nil else { return }
        self.tailscaleRefresh = Task.detached {
            let data = RemoteMicTailscaleCLI.readStatus()
            await MainActor.run {
                RemoteMicController.shared.applyTailscale(data)
            }
        }
    }

    private func applyTailscale(_ data: Data?) {
        self.tailscaleRefresh = nil
        guard let data else {
            if self.loggedTailscaleMiss == false {
                self.loggedTailscaleMiss = true
                DebugLogger.shared.info("Tailscale CLI is not installed; LAN and Thunderbolt discovery still run", source: "RemoteMic")
            }
            return
        }
        self.selfAddresses = RemoteMicDiscovery.selfAddresses(in: data)
        self.tailscalePeers = RemoteMicDiscovery.parseTailscaleStatus(data)
        self.tailscaleRoutes = self.tailscalePeers.flatMap { peer in
            peer.endpoints.compactMap { endpoint -> RemoteMicRouteBox? in
                guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
                return RemoteMicRouteBox(
                    peerID: peer.id,
                    peerName: peer.name,
                    address: endpoint.address,
                    interfaceName: endpoint.interfaceName,
                    kind: endpoint.kind,
                    endpoint: NWEndpoint.hostPort(host: NWEndpoint.Host(endpoint.address), port: port)
                )
            }
        }
        self.publishPeers()
    }

    private func publishPeers() {
        let bonjour = Dictionary(grouping: self.bonjourRoutes, by: \.peerID).compactMap { peerID, routes -> RemoteMicPeer? in
            guard let first = routes.first else { return nil }
            return RemoteMicPeer(
                id: peerID,
                name: first.peerName,
                endpoints: routes.map {
                    RemoteMicEndpoint(address: $0.address, port: RemoteMicProtocol.port, interfaceName: $0.interfaceName, kind: $0.kind)
                },
                signingPublicKey: nil,
                sharedDeviceUID: first.deviceUID,
                sharedDeviceName: first.deviceName
            )
        }
        self.peers = RemoteMicDiscovery.merge(
            bonjour: bonjour,
            tailscale: self.tailscalePeers,
            selfPeerID: self.identity.peerID,
            selfAddresses: self.selfAddresses
        )
        self.catalogRevision += 1
    }

    private func bestRoute(for peerID: String, name: String) -> RemoteMicRouteBox? {
        let now = Date()
        let matches = self.routes.filter { route in
            let idMatch = route.peerID == peerID || route.peerID == RemoteMicDiscovery.tailscaleIDPrefix + name.lowercased()
            let nameMatch = route.peerName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            return idMatch || nameMatch
        }
        let fresh = matches.filter { route in
            guard let failed = self.recentFailures[route.address] else { return true }
            return now.timeIntervalSince(failed) >= 8
        }
        let pool = fresh.isEmpty ? matches : fresh
        return pool.min { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.address < rhs.address
        }
    }

    private func rekeyRoutes(named name: String, to peerID: String) {
        for route in self.bonjourRoutes where route.peerName.compare(name, options: .caseInsensitive) == .orderedSame {
            route.peerID = peerID
        }
        for route in self.tailscaleRoutes where route.peerName.compare(name, options: .caseInsensitive) == .orderedSame {
            route.peerID = peerID
        }
    }

    private func initiatorSession(_ peerID: String) -> RemoteMicSession? {
        self.sessions.first { session in
            session.isInitiator && (session.peerID == peerID || session.remote?.peerID == peerID)
        }
    }

    private func liveInitiator(_ peerID: String) -> RemoteMicSession? {
        guard let session = self.initiatorSession(peerID), session.machine.acceptsAudio, session.link.isReady else { return nil }
        return session
    }

    private func loadIdentity() {
        let url = self.identityURL()
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(RemoteMicIdentity.self, from: data),
           stored.peerID.isEmpty == false,
           stored.signingPrivate.isEmpty == false
        {
            self.identity = stored
            return
        }
        let signing = RemoteMicPairing.generateSigning()
        self.identity = RemoteMicIdentity(
            peerID: UUID().uuidString.lowercased(),
            signingPrivate: signing.privateKey,
            signingPublic: signing.publicKey,
            pinnedSigningKeys: [:],
            knownPeers: []
        )
        self.saveIdentity()
    }

    private func saveIdentity() {
        let url = self.identityURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self.identity) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func identityURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FluidVoice/studio-identity.json")
    }
}

enum RemoteMicPasteboard {
    static func deliver(_ text: String) {
        guard SettingsStore.shared.remotePasteEnabled else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum FluidVoiceStudioUninstall {
    @MainActor
    static func removeStudioIntegration() {
        RemoteMicController.shared.stop()
        try? SMAppService.mainApp.unregister()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("FluidVoiceStudio.") {
            defaults.removeObject(forKey: key)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let url = base?.appendingPathComponent("FluidVoice/studio-identity.json") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
