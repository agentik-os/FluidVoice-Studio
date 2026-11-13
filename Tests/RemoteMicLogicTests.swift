//
//  RemoteMicLogicTests.swift
//  FluidVoice Studio
//
//  Standalone checks for discovery, pairing, framing, and the Screen Sharing hotkey.
//

import Foundation

@main
struct RemoteMicLogicTests {
    static func main() {
        self.testFrames()
        self.testAudioAndPaste()
        self.testPaths()
        self.testDiscovery()
        self.testSessionAndApproval()
        self.testHotkey()
        self.testPermissionsAndDevices()
        self.testPairing()
        print("Passed \(Check.count) remote-microphone cases")
    }

    private static func testFrames() {
        let ping = RemoteMicFrame(type: .ping, flags: 0, payload: Data())
        var buffer = ping.encoded() ?? Data()
        let pong = RemoteMicFrame(type: .pong, flags: 7, payload: Data([1, 2, 3]))
        buffer.append(pong.encoded() ?? Data())
        guard case let .frame(first) = RemoteMicFrame.peel(from: &buffer) else { Check.fail("first frame") }
        Check.ok(first == ping, "ping round trip")
        guard case let .frame(second) = RemoteMicFrame.peel(from: &buffer) else { Check.fail("second frame") }
        Check.ok(second == pong, "pong round trip")
        Check.ok(buffer.isEmpty, "buffer drained")
        Check.ok(RemoteMicFrame.peel(from: &buffer) == .needMore, "empty buffer needs more")

        var truncated = Data((ping.encoded() ?? Data()).dropLast())
        Check.ok(RemoteMicFrame.peel(from: &truncated) == .needMore, "truncated frame waits")

        var junk = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        Check.ok(RemoteMicFrame.peel(from: &junk) == .invalid, "bad magic is rejected")

        var oversized = Data("FVR1".utf8)
        oversized.append(RemoteMicMessageType.ping.rawValue)
        oversized.append(0)
        RemoteMicBytes.append(UInt32(RemoteMicProtocol.maxPayload + 1), to: &oversized)
        Check.ok(RemoteMicFrame.peel(from: &oversized) == .invalid, "oversized payload is rejected")

        let hello = RemoteMicHello(
            peerID: "peer-1",
            name: "mbc-studio",
            role: "share",
            agreementPublic: Data([1, 2, 3]),
            signingPublic: Data([4, 5]),
            nonce: Data([9]),
            signature: Data([8]),
            deviceUID: "jabra",
            deviceName: "Jabra PanaCast 50"
        )
        let encoded = RemoteMicHello.encode(hello)
        Check.ok(RemoteMicHello.decode(encoded ?? Data()) == hello, "hello round trip")
        Check.ok(RemoteMicHello.decode(Data("{}".utf8)) == nil, "empty hello is rejected")
    }

    private static func testAudioAndPaste() {
        let pcm = Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let encoded = RemoteMicAudioCodec.encode(sequence: 4, sampleRate: 48_000, pcm: pcm)
        let decoded = RemoteMicAudioCodec.decode(encoded)
        Check.ok(decoded?.sequence == 4 && decoded?.sampleRate == 48_000 && decoded?.pcm == pcm, "audio frame")
        let floats = RemoteMicAudioCodec.floatSamples(fromPCM16: pcm)
        Check.ok(floats.count == 3, "three samples")
        Check.ok(floats[0] == 0, "silence")
        Check.ok(abs(floats[1] - 0.9999695) < 0.0001, "full scale")
        Check.ok(floats[2] == -1, "negative full scale")
        Check.ok(RemoteMicAudioCodec.decode(Data([0, 0, 0, 1])) == nil, "short audio is rejected")

        let paste = RemoteMicPasteCodec.encode("Hello from agk-studio")
        Check.ok(RemoteMicPasteCodec.decode(paste ?? Data()) == "Hello from agk-studio", "paste round trip")
        Check.ok(RemoteMicPasteCodec.encode(String(repeating: "a", count: 8_001)) == nil, "paste limit")
        Check.ok(RemoteMicPasteCodec.encode("   ") == nil, "blank paste")
    }

