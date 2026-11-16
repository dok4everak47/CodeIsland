import AppKit
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The icon is the only entry point into menu-bar mode, so its presence, its
/// template art (macOS tints it, the app must not) and its click routing are
/// part of the feature, not decoration.
@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var controller: StatusItemController?
    private var savedMenuBarMode: Any?
    private var savedHideWhenNoSession: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedMenuBarMode = UserDefaults.standard.object(forKey: SettingsKey.menuBarMode)
        savedHideWhenNoSession = UserDefaults.standard.object(forKey: SettingsKey.hideWhenNoSession)
    }

    override func tearDown() async throws {
        controller?.hideStatusItemForTests()
        controller = nil
        restore(SettingsKey.menuBarMode, savedMenuBarMode)
        restore(SettingsKey.hideWhenNoSession, savedHideWhenNoSession)
        try await super.tearDown()
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func spinRunLoop(_ seconds: TimeInterval = 0.2) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func makeController(menuBarMode: Bool) -> StatusItemController {
        UserDefaults.standard.set(menuBarMode, forKey: SettingsKey.menuBarMode)
        UserDefaults.standard.set(false, forKey: SettingsKey.hideWhenNoSession)
        let controller = StatusItemController()
        controller.appState = AppState()
        controller.startObserving()
        spinRunLoop()
        self.controller = controller
        return controller
    }

    func testMenuBarModeShowsATemplateIconInTheStatusBar() throws {
        let controller = makeController(menuBarMode: true)
        let item = try XCTUnwrap(controller.debugStatusItem, "menu-bar mode has no icon")
        let button = try XCTUnwrap(item.button)

        XCTAssertTrue(item.isVisible)
        let image = try XCTUnwrap(button.image)
        XCTAssertTrue(image.isTemplate, "the menu bar tints its own art; a baked-in colour breaks that")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertNotNil(button.action, "the icon has to answer clicks")
        XCTAssertEqual(button.toolTip, "CodeIsland")
        // The badge is a subview, never part of the template image.
        let dot = try XCTUnwrap(controller.debugBadgeDot)
        XCTAssertTrue(button.subviews.contains(dot))
        XCTAssertTrue(dot.isHidden, "nothing is running: no dot")
        XCTAssertTrue(dot.wantsLayer)
    }

    func testTheIconReachesTheMenuBar() throws {
        let controller = makeController(menuBarMode: true)
        XCTAssertNotNil(controller.debugStatusItem)
        let rect = try XCTUnwrap(
            controller.buttonScreenRect,
            "the item never made it into the menu bar"
        )
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        guard let screen = NSScreen.main else { return }
        XCTAssertTrue(screen.frame.contains(rect), "the icon must sit on screen")
    }

    func testAClickOpensThePanelInsteadOfTheMenu() throws {
        let controller = makeController(menuBarMode: true)
        XCTAssertNotNil(controller.debugStatusItem)
        var toggles = 0
        controller.onTogglePanel = { toggles += 1 }

        controller.perform(NSSelectorFromString("statusButtonClicked"))
        XCTAssertEqual(toggles, 1, "a left click belongs to the drop-down")
    }

    func testLeavingMenuBarModeTakesTheIconAway() throws {
        let controller = makeController(menuBarMode: false)
        XCTAssertNil(controller.debugStatusItem, "notch mode keeps the icon optional")
    }
}
