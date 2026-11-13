import XCTest
@testable import CodeIsland

/// #219 — pure placement math for dodging third-party status items on
/// external screens (Bartender overlap).
final class MenuBarIconAvoidanceTests: XCTestCase {
    private let screenMinX: CGFloat = 0
    private let screenMaxX: CGFloat = 2560
    private let maxShift: CGFloat = 640  // 25% of 2560

    private func resolve(preferredX: CGFloat, width: CGFloat, occupied: [ClosedRange<CGFloat>]) -> CGFloat {
        MenuBarIconAvoidance.resolvedX(
            preferredX: preferredX,
            panelWidth: width,
            occupied: occupied,
            screenMinX: screenMinX,
            screenMaxX: screenMaxX,
            maxShift: maxShift
        )
    }

    func testNoOverlapKeepsCenteredPosition() {
        // Bartender bar lives right of the centered island — no move needed.
        XCTAssertEqual(resolve(preferredX: 1180, width: 200, occupied: [1500...2540]), 1180)
    }

    func testOverlapSlidesLeftIntoNearestGap() {
        // Icons from 1300 to the right edge; centered island (1180...1380) overlaps.
        let x = resolve(preferredX: 1180, width: 200, occupied: [1300...2540])
        XCTAssertEqual(x, 1300 - MenuBarIconAvoidance.margin - 200)
    }

    func testOverlapPrefersSmallestMove() {
        // A small island overlapping the left edge of an icon cluster moves left,
        // not all the way past the cluster.
        let x = resolve(preferredX: 1250, width: 100, occupied: [1300...1400])
        XCTAssertEqual(x, 1300 - MenuBarIconAvoidance.margin - 100)
    }

    func testPackedMenuBarFallsBackToPreferred() {
        // No gap fits within maxShift — stay centered rather than jump to a corner.
        let x = resolve(preferredX: 1180, width: 200, occupied: [0...2560])
        XCTAssertEqual(x, 1180)
    }

    func testGapBetweenClustersIsUsed() {
        // Two clusters with a usable gap between them just right of center.
        let x = resolve(preferredX: 1180, width: 200, occupied: [900...1200, 1500...2540])
        XCTAssertEqual(x, 1200 + MenuBarIconAvoidance.margin)
    }

    func testShiftBeyondMaxIsRejected() {
        // Gap exists but requires moving further than maxShift.
        let x = MenuBarIconAvoidance.resolvedX(
            preferredX: 1180,
            panelWidth: 200,
            occupied: [1000...2560],
            screenMinX: 0,
            screenMaxX: 2560,
            maxShift: 100
        )
        XCTAssertEqual(x, 1180)
    }

    func testMergeRangesJoinsNearbyIcons() {
        // Individual status items sit a few points apart — they merge into one block.
        let merged = MenuBarIconAvoidance.mergeRanges([100...130, 134...160, 300...330])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], 100...160)
        XCTAssertEqual(merged[1], 300...330)
    }

    func testResolvedPositionNeverLeavesScreen() {
        let x = resolve(preferredX: 100, width: 200, occupied: [0...350])
        XCTAssertGreaterThanOrEqual(x, screenMinX)
        XCTAssertLessThanOrEqual(x + 200, screenMaxX)
    }

    func testWingRoomStopsBeforeTheNearestIcon() {
        // Icons 10pt from the notch: the wing may only take 2 of them, with the
        // 8pt clearance kept.
        XCTAssertEqual(
            MenuBarIconAvoidance.clampedToMenuBar(slot: 40, freeSpaceRight: 10, clearance: 8),
            2
        )
        // Icons further out than the wing needs: nothing changes.
        XCTAssertEqual(
            MenuBarIconAvoidance.clampedToMenuBar(slot: 26, freeSpaceRight: 60, clearance: 8),
            26
        )
        // An icon right against the notch leaves no room at all, never a
        // negative one.
        XCTAssertEqual(
            MenuBarIconAvoidance.clampedToMenuBar(slot: 26, freeSpaceRight: 3, clearance: 8),
            0
        )
        // A clear menu bar (external display, Bartender off) is no constraint.
        XCTAssertEqual(
            MenuBarIconAvoidance.clampedToMenuBar(slot: 26, freeSpaceRight: .infinity, clearance: 8),
            26
        )
    }

    func testMenuBarSpaceIgnoresSubPointChurn() {
        let space = MenuBarSpace()
        XCTAssertEqual(space.freeSpaceRight, .infinity)
        space.update(freeSpaceRight: 42.2)
        XCTAssertEqual(space.freeSpaceRight, 42, accuracy: 0.001)
        space.update(freeSpaceRight: 42.1)
        XCTAssertEqual(space.freeSpaceRight, 42, accuracy: 0.001)
    }
}
