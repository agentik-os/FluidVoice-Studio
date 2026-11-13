//
//  RemoteMicPermissions.swift
//  FluidVoice Studio
//
//  One-line explanations and the System Settings pane for each permission.
//

import Foundation

nonisolated enum RemoteMicPermissionKind: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case localNetwork
}

nonisolated enum RemoteMicPermissionState: String, Equatable, Sendable {
    case granted
    case missing
    case denied
}

nonisolated struct RemoteMicPermissionCopy: Equatable, Sendable {
    var kind: RemoteMicPermissionKind
    var title: String
    var explanation: String
    var settingsURL: String
}

nonisolated enum RemoteMicPermissions {
    static let all: [RemoteMicPermissionCopy] = [
        RemoteMicPermissionCopy(
            kind: .microphone,
            title: "Microphone",
            explanation: "Records your voice for dictation and for microphones you choose to share.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ),
        RemoteMicPermissionCopy(
            kind: .accessibility,
            title: "Accessibility",
            explanation: "Types the transcript into the app you are using.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ),
        RemoteMicPermissionCopy(
            kind: .inputMonitoring,
            title: "Input Monitoring",
            explanation: "Hears the dictation hotkey, including Ctrl+Option+D from Screen Sharing.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ),
        RemoteMicPermissionCopy(
            kind: .localNetwork,
            title: "Local Network",
            explanation: "Finds paired Macs on your LAN and Thunderbolt bridge. Nothing is opened to the internet.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ),
    ]

    static func copy(for kind: RemoteMicPermissionKind) -> RemoteMicPermissionCopy? {
        self.all.first { $0.kind == kind }
    }
}
