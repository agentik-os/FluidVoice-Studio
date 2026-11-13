//
//  RemoteMicAudioCatalog.swift
//  FluidVoice Studio
//
//  Presents a paired remote microphone as an input the existing picker already understands.
//

import CoreAudio
import Foundation

enum RemoteMicAudioCatalog {
    static func merge(local: [AudioDevice.Device]) -> [AudioDevice.Device] {
        let remote = RemoteMicController.shared.selectableInputDevices()
        let seen = Set(local.map(\.uid))
        return local + remote.filter { seen.contains($0.uid) == false }
    }

    static func makeDevice(uid: String, name: String, alive: Bool) -> AudioDevice.Device {
        let parsed = RemoteMicDeviceIdentity.parse(uid)
        let objectID = parsed.map {
            RemoteMicDeviceIdentity.syntheticObjectID(peerID: $0.peerID, deviceUID: $0.deviceUID)
        } ?? 0xF000_0001
        return AudioDevice.Device(
            id: AudioObjectID(objectID),
            uid: uid,
            name: name,
            hasInput: true,
            hasOutput: false,
            transportType: kAudioDeviceTransportTypeVirtual,
            inputDataSourceID: nil,
            isAlive: alive
        )
    }
}