    private static func testPaths() {
        Check.ok(RemoteMicPath.classify(address: "8.8.8.8", interfaceName: "en0") == .rejected, "public internet is refused")
        Check.ok(RemoteMicPath.classify(address: "100.111.101.38", interfaceName: nil) == .tailscale, "mbc tailscale")
        Check.ok(RemoteMicPath.classify(address: "100.122.224.94", interfaceName: "utun3") == .tailscale, "agk tailscale")
        Check.ok(RemoteMicPath.classify(address: "192.168.3.1", interfaceName: "bridge0") == .thunderbolt, "thunderbolt bridge")
        Check.ok(RemoteMicPath.classify(address: "192.168.3.1", interfaceName: "en0") == .lan, "same subnet on wifi is LAN")
        Check.ok(RemoteMicPath.classify(address: "169.254.10.20", interfaceName: nil) == .thunderbolt, "link local")
        Check.ok(RemoteMicPath.classify(address: "fd7a:115c:a1e0::12", interfaceName: nil) == .tailscale, "tailscale ipv6")
        Check.ok(RemoteMicPath.classify(address: "fe80::1", interfaceName: nil) == .thunderbolt, "ipv6 link local")
        Check.ok(RemoteMicPath.classify(address: "mbc-studio", interfaceName: "bridge0") == .thunderbolt, "bonjour on bridge")
        Check.ok(RemoteMicPath.allows("1.1.1.1", interfaceName: "bridge0") == false, "public address stays closed")

        let best = RemoteMicEndpoint.best(among: [
            RemoteMicEndpoint(address: "100.111.101.38", port: 18_765, interfaceName: "utun", kind: .tailscale),
            RemoteMicEndpoint(address: "192.168.1.8", port: 18_765, interfaceName: "en0", kind: .lan),
            RemoteMicEndpoint(address: "192.168.3.1", port: 18_765, interfaceName: "bridge0", kind: .thunderbolt),
            RemoteMicEndpoint(address: "8.8.8.8", port: 18_765, interfaceName: nil, kind: .rejected),
        ])
        Check.ok(best?.address == "192.168.3.1" && best?.kind == .thunderbolt, "thunderbolt wins")
    }

    private static func testDiscovery() {
        let jsonText = """
        {"Self":{"HostName":"agk-studio","OS":"macOS","Online":true,"TailscaleIPs":["100.122.224.94"]},
         "Peer":{
           "a":{"HostName":"mbc-studio","OS":"macOS","Online":true,"TailscaleIPs":["100.111.101.38","fd7a:115c:a1e0::38"]},
           "b":{"HostName":"phone","OS":"iOS","Online":true,"TailscaleIPs":["100.1.1.1"]},
           "c":{"HostName":"offline-mac","OS":"macOS","Online":false,"TailscaleIPs":["100.2.2.2"]}
         }}
        """
        let json = Data(jsonText.utf8)
        let peers = RemoteMicDiscovery.parseTailscaleStatus(json)
        Check.ok(peers.count == 1 && peers.first?.name == "mbc-studio", "only the online Mac")
        Check.ok(peers.first?.endpoints.contains { $0.kind == .tailscale } == true, "tailscale path")
        Check.ok(RemoteMicDiscovery.selfAddresses(in: json) == ["100.122.224.94"], "self addresses")

        let bonjour = RemoteMicPeer(
            id: "uuid-mbc",
            name: "mbc-studio",
            endpoints: [RemoteMicEndpoint(address: "192.168.3.1", port: 18_765, interfaceName: "bridge0", kind: .thunderbolt)],
            signingPublicKey: nil,
            sharedDeviceUID: "jabra",
            sharedDeviceName: "Jabra PanaCast 50"
        )
        let merged = RemoteMicDiscovery.merge(
            bonjour: [bonjour],
            tailscale: peers,
            selfPeerID: "uuid-agk",
            selfAddresses: ["100.122.224.94"]
        )
        Check.ok(merged.count == 1, "one merged peer")
        Check.ok(merged.first?.id == "uuid-mbc", "bonjour identity wins")
        Check.ok(merged.first?.bestPath?.kind == .thunderbolt, "merged peer prefers thunderbolt")
        Check.ok(merged.first?.endpoints.contains { $0.kind == .tailscale } == true, "tailscale remains as fallback")

        let echo = RemoteMicDiscovery.merge(
            bonjour: [RemoteMicPeer(id: "uuid-agk", name: "agk-studio", endpoints: bonjour.endpoints, signingPublicKey: nil, sharedDeviceUID: "", sharedDeviceName: "")],
            tailscale: [],
            selfPeerID: "uuid-agk",
            selfAddresses: []
        )
        Check.ok(echo.isEmpty, "this Mac is not discovered as itself")
    }

