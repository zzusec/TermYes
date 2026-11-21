@preconcurrency import AppKit
import CoreGraphics
import Foundation

struct WindowBadgePlacement: Equatable {
    let windowID: Int
    let number: Int
    let label: String
    let topLeftFrame: CGRect
}

struct WindowBadgeTracker: Equatable {
    static let badgeHeight: CGFloat = 20
    static let topInset: CGFloat = 4
    static let trailingInset: CGFloat = 8
    static let minimumWindowWidth: CGFloat = 110
    static let minimumWindowHeight: CGFloat = 48

    private(set) var numberByWindowID: [Int: Int] = [:]

    static func circledLabel(for number: Int) -> String {
        guard number > 0 else { return "\(number)" }
        if number <= 20, let scalar = UnicodeScalar(0x2460 + number - 1) {
            return String(Character(scalar))
        }
        if number <= 35, let scalar = UnicodeScalar(0x3251 + number - 21) {
            return String(Character(scalar))
        }
        if number <= 50, let scalar = UnicodeScalar(0x32B1 + number - 36) {
            return String(Character(scalar))
        }
        return "\(number)"
    }

    static func badgeWidth(for number: Int) -> CGFloat {
        if number < 10 { return 20 }
        if number < 100 { return 25 }
        return 31
    }

    static func badgeFrame(for windowBounds: CGRect, number: Int) -> CGRect? {
        guard windowBounds.width >= minimumWindowWidth,
              windowBounds.height >= minimumWindowHeight else { return nil }
        let width = badgeWidth(for: number)
        let x = (windowBounds.maxX - trailingInset - width).rounded()
        let y = (windowBounds.minY + topInset).rounded()
        return CGRect(x: x, y: y, width: width, height: badgeHeight)
    }

    static func cocoaFrame(fromTopLeft topLeftFrame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: topLeftFrame.minX,
            y: primaryScreenMaxY - topLeftFrame.maxY,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
    }

    static func isBadgeObscured(_ badgeFrame: CGRect, by obscuringRects: [CGRect]) -> Bool {
        let probe = badgeFrame.insetBy(dx: 2, dy: 2)
        guard !probe.isNull, probe.width > 0, probe.height > 0 else { return false }
        return obscuringRects.contains { rect in
            let intersection = rect.intersection(probe)
            return !intersection.isNull && intersection.width >= 1 && intersection.height >= 1
        }
    }

    /// Assigns stable positive numbers (1, 2, 3...) to live user windows and never mutates
    /// an existing live window's number when window positions rotate or neighbors close.
    mutating func synchronize(liveWindowIDs: [Int], excludedWindowIDs: Set<Int> = []) {
        let retainedSet = Set(liveWindowIDs).subtracting(excludedWindowIDs)
        numberByWindowID = numberByWindowID.filter { retainedSet.contains($0.key) }

        var usedNumbers = Set(numberByWindowID.values)
        for id in liveWindowIDs where retainedSet.contains(id) && numberByWindowID[id] == nil {
            var candidate = 1
            while usedNumbers.contains(candidate) {
                candidate += 1
            }
            numberByWindowID[id] = candidate
            usedNumbers.insert(candidate)
        }
    }

    func number(for windowID: Int) -> Int? {
        numberByWindowID[windowID]
    }

    func visiblePlacements(
        targetWindowIDs: [Int],
        boundsByID: [Int: CGRect],
        obscuringBoundsByID: [Int: [CGRect]] = [:]
    ) -> [WindowBadgePlacement] {
        var seen = Set<Int>()
        var placements: [WindowBadgePlacement] = []
        for id in targetWindowIDs where seen.insert(id).inserted {
            guard let number = numberByWindowID[id],
                  let windowBounds = boundsByID[id],
                  let frame = Self.badgeFrame(for: windowBounds, number: number) else { continue }
            let obscuring = obscuringBoundsByID[id] ?? []
            guard !Self.isBadgeObscured(frame, by: obscuring) else { continue }
            placements.append(
                WindowBadgePlacement(
                    windowID: id,
                    number: number,
                    label: Self.circledLabel(for: number),
                    topLeftFrame: frame
                )
            )
        }
        return placements
    }
}

