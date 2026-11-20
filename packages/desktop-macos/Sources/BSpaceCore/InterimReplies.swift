import Foundation

/// Answers for the channels whose feature the native shell does not have yet.
///
/// The port lands in stages (`docs/superpowers/plans/2026-11-16-macos-native-client.md`,
/// section 9), and the web client calls most of the bridge on every start. A
/// channel with no handler would reject its Promise, and a rejected call
/// inside an effect takes the whole client down. So until a feature is ported,
/// its channels answer what Electron answers where that feature is absent:
/// no update mechanism, the system's own picker of what to share.
///
/// The number after each group is the stage that replaces it with a real
/// handler; the entry is deleted from here in the same change. `BridgeRouter`
/// refuses a second handler for a channel, so one cannot be left behind.
public enum InterimReplies {
    /// `fire` channels that are accepted and do nothing yet.
    public static let fireChannels: Set<String> = [
        // Stage 4: what is left of screen sharing.
        "screen-share-selected", "screen-share-audio-preference",
        // Stage 5: updates.
        "install-update", "check-for-updates", "dismiss-update", "open-release-page",
    ]

    /// `invoke` channels with the answer each gives for now.
    public static func invokeReplies() -> [String: BridgeReply] {
        return [

            // Stage 4: what is left of screen sharing.
            "screen-share-preselect": .undefined,
            "get-audio-routers": .value([Any]()),
            "system-audio-exclusion-failed": .value(false),
            "system-audio-start": .value(["ok": false, "reason": "unsupported-platform"] as [String: Any]),
            "system-audio-stop": .undefined,

            // Stage 5. A build that does not update itself: the user fetches
            // the next one by hand.
            "get-update-status": .value([
                "capability": "manual",
                "dismissedVersion": NSNull(),
                "status": ["phase": "idle"],
            ] as [String: Any]),
        ]
    }

    /// Registers every interim answer on a router.
    public static func register(on router: BridgeRouter) {
        for channel in fireChannels {
            router.onFire(channel) { _ in }
        }
        for (channel, answer) in invokeReplies() {
            router.onInvoke(channel, answering: { _ in answer })
        }
    }
}
