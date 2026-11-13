//
//  RemoteMicSettingsSection.swift
//  FluidVoice Studio
//

import AppKit
import Combine
import SwiftUI

struct RemoteMicSettingsSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var remote = RemoteMicController.shared
    @State private var localMics: [AudioDevice.Device] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote microphones")
                .font(.headline)
            Text("Use another Mac's microphone, or share one from this Mac. Audio stays on Thunderbolt, your LAN, or Tailscale, and it is encrypted after pairing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(self.remote.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            self.prompt(self.remote.incomingPrompt, confirmTitle: "Approve")
            self.prompt(self.remote.outgoingPrompt, confirmTitle: "Codes match")

            if self.remote.peers.isEmpty {
                Text("No other FluidVoice Macs are visible yet. They appear automatically on the same network, Thunderbolt bridge, or tailnet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.remote.peers) { peer in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use the microphone of \(peer.name)")
                                .font(.body.weight(.medium))
                            Text(peer.bestPath.map { "Fastest path: \($0.kind.label)" } ?? "No private path")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Use") {
                            self.remote.useMicrophone(of: peer)
                        }
                        .disabled(peer.bestPath == nil)
                    }
                }
            }

            Divider()

            Toggle("Share this Mac's microphones", isOn: Binding(
                get: { self.settings.shareLocalMicrophones },
                set: { self.settings.shareLocalMicrophones = $0 }
            ))
            Text("Each Mac still has to be approved before it can hear a microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if self.settings.shareLocalMicrophones {
                Picker("Microphone to share", selection: Binding(
                    get: { self.settings.sharedMicrophoneUID },
                    set: { self.settings.sharedMicrophoneUID = $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(self.localMics, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            if self.settings.remoteMicGrants.isEmpty == false {
                Text("Approved listeners")
                    .font(.subheadline.weight(.semibold))
                ForEach(self.settings.remoteMicGrants, id: \.self) { grant in
                    HStack {
                        Text("\(grant.peerName) can use \(grant.deviceName)")
                            .font(.callout)
                        Spacer()
                        Button("Revoke") {
                            self.remote.revoke(peerID: grant.peerID, deviceUID: grant.deviceUID)
                        }
                    }
                }
            }

            Toggle("Send clipboard text to a paired Mac", isOn: Binding(
                get: { self.settings.remotePasteEnabled },
                set: { self.settings.remotePasteEnabled = $0 }
            ))
            if self.settings.remotePasteEnabled, self.remote.peers.isEmpty == false {
                ForEach(self.remote.peers) { peer in
                    Button("Send clipboard to \(peer.name)") {
                        self.remote.sendClipboard(to: peer.id)
                    }
                }
            }

            Divider()

            Text("Permissions")
                .font(.subheadline.weight(.semibold))
            RemoteMicPermissionList(style: .settings)

            Button("Remove Studio login item and pairing") {
                FluidVoiceStudioUninstall.removeStudioIntegration()
            }
            Text("This turns off launch-at-login, forgets pairing, and leaves the app in place. Delete FluidVoice from Applications to finish uninstalling.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            self.localMics = AudioDevice.listInputDevices().filter { RemoteMicDeviceIdentity.isRemote($0.uid) == false }
        }
    }

    @ViewBuilder
    private func prompt(_ prompt: RemoteMicPrompt?, confirmTitle: String) -> some View {
        if let prompt {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.isIncoming ? "\(prompt.peerName) wants to use \(prompt.deviceName)" : "Pair with \(prompt.peerName)")
                    .font(.body.weight(.semibold))
                Text("Confirm this code is the same on both Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(prompt.code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                HStack {
                    Button(confirmTitle) { self.remote.approve(prompt.id) }
                    Button("Decline") { self.remote.deny(prompt.id) }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct RemoteMicPermissionList: View {
    enum Style {
        case settings
        case onboarding
    }

    var style: Style
    var kinds: [RemoteMicPermissionKind] = RemoteMicPermissionKind.allCases
    @ObservedObject private var remote = RemoteMicController.shared
    @State private var states: [RemoteMicPermissionKind: RemoteMicPermissionState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RemoteMicPermissions.all.filter { self.kinds.contains($0.kind) }, id: \.kind) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(self.style == .onboarding ? .system(size: 15, weight: .semibold) : .body.weight(.medium))
                            .foregroundStyle(self.style == .onboarding ? Color.white : Color.primary)
                        Text(item.explanation)
                            .font(self.style == .onboarding ? .system(size: 12, weight: .medium) : .caption)
                            .foregroundStyle(self.style == .onboarding ? Color.white.opacity(0.62) : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(self.label(self.states[item.kind] ?? .missing))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(self.states[item.kind] == .granted ? Color.green : Color.secondary)
                    if self.states[item.kind] != .granted {
                        Button("Open Settings") {
                            RemoteMicPermissionProbe.request(item.kind)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear { self.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            self.refresh()
        }
    }

    private func refresh() {
        self.states = RemoteMicPermissionProbe.snapshot(localNetwork: self.remote.localNetwork)
    }

    private func label(_ state: RemoteMicPermissionState) -> String {
        switch state {
        case .granted: "Allowed"
        case .missing: "Needed"
        case .denied: "Blocked"
        }
    }
}
