import AppKit
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Menu-bar presentation: what the status item says, and where the drop-down
/// lands. Both are pure functions precisely so they can be pinned down here —
/// the window itself needs a screen to be tested on.
final class MenuBarPanelTests: XCTestCase {
    // MARK: - Badge

    func testBadgeIsIdleWithoutSessions() {
        XCTAssertEqual(MenuBarBadge.resolve([AgentStatus]()), .idle)
        XCTAssertEqual(MenuBarBadge.resolve([.idle, .idle]), .idle)
        XCTAssertNil(MenuBarBadge.idle.color, "an idle island has no dot at all")
    }

    func testBadgeReportsWorkInProgress() {
        XCTAssertEqual(MenuBarBadge.resolve([.idle, .processing]), .working)
        XCTAssertEqual(MenuBarBadge.resolve([.running]), .working)
        XCTAssertNotNil(MenuBarBadge.working.color)
    }

    func testBadgePrefersAnAgentWaitingOnTheUser() {
        XCTAssertEqual(MenuBarBadge.resolve([.processing, .waitingApproval]), .attention)
        XCTAssertEqual(MenuBarBadge.resolve([.running, .waitingQuestion, .waitingApproval]), .attention)
        XCTAssertNotNil(MenuBarBadge.attention.color)
    }

    // MARK: - Frame

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    /// A status item near the right end of the menu bar.
    private var anchor: NSRect { NSRect(x: 1200, y: 875, width: 24, height: 24) }

    func testFrameHangsUnderTheIconWithoutCrossingTheRightEdge() {
        let frame = MenuBarPanelGeometry.frame(
            contentSize: CGSize(width: 300, height: 200),
            anchor: anchor,
            screenFrame: screen
        )
        XCTAssertEqual(frame.height, 200)
        XCTAssertEqual(frame.width, 300)
        // 6pt under the menu bar, and the icon's centre is the card's centre
        // whenever the card fits.
        XCTAssertEqual(frame.maxY, anchor.minY - MenuBarPanelGeometry.gap)
        XCTAssertEqual(frame.midX, anchor.midX)
    }

    func testFrameShiftsLeftWhenTheIconIsTooCloseToTheEdge() {
        let wide = MenuBarPanelGeometry.frame(
            contentSize: CGSize(width: 580, height: 200),
            anchor: anchor,
            screenFrame: screen
        )
        XCTAssertEqual(
            wide.maxX,
            screen.maxX - MenuBarPanelGeometry.edgeMargin,
            "a wide card is pushed back inside the screen instead of hanging off it"
        )
    }

    func testFrameLeavesTheLeftEdgeAlone() {
        let left = NSRect(x: 4, y: 875, width: 24, height: 24)
        let frame = MenuBarPanelGeometry.frame(
            contentSize: CGSize(width: 300, height: 200),
            anchor: left,
            screenFrame: screen
        )
        XCTAssertEqual(frame.minX, screen.minX + MenuBarPanelGeometry.edgeMargin)
    }

    func testFrameClampsToTheSpaceBelowTheMenuBar() {
        let frame = MenuBarPanelGeometry.frame(
            contentSize: CGSize(width: 300, height: 5000),
            anchor: anchor,
            screenFrame: screen
        )
        XCTAssertEqual(frame.minY, screen.minY + MenuBarPanelGeometry.edgeMargin)
        let available = anchor.minY - MenuBarPanelGeometry.gap
            - (screen.minY + MenuBarPanelGeometry.edgeMargin)
        XCTAssertEqual(frame.height, available)
    }

    func testFrameNeverShrinksToNothing() {
        let frame = MenuBarPanelGeometry.frame(
            contentSize: .zero,
            anchor: anchor,
            screenFrame: screen
        )
        XCTAssertGreaterThanOrEqual(frame.height, MenuBarPanelGeometry.minimumHeight)
        XCTAssertGreaterThan(frame.width, 0)
    }
}
