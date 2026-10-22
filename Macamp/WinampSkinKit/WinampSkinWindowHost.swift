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
        return CGRect(
            x: logicalFrame.minX,
            y: logicalFrame.minY,
            width: size.width,
            height: size.height
        )
    }

    static func logicalFrame(for screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(0.01, scale)
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
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

    /// Optional logical resize grid used by Classic tiled windows. The host
    /// applies it at the AppKit delegate boundary so the skin surface always
    /// receives a valid logical size.
    var resizeGrid: CGSize?
    var minimumLogicalSize: CGSize?
    var screenSnapDistance: CGFloat = 10
    var snapsToVisibleScreenEdges = true

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

    private var windowMoveObservers: [UUID: () -> Void] = [:]
    private var interactiveDragObservers: [UUID: (Bool, Bool) -> Void] = [:]
    private var isPerformingInteractiveDrag = false
    private var isApplyingGroupFrame = false

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
        // Skin views decide whether a point is draggable, interactive, or
        // transparent. Letting AppKit move every background pixel would make
        // transparent holes and skinned controls steal pointer gestures.
        window.isMovableByWindowBackground = false
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
        if !isPerformingInteractiveDrag, !isApplyingGroupFrame { snapToVisibleScreenEdgesIfNeeded() }
        onLogicalFrameChange?(logicalFrame)
        windowMoveObservers.values.forEach { $0() }
    }

    /// Runs AppKit's native drag while allowing attached windows to treat it
    /// as one transaction and defer snapping/docking until mouse-up. Option
    /// dragging explicitly detaches the source window before moving it.
    func performDrag(with event: NSEvent) {
        let explicitlyUndocking = event.modifierFlags.contains(.option)
        beginInteractiveDrag(explicitlyUndocking: explicitlyUndocking)
        window.performDrag(with: event)
        endInteractiveDrag(explicitlyUndocking: explicitlyUndocking)
    }

    func beginInteractiveDrag(explicitlyUndocking: Bool = false) {
        isPerformingInteractiveDrag = true
        interactiveDragObservers.values.forEach { $0(true, explicitlyUndocking) }
    }

    func endInteractiveDrag(explicitlyUndocking: Bool = false) {
        interactiveDragObservers.values.forEach { $0(false, explicitlyUndocking) }
        isPerformingInteractiveDrag = false
    }

    fileprivate func setFrameFromGroup(_ frame: CGRect, display: Bool) {
        isApplyingGroupFrame = true
        window.setFrame(frame, display: display)
        isApplyingGroupFrame = false
    }

    func windowDidResize(_ notification: Notification) {
        onLogicalFrameChange?(logicalFrame)
        applyRegionMask()
    }

    func windowWillResize(_ sender: NSWindow, toFrameSize frameSize: NSSize) -> NSSize {
        guard !isShaded, let resizeGrid, resizeGrid.width > 0, resizeGrid.height > 0 else { return frameSize }
        let logicalWidth = frameSize.width / scale
        let logicalHeight = frameSize.height / scale
        let minimum = minimumLogicalSize ?? .zero
        let snappedWidth = max(minimum.width, floor(logicalWidth / resizeGrid.width) * resizeGrid.width)
        let snappedHeight = max(minimum.height, floor(logicalHeight / resizeGrid.height) * resizeGrid.height)
        return WinampSkinWindowGeometry.screenSize(for: CGSize(width: snappedWidth, height: snappedHeight), scale: scale)
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
        // Modern region paths already use the flipped view's top-left logical
        // coordinates. The content view's backing layer follows that same
        // orientation, so applying a second vertical flip shifts regions such
        // as HeadAMP's drawers downward and clips their top edges.
        var transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: bounds.minX, ty: bounds.minY)
        let mask = CAShapeLayer()
        mask.fillRule = .nonZero
        mask.path = regionPath.cgPath.copy(using: &transform)
        mask.frame = bounds
        contentView.layer?.mask = mask
    }

    fileprivate func snapToVisibleScreenEdgesIfNeeded() {
        guard snapsToVisibleScreenEdges, screenSnapDistance >= 0, !window.isMiniaturized else { return }
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        let distance = screenSnapDistance
        if abs(frame.minX - visible.minX) <= distance { frame.origin.x = visible.minX }
        if abs(frame.maxX - visible.maxX) <= distance { frame.origin.x = visible.maxX - frame.width }
        if abs(frame.minY - visible.minY) <= distance { frame.origin.y = visible.minY }
        if abs(frame.maxY - visible.maxY) <= distance { frame.origin.y = visible.maxY - frame.height }
        guard frame.origin != window.frame.origin else { return }
        window.setFrameOrigin(frame.origin)
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

    @discardableResult
    fileprivate func addWindowMoveObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        windowMoveObservers[token] = observer
        return token
    }

    fileprivate func removeWindowMoveObserver(_ token: UUID) {
        windowMoveObservers.removeValue(forKey: token)
    }

    @discardableResult
    fileprivate func addInteractiveDragObserver(_ observer: @escaping (Bool, Bool) -> Void) -> UUID {
        let token = UUID()
        interactiveDragObservers[token] = observer
        return token
    }

    fileprivate func removeInteractiveDragObserver(_ token: UUID) {
        interactiveDragObservers.removeValue(forKey: token)
    }
}

