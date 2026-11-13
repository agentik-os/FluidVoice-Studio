//
//  RemoteMicSessionMachine.swift
//  FluidVoice Studio
//
//  Audio is allowed only after both Macs accept the same pairing transcript.
//

import Foundation

nonisolated enum RemoteMicPhase: Equatable, Sendable {
    case awaitingHello
    case awaitingConsent(code: String, peerName: String, deviceName: String, pinned: Bool)
    case live(deviceUID: String, deviceName: String)
    case rejected
}

nonisolated struct RemoteMicSessionMachine: Equatable, Sendable {
    private(set) var phase: RemoteMicPhase = .awaitingHello
    private var localAccepted = false
    private var remoteAccepted = false
    private var deviceUID = ""
    private var deviceName = ""

    mutating func receiveHello(code: String, peerName: String, deviceUID: String, deviceName: String, pinned: Bool) {
        guard case .awaitingHello = self.phase else { return }
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.phase = .awaitingConsent(code: code, peerName: peerName, deviceName: deviceName, pinned: pinned)
    }

    mutating func localAccept() {
        self.localAccepted = true
        self.advance()
    }

    mutating func remoteAccept() {
        self.remoteAccepted = true
        self.advance()
    }

    mutating func reject() {
        self.phase = .rejected
    }

    var acceptsAudio: Bool {
        if case .live = self.phase { return true }
        return false
    }

    private mutating func advance() {
        guard self.localAccepted, self.remoteAccepted else { return }
        guard case .awaitingConsent = self.phase else { return }
        self.phase = .live(deviceUID: self.deviceUID, deviceName: self.deviceName)
    }
}

nonisolated enum RemoteMicFailure: Error, LocalizedError, Equatable {
    case needsConsent(String)
    case unreachable(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .needsConsent(name):
            return "Approve the pairing code on this Mac and on \(name) before dictating."
        case let .unreachable(name):
            return "\(name) is not reachable on Thunderbolt, the local network, or Tailscale."
        case let .timedOut(name):
            return "No audio arrived from \(name). Check that it is sharing a microphone and that the cable or Tailscale link is up."
        }
    }
}

nonisolated enum RemoteMicApproval {
    /// A pinned identity reconnects without a prompt. The sharing Mac still
    /// requires a per-device grant, so a new microphone is not silently opened.
    static func shouldAutoAccept(isSharer: Bool, pinned: Bool, deviceGranted: Bool) -> Bool {
        guard pinned else { return false }
        return isSharer ? deviceGranted : true
    }
}
