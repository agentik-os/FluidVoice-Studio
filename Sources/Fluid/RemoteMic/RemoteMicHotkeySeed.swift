//
//  RemoteMicHotkeySeed.swift
//  FluidVoice Studio
//
//  Adds Ctrl+Option+D once, beside the existing default, without putting it back
//  if you remove it later.
//

import AppKit
import Combine
import Foundation

enum RemoteMicHotkeySeed {
    static let migrationDefaultsKey = "FluidVoiceStudio.remoteHotkeySeeded"

    static func makeShortcut() -> HotkeyShortcut {
        HotkeyShortcut(
            keyCode: RemoteMicHotkeyMatch.remoteControlKeyCode,
            modifierFlags: [.control, .option]
        )
    }
}

extension SettingsStore {
    func seedRemoteControlHotkeyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: RemoteMicHotkeySeed.migrationDefaultsKey) == false else { return }
        var shortcuts = self.primaryDictationShortcuts
        let remote = RemoteMicHotkeySeed.makeShortcut()
        if shortcuts.contains(where: { $0.hasSameTrigger(as: remote) }) == false {
            shortcuts.append(remote)
            self.primaryDictationShortcuts = shortcuts
        }
        defaults.set(true, forKey: RemoteMicHotkeySeed.migrationDefaultsKey)
    }

    var shareLocalMicrophones: Bool {
        get { UserDefaults.standard.bool(forKey: Self.shareLocalMicrophonesKey) }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.shareLocalMicrophonesKey)
            RemoteMicController.shared.applySharingPreference()
        }
    }

    var sharedMicrophoneUID: String {
        get { UserDefaults.standard.string(forKey: Self.sharedMicrophoneUIDKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.sharedMicrophoneUIDKey)
            RemoteMicController.shared.applySharedDevice()
        }
    }

    var remotePasteEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.remotePasteEnabledKey) }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.remotePasteEnabledKey)
        }
    }

    var remoteMicGrants: [RemoteMicGrant] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.remoteMicGrantsKey),
                  let grants = try? JSONDecoder().decode([RemoteMicGrant].self, from: data)
            else { return [] }
            return grants
        }
        set {
            self.objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.remoteMicGrantsKey)
            }
        }
    }

    func isRemoteMicGranted(peerID: String, deviceUID: String) -> Bool {
        self.remoteMicGrants.contains { $0.peerID == peerID && $0.deviceUID == deviceUID }
    }

    func grantRemoteMic(peerID: String, deviceUID: String, peerName: String, deviceName: String) {
        var grants = self.remoteMicGrants.filter { $0.peerID != peerID || $0.deviceUID != deviceUID }
        grants.append(RemoteMicGrant(peerID: peerID, deviceUID: deviceUID, peerName: peerName, deviceName: deviceName))
        self.remoteMicGrants = grants
    }

    func revokeRemoteMic(peerID: String, deviceUID: String) {
        self.remoteMicGrants = self.remoteMicGrants.filter { $0.peerID != peerID || $0.deviceUID != deviceUID }
    }

    private static let shareLocalMicrophonesKey = "FluidVoiceStudio.shareLocalMicrophones"
    private static let sharedMicrophoneUIDKey = "FluidVoiceStudio.sharedMicrophoneUID"
    private static let remotePasteEnabledKey = "FluidVoiceStudio.remotePasteEnabled"
    private static let remoteMicGrantsKey = "FluidVoiceStudio.remoteMicGrants"
}
