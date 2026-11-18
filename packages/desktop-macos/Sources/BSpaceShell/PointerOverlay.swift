import AppKit
import BSpaceCore

/// What draws viewers' pointers over a display.
public protocol PointerOverlayPresenter: AnyObject {
    /// The number of the window that draws over that display, made if there
    /// is none yet: a capture of the display leaves that window out, or
    /// every viewer would see each pointer twice, the drawn one and the
    /// captured one a frame behind. Nil when there is no such display.
    func windowNumber(forDisplay display: UInt32) -> UInt32?

    /// Draws these pointers over that display and nothing anywhere else. No
    /// pointers, or no display, shows nothing.
    func show(_ pointers: [OverlayPointer], onDisplay display: UInt32?)
}

/// The pointers in a transparent panel over the display.
///
/// - It never takes the mouse or the keyboard: pointing must not get in the
///   way of whatever the sharer is doing.
/// - It is on every Space, above a full-screen application too: a viewer
///   keeps pointing at whatever the stream shows. An ordinary window cannot
///   join another application's full-screen Space; a non-activating panel can.
/// - It is out of Mission Control, where it would be an empty tile the size
///   of the screen.
/// - A panel is kept for as long as the shell runs, shown or not: the
///   captures that leave it out know it by its number.
public final class SystemPointerOverlay: PointerOverlayPresenter {
    private let hidesFromCaptures: Bool
    private var panels: [UInt32: OverlayPanel] = [:]
    private var shown: (pointers: [OverlayPointer], display: UInt32?) = ([], nil)
    private var observer: NSObjectProtocol?

    /// - Parameter hidesFromCaptures: whether the panel also asks the system
    ///   to keep it out of captures that do not leave it out themselves (the
    ///   window's sharing type). The shell's own captures name the panel in
    ///   their filter and do not depend on it; a check turns it off to see
    ///   that filter work by itself.
    public init(hidesFromCaptures: Bool = true) {
        self.hidesFromCaptures = hidesFromCaptures
        // A display was unplugged, moved or changed its size.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.show(self.shown.pointers, onDisplay: self.shown.display)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func windowNumber(forDisplay display: UInt32) -> UInt32? {
        guard let panel = panel(for: display), panel.windowNumber > 0 else { return nil }
        return UInt32(panel.windowNumber)
    }

    public func show(_ pointers: [OverlayPointer], onDisplay display: UInt32?) {
        shown = (pointers, display)
        for (id, panel) in panels where id != display {
            panel.clear()
        }
        // A display that went away shows nothing, rather than its pointers
        // on another one.
        guard let display, let screen = Self.screen(of: display), let panel = panel(for: display) else {
            if let display {
                panels[display]?.clear()
            }
            return
        }
        panel.draw(pointers, on: screen)
    }

    /// A picture of these pointers as the overlay draws them, on a plain
    /// dark ground, as PNG data. For checks and documents: the overlay
    /// itself is left out of every capture, and a photograph of the
    /// screen would show whatever else is on it.
    public static func picture(of pointers: [OverlayPointer], size: CGSize, scale: CGFloat) -> Data? {
        let view = OverlayMarksView()
        view.frame = CGRect(origin: .zero, size: size)
        view.contentsScale = scale
        view.render(pointers)
        CATransaction.flush()
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let layer = view.layer, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func panel(for display: UInt32) -> OverlayPanel? {
        if let panel = panels[display] {
            return panel
        }
        guard let screen = Self.screen(of: display) else { return nil }
        let panel = OverlayPanel(screen: screen, hidesFromCaptures: hidesFromCaptures)
        panels[display] = panel
        return panel
    }

    private static func screen(of display: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }
}

private final class OverlayPanel: NSPanel {
    private let marks = OverlayMarksView()

    init(screen: NSScreen, hidesFromCaptures: Bool) {
        // Not deferred: the window has to exist, and have its number, before
        // it is ever shown.
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // A panel hides when its application is not the active one, which
        // this one is not whenever the sharer works in something else.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // For captures that take the screen without a filter of ours (the
        // system's picker): the shell's own captures leave the window out
        // by its number.
        sharingType = hidesFromCaptures ? .none : .readOnly
        contentView = marks
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func draw(_ pointers: [OverlayPointer], on screen: NSScreen) {
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
        }
        marks.contentsScale = screen.backingScaleFactor
        marks.render(pointers)
        if pointers.isEmpty {
            orderOut(nil)
        } else if !isVisible {
            orderFrontRegardless()
        }
    }

    func clear() {
        marks.render([])
        orderOut(nil)
    }
}

/// The pointers themselves: an arrow, the viewer's name beside it, and a
/// ring that spreads from it on a click. Shapes, sizes and timings are the
/// Electron overlay's.
///
/// The page measures from the top and the layers from the bottom: every
/// offset the page has downward is written here as a negative one, and the
/// layer tree is left the way Core Animation has it, so that text and a
/// picture of the tree (`SystemPointerOverlay.picture`) come out the way the
/// screen shows them.
private final class OverlayMarksView: NSView {
    var contentsScale: CGFloat = 2

    private var marks: [String: Mark] = [:]

    private final class Mark {
        /// Has no size: it stands at the point, and the rest hangs off it.
        let layer = CALayer()
        let arrow = CAShapeLayer()
        let label = CAShapeLayer()
        let text = CATextLayer()
        var name: String?
        var ping = 0.0
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// How far right of and below the point the name's tag starts, and how
    /// high it is.
    private static let tagOffset: CGFloat = 17
    private static let tagHeight: CGFloat = 20

