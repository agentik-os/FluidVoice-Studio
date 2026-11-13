//
//  RemoteMicProtocol.swift
//  FluidVoice Studio
//
//  Framing, path selection, and device identities for remote microphones.
//  Part of FluidVoice (GPLv3). Isolated so upstream rebases stay small.
//

import Foundation

nonisolated enum RemoteMicProtocol {
    static let port: UInt16 = 18_765
    static let serviceType = "_fluidvoice-mic._tcp"
    static let sampleRate: UInt32 = 48_000
    static let magic = Data("FVR1".utf8)
    static let headerLength = 10
    static let maxPayload = 65_536
    static let pasteCharacterLimit = 8_000
}

nonisolated enum RemoteMicMessageType: UInt8, Equatable, Sendable {
    case hello = 1
    case secure = 2
    case ping = 3
    case pong = 4
}

nonisolated enum RemoteMicSecureType: UInt8, Equatable, Sendable {
    case accept = 1
    case reject = 2
    case audio = 3
    case paste = 4
    case resume = 5
    case pause = 6
}

nonisolated enum RemoteMicPeel: Equatable, Sendable {
    case needMore
    case invalid
    case frame(RemoteMicFrame)
}

nonisolated struct RemoteMicFrame: Equatable, Sendable {
    var type: RemoteMicMessageType
    var flags: UInt8
    var payload: Data

    func encoded() -> Data? {
        guard self.payload.count <= RemoteMicProtocol.maxPayload else { return nil }
        var data = Data()
        data.reserveCapacity(RemoteMicProtocol.headerLength + self.payload.count)
        data.append(RemoteMicProtocol.magic)
        data.append(self.type.rawValue)
        data.append(self.flags)
        RemoteMicBytes.append(UInt32(self.payload.count), to: &data)
        data.append(self.payload)
        return data
    }

    static func peel(from buffer: inout Data) -> RemoteMicPeel {
        guard buffer.count >= RemoteMicProtocol.headerLength else { return .needMore }
        guard buffer.prefix(RemoteMicProtocol.magic.count) == RemoteMicProtocol.magic else { return .invalid }
        let typeIndex = buffer.index(buffer.startIndex, offsetBy: 4)
        let flagsIndex = buffer.index(after: typeIndex)
        guard let type = RemoteMicMessageType(rawValue: buffer[typeIndex]) else { return .invalid }
        let length = RemoteMicBytes.readUInt32(buffer, at: 6)
        guard length <= RemoteMicProtocol.maxPayload else { return .invalid }
        let total = RemoteMicProtocol.headerLength + Int(length)
        guard buffer.count >= total else { return .needMore }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: RemoteMicProtocol.headerLength)
        let payloadEnd = buffer.index(payloadStart, offsetBy: Int(length))
        let frame = RemoteMicFrame(type: type, flags: buffer[flagsIndex], payload: Data(buffer[payloadStart..<payloadEnd]))
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return .frame(frame)
    }
}

nonisolated enum RemoteMicBytes {
    static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let bytes = [UInt8](data[start..<data.index(start, offsetBy: 4)])
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}

nonisolated enum RemoteMicAudioCodec {
    static func encode(sequence: UInt32, sampleRate: UInt32, pcm: Data) -> Data {
        var data = Data()
        data.reserveCapacity(8 + pcm.count)
        RemoteMicBytes.append(sequence, to: &data)
        RemoteMicBytes.append(sampleRate, to: &data)
        data.append(pcm)
        return data
    }

    static func decode(_ data: Data) -> (sequence: UInt32, sampleRate: UInt32, pcm: Data)? {
        guard data.count >= 8 else { return nil }
        let sequence = RemoteMicBytes.readUInt32(data, at: 0)
        let sampleRate = RemoteMicBytes.readUInt32(data, at: 4)
        guard sampleRate > 0 else { return nil }
        let start = data.index(data.startIndex, offsetBy: 8)
        let pcm = Data(data[start...])
        guard pcm.count.isMultiple(of: 2) else { return nil }
        return (sequence, sampleRate, pcm)
    }

    static func floatSamples(fromPCM16 pcm: Data) -> [Float] {
        let bytes = [UInt8](pcm)
        var samples: [Float] = []
        samples.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let unsigned = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let signed = Int16(bitPattern: unsigned)
            samples.append(Float(signed) / 32_768.0)
            index += 2
        }
        return samples
    }
}

