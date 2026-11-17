import Foundation

/// The page-side half of a bridge: the script that defines `window.backspace`
/// (or `window.bspaceUpdate`) before any script of the page runs. It is built
/// from the contract, so a member exists on the page exactly when the contract
/// lists it.
///
/// What the page observes is what Electron's preload gives it:
/// - a `fire` member returns `undefined` and never throws for a failed send;
/// - an `invoke` member returns a Promise of the shell's answer;
/// - a `subscribe` member keeps every callback it is given, each registration
///   on its own, and returns a remover only where the contract says so.
public enum BridgeScript {
    /// The `WKScriptMessageHandler` name pages post to.
    public static func messageHandlerName(for bridge: BridgeContract.Bridge) -> String {
        bridge.rawValue
    }

    /// The function the shell calls to hand an event to the page. Events are
    /// not a security boundary (a page can only call its own callbacks through
    /// it), so it is a property of `window`, kept out of enumeration.
    public static func deliveryFunctionName(for bridge: BridgeContract.Bridge) -> String {
        "__\(bridge.rawValue)Deliver"
    }

    /// - Parameter values: what each `value` member holds, as JSON-compatible
    ///   objects. A value member missing here is a programming error.
    public static func source(
        bridge: BridgeContract.Bridge,
        contract: BridgeContract,
        values: [String: Any]
    ) throws -> String {
        let members = contract.members(of: bridge)
        for member in members where member.kind == .value && values[member.name] == nil {
            throw BridgeContract.Malformed(description: "\(bridge.rawValue).\(member.name): the shell gives it no value")
        }
        let table: [[String: Any]] = members.map { member in
            var row: [String: Any] = ["name": member.name, "kind": member.kind.rawValue]
            if let channel = member.channel { row["channel"] = channel }
            if let unsubscribe = member.unsubscribe { row["unsubscribe"] = unsubscribe }
            return row
        }
        return """
        (() => {
          'use strict';
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(try literal(messageHandlerName(for: bridge)))];
          if (!handler || window.top !== window) return;
          const post = handler.postMessage.bind(handler);
          const stringify = JSON.stringify;
          const members = \(try literal(table));
          const values = \(try literal(values));
          const listeners = new Map();
          const send = (kind, channel, args) => post({ kind, channel, args: stringify(args) });

          const api = {};
          for (const member of members) {
            if (member.kind === 'value') {
              api[member.name] = values[member.name];
            } else if (member.kind === 'fire') {
              api[member.name] = (...args) => { send('fire', member.channel, args).catch(() => {}); };
            } else if (member.kind === 'invoke') {
              api[member.name] = (...args) => send('invoke', member.channel, args);
            } else {
              api[member.name] = (callback) => {
                const entry = { callback };
                const list = listeners.get(member.channel) || [];
                list.push(entry);
                listeners.set(member.channel, list);
                // The shell holds some events until someone listens for them.
                send('subscribe', member.channel, []).catch(() => {});
                if (!member.unsubscribe) return undefined;
                return () => {
                  const current = listeners.get(member.channel) || [];
                  const index = current.indexOf(entry);
                  if (index !== -1) current.splice(index, 1);
                };
              };
            }
          }

          const deliver = (channel, payload) => {
            for (const entry of [...(listeners.get(channel) || [])]) {
              try {
                entry.callback(payload);
              } catch (error) {
                console.error('[bridge] a listener of ' + channel + ' threw:', error);
              }
            }
          };

          Object.defineProperty(window, \(try literal(bridge.rawValue)), { value: Object.freeze(api), enumerable: true });
          Object.defineProperty(window, \(try literal(deliveryFunctionName(for: bridge))), { value: deliver });
        })();
        """
    }

    /// A JSON-compatible object as a JavaScript literal. JSON is JavaScript
    /// except for the two Unicode line separators, which older engines do not
    /// allow inside a string literal; they are escaped.
    static func literal(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeContract.Malformed(description: "a bridge value is not valid UTF-8")
        }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
