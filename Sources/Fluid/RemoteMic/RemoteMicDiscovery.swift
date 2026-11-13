//
//  RemoteMicDiscovery.swift
//  FluidVoice Studio
//
//  Merges Bonjour sights with Tailscale peers and keeps the fastest private path.
//

import Foundation

nonisolated struct RemoteMicPeer: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var endpoints: [RemoteMicEndpoint]
    var signingPublicKey: Data?
    var sharedDeviceUID: String
    var sharedDeviceName: String

    var bestPath: RemoteMicEndpoint? {
        RemoteMicEndpoint.best(among: self.endpoints)
    }
}

nonisolated enum RemoteMicDiscovery {
    static let tailscaleIDPrefix = "ts:"

    static func selfAddresses(in data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["Self"] as? [String: Any]
        else { return [] }
        return Set(node["TailscaleIPs"] as? [String] ?? [])
    }

    static func parseTailscaleStatus(_ data: Data) -> [RemoteMicPeer] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers = root["Peer"] as? [String: Any] ?? [:]
        var found: [RemoteMicPeer] = []
        for value in peers.values {
            guard let peer = value as? [String: Any] else { continue }
            if let online = peer["Online"] as? Bool, online == false { continue }
            let os = peer["OS"] as? String
            guard self.isMacPeer(os) else { continue }
            let name = self.hostName(peer)
            guard name.isEmpty == false else { continue }
            let addresses = peer["TailscaleIPs"] as? [String] ?? []
            let endpoints = addresses.compactMap { address -> RemoteMicEndpoint? in
                let kind = RemoteMicPath.classify(address: address, interfaceName: "utun")
                guard kind == .tailscale else { return nil }
                return RemoteMicEndpoint(address: address, port: RemoteMicProtocol.port, interfaceName: "utun", kind: kind)
            }
            guard endpoints.isEmpty == false else { continue }
            found.append(
                RemoteMicPeer(
                    id: self.tailscaleIDPrefix + name.lowercased(),
                    name: name,
                    endpoints: endpoints,
                    signingPublicKey: nil,
                    sharedDeviceUID: "",
                    sharedDeviceName: ""
                )
            )
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func merge(
        bonjour: [RemoteMicPeer],
        tailscale: [RemoteMicPeer],
        selfPeerID: String,
        selfAddresses: Set<String>
    ) -> [RemoteMicPeer] {
        var byName: [String: RemoteMicPeer] = [:]
        for peer in bonjour + tailscale {
            if peer.id == selfPeerID { continue }
            let cleaned = self.withoutSelf(peer, selfAddresses: selfAddresses)
            guard cleaned.endpoints.isEmpty == false else { continue }
            let key = cleaned.name.lowercased()
            if var existing = byName[key] {
                existing.endpoints.append(contentsOf: cleaned.endpoints)
                if existing.id.hasPrefix(self.tailscaleIDPrefix), cleaned.id.hasPrefix(self.tailscaleIDPrefix) == false {
                    existing.id = cleaned.id
                }
                if existing.sharedDeviceUID.isEmpty {
                    existing.sharedDeviceUID = cleaned.sharedDeviceUID
                    existing.sharedDeviceName = cleaned.sharedDeviceName
                }
                if existing.signingPublicKey == nil {
                    existing.signingPublicKey = cleaned.signingPublicKey
                }
                existing.endpoints = self.unique(existing.endpoints)
                byName[key] = existing
            } else {
                var inserted = cleaned
                inserted.endpoints = self.unique(cleaned.endpoints)
                byName[key] = inserted
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func withoutSelf(_ peer: RemoteMicPeer, selfAddresses: Set<String>) -> RemoteMicPeer {
        var copy = peer
        copy.endpoints = peer.endpoints.filter { endpoint in
            endpoint.kind != .rejected && selfAddresses.contains(endpoint.address) == false
        }
        return copy
    }

    private static func unique(_ endpoints: [RemoteMicEndpoint]) -> [RemoteMicEndpoint] {
        var seen: [String] = []
        var result: [RemoteMicEndpoint] = []
        for endpoint in endpoints {
            let key = "\(endpoint.kind.rawValue)|\(endpoint.address)|\(endpoint.interfaceName ?? "")"
            guard seen.contains(key) == false else { continue }
            seen.append(key)
            result.append(endpoint)
        }
        return result
    }

    private static func hostName(_ peer: [String: Any]) -> String {
        let host = (peer["HostName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty == false { return host }
        let dns = (peer["DNSName"] as? String) ?? ""
        return dns.split(separator: ".").first.map(String.init) ?? ""
    }

    private static func isMacPeer(_ os: String?) -> Bool {
        guard let os, os.isEmpty == false else { return true }
        return os.lowercased().contains("mac")
    }
}
