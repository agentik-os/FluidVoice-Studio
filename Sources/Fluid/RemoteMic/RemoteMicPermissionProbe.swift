//
//  RemoteMicPermissionProbe.swift
//  FluidVoice Studio
//

import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid

enum RemoteMicPermissionProbe {
    static func snapshot(localNetwork: RemoteMicPermissionState) -> [RemoteMicPermissionKind: RemoteMicPermissionState] {
        [
            .microphone: self.microphone(),
            .accessibility: AXIsProcessTrusted() ? .granted : .missing,
            .inputMonitoring: self.inputMonitoring(),
            .localNetwork: localNetwork,
        ]
    }

    static func request(_ kind: RemoteMicPermissionKind) {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .denied, .restricted:
                self.open(kind)
            case .authorized:
                break
            @unknown default:
                self.open(kind)
            }
        case .accessibility:
            self.promptForAccessibility()
            self.open(kind)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            self.open(kind)
        case .localNetwork:
            RemoteMicController.shared.start()
            self.open(kind)
        }
    }

    static func open(_ kind: RemoteMicPermissionKind) {
        guard let copy = RemoteMicPermissions.copy(for: kind),
              let url = URL(string: copy.settingsURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func microphone() -> RemoteMicPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .missing
        @unknown default:
            return .missing
        }
    }

    private static func inputMonitoring() -> RemoteMicPermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .missing
        }
    }

    private static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
