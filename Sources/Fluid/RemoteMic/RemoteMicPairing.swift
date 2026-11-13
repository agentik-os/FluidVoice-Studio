//
//  RemoteMicPairing.swift
//  FluidVoice Studio
//
//  X25519 session keys, identity signatures, and the short code both Macs compare.
//

import CryptoKit
import Foundation

nonisolated enum RemoteMicCryptoError: Error, Equatable {
    case key
    case seal
}

nonisolated enum RemoteMicPairing {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let info = Data("fluidvoice-studio-mic-v1".utf8)

    static func generateAgreement() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    static func generateSigning() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    static func sign(_ data: Data, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: data)
    }

    static func verify(signature: Data, data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    static func agreementKey(localPrivate: Data, remotePublic: Data, salt: Data) throws -> Data {
        let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localPrivate)
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublic)
        let shared = try local.sharedSecretFromKeyAgreement(with: remote)
        let symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: self.info,
            outputByteCount: 32
        )
        return symmetric.withUnsafeBytes { Data($0) }
    }

    static func confirmationCode(
        localPublic: Data,
        remotePublic: Data,
        localNonce: Data,
        remoteNonce: Data
    ) -> String {
        let publics = [localPublic, remotePublic].sorted { $0.lexicographicallyPrecedes($1) }
        let nonces = [localNonce, remoteNonce].sorted { $0.lexicographicallyPrecedes($1) }
        var material = Data("fv-studio-v1".utf8)
        for part in publics + nonces {
            material.append(part)
        }
        return self.code(from: Data(SHA256.hash(data: material)))
    }

    static func code(from digest: Data) -> String {
        let bytes = [UInt8](digest.prefix(4))
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        var characters: [Character] = []
        for _ in 0..<6 {
            let index = Int(value & 31)
            characters.append(self.alphabet[index])
            value >>= 5
        }
        return String(characters)
    }

    static func salt(localNonce: Data, remoteNonce: Data) -> Data {
        let ordered = [localNonce, remoteNonce].sorted { $0.lexicographicallyPrecedes($1) }
        var salt = Data()
        for nonce in ordered { salt.append(nonce) }
        return salt
    }

    static func seal(_ payload: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw RemoteMicCryptoError.key }
        let symmetric = SymmetricKey(data: key)
        let sealed = try AES.GCM.seal(payload, using: symmetric)
        guard let combined = sealed.combined else { throw RemoteMicCryptoError.seal }
        return combined
    }

    static func open(_ payload: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw RemoteMicCryptoError.key }
        let symmetric = SymmetricKey(data: key)
        let box = try AES.GCM.SealedBox(combined: payload)
        return try AES.GCM.open(box, using: symmetric)
    }
}