    private static func testSessionAndApproval() {
        var machine = RemoteMicSessionMachine()
        Check.ok(machine.acceptsAudio == false, "no audio before hello")
        machine.receiveHello(code: "ABCDEF", peerName: "mbc-studio", deviceUID: "jabra", deviceName: "Jabra", pinned: true)
        machine.localAccept()
        Check.ok(machine.acceptsAudio == false, "one approval is not enough")
        machine.remoteAccept()
        Check.ok(machine.acceptsAudio, "both approvals open audio")
        if case let .live(deviceUID, _) = machine.phase {
            Check.ok(deviceUID == "jabra", "live device")
        } else {
            Check.fail("expected live")
        }

        var rejected = RemoteMicSessionMachine()
        rejected.receiveHello(code: "ABCDEF", peerName: "mbc-studio", deviceUID: "jabra", deviceName: "Jabra", pinned: false)
        rejected.reject()
        rejected.localAccept()
        rejected.remoteAccept()
        Check.ok(rejected.acceptsAudio == false, "reject sticks")

        Check.ok(RemoteMicApproval.shouldAutoAccept(isSharer: true, pinned: true, deviceGranted: true), "granted device auto-accepts")
        Check.ok(RemoteMicApproval.shouldAutoAccept(isSharer: true, pinned: true, deviceGranted: false) == false, "new device still asks")
        Check.ok(RemoteMicApproval.shouldAutoAccept(isSharer: false, pinned: true, deviceGranted: false), "listener reconnects after the pin")
        Check.ok(RemoteMicApproval.shouldAutoAccept(isSharer: false, pinned: false, deviceGranted: true) == false, "first pair is manual")
    }

    private static func testHotkey() {
        let mask = RemoteMicHotkeyMatch.relevantMask
        let chord = RemoteMicHotkeyMatch.controlFlag | RemoteMicHotkeyMatch.optionFlag
        let withGlobe = chord | RemoteMicHotkeyMatch.functionFlag
        Check.ok(
            RemoteMicHotkeyMatch.flagsMatch(eventFlags: withGlobe, shortcutFlags: chord, relevantMask: mask, shortcutIsModifierOnly: false),
            "ctrl+opt+D ignores the extra Fn flag"
        )
        Check.ok(
            RemoteMicHotkeyMatch.flagsMatch(eventFlags: chord, shortcutFlags: chord, relevantMask: mask, shortcutIsModifierOnly: false),
            "ctrl+opt+D without Fn"
        )
        Check.ok(
            RemoteMicHotkeyMatch.flagsMatch(eventFlags: RemoteMicHotkeyMatch.controlFlag, shortcutFlags: chord, relevantMask: mask, shortcutIsModifierOnly: false) == false,
            "ctrl alone does not match"
        )
        Check.ok(
            RemoteMicHotkeyMatch.flagsMatch(eventFlags: RemoteMicHotkeyMatch.functionFlag, shortcutFlags: 0, relevantMask: mask, shortcutIsModifierOnly: true) == false,
            "Fn-only Automatic mode still requires the function flag"
        )
        let functionChord = chord | RemoteMicHotkeyMatch.functionFlag
        Check.ok(
            RemoteMicHotkeyMatch.flagsMatch(eventFlags: chord, shortcutFlags: functionChord, relevantMask: mask, shortcutIsModifierOnly: false) == false,
            "a shortcut that includes Fn still requires it"
        )
        Check.ok(
            RemoteMicHotkeyMatch.keyCodesMatch(shortcutKeyCode: 2, eventKeyCode: 9, unicode: "d", eventFlags: chord),
            "Screen Sharing unicode D counts as the D key"
        )
        Check.ok(
            RemoteMicHotkeyMatch.keyCodesMatch(shortcutKeyCode: 2, eventKeyCode: 9, unicode: "d", eventFlags: 0) == false,
            "plain D is not rewritten"
        )
        Check.ok(
            RemoteMicHotkeyMatch.canonicalEventKeyCode(rawKeyCode: 9, unicode: "D", eventFlags: withGlobe, activeRemotePress: false) == 2,
            "keydown canonical key code"
        )
        Check.ok(
            RemoteMicHotkeyMatch.canonicalEventKeyCode(rawKeyCode: 9, unicode: "d", eventFlags: 0, activeRemotePress: true) == 2,
            "keyup still matches after the modifiers are released"
        )
        Check.ok(
            RemoteMicHotkeyMatch.canonicalEventKeyCode(rawKeyCode: 9, unicode: "d", eventFlags: 0, activeRemotePress: false) == 9,
            "typing D is unchanged"
        )
    }

