import AppKit
import BSpaceCore
import ScreenCaptureKit

/// Lists what can be shared, with a picture of each.
public protocol ScreenSourceLister: AnyObject {
    /// Answers on the main queue. The list is empty when the app may not
    /// record the screen.
    func listSources(completion: @escaping ([ScreenSource]) -> Void)
}

/// The list from the system: every display, then every ordinary window, each
/// photographed by ScreenCaptureKit.
public final class SystemScreenSourceLister: ScreenSourceLister {
    /// What to call a display the system gives no name for: its number, from 1.
    private let unnamedScreen: (Int) -> String

    public init(unnamedScreen: @escaping (Int) -> String) {
        self.unnamedScreen = unnamedScreen
    }

    public func listSources(completion: @escaping ([ScreenSource]) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            // The system asks the user the first time and does nothing after
            // that; the list stays empty until the app is allowed.
            if !CGRequestScreenCaptureAccess() {
                NSLog("[capture] no Screen Recording permission: there is nothing to list")
            }
            completion([])
            return
        }
        // The names of the displays come from AppKit, on the main thread.
        var screenNames: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                screenNames[number.uint32Value] = screen.localizedName
            }
        }
        let unnamedScreen = self.unnamedScreen
        Task {
            let sources = await Self.capture(screenNames: screenNames, unnamedScreen: unnamedScreen)
            await MainActor.run { completion(sources) }
        }
    }

    private static func capture(
        screenNames: [UInt32: String],
        unnamedScreen: @escaping (Int) -> String
    ) async -> [ScreenSource] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            NSLog("[capture] the system did not list what can be shared: %@", error.localizedDescription)
            return []
        }

        let windows = content.windows.filter { window in
            ScreenSourceRules.isListed(ShareableWindow(
                id: window.windowID,
                title: window.title ?? "",
                hasApplication: window.owningApplication != nil,
                bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                width: window.frame.width,
                height: window.frame.height
            ))
        }

        // Every picture is taken at once; the list keeps the system's order.
        return await withTaskGroup(of: (Int, ScreenSource?).self) { group in
            for (index, display) in content.displays.enumerated() {
                group.addTask {
                    let name = screenNames[display.displayID] ?? unnamedScreen(index + 1)
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    guard let picture = await thumbnail(
                        of: filter, width: Double(display.width), height: Double(display.height)
                    ) else { return (index, nil) }
                    return (index, ScreenSource(kind: .display(display.displayID), name: name, thumbnailPNG: picture))
                }
            }
            for (index, window) in windows.enumerated() {
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let picture = await thumbnail(
                        of: filter, width: window.frame.width, height: window.frame.height
                    ) else { return (content.displays.count + index, nil) }
                    let icon = window.owningApplication.flatMap { applicationIcon(processID: $0.processID) }
                    return (content.displays.count + index, ScreenSource(
                        kind: .window(window.windowID), name: window.title ?? "", thumbnailPNG: picture, appIconPNG: icon
                    ))
                }
            }
            var found: [(Int, ScreenSource)] = []
            for await (index, source) in group {
                if let source {
                    found.append((index, source))
                }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// A picture of what a filter shows, fitted to the thumbnail box. Nil when
    /// the system would not take it: the window closed, or cannot be captured.
    private static func thumbnail(of filter: SCContentFilter, width: Double, height: Double) async -> Data? {
        let size = ScreenSourceRules.thumbnailSize(width: width, height: height)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The icon of a running application, drawn at the size of a tile's badge.
    private static func applicationIcon(processID: pid_t) -> Data? {
        guard let icon = NSRunningApplication(processIdentifier: processID)?.icon else { return nil }
        let side = ScreenSourceRules.iconSide
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = icon.cgImage(forProposedRect: &rect, context: context, hints: nil) else { return nil }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(image, in: rect)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Answers the page's requests for the list, under the rule of
/// `ScreenSourceGate`: new pictures only for a focused window and no more
/// often than once a second; otherwise the list the page already had.
final class ScreenSourceService {
    private let lister: ScreenSourceLister
    private var gate = ScreenSourceGate()
    /// Requests that arrived while a list was being made: they get that list.
    private var waiting: [([ScreenSource]) -> Void] = []
    /// Counts the pages: a list made for a page that is gone is not kept.
    private var page = 0

    init(lister: ScreenSourceLister) {
        self.lister = lister
    }

    func sources(windowFocused: Bool, now: @escaping () -> Date = Date.init, completion: @escaping ([ScreenSource]) -> Void) {
        if !waiting.isEmpty {
            waiting.append(completion)
            return
        }
        guard gate.decision(windowFocused: windowFocused, now: now()) == .enumerate else {
            completion(gate.last)
            return
        }
        waiting = [completion]
        let askedOn = page
        lister.listSources { [weak self] sources in
            guard let self else { return }
            let answers = self.waiting
            self.waiting = []
            if askedOn == self.page {
                self.gate.served(sources, at: now())
            }
            answers.forEach { $0(sources) }
        }
    }

    /// The page changed: the next one starts with nothing.
    func pageChanged() {
        page += 1
        gate.reset()
    }
}
