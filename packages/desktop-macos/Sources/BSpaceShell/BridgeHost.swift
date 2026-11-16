import BSpaceCore
import WebKit

/// The native half of one bridge: receives what the page posts, hands it to the
/// router, and sends the shell's events back.
public final class BridgeHost: NSObject, WKScriptMessageHandlerWithReply {
    public let router: BridgeRouter
    private let bridge: BridgeContract.Bridge
    private let eventChannels: Set<String>
    private weak var webView: WKWebView?

    public init(contract: BridgeContract, bridge: BridgeContract.Bridge) {
        self.bridge = bridge
        router = BridgeRouter(contract: contract, bridge: bridge)
        eventChannels = contract.eventChannels(of: bridge)
    }

    /// Adds the page-side script and the message handler to a configuration.
    /// The script runs at document start, in the main frame only.
    public func install(
        into controller: WKUserContentController,
        contract: BridgeContract,
        values: [String: Any]
    ) throws {
        let source = try BridgeScript.source(bridge: bridge, contract: contract, values: values)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: BridgeScript.messageHandlerName(for: bridge))
    }

    public func attach(to webView: WKWebView) {
        self.webView = webView
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // The script is injected into the main frame only, but the message
        // handler is reachable from every frame of the page (deviation 2).
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "The bridge is available to the main frame only")
            return
        }
        switch router.decode(message.body) {
        case .failure(let error):
            replyHandler(nil, error.description)
        case .success(let decoded):
            router.dispatch(decoded) { reply in
                switch reply {
                case .undefined: replyHandler(nil, nil)
                case .null: replyHandler(NSNull(), nil)
                case .value(let value): replyHandler(value, nil)
                case .failure(let reason): replyHandler(nil, reason)
                }
            }
        }
    }

    /// Sends an event to every callback the page has subscribed on a channel.
    /// `payload` is a JSON-compatible value. Sending on a channel the contract
    /// does not list is a programming error.
    public func emit(_ channel: String, payload: Any) {
        precondition(eventChannels.contains(channel), "\(channel) is not an event channel of the contract")
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "const deliver = window[name]; if (typeof deliver === 'function') deliver(channel, payload);",
            arguments: [
                "name": BridgeScript.deliveryFunctionName(for: bridge),
                "channel": channel,
                "payload": payload,
            ],
            in: nil,
            in: .page,
            completionHandler: { result in
                if case .failure(let error) = result {
                    NSLog("[bridge] could not deliver %@: %@", channel, error.localizedDescription)
                }
            }
        )
    }
}
