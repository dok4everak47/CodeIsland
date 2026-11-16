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

    private func makeController(anchor: NSRect) throws -> (MenuBarPanelController, AppState) {
        let appState = AppState()
        let controller = MenuBarPanelController(appState: appState)
        controller.anchorProvider = { anchor }
        controller.activate()
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
}
