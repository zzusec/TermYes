import AppKit
import CoreGraphics
import Foundation

@main
struct WindowBadgeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() {
        var tracker = WindowBadgeTracker()

        // 1. Initial numbering follows stable window order: ①, ②, ③.
        tracker.synchronize(liveWindowIDs: [101, 102, 103])
        expect(tracker.number(for: 101) == 1, "First window must receive badge 1")
        expect(tracker.number(for: 102) == 2, "Second window must receive badge 2")
        expect(tracker.number(for: 103) == 3, "Third window must receive badge 3")
        expect(WindowBadgeTracker.circledLabel(for: 1) == "①", "1 must format as ①")
        expect(WindowBadgeTracker.circledLabel(for: 2) == "②", "2 must format as ②")
        expect(WindowBadgeTracker.circledLabel(for: 20) == "⑳", "20 must format as ⑳")
        expect(WindowBadgeTracker.circledLabel(for: 21) == "㉑", "21 must format as ㉑")

        // 2. Rotating window positions clockwise must keep each window's badge unchanged.
        tracker.synchronize(liveWindowIDs: [103, 101, 102])
        expect(tracker.number(for: 101) == 1, "Rotated window 101 must keep badge ①")
        expect(tracker.number(for: 102) == 2, "Rotated window 102 must keep badge ②")
        expect(tracker.number(for: 103) == 3, "Rotated window 103 must keep badge ③")

        // 3. Closing middle window 102 leaves 101 as ① and 103 as ③; opening 104 reuses lowest free ②.
        tracker.synchronize(liveWindowIDs: [103, 101])
        expect(tracker.number(for: 101) == 1 && tracker.number(for: 103) == 3 && tracker.number(for: 102) == nil,
               "Closing a window must not renumber surviving windows")
        tracker.synchronize(liveWindowIDs: [103, 101, 104])
        expect(tracker.number(for: 104) == 2 && tracker.number(for: 101) == 1 && tracker.number(for: 103) == 3,
               "A newly opened window must claim the smallest available badge without changing existing badges")

        // 4. Dedicated temporary continue windows are excluded from user window badges.
        tracker.synchronize(liveWindowIDs: [103, 101, 104, 999], excludedWindowIDs: [999])
        expect(tracker.number(for: 999) == nil, "Temporary continue windows must not receive user badges")

        // 5. Placement follows window bounds as slots swap, and hides when an upper window obscures the badge corner.
        let leftTopSlot = CGRect(x: 0, y: 30, width: 720, height: 390)
        let rightFullSlot = CGRect(x: 720, y: 30, width: 720, height: 780)
        let leftBottomSlot = CGRect(x: 0, y: 420, width: 720, height: 390)

        let beforeRotate = tracker.visiblePlacements(
            targetWindowIDs: [101, 104, 103],
            boundsByID: [101: leftTopSlot, 104: rightFullSlot, 103: leftBottomSlot]
        )
        expect(beforeRotate.map(\.label) == ["①", "②", "③"], "All three unobscured windows must show ①, ②, ③")
        expect(beforeRotate[0].topLeftFrame == CGRect(x: 692, y: 34, width: 20, height: 20),
               "Top-left window badge must anchor inside top-right of its titlebar")

        let afterRotate = tracker.visiblePlacements(
            targetWindowIDs: [103, 101, 104],
            boundsByID: [103: leftTopSlot, 101: rightFullSlot, 104: leftBottomSlot]
        )
        expect(afterRotate.map(\.windowID) == [103, 101, 104] && afterRotate.map(\.label) == ["③", "①", "②"],
               "After clockwise rotation, ③ moves to top-left, ① moves to right, and ② moves to bottom-left")
        expect(afterRotate[0].topLeftFrame == CGRect(x: 692, y: 34, width: 20, height: 20),
               "③ must now appear at the top-left slot's titlebar corner")
        expect(afterRotate[1].topLeftFrame == CGRect(x: 1412, y: 34, width: 20, height: 20),
               "① must now appear at the right slot's titlebar corner")

        // Finder window covering the right window's top-right corner hides only ① while keeping ③ and ② visible.
        let finderOverRight = CGRect(x: 1000, y: 20, width: 440, height: 500)
        let partiallyObscured = tracker.visiblePlacements(
            targetWindowIDs: [103, 101, 104],
            boundsByID: [103: leftTopSlot, 101: rightFullSlot, 104: leftBottomSlot],
            obscuringBoundsByID: [101: [finderOverRight]]
        )
        expect(partiallyObscured.map(\.label) == ["③", "②"],
               "An upper window covering a terminal's badge corner must hide only that obscured badge")

        // Coordinate conversion round-trip with Top-Left screen space.
        let cocoa = WindowBadgeTracker.cocoaFrame(fromTopLeft: CGRect(x: 692, y: 34, width: 20, height: 20), primaryScreenMaxY: 900)
        expect(cocoa == CGRect(x: 692, y: 846, width: 20, height: 20), "Top-left to AppKit frame conversion must place badge inside titlebar")

        print("Window badge tests passed (stable ①②③ assignment, rotation invariance, gap reuse, continue exclusion, Z-order occlusion, coordinate mapping).")
    }
}