/// Tracks the actual docking graph between skin windows. Membership is only a
/// registry; detached members never move together. Edges are created when a
/// window is snapped close to another member or explicitly through `dock`.
@MainActor
final class WinampSkinWindowGroup {
    private struct Member {
        weak var host: WinampSkinWindowHost?
        let observerToken: UUID
        let dragObserverToken: UUID
        var lastScreenOrigin: CGPoint
    }

    private struct DockEdge: Hashable {
        let first: ObjectIdentifier
        let second: ObjectIdentifier
        let relativeOrigin: CGPoint

        func contains(_ key: ObjectIdentifier) -> Bool { first == key || second == key }
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var edges: Set<DockEdge> = []
    private var dragStartOrigins: [ObjectIdentifier: [ObjectIdentifier: CGPoint]] = [:]
    private var isApplyingGroupMove = false
    private let snapDistance: CGFloat = 10

    var hosts: [WinampSkinWindowHost] {
        members.values.compactMap(\.host)
    }

    func add(_ host: WinampSkinWindowHost) {
        let key = ObjectIdentifier(host)
        guard members[key] == nil else { return }

        let token = host.addWindowMoveObserver { [weak self, weak host] in
            guard let self, let host else { return }
            self.hostDidMove(host)
        }
        let dragToken = host.addInteractiveDragObserver { [weak self, weak host] dragging, explicitlyUndocking in
            guard let self, let host else { return }
            if dragging { self.hostWillBeginDragging(host, explicitlyUndocking: explicitlyUndocking) }
            else { self.hostDidEndDragging(host) }
        }
        members[key] = Member(host: host, observerToken: token, dragObserverToken: dragToken, lastScreenOrigin: host.window.frame.origin)
    }

    func remove(_ host: WinampSkinWindowHost) {
        guard let member = members.removeValue(forKey: ObjectIdentifier(host)) else { return }
        host.removeWindowMoveObserver(member.observerToken)
        host.removeInteractiveDragObserver(member.dragObserverToken)
        edges = edges.filter { !$0.contains(ObjectIdentifier(host)) }
    }

    var dockedPairs: [(WinampSkinWindowHost, WinampSkinWindowHost)] {
        edges.compactMap { edge in
            guard let first = members[edge.first]?.host,
                  let second = members[edge.second]?.host else { return nil }
            return (first, second)
        }
    }

