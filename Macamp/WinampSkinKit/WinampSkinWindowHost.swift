import AppKit

/// Converts between the logical pixel coordinates used by a Winamp skin and
/// the AppKit screen coordinates used by an NSWindow.
enum WinampSkinWindowGeometry {
    static func screenSize(for logicalSize: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(0.01, scale)
        return CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
    }

    static func screenFrame(for logicalFrame: CGRect, scale: CGFloat) -> CGRect {
        let size = screenSize(for: logicalFrame.size, scale: scale)
        let scale = max(0.01, scale)
        return CGRect(
            x: logicalFrame.minX * scale,
            y: logicalFrame.minY * scale,
            width: size.width,
            height: size.height
        )
    }

    static func logicalFrame(for screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(0.01, scale)
        return CGRect(
            x: screenFrame.minX / scale,
            y: screenFrame.minY / scale,
            width: screenFrame.width / scale,
            height: screenFrame.height / scale
        )
    }
}

enum WinampSkinWindowActivityState: Equatable {
    case active
    case inactive
}

enum WinampSkinWindowDockingState: Equatable {
    case free
    case preparingToRedock
    case docked
}

/// Shared host for borderless Winamp windows.
///
/// Skin content remains expressed in logical Winamp pixels. Only this host
/// converts the window frame and region mask to screen coordinates. The
/// renderer remains responsible for drawing and for any skin-specific content
/// hit testing; `acceptsInput` is the host-level hook that keeps those two
/// concerns composable.
@MainActor
final class WinampSkinWindowHost: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var normalLogicalSize: CGSize
    let shadeLogicalSize: CGSize?

    private(set) var isShaded = false
    private(set) var activityState: WinampSkinWindowActivityState = .inactive
    private(set) var dockingState: WinampSkinWindowDockingState = .free

    private(set) var scale: CGFloat

    var regionPath: NSBezierPath? {
        didSet { applyRegionMask() }
    }

    /// When enabled, the renderer can ask the host whether a logical point
    /// should receive input. Returning false is the transparent-pixel
    /// click-through hook; it does not disable the whole window.
    var clickThroughTransparentPixels = false
    var clickThroughTest: ((CGPoint) -> Bool)?

    var onLogicalFrameChange: ((CGRect) -> Void)?
    var onActivityStateChange: ((WinampSkinWindowActivityState) -> Void)?
    var onShadeStateChange: ((Bool) -> Void)?

    var logicalFrame: CGRect {
        get { WinampSkinWindowGeometry.logicalFrame(for: window.frame, scale: scale) }
        set { setLogicalFrame(newValue, display: false, clampedToVisibleScreens: false) }
    }

    var currentLogicalSize: CGSize {
        isShaded ? (shadeLogicalSize ?? normalLogicalSize) : normalLogicalSize
    }

    init(normalLogicalSize: CGSize, shadeLogicalSize: CGSize? = nil, scale: CGFloat = 1, allowsResize: Bool = false) {
        self.normalLogicalSize = normalLogicalSize
        self.shadeLogicalSize = shadeLogicalSize
        self.scale = max(0.01, scale)
        let style: NSWindow.StyleMask = allowsResize ? [.borderless, .miniaturizable, .resizable] : [.borderless, .miniaturizable]
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WinampSkinWindowGeometry.screenSize(for: normalLogicalSize, scale: self.scale)),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        self.window = window
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
    }

    func setContentView(_ contentView: NSView) {
        window.contentView = contentView
        resizeWindow(to: logicalFrame, display: false)
        applyRegionMask()
    }

    func setScale(_ value: CGFloat, display: Bool = false) {
        let next = max(0.01, value)
        guard next != scale else { return }
        let logicalFrame = self.logicalFrame
        scale = next
        resizeWindow(to: logicalFrame, display: display)
        applyRegionMask()
        if display { window.displayIfNeeded() }
    }

    func setLogicalFrame(_ frame: CGRect, display: Bool = false, clampedToVisibleScreens: Bool = false) {
        let screenFrame = WinampSkinWindowGeometry.screenFrame(for: frame, scale: scale)
        let corrected = clampedToVisibleScreens ? Self.corrected(screenFrame) : screenFrame
        window.setFrame(corrected, display: display)
        onLogicalFrameChange?(logicalFrame)
    }

    func setSkinActive(_ active: Bool) {
        let next: WinampSkinWindowActivityState = active ? .active : .inactive
        guard next != activityState else { return }
        activityState = next
        onActivityStateChange?(next)
    }

    func setShaded(_ shaded: Bool, display: Bool = true) {
        guard shaded != isShaded else { return }
        let frame = logicalFrame
        isShaded = shaded
        resizeWindow(to: CGRect(origin: frame.origin, size: currentLogicalSize), display: display)
        applyRegionMask()
        onShadeStateChange?(shaded)
    }

    /// Resize the real skin window in Winamp logical pixels.  MAKI Layout
    /// objects use this entry point instead of maintaining renderer-only
    /// geometry.
    func resizeLogicalWindow(to size: CGSize, display: Bool = true) {
        guard size.width > 0, size.height > 0 else { return }
        normalLogicalSize = size
        guard !isShaded else { return }
        let frame = logicalFrame
        resizeWindow(to: CGRect(origin: frame.origin, size: size), display: display)
        applyRegionMask()
        onLogicalFrameChange?(logicalFrame)
    }

    func beforeRedock() {
        dockingState = .preparingToRedock
    }

    func redock() {
        dockingState = .docked
    }

    func undock() {
        dockingState = .free
    }

    func acceptsInput(atLogicalPoint point: CGPoint) -> Bool {
        guard CGRect(origin: .zero, size: currentLogicalSize).contains(point) else { return false }
        if let regionPath, !regionPath.contains(point) { return false }
        guard clickThroughTransparentPixels else { return true }
        return clickThroughTest?(point) ?? true
    }

    func windowDidMove(_ notification: Notification) {
        onLogicalFrameChange?(logicalFrame)
    }

    func windowDidResize(_ notification: Notification) {
        onLogicalFrameChange?(logicalFrame)
        applyRegionMask()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        setSkinActive(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        setSkinActive(false)
    }

    private func resizeWindow(to logicalFrame: CGRect, display: Bool) {
        let screenSize = WinampSkinWindowGeometry.screenSize(for: logicalFrame.size, scale: scale)
        let screenOrigin = WinampSkinWindowGeometry.screenFrame(for: CGRect(origin: logicalFrame.origin, size: .zero), scale: scale).origin
        window.setFrame(CGRect(origin: screenOrigin, size: screenSize), display: display)
    }

    private func applyRegionMask() {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        guard let regionPath else {
            contentView.layer?.mask = nil
            return
        }

        let bounds = contentView.bounds
        let logicalSize = currentLogicalSize
        guard logicalSize.width > 0, logicalSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scaleX = bounds.width / logicalSize.width
        let scaleY = bounds.height / logicalSize.height
        var transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: -scaleY, tx: bounds.minX, ty: bounds.maxY)
        let mask = CAShapeLayer()
        mask.fillRule = .nonZero
        mask.path = regionPath.cgPath.copy(using: &transform)
        mask.frame = bounds
        contentView.layer?.mask = mask
    }

    private static func corrected(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let screen = screens.first(where: { $0.intersects(frame) }) ?? NSScreen.main?.visibleFrame else { return frame }
        return CGRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - frame.width),
            y: min(max(frame.minY, screen.minY), screen.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}