    init() {
        super.init(frame: .zero)
        // The view owns its layer.
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func render(_ pointers: [OverlayPointer]) {
        guard let root = layer else { return }
        var seen: Set<String> = []
        for pointer in pointers {
            seen.insert(pointer.id)
            let position = CGPoint(x: pointer.x * bounds.width, y: (1 - pointer.y) * bounds.height)
            let color = CGColor(
                srgbRed: CGFloat(pointer.color.red) / 255, green: CGFloat(pointer.color.green) / 255,
                blue: CGFloat(pointer.color.blue) / 255, alpha: 1
            )
            let mark: Mark
            if let known = marks[pointer.id] {
                mark = known
                // It glides to where it is now, and fades when it stops.
                Self.animated(0.09, .linear) { mark.layer.position = position }
                Self.animated(0.3, .easeOut) { mark.layer.opacity = pointer.isIdle ? 0 : 1 }
            } else {
                mark = Self.makeMark()
                marks[pointer.id] = mark
                Self.animated(0, .linear) {
                    mark.layer.position = position
                    mark.layer.opacity = pointer.isIdle ? 0 : 1
                    root.addSublayer(mark.layer)
                }
            }
            Self.animated(0, .linear) {
                mark.arrow.fillColor = color
                mark.label.fillColor = color
                if mark.name != pointer.name {
                    mark.name = pointer.name
                    self.setName(pointer.name, on: mark)
                }
            }
            if pointer.ping > 0, pointer.ping != mark.ping {
                mark.ping = pointer.ping
                Self.ring(color: color, in: mark.layer)
            }
        }
        for (id, mark) in marks where !seen.contains(id) {
            mark.layer.removeFromSuperlayer()
            marks[id] = nil
        }
    }

    /// Runs `changes` as one transaction: over `seconds`, or at once for 0.
    private static func animated(_ seconds: CFTimeInterval, _ timing: CAMediaTimingFunctionName, _ changes: () -> Void) {
        CATransaction.begin()
        if seconds > 0 {
            CATransaction.setAnimationDuration(seconds)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        } else {
            CATransaction.setDisableActions(true)
        }
        changes()
        CATransaction.commit()
    }

    private static func makeMark() -> Mark {
        let mark = Mark()
        // The arrow of the page's pointer, drawn at 22 points for its 20:
        // its tip a little right of and below the point.
        let scale: CGFloat = 22.0 / 20.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2 * scale, y: -1.5 * scale))
        path.addLine(to: CGPoint(x: 16.5 * scale, y: -8.2 * scale))
        path.addLine(to: CGPoint(x: 10 * scale, y: -10.2 * scale))
        path.addLine(to: CGPoint(x: 7.6 * scale, y: -16.8 * scale))
        path.closeSubpath()
        mark.arrow.path = path
        mark.arrow.strokeColor = CGColor(gray: 0, alpha: 0.65)
        mark.arrow.lineWidth = 1.2 * scale
        mark.arrow.lineJoin = .round
        mark.arrow.shadowColor = CGColor(gray: 0, alpha: 1)
        mark.arrow.shadowOpacity = 0.45
        mark.arrow.shadowOffset = CGSize(width: 0, height: -1)
        mark.arrow.shadowRadius = 2

        mark.text.font = font
        mark.text.fontSize = font.pointSize
        mark.text.foregroundColor = CGColor(gray: 0, alpha: 0.82)
        mark.text.alignmentMode = .left
        mark.text.truncationMode = .none
        mark.text.isWrapped = false

        mark.layer.addSublayer(mark.arrow)
        mark.layer.addSublayer(mark.label)
        mark.label.addSublayer(mark.text)
        return mark
    }

    /// The name in its tag below and to the right of the arrow.
    private func setName(_ name: String, on mark: Mark) {
        mark.label.isHidden = name.isEmpty
        guard !name.isEmpty else { return }
        let width = ceil((name as NSString).size(withAttributes: [.font: Self.font]).width)
        let size = CGSize(width: width + 14, height: Self.tagHeight)
        mark.label.frame = CGRect(
            origin: CGPoint(x: Self.tagOffset, y: -Self.tagOffset - Self.tagHeight), size: size
        )
        mark.label.path = Self.tag(size)
        mark.text.contentsScale = contentsScale
        mark.text.string = name
        mark.text.frame = CGRect(x: 7, y: 2, width: width + 1, height: 16)
    }

    /// The outline of a tag: corners rounded by 6 points, the top left one,
    /// which meets the arrow, by 3.
    private static func tag(_ size: CGSize) -> CGPath {
        let near: CGFloat = 3
        let far: CGFloat = 6
        let topLeft = CGPoint(x: 0, y: size.height)
        let topRight = CGPoint(x: size.width, y: size.height)
        let bottomRight = CGPoint(x: size.width, y: 0)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: near, y: size.height))
        path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: far)
        path.addArc(tangent1End: bottomRight, tangent2End: .zero, radius: far)
        path.addArc(tangent1End: .zero, tangent2End: topLeft, radius: far)
        path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: near)
        path.closeSubpath()
        return path
    }

    /// A click: a ring that spreads from the point and fades, in 0.7 s.
    private static func ring(color: CGColor, in layer: CALayer) {
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        ring.position = .zero
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color
        ring.lineWidth = 2
        ring.opacity = 0

        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 0.4
        spread.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [spread, fade]
        both.duration = 0.7
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        layer.insertSublayer(ring, at: 0)
        ring.add(both, forKey: "ring")
        CATransaction.commit()
    }
}