nonisolated enum RemoteMicPasteCodec {
    static func encode(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= RemoteMicProtocol.pasteCharacterLimit else { return nil }
        let body = Data(trimmed.utf8)
        var data = Data([RemoteMicSecureType.paste.rawValue])
        data.append(body)
        return data
    }

    static func decode(_ data: Data) -> String? {
        guard let first = data.first, first == RemoteMicSecureType.paste.rawValue, data.count > 1 else { return nil }
        let body = data.dropFirst()
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        guard text.count <= RemoteMicProtocol.pasteCharacterLimit else { return nil }
        return text
    }
}

nonisolated enum RemoteMicPathKind: Int, Comparable, Sendable {
    case thunderbolt = 0
    case lan = 1
    case tailscale = 2
    case rejected = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .thunderbolt: "Thunderbolt"
        case .lan: "Local network"
        case .tailscale: "Tailscale"
        case .rejected: "Unavailable"
        }
    }
}

nonisolated struct RemoteMicEndpoint: Equatable, Sendable {
    var address: String
    var port: UInt16
    var interfaceName: String?
    var kind: RemoteMicPathKind
    var bonjourName: String? = nil
    var bonjourType: String? = nil
    var bonjourDomain: String? = nil

    static func best(among endpoints: [RemoteMicEndpoint]) -> RemoteMicEndpoint? {
        endpoints.filter { $0.kind != .rejected }.min { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.address < rhs.address
        }
    }
}

nonisolated enum RemoteMicPath {
    static func classify(address: String, interfaceName: String?) -> RemoteMicPathKind {
        let cleaned = self.clean(address)
        switch self.family(cleaned) {
        case .publicInternet, .loopback, .unspecified, .unknown:
            return .rejected
        case .tailscale:
            return .tailscale
        case .linkLocal:
            return .thunderbolt
        case .privateLAN:
            return self.isThunderboltInterface(interfaceName) ? .thunderbolt : .lan
        case .name:
            if self.isThunderboltInterface(interfaceName) { return .thunderbolt }
            if self.isLocalInterface(interfaceName) { return .lan }
            return .rejected
        }
    }

    static func allows(_ address: String, interfaceName: String?) -> Bool {
        self.classify(address: address, interfaceName: interfaceName) != .rejected
    }

    private enum Family {
        case publicInternet
        case loopback
        case unspecified
        case unknown
        case tailscale
        case linkLocal
        case privateLAN
        case name
    }

    private static func clean(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        if let zone = value.firstIndex(of: "%") {
            value = String(value[..<zone])
        }
        return value
    }

    private static func family(_ address: String) -> Family {
        if address.isEmpty { return .unknown }
        if address.contains(":") { return self.ipv6Family(address) }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return address.allSatisfy({ $0.isNumber || $0 == "." }) ? .unknown : .name
        }
        let octets = parts.compactMap { UInt16($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return .unknown }
        let a = octets[0]
        let b = octets[1]
        if a == 0 { return .unspecified }
        if a == 127 { return .loopback }
        if a == 10 { return .privateLAN }
        if a == 192 && b == 168 { return .privateLAN }
        if a == 172 && (16...31).contains(b) { return .privateLAN }
        if a == 169 && b == 254 { return .linkLocal }
        if a == 100 && (64...127).contains(b) { return .tailscale }
        return .publicInternet
    }

    private static func ipv6Family(_ address: String) -> Family {
        let lower = address.lowercased()
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" { return .loopback }
        if lower == "::" { return .unspecified }
        if lower.hasPrefix("fe80:") { return .linkLocal }
        if lower.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .privateLAN }
        return .publicInternet
    }

    private static func isThunderboltInterface(_ name: String?) -> Bool {
        guard let name else { return false }
        let lower = name.lowercased()
        return lower.contains("bridge") || lower.contains("thunderbolt") || lower.hasPrefix("tb")
    }

    private static func isLocalInterface(_ name: String?) -> Bool {
        guard let name else { return false }
        let lower = name.lowercased()
        if lower.hasPrefix("en") || lower.hasPrefix("awdl") || lower.hasPrefix("llw") { return true }
        return self.isThunderboltInterface(lower)
    }
}

