import Foundation

/// What the shell answers a call with.
public enum BridgeReply {
    /// The page gets `undefined`, as from an Electron handler that returns nothing.
    case undefined
    /// The page gets `null`.
    case null
    /// The page gets this JSON-compatible value (`String`, `Bool`, a number,
    /// an array or a dictionary of those).
    case value(Any)
    /// The Promise rejects with this message.
    case failure(String)
}

/// The arguments of one call, as the page passed them. `undefined` and
/// functions arrive as `null`, as they would through `JSON.stringify`.
public struct BridgeArguments {
    public let values: [Any]

    public init(_ values: [Any]) {
        self.values = values
    }

    private func value(at index: Int) -> Any? {
        guard values.indices.contains(index), !(values[index] is NSNull) else { return nil }
        return values[index]
    }

    public func string(at index: Int) -> String? {
        value(at: index) as? String
    }

    /// A JavaScript boolean. A number is not one, though Foundation would
    /// happily read `1` as true.
    public func bool(at index: Int) -> Bool? {
        guard let number = value(at: index) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    public func array(at index: Int) -> [Any]? {
        value(at: index) as? [Any]
    }

    public func object(at index: Int) -> [String: Any]? {
        value(at: index) as? [String: Any]
    }
}

/// One message a page posted, checked against the contract.
public struct BridgeMessage {
    public let kind: BridgeContract.Kind
    public let channel: String
    public let arguments: BridgeArguments
}

public struct BridgeError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Routes the calls of one bridge to their handlers, by channel name, as
/// `ipcMain` does in Electron.
///
/// Every call channel of the contract has to be accounted for before the first
/// page loads: either a handler is registered for it, or it is listed in
/// `InterimReplies` as belonging to a later stage of the port. `unhandledChannels`
/// says what is left, and the shell refuses to start with anything in it.
public final class BridgeRouter {
    public typealias FireHandler = (BridgeArguments) -> Void
    public typealias InvokeHandler = (BridgeArguments, @escaping (BridgeReply) -> Void) -> Void

    private let callChannels: [String: BridgeContract.Kind]
    private let eventChannels: Set<String>
    private var fireHandlers: [String: FireHandler] = [:]
    private var invokeHandlers: [String: InvokeHandler] = [:]
    private var subscribeHandlers: [String: () -> Void] = [:]

    public init(contract: BridgeContract, bridge: BridgeContract.Bridge) {
        callChannels = contract.callChannels(of: bridge)
        eventChannels = contract.eventChannels(of: bridge)
    }

    /// Registers the handler of a `fire` channel. Registering a channel the
    /// contract does not have, or has as another kind, or twice, is a
    /// programming error and stops the app at launch.
    public func onFire(_ channel: String, _ handler: @escaping FireHandler) {
        precondition(callChannels[channel] == .fire, "\(channel) is not a fire channel of the contract")
        precondition(fireHandlers[channel] == nil, "\(channel) already has a handler")
        fireHandlers[channel] = handler
    }

    public func onInvoke(_ channel: String, _ handler: @escaping InvokeHandler) {
        precondition(callChannels[channel] == .invoke, "\(channel) is not an invoke channel of the contract")
        precondition(invokeHandlers[channel] == nil, "\(channel) already has a handler")
        invokeHandlers[channel] = handler
    }

    /// An invoke handler that answers at once.
    public func onInvoke(_ channel: String, answering handler: @escaping (BridgeArguments) -> BridgeReply) {
        onInvoke(channel) { arguments, reply in reply(handler(arguments)) }
    }

    /// Registers what to do each time the page subscribes to an event
    /// channel. Optional: most events are simply sent, heard or not. It is for
    /// an event that must not be lost when it comes before the page listens.
    public func onSubscribe(_ channel: String, _ handler: @escaping () -> Void) {
        precondition(eventChannels.contains(channel), "\(channel) is not an event channel of the contract")
        precondition(subscribeHandlers[channel] == nil, "\(channel) already has a subscription handler")
        subscribeHandlers[channel] = handler
    }

    /// Call channels of the contract nobody answers, sorted.
    public var unhandledChannels: [String] {
        callChannels.keys.filter { fireHandlers[$0] == nil && invokeHandlers[$0] == nil }.sorted()
    }

    /// Reads a posted message: `{ kind, channel, args }`, where `args` is the
    /// JSON text of the argument list. Besides its calls the page posts a
    /// `subscribe` message each time it starts listening on an event channel.
    public func decode(_ body: Any) -> Result<BridgeMessage, BridgeError> {
        guard
            let body = body as? [String: Any],
            let kindName = body["kind"] as? String,
            let channel = body["channel"] as? String,
            let argumentsText = body["args"] as? String
        else { return .failure(BridgeError("malformed bridge message")) }

        guard let kind = BridgeContract.Kind(rawValue: kindName), kind != .value else {
            return .failure(BridgeError("unknown call kind '\(kindName)'"))
        }
        if kind == .subscribe {
            guard eventChannels.contains(channel) else {
                return .failure(BridgeError("'\(channel)' is not an event channel"))
            }
            return .success(BridgeMessage(kind: kind, channel: channel, arguments: BridgeArguments([])))
        }
        guard let declared = callChannels[channel] else {
            return .failure(BridgeError("No handler registered for '\(channel)'"))
        }
        guard declared == kind else {
            return .failure(BridgeError("'\(channel)' is a \(declared.rawValue) channel"))
        }
        guard
            let data = argumentsText.data(using: .utf8),
            let arguments = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return .failure(BridgeError("the arguments of '\(channel)' are not a list")) }

        return .success(BridgeMessage(kind: kind, channel: channel, arguments: BridgeArguments(arguments)))
    }

    /// Runs the handler of a message. `reply` is called exactly once: for a
    /// fire with `.undefined` as soon as the handler returns, for an invoke
    /// with the handler's answer.
    public func dispatch(_ message: BridgeMessage, reply: @escaping (BridgeReply) -> Void) {
        switch message.kind {
        case .fire:
            guard let handler = fireHandlers[message.channel] else {
                reply(.failure("No handler registered for '\(message.channel)'"))
                return
            }
            handler(message.arguments)
            reply(.undefined)
        case .invoke:
            guard let handler = invokeHandlers[message.channel] else {
                reply(.failure("No handler registered for '\(message.channel)'"))
                return
            }
            var answered = false
            handler(message.arguments) { answer in
                guard !answered else { return }
                answered = true
                reply(answer)
            }
        case .subscribe:
            subscribeHandlers[message.channel]?()
            reply(.undefined)
        case .value:
            reply(.failure("'\(message.channel)' cannot be called"))
        }
    }
}
