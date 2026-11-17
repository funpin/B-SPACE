import Foundation

/// Answers for the channels whose feature the native shell does not have yet.
///
/// The port lands in stages (`docs/superpowers/plans/2026-11-16-macos-native-client.md`,
/// section 9), and the web client calls most of the bridge on every start. A
/// channel with no handler would reject its Promise, and a rejected call
/// inside an effect takes the whole client down. So until a feature is ported,
/// its channels answer what Electron answers where that feature is absent:
/// no update mechanism, no sources to list, no global shortcuts running.
///
/// The number after each group is the stage that replaces it with a real
/// handler; the entry is deleted from here in the same change. `BridgeRouter`
/// refuses a second handler for a channel, so one cannot be left behind.
public enum InterimReplies {
    /// `fire` channels that are accepted and do nothing yet.
    public static let fireChannels: Set<String> = [
        // Stage 2: language, recovery.
        "set-language", "renderer-ready", "recovery-action",
        // Stage 3: tray, global shortcuts.
        "set-tray-state", "set-tray-context", "keybind-portal-retry",
        // Stage 4: screen sharing, viewers' pointers.
        "screen-share-selected", "screen-share-audio-preference",
        "stream-pointer-overlay", "stream-pointer-overlay-end",
        // Stage 5: updates.
        "install-update", "check-for-updates", "dismiss-update", "open-release-page",
    ]

    /// `invoke` channels with the answer each gives for now.
    public static func invokeReplies() -> [String: BridgeReply] {
        return [
            // Stage 2. Recovery: the initial state, nothing went wrong.
            "get-recovery-state": .value([
                "mode": "normal",
                "reason": NSNull(),
                "updateState": "idle",
                "updateVersion": NSNull(),
                "lastUpdateError": NSNull(),
                "lastCheckResult": NSNull(),
            ] as [String: Any]),

            // Stage 3. No activity detected; the shortcut hook is not running;
            // the portal status is null everywhere but on Wayland.
            "get-current-activity": .null,
            "keybinds-sync": .value(false),
            "keybind-portal-status": .null,
            "check-accessibility": .value(false),

            // Stage 4. WebKit's own picker chooses the source, as for a server
            // whose client knows nothing of the native shell (plan, 5.5).
            "get-screen-share-picker-mode": .value("system"),
            "get-screen-sources": .value([Any]()),
            "screen-share-preselect": .undefined,
            "get-system-audio-capability": .value("unavailable"),
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