@MainActor
private final class WindowBadgeView: NSView {
    var number: Int = 1 {
        didSet {
            if oldValue != number {
                setAccessibilityLabel("窗口 \(WindowBadgeTracker.circledLabel(for: number))")
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("窗口 ①")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        guard outerRect.width > 2, outerRect.height > 2 else { return }

        let radius = outerRect.height / 2
        let path = NSBezierPath(roundedRect: outerRect, xRadius: radius, yRadius: radius)

        NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 0.90).setFill()
        path.fill()

        NSColor(calibratedWhite: 0.96, alpha: 0.92).setStroke()
        path.lineWidth = 1.35
        path.stroke()

        let text = "\(number)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.99, alpha: 1.0)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = CGPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        )
        text.draw(at: textOrigin, withAttributes: attributes)
    }
}

@MainActor
private final class WindowBadgePanel: NSPanel {
    let badgeView: WindowBadgeView

    init(frame: NSRect, number: Int) {
        self.badgeView = WindowBadgeView(frame: NSRect(origin: .zero, size: frame.size))
        self.badgeView.number = number
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = badgeView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowBadgeController {
    private(set) var tracker = WindowBadgeTracker()
    private(set) var activePlacements: [WindowBadgePlacement] = []
    private var panels: [Int: WindowBadgePanel] = [:]
    private let rendersPanels: Bool

    init(rendersPanels: Bool = true) {
        self.rendersPanels = rendersPanels
    }

    func synchronizeIdentity(liveWindowIDs: [Int], excludedWindowIDs: Set<Int> = []) {
        tracker.synchronize(liveWindowIDs: liveWindowIDs, excludedWindowIDs: excludedWindowIDs)
        let retainedIDs = Set(tracker.numberByWindowID.keys)
        for (id, panel) in panels where !retainedIDs.contains(id) {
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: id)
        }
    }

    func badgeNumber(for windowID: Int) -> Int? {
        tracker.number(for: windowID)
    }

    func updateVisibleBadges(
        targetWindowIDs: [Int],
        boundsByID: [Int: CGRect],
        obscuringBoundsByID: [Int: [CGRect]] = [:]
    ) {
        let placements = tracker.visiblePlacements(
            targetWindowIDs: targetWindowIDs,
            boundsByID: boundsByID,
            obscuringBoundsByID: obscuringBoundsByID
        )
        activePlacements = placements

        guard rendersPanels else { return }
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else {
            hideAllPanels()
            return
        }

        let visibleSet = Set(placements.map(\.windowID))
        for (id, panel) in panels where !visibleSet.contains(id) {
            panel.orderOut(nil)
        }

        for placement in placements {
            let cocoaRect = WindowBadgeTracker.cocoaFrame(
                fromTopLeft: placement.topLeftFrame,
                primaryScreenMaxY: primaryMaxY
            )
            if let existing = panels[placement.windowID] {
                existing.badgeView.number = placement.number
                if existing.frame != cocoaRect {
                    existing.setFrame(cocoaRect, display: true)
                    existing.badgeView.frame = NSRect(origin: .zero, size: cocoaRect.size)
                }
                if !existing.isVisible {
                    existing.orderFrontRegardless()
                }
            } else {
                let panel = WindowBadgePanel(frame: cocoaRect, number: placement.number)
                panels[placement.windowID] = panel
                panel.orderFrontRegardless()
            }
        }
    }

    func clearVisibleBadges() {
        activePlacements = []
        guard rendersPanels else { return }
        hideAllPanels()
    }

    func resetAll() {
        tracker = WindowBadgeTracker()
        activePlacements = []
        for panel in panels.values {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private func hideAllPanels() {
        for panel in panels.values where panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