    /// Creates a persistent relationship using current display-space offsets.
    func dock(_ first: WinampSkinWindowHost, to second: WinampSkinWindowHost) {
        guard first !== second,
              members[ObjectIdentifier(first)] != nil,
              members[ObjectIdentifier(second)] != nil else { return }
        let firstID = ObjectIdentifier(first)
        let secondID = ObjectIdentifier(second)
        let edge = firstID.hashValue < secondID.hashValue
            ? DockEdge(first: firstID, second: secondID, relativeOrigin: CGPoint(x: first.window.frame.minX - second.window.frame.minX, y: first.window.frame.minY - second.window.frame.minY))
            : DockEdge(first: secondID, second: firstID, relativeOrigin: CGPoint(x: second.window.frame.minX - first.window.frame.minX, y: second.window.frame.minY - first.window.frame.minY))
        edges = edges.filter { !($0.contains(firstID) && $0.contains(secondID)) }
        edges.insert(edge)
    }

    func connect(_ first: WinampSkinWindowHost, _ second: WinampSkinWindowHost) {
        dock(first, to: second)
    }

    func undock(_ host: WinampSkinWindowHost) {
        edges = edges.filter { !$0.contains(ObjectIdentifier(host)) }
    }

    func disconnect(_ host: WinampSkinWindowHost) {
        undock(host)
    }

    /// Moves the whole group so that the selected member reaches the requested
    /// logical origin. This is the programmatic counterpart to dragging a
    /// member window through AppKit.
    func move(_ host: WinampSkinWindowHost, toLogicalOrigin origin: CGPoint, display: Bool = false) {
        guard members[ObjectIdentifier(host)] != nil else { return }
        let target = WinampSkinWindowGeometry.screenFrame(for: CGRect(origin: origin, size: host.logicalFrame.size), scale: host.scale).origin
        let delta = CGPoint(x: target.x - host.window.frame.minX, y: target.y - host.window.frame.minY)
        apply(screenDelta: delta, display: display, from: host, sourceAlreadyMoved: false)
    }

    private func hostDidMove(_ host: WinampSkinWindowHost) {
        guard !isApplyingGroupMove, let member = members[ObjectIdentifier(host)] else { return }
        let currentOrigin = host.window.frame.origin
        let delta = CGPoint(
            x: currentOrigin.x - member.lastScreenOrigin.x,
            y: currentOrigin.y - member.lastScreenOrigin.y
        )
        guard delta.x != 0 || delta.y != 0 else { return }

        let hostID = ObjectIdentifier(host)
        members[hostID]?.lastScreenOrigin = currentOrigin
        if edges.contains(where: { $0.contains(hostID) }) {
            let snapshot = dragStartOrigins[hostID]
            let dragDelta: CGPoint
            if let start = snapshot?[hostID] {
                dragDelta = CGPoint(x: currentOrigin.x - start.x, y: currentOrigin.y - start.y)
            } else {
                dragDelta = delta
            }
            apply(screenDelta: dragDelta, display: snapshot != nil, from: host, sourceAlreadyMoved: true, startOrigins: snapshot)
        }
    }

    private func hostWillBeginDragging(_ host: WinampSkinWindowHost, explicitlyUndocking: Bool) {
        if explicitlyUndocking { undock(host) }
        let id = ObjectIdentifier(host)
        let component = connectedComponent(containing: host)
        dragStartOrigins[id] = Dictionary(uniqueKeysWithValues: component.compactMap { key in
            members[key]?.host.map { (key, $0.window.frame.origin) }
        })
    }

    private func hostDidEndDragging(_ host: WinampSkinWindowHost) {
        let id = ObjectIdentifier(host)
        host.snapToVisibleScreenEdgesIfNeeded()
        if edges.contains(where: { $0.contains(id) }) {
            let actual = host.window.frame.origin
            let old = members[id]?.lastScreenOrigin ?? actual
            apply(screenDelta: CGPoint(x: actual.x - old.x, y: actual.y - old.y), display: true, from: host, sourceAlreadyMoved: true)
        } else {
            tryAutoDock(host)
        }
        dragStartOrigins.removeValue(forKey: id)
        members[id]?.lastScreenOrigin = host.window.frame.origin
    }

