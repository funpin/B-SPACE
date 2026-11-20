import AppKit
import BSpaceCore

/// What draws the tray: the character's frame and the menu under it.
public protocol TrayPresenter: AnyObject {
    /// Called with what the chosen menu item does.
    var onCommand: ((TrayMenuCommand) -> Void)? { get set }
    func show(_ frame: TrayFrame)
    func setMenu(_ items: [TrayMenuItem])
}

/// One round button of the row at the top of the tray menu: a system symbol
/// on a circle whose colour says the state.
final class TrayRoundButton: NSButton {
    static let diameter: CGFloat = 30

    var control: TrayControl {
        didSet { refresh() }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(control: TrayControl) {
        self.control = control
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrayRoundButton is made in code")
    }

    /// The system symbol that stands for a control and its state.
    static func symbolName(for kind: TrayControl.Kind) -> String {
        switch kind {
        case .microphone(let isOn):
            return isOn ? "mic.fill" : "mic.slash.fill"
        case .sound(let isOn):
            return isOn ? "speaker.wave.2.fill" : "speaker.slash.fill"
        case .pointers(let isOn):
            return isOn ? "cursorarrow.rays" : "cursorarrow"
        case .stopCamera:
            return "video.slash.fill"
        case .stopScreenShare:
            return "rectangle.on.rectangle.slash.fill"
        case .disconnect:
            return "phone.down.fill"
        }
    }

    private func refresh() {
        let symbol = NSImage(systemSymbolName: Self.symbolName(for: control.kind), accessibilityDescription: control.title)
        image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        contentTintColor = control.tone == .plain ? .labelColor : .white
        toolTip = control.title
        setAccessibilityLabel(control.title)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// Run by AppKit with the view's appearance current, so the colours come
    /// out right in a light and in a dark menu.
    override func updateLayer() {
        let fill: NSColor
        switch control.tone {
        case .plain:
            fill = NSColor.labelColor.withAlphaComponent(isHovered ? 0.2 : 0.1)
        case .danger:
            fill = isHovered ? NSColor.systemRed.blended(withFraction: 0.15, of: .black) ?? .systemRed : .systemRed
        case .accent:
            fill = isHovered
                ? NSColor.controlAccentColor.blended(withFraction: 0.15, of: .black) ?? .controlAccentColor
                : .controlAccentColor
        }
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = fill.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

/// The row of round buttons, as the view of one menu item.
final class TrayControlsView: NSView {
    static let sideMargin: CGFloat = 14
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 42

    /// Called with the control whose button was pressed.
    var onControl: ((TrayControl) -> Void)?
    private var buttons: [TrayRoundButton] = []

    var controls: [TrayControl] {
        buttons.map(\.control)
    }

    init(controls: [TrayControl]) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(for: controls.count), height: Self.rowHeight))
        // The menu is as wide as its widest item; the row keeps to the left.
        autoresizingMask = [.width]
        update(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrayControlsView is made in code")
    }

    static func width(for count: Int) -> CGFloat {
        let buttons = CGFloat(count) * TrayRoundButton.diameter + CGFloat(max(count - 1, 0)) * spacing
        return sideMargin * 2 + buttons
    }

    /// Shows these controls, changing the buttons that are there in place
    /// when they are the same row in another state, so an open menu does not
    /// jump under the pointer.
    func update(_ controls: [TrayControl]) {
        if controls.count != buttons.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = controls.enumerated().map { index, control in
                let button = TrayRoundButton(control: control)
                button.target = self
                button.action = #selector(pressed(_:))
                button.setFrameOrigin(NSPoint(
                    x: Self.sideMargin + CGFloat(index) * (TrayRoundButton.diameter + Self.spacing),
                    y: (Self.rowHeight - TrayRoundButton.diameter) / 2
                ))
                addSubview(button)
                return button
            }
            setFrameSize(NSSize(width: max(frame.width, Self.width(for: controls.count)), height: Self.rowHeight))
        } else {
            for (button, control) in zip(buttons, controls) where button.control != control {
                button.control = control
            }
        }
    }

    @objc private func pressed(_ sender: TrayRoundButton) {
        onControl?(sender.control)
    }
}

/// The character in the menu bar, as a status item with a menu.
///
/// The frame images are the template PNGs of the Electron build
/// (`tray-<frame>Template.png` and `@2x`), copied into the bundle's resources.
public final class SystemTrayPresenter: NSObject, TrayPresenter {
    public var onCommand: ((TrayMenuCommand) -> Void)?

