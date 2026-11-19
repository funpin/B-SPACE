import Foundation

/// The bridges the shell exposes to its pages, read from
/// `packages/desktop/src/bridgeContract.json`. That file is the one description
/// both shells implement; `bridgeContract.test.ts` holds Electron's preload
/// scripts to it, and `BridgeRouter` holds this shell to it.
public struct BridgeContract: Equatable {
    public enum Kind: String, Decodable, Equatable {
        /// A plain property, read synchronously.
        case value
        /// A call that sends and returns `undefined`.
        case fire
        /// A call that returns a Promise of the shell's answer.
        case invoke
        /// Takes a callback for an event the shell sends.
        case subscribe
    }

    public struct Member: Decodable, Equatable {
        public let name: String
        public let kind: Kind
        /// Present for everything but a value.
        public let channel: String?
        /// Present for a subscription: whether it returns a function that
        /// removes the callback.
        public let unsubscribe: Bool?
        /// Present, and true, on a member this shell alone exposes: it stands
        /// in for something Chromium does by itself and WebKit does not, so
        /// Electron's preload does not have it.
        public let nativeOnly: Bool?

        public init(name: String, kind: Kind, channel: String? = nil, unsubscribe: Bool? = nil, nativeOnly: Bool? = nil) {
            self.name = name
            self.kind = kind
            self.channel = channel
            self.unsubscribe = unsubscribe
            self.nativeOnly = nativeOnly
        }
    }

    public enum Bridge: String, CaseIterable {
        /// `window.backspace`, the main window.
        case backspace
        /// `window.bspaceUpdate`, the update window.
        case bspaceUpdate
    }

    public struct Malformed: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    private let members: [Bridge: [Member]]

    public func members(of bridge: Bridge) -> [Member] {
        members[bridge] ?? []
    }

    /// Channels a page sends on, with the kind of call each is.
    public func callChannels(of bridge: Bridge) -> [String: Kind] {
        var channels: [String: Kind] = [:]
        for member in members(of: bridge) where member.kind == .fire || member.kind == .invoke {
            if let channel = member.channel { channels[channel] = member.kind }
        }
        return channels
    }

    /// Channels the shell sends events on.
    public func eventChannels(of bridge: Bridge) -> Set<String> {
        Set(members(of: bridge).filter { $0.kind == .subscribe }.compactMap(\.channel))
    }

    public init(data: Data) throws {
        let decoded: [String: [Member]]
        do {
            decoded = try JSONDecoder().decode([String: [Member]].self, from: data)
        } catch {
            throw Malformed(description: "the contract is not readable: \(error)")
        }
        let unknown = decoded.keys.filter { Bridge(rawValue: $0) == nil }.sorted()
        guard unknown.isEmpty else {
            throw Malformed(description: "unknown bridge \(unknown.joined(separator: ", "))")
        }

        var members: [Bridge: [Member]] = [:]
        for bridge in Bridge.allCases {
            guard let list = decoded[bridge.rawValue] else {
                throw Malformed(description: "\(bridge.rawValue): no member list")
            }
            try Self.validate(list, bridge: bridge)
            members[bridge] = list
        }
        self.members = members
    }

    private static func validate(_ list: [Member], bridge: Bridge) throws {
        var names = Set<String>()
        var callChannels = Set<String>()
        var eventChannels = Set<String>()
        for member in list {
            let place = "\(bridge.rawValue).\(member.name)"
            guard isIdentifier(member.name) else {
                throw Malformed(description: "\(place): not a usable member name")
            }
            guard names.insert(member.name).inserted else {
                throw Malformed(description: "\(place): declared twice")
            }
            // Left out, not false: a member of both shells is the ordinary case.
            guard member.nativeOnly ?? true else {
                throw Malformed(description: "\(place): \"nativeOnly\" is true or left out")
            }
            switch member.kind {
            case .value:
                guard member.channel == nil, member.unsubscribe == nil else {
                    throw Malformed(description: "\(place): a value has no channel")
                }
            case .fire, .invoke:
                guard let channel = member.channel, !channel.isEmpty else {
                    throw Malformed(description: "\(place): no channel")
                }
                guard member.unsubscribe == nil else {
                    throw Malformed(description: "\(place): only a subscription has \"unsubscribe\"")
                }
                guard callChannels.insert(channel).inserted else {
                    throw Malformed(description: "\(place): channel \(channel) is already used")
                }
            case .subscribe:
                guard let channel = member.channel, !channel.isEmpty else {
                    throw Malformed(description: "\(place): no channel")
                }
                guard member.unsubscribe != nil else {
                    throw Malformed(description: "\(place): a subscription says whether it can be removed")
                }
                guard eventChannels.insert(channel).inserted else {
                    throw Malformed(description: "\(place): channel \(channel) is already used")
                }
            }
        }
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy { rest.contains($0) }
    }
}