    private func apply(screenDelta delta: CGPoint, display: Bool, from source: WinampSkinWindowHost, sourceAlreadyMoved: Bool, startOrigins: [ObjectIdentifier: CGPoint]? = nil) {
        guard delta.x != 0 || delta.y != 0 else { return }
        let component = connectedComponent(containing: source)
        isApplyingGroupMove = true
        defer { isApplyingGroupMove = false }

        for key in component {
            guard let member = members[key], let host = member.host else {
                members.removeValue(forKey: key)
                continue
            }
            if key != ObjectIdentifier(source) || !sourceAlreadyMoved {
                let origin: CGPoint
                if let start = startOrigins?[key] {
                    origin = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
                } else {
                    origin = CGPoint(x: host.window.frame.minX + delta.x, y: host.window.frame.minY + delta.y)
                }
                host.setFrameFromGroup(CGRect(origin: origin, size: host.window.frame.size), display: display)
            }
            members[key]?.lastScreenOrigin = host.window.frame.origin
        }
    }

    private func connectedComponent(containing source: WinampSkinWindowHost) -> Set<ObjectIdentifier> {
        let sourceID = ObjectIdentifier(source)
        var result: Set<ObjectIdentifier> = [sourceID]
        var changed = true
        while changed {
            changed = false
            for edge in edges where result.contains(edge.first) || result.contains(edge.second) {
                if result.insert(edge.first).inserted { changed = true }
                if result.insert(edge.second).inserted { changed = true }
            }
        }
        return result
    }

    private func tryAutoDock(_ host: WinampSkinWindowHost) {
        let hostID = ObjectIdentifier(host)
        guard members[hostID] != nil,
              let other = members.values.compactMap(\.host).first(where: { $0 !== host && shouldDock(host, to: $0) }) else { return }
        let frame = host.window.frame
        let otherFrame = other.window.frame
        var snapped = frame
        let horizontalCandidates = [otherFrame.minX - frame.width, otherFrame.maxX]
        let verticalCandidates = [otherFrame.minY - frame.height, otherFrame.maxY]
        let horizontal = horizontalCandidates.min(by: { abs($0 - frame.minX) < abs($1 - frame.minX) })
        let vertical = verticalCandidates.min(by: { abs($0 - frame.minY) < abs($1 - frame.minY) })
        if let horizontal, abs(horizontal - frame.minX) <= snapDistance,
           frame.maxY > otherFrame.minY && frame.minY < otherFrame.maxY {
            snapped.origin.x = horizontal
        } else if let vertical, abs(vertical - frame.minY) <= snapDistance,
                  frame.maxX > otherFrame.minX && frame.minX < otherFrame.maxX {
            snapped.origin.y = vertical
        } else {
            return
        }
        isApplyingGroupMove = true
        host.setFrameFromGroup(snapped, display: false)
        isApplyingGroupMove = false
        dock(host, to: other)
        members[hostID]?.lastScreenOrigin = snapped.origin
    }

    private func shouldDock(_ host: WinampSkinWindowHost, to other: WinampSkinWindowHost) -> Bool {
        let frame = host.window.frame
        let otherFrame = other.window.frame
        let horizontalGap = min(abs(frame.maxX - otherFrame.minX), abs(frame.minX - otherFrame.maxX))
        let verticalGap = min(abs(frame.maxY - otherFrame.minY), abs(frame.minY - otherFrame.maxY))
        let overlapsVertically = frame.maxY > otherFrame.minY && frame.minY < otherFrame.maxY
        let overlapsHorizontally = frame.maxX > otherFrame.minX && frame.minX < otherFrame.maxX
        return (horizontalGap <= snapDistance && overlapsVertically) ||
            (verticalGap <= snapDistance && overlapsHorizontally)
    }
}