    private let statusItem: NSStatusItem
    private let images: [TrayFrame: NSImage]
    /// What the menu shows now.
    private var items: [TrayMenuItem] = []
    /// What each menu item does, by the item's tag.
    private var commands: [TrayMenuCommand] = []
    private var controlsView: TrayControlsView?

    /// Loads the frame images of a folder: `tray-<frame>Template.png`, each
    /// with its `@2x` file when there is one. A frame with no file is left
    /// out.
    ///
    /// The size is set by hand, in points, from the pixels of the plain file.
    /// The generated PNGs say 1200 dpi, and AppKit believes them: left to
    /// itself it draws an 18-pixel frame one point wide. Electron goes by the
    /// pixels and the `@2x` suffix alone.
    public static func loadFrames(from directory: URL) -> [TrayFrame: NSImage] {
        var images: [TrayFrame: NSImage] = [:]
        for frame in TrayFrame.allCases {
            let plain = directory.appendingPathComponent("\(frame.resourceName).png")
            guard
                let data = try? Data(contentsOf: plain),
                let base = NSBitmapImageRep(data: data),
                base.pixelsWide > 0, base.pixelsHigh > 0
            else { continue }
            let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
            let image = NSImage(size: size)
            base.size = size
            image.addRepresentation(base)

            let doubled = directory.appendingPathComponent("\(frame.resourceName)@2x.png")
            if let data = try? Data(contentsOf: doubled), let sharp = NSBitmapImageRep(data: data) {
                sharp.size = size
                image.addRepresentation(sharp)
            }
            // The system tints a template for a light or a dark menu bar.
            image.isTemplate = true
            images[frame] = image
        }
        return images
    }

    /// The system symbol in front of a line of the menu, by what the line
    /// does. A press on a button of the row has none: the button is its own.
    static func symbolName(for command: TrayMenuCommand) -> String? {
        switch command {
        case .control(.setStatus):
            return "moon"
        case .show:
            return "macwindow"
        case .quit:
            return "power"
        case .control:
            return nil
        }
    }

    /// The system symbols the menu is drawn with that this system does not
    /// have. Empty on a system that has them all.
    public static func missingControlSymbols() -> [String] {
        let kinds: [TrayControl.Kind] = [
            .microphone(isOn: true), .microphone(isOn: false), .sound(isOn: true), .sound(isOn: false),
            .pointers(isOn: true), .pointers(isOn: false), .stopCamera, .stopScreenShare, .disconnect,
        ]
        let lines: [TrayMenuCommand] = [.control(.setStatus(.dnd)), .show, .quit]
        return (kinds.map(TrayRoundButton.symbolName(for:)) + lines.compactMap(symbolName(for:))).filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
    }

    /// Nil when the bundle has no frame images: an executable that is not an
    /// application bundle shows no tray.
    public init?(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return nil }
        let images = Self.loadFrames(from: resources)
        guard images[.idle] != nil else { return nil }
        self.images = images
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.toolTip = AppIdentity.displayName
        statusItem.button?.image = images[.idle]
    }

    /// A frame whose image is missing falls back to the idle one.
    public func show(_ frame: TrayFrame) {
        statusItem.button?.image = images[frame] ?? images[.idle]
    }

    /// Shows these items. A menu with the same items in another state (a
    /// button switched, a check mark set) is changed in place, so that it can
    /// be open while the web client answers a press; anything else is built
    /// anew.
    public func setMenu(_ items: [TrayMenuItem]) {
        defer { self.items = items }
        if let menu = statusItem.menu, Self.shape(of: items) == Self.shape(of: self.items) {
            commands = []
            for (entry, item) in zip(menu.items, items) {
                configure(entry, for: item)
            }
            menu.minimumWidth = Self.minimumWidth(for: items)
            return
        }
        commands = []
        controlsView = nil
        let menu = NSMenu()
        // Items are enabled or not as built here, not by who answers them.
        menu.autoenablesItems = false
        for item in items {
            let entry: NSMenuItem = item == .separator ? .separator() : NSMenuItem()
            configure(entry, for: item)
            menu.addItem(entry)
        }
        menu.minimumWidth = Self.minimumWidth(for: items)
        statusItem.menu = menu
    }

