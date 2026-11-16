import AppKit
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The drop-down as a whole: opening must land a visible window under the icon,
/// and the same refusals that keep the notch open must keep it open here.
@MainActor
final class MenuBarPanelControllerTests: XCTestCase {
    private var controller: MenuBarPanelController?
    private var state: AppState?

    override func tearDown() async throws {
        controller?.close()
        controller = nil
        state = nil
        try await super.tearDown()
    }

    private func makeController(
        anchor: NSRect,
        pointer: NSPoint = .zero,
        grace: TimeInterval = 0.05
    ) throws -> (MenuBarPanelController, AppState) {
        let appState = AppState()
        let controller = MenuBarPanelController(appState: appState)
        controller.anchorProvider = { anchor }
        controller.pointerLocation = { pointer }
        controller.hoverGrace = grace
        // The real timer would poll the real pointer, not the test's.
        controller.activate(trackingHover: false)
        self.controller = controller
        self.state = appState
        return (controller, appState)
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testOpeningHangsAVisiblePanelUnderTheIcon() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        let (controller, _) = try makeController(anchor: anchor)

        controller.open()
        await wait(0.4)

        XCTAssertTrue(controller.isOpen)
        let window = try XCTUnwrap(controller.debugWindow, "the drop-down has no window")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, "the panel must not stay transparent")
        XCTAssertEqual(window.frame.maxY, anchor.minY - MenuBarPanelGeometry.gap, accuracy: 1)
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.frame.maxX)
        XCTAssertGreaterThanOrEqual(window.frame.minX, screen.frame.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, screen.frame.minY)
        XCTAssertGreaterThanOrEqual(window.frame.height, MenuBarPanelGeometry.minimumHeight)
        XCTAssertTrue(window.isKind(of: NSPanel.self), "the drop-down is a panel, not a plain window")
    }

    func testAnOpenRequestCannotBeDismissed() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        let (controller, appState) = try makeController(anchor: anchor)

        appState.surface = .approvalCard(sessionId: "s1")
        controller.open()
        await wait(0.3)
        XCTAssertTrue(controller.isOpen)

        // An outside click / Esc / icon click must not hide the request.
        controller.close()
        XCTAssertTrue(controller.isOpen, "an open approval card must stay on screen")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s1"))

        // Answering it lets the panel go.
        appState.surface = .sessionList
        controller.close()
        XCTAssertFalse(controller.isOpen)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    func testOpeningWithNoSessionsKeepsTheCompactBar() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        let (controller, appState) = try makeController(anchor: anchor)

        controller.open()
        await wait(0.3)
        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(
            appState.surface, .collapsed,
            "nothing to list: the drop-down shows the bar, not an empty list"
        )
    }

    // MARK: - Hover

    /// Pointing at the icon is the whole gesture: no click anywhere.
    func testHoveringTheIconOpensTheDropDown() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        let (controller, _) = try makeController(
            anchor: anchor,
            pointer: NSPoint(x: anchor.midX, y: anchor.midY)
        )
        XCTAssertFalse(controller.isOpen)

        controller.pollHover()
        XCTAssertTrue(controller.isOpen, "the pointer on the icon has to bring the card up")
    }

    /// Leaving both the icon and the card puts it away, after the short grace
    /// the pointer needs to cross the gap between them.
    func testLeavingTheCardPutsItAway() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        var pointer = NSPoint(x: anchor.midX, y: anchor.midY)
        let (controller, _) = try makeController(anchor: anchor, pointer: pointer, grace: 0.05)
        controller.pointerLocation = { pointer }
        controller.pollHover()
        XCTAssertTrue(controller.isOpen)

        pointer = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        controller.pollHover()
        XCTAssertTrue(controller.isOpen, "the grace period has not run out yet")
        await wait(0.2)
        controller.pollHover()
        XCTAssertFalse(controller.isOpen)
    }

    /// Walking from the icon onto the card must not drop it — answering a
    /// card means hovering it.
    func testWalkingOntoTheCardKeepsItUp() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        var pointer = NSPoint(x: anchor.midX, y: anchor.midY)
        let (controller, _) = try makeController(anchor: anchor, pointer: pointer, grace: 0.05)
        controller.pointerLocation = { pointer }
        controller.pollHover()
        XCTAssertTrue(controller.isOpen)
        let window = try XCTUnwrap(controller.debugWindow)
        await wait(0.3)

        pointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        controller.pollHover()
        await wait(0.2)
        controller.pollHover()
        XCTAssertTrue(controller.isOpen, "the pointer is on the card, not away from it")
    }

    /// A request waiting for an answer outlives the pointer walking away.
    func testHoveringAwayCannotDismissAnOpenRequest() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen to place the drop-down on")
        }
        let anchor = NSRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 12, width: 24, height: 24)
        let (controller, appState) = try makeController(
            anchor: anchor,
            pointer: NSPoint(x: 0, y: 0),
            grace: 0.05
        )
        appState.surface = .approvalCard(sessionId: "s1")
        controller.open()
        await wait(0.3)

        controller.pollHover()
        await wait(0.2)
        controller.pollHover()
        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s1"))
    }
}