    private static func testPermissionsAndDevices() {
        let copies = RemoteMicPermissions.all
        Check.ok(copies.count == 4, "four permissions")
        Check.ok(Set(copies.map(\.settingsURL)).count == 4, "distinct settings panes")
        for copy in copies {
            Check.ok(copy.explanation.contains("\n") == false, "\(copy.kind) explanation is one line")
            Check.ok(copy.explanation.contains("."), "\(copy.kind) explanation")
            Check.ok(copy.settingsURL.contains("Privacy_"), "\(copy.kind) pane")
        }
        let uid = RemoteMicDeviceIdentity.makeUID(peerID: "uuid-mbc", deviceUID: "AppleUSBAudioEngine:Jabra:2")
        let parsed = RemoteMicDeviceIdentity.parse(uid)
        Check.ok(parsed?.peerID == "uuid-mbc" && parsed?.deviceUID == "AppleUSBAudioEngine:Jabra:2", "uid round trip")
        Check.ok(RemoteMicDeviceIdentity.isRemote(uid), "remote prefix")
        Check.ok(RemoteMicDeviceIdentity.isRemote("BuiltInMicrophoneDevice") == false, "local uid")
        let objectID = RemoteMicDeviceIdentity.syntheticObjectID(peerID: "uuid-mbc", deviceUID: "jabra")
        Check.ok(objectID == RemoteMicDeviceIdentity.syntheticObjectID(peerID: "uuid-mbc", deviceUID: "jabra"), "stable object id")
        Check.ok(objectID >= 0xF000_0000, "object id stays out of the HAL range")
        Check.ok(
            RemoteMicDeviceIdentity.displayName(device: "Jabra PanaCast 50", computer: "mbc-studio") == "Jabra PanaCast 50 — mbc-studio",
            "picker name"
        )
    }

    private static func testPairing() {
        let alice = RemoteMicPairing.generateAgreement()
        let bob = RemoteMicPairing.generateAgreement()
        let aliceSign = RemoteMicPairing.generateSigning()
        let nonceA = Data([1, 2, 3, 4])
        let nonceB = Data([9, 8, 7, 6])
        let salt = RemoteMicPairing.salt(localNonce: nonceA, remoteNonce: nonceB)
        let forward = try? RemoteMicPairing.agreementKey(localPrivate: alice.privateKey, remotePublic: bob.publicKey, salt: salt)
        let backward = try? RemoteMicPairing.agreementKey(localPrivate: bob.privateKey, remotePublic: alice.publicKey, salt: salt)
        Check.ok(forward == backward && (forward?.count == 32), "shared session key")
        let left = RemoteMicPairing.confirmationCode(
            localPublic: alice.publicKey, remotePublic: bob.publicKey, localNonce: nonceA, remoteNonce: nonceB
        )
        let right = RemoteMicPairing.confirmationCode(
            localPublic: bob.publicKey, remotePublic: alice.publicKey, localNonce: nonceB, remoteNonce: nonceA
        )
        Check.ok(left == right && left.count == 6, "both Macs show the same code")
        Check.ok(left.allSatisfy { RemoteMicPairing.alphabet.contains($0) }, "code alphabet")

        let signature = try? RemoteMicPairing.sign(alice.publicKey, privateKey: aliceSign.privateKey)
        Check.ok(
            RemoteMicPairing.verify(signature: signature ?? Data(), data: alice.publicKey, publicKey: aliceSign.publicKey),
            "identity signature"
        )
        Check.ok(
            RemoteMicPairing.verify(signature: signature ?? Data(), data: bob.publicKey, publicKey: aliceSign.publicKey) == false,
            "signature does not cover a different key"
        )

        let key = forward ?? Data()
        let sealed = try? RemoteMicPairing.seal(Data("pcm".utf8), key: key)
        let opened = try? RemoteMicPairing.open(sealed ?? Data(), key: key)
        Check.ok(opened == Data("pcm".utf8), "encrypted payload")
        var tampered = sealed ?? Data()
        if tampered.isEmpty == false {
            tampered[tampered.startIndex] ^= 0xFF
        }
        Check.ok((try? RemoteMicPairing.open(tampered, key: key)) == nil, "tampering is rejected")
        Check.ok(RemoteMicPairing.code(from: Data([0xBA, 0x78, 0x16, 0xBF])).count == 6, "code width")
    }
}

enum Check {
    static var count = 0

    static func ok(_ condition: Bool, _ message: String) {
        self.count += 1
        if condition == false {
            self.fail(message)
        }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