    /// How wide the menu has to be for its longest line. Beside an item with
    /// a view of its own the system sizes the menu by that view and cuts the
    /// lines of text short, so the width is worked out here: the text in the
    /// menu's font, plus the column of check marks and the margins.
    static func minimumWidth(for items: [TrayMenuItem]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        var widest: CGFloat = 0
        for item in items {
            switch item {
            case .separator:
                break
            case .label(let title), .action(let title, _), .toggle(let title, _, _):
                let text = (title as NSString).size(withAttributes: [.font: font]).width
                widest = max(widest, ceil(text) + textMargins)
            case .controls(let controls):
                widest = max(widest, TrayControlsView.width(for: controls.count))
            }
        }
        return widest
    }

    /// The column of check marks and the symbol to the left of a line, and
    /// the margins on both sides of it.
    static let textMargins: CGFloat = 80

    /// What kinds of items a menu has, in order, whatever they say.
    private static func shape(of items: [TrayMenuItem]) -> [Int] {
        items.map {
            switch $0 {
            case .separator: return 0
            case .label: return 1
            case .controls: return 2
            case .toggle: return 3
            case .action: return 4
            }
        }
    }

    private func configure(_ entry: NSMenuItem, for item: TrayMenuItem) {
        switch item {
        case .separator:
            break
        case .label(let title):
            entry.title = title
            entry.isEnabled = false
        case .controls(let controls):
            if let view = controlsView, entry.view === view {
                view.update(controls)
            } else {
                let view = TrayControlsView(controls: controls)
                view.onControl = { [weak self] control in
                    self?.pressed(control)
                }
                controlsView = view
                entry.view = view
            }
        case .toggle(let title, let isOn, let command):
            choose(entry, title: title, command: command)
            entry.state = isOn ? .on : .off
        case .action(let title, let command):
            choose(entry, title: title, command: command)
        }
    }

    private func choose(_ entry: NSMenuItem, title: String, command: TrayMenuCommand) {
        entry.title = title
        // The title says what the line does; the symbol only helps find it.
        entry.image = Self.symbolName(for: command).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        entry.target = self
        entry.action = #selector(chosen(_:))
        entry.tag = commands.count
        commands.append(command)
    }

    private func pressed(_ control: TrayControl) {
        if control.closesMenu {
            statusItem.menu?.cancelTracking()
        }
        onCommand?(control.command)
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag) else { return }
        onCommand?(commands[sender.tag])
    }
}

/// Keeps the tray in step with what the web client reports: plays the
/// character's animation for the reported state and rebuilds the menu when
/// the quick controls or the language change.
public final class TrayCoordinator {
    /// Called with what the chosen menu item does.
    public var onCommand: ((TrayMenuCommand) -> Void)?
    /// Whether the system asks apps to keep still. The character then shows
    /// each state's still frame instead of its loop. A check run replaces it.
    public var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private let presenter: TrayPresenter
    private let strings: DesktopStrings
    private var language: DesktopLanguage
    private var animator = TrayAnimator()
    private var context = TrayContext.empty
    private var timer: DispatchWorkItem?

    public init(presenter: TrayPresenter, strings: DesktopStrings, language: DesktopLanguage) {
        self.presenter = presenter
        self.strings = strings
        self.language = language
        presenter.onCommand = { [weak self] command in
            self?.onCommand?(command)
        }
        rebuildMenu()
        setState(.idle)
    }

    deinit {
        timer?.cancel()
    }

    public func setState(_ state: TrayState) {
        apply(animator.set(state, reducedMotion: prefersReducedMotion()))
    }

    public func setContext(_ context: TrayContext) {
        guard context != self.context else { return }
        self.context = context
        rebuildMenu()
    }

    public func setLanguage(_ language: DesktopLanguage) {
        guard language != self.language else { return }
        self.language = language
        rebuildMenu()
    }

    /// The window shows another page. Whatever the last one reported is not
    /// true of this one: the controls go and the character rests, until the
    /// new page reports.
    public func pageChanged() {
        setContext(.empty)
        setState(.idle)
    }

    private func rebuildMenu() {
        presenter.setMenu(TrayMenu.items(context: context, strings: strings, language: language))
    }

    private func apply(_ commands: [TrayAnimator.Command]) {
        for command in commands {
            switch command {
            case .show(let frame):
                presenter.show(frame)
            case .cancel:
                timer?.cancel()
                timer = nil
            case .schedule(let milliseconds):
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.timer = nil
                    self.apply(self.animator.timerFired(reducedMotion: self.prefersReducedMotion()))
                }
                timer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
            }
        }
    }
}