nonisolated enum RemoteMicDeviceIdentity {
    static let prefix = "fluidvoice.remote."

    static func makeUID(peerID: String, deviceUID: String) -> String {
        self.prefix + peerID + "|" + deviceUID
    }

    static func isRemote(_ uid: String) -> Bool {
        uid.hasPrefix(self.prefix)
    }

    static func parse(_ uid: String) -> (peerID: String, deviceUID: String)? {
        guard uid.hasPrefix(self.prefix) else { return nil }
        let rest = uid.dropFirst(self.prefix.count)
        guard let bar = rest.firstIndex(of: "|") else { return nil }
        let peerID = String(rest[..<bar])
        let deviceUID = String(rest[rest.index(after: bar)...])
        guard peerID.isEmpty == false, deviceUID.isEmpty == false else { return nil }
        return (peerID, deviceUID)
    }

    static func displayName(device: String, computer: String) -> String {
        let mic = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = computer.trimmingCharacters(in: .whitespacesAndNewlines)
        if mic.isEmpty { return mac.isEmpty ? "Remote microphone" : "Microphone of \(mac)" }
        if mac.isEmpty { return mic }
        return "\(mic) — \(mac)"
    }

    static func syntheticObjectID(peerID: String, deviceUID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in (peerID + "|" + deviceUID).utf8 {
            hash = hash &* 1_677_7619 &+ UInt32(byte)
        }
        return 0xF000_0000 | (hash & 0x0FFF_FFFF)
    }
}

nonisolated struct RemoteMicHello: Equatable, Sendable {
    var peerID: String
    var name: String
    var role: String
    var agreementPublic: Data
    var signingPublic: Data
    var nonce: Data
    var signature: Data
    var deviceUID: String
    var deviceName: String

    static func encode(_ hello: RemoteMicHello) -> Data? {
        guard hello.peerID.isEmpty == false, hello.name.isEmpty == false else { return nil }
        let object: [String: String] = [
            "peerID": hello.peerID,
            "name": hello.name,
            "role": hello.role,
            "agreement": hello.agreementPublic.base64EncodedString(),
            "signing": hello.signingPublic.base64EncodedString(),
            "nonce": hello.nonce.base64EncodedString(),
            "signature": hello.signature.base64EncodedString(),
            "deviceUID": hello.deviceUID,
            "deviceName": hello.deviceName,
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> RemoteMicHello? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let peerID = object["peerID"] as? String, peerID.isEmpty == false,
              let name = object["name"] as? String, name.isEmpty == false,
              let role = object["role"] as? String,
              let agreement = Self.data(object["agreement"]),
              let signing = Self.data(object["signing"]),
              let nonce = Self.data(object["nonce"]),
              let signature = Self.data(object["signature"])
        else { return nil }
        return RemoteMicHello(
            peerID: peerID,
            name: name,
            role: role,
            agreementPublic: agreement,
            signingPublic: signing,
            nonce: nonce,
            signature: signature,
            deviceUID: object["deviceUID"] as? String ?? "",
            deviceName: object["deviceName"] as? String ?? ""
        )
    }

    private static func data(_ value: Any?) -> Data? {
        guard let text = value as? String else { return nil }
        return Data(base64Encoded: text)
    }
}

nonisolated struct RemoteMicGrant: Codable, Equatable, Hashable, Sendable {
    var peerID: String
    var deviceUID: String
    var peerName: String
    var deviceName: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.peerID)
        hasher.combine(self.deviceUID)
    }
}
