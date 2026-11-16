import AppKit

extension UserDefaults {
    @objc dynamic var hideWhenNoSession: Bool {
        bool(forKey: SettingsKey.hideWhenNoSession)
    }

    @objc dynamic var menuBarMode: Bool {
        bool(forKey: SettingsKey.menuBarMode)
    }
}

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    /// Owned by `AppDelegate`; read for the badge, watched for changes.
    weak var appState: AppState?
    /// Left click in menu-bar mode: bring the drop-down up. Hover normally got
    /// there first, so the click only ever opens and never dismisses what the
    /// pointer is still sitting on. Without it (the classic notch mode's
    /// optional icon) the click falls back to the menu.
    var onShowPanel: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var badgeDot: NSView?
    private var observation: NSKeyValueObservation?
    private var menuBarObservation: NSKeyValueObservation?
    private var isBadgeObservationArmed = false
    private lazy var menu: NSMenu = makeMenu()

    /// The item and its badge, for tests.
    var debugStatusItem: NSStatusItem? { statusItem }
    var debugBadgeDot: NSView? { badgeDot }

    /// Take the item away again: a test process must not leave an icon behind.
    func hideStatusItemForTests() { hideStatusItem() }

    /// The button in screen coordinates — the drop-down hangs under it.
    var buttonScreenRect: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func startObserving() {
        syncVisibility()
        observation = UserDefaults.standard.observe(
            \.hideWhenNoSession, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.syncVisibility() }
        }
        menuBarObservation = UserDefaults.standard.observe(
            \.menuBarMode, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.syncVisibility() }
        }
        armBadgeObservation()
    }

    /// Menu-bar mode has no other entry point, so the icon is not optional
    /// there — `hideWhenNoSession` only governs the notch presentation.
    private func syncVisibility() {
        if SettingsManager.shared.menuBarMode || SettingsManager.shared.hideWhenNoSession {
            showStatusItem()
        } else {
            hideStatusItem()
        }
    }

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "CodeIsland"
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let dot = Self.makeBadgeDot()
            button.addSubview(dot)
            badgeDot = dot
        }
        statusItem = item
        updateBadge()
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        // No panel to open outside menu-bar mode: every click is the menu.
        guard !isRightClick, let onShowPanel else {
            showMenu()
            return
        }
        onShowPanel()
    }

    private func showMenu() {
        guard let item = statusItem, let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    private func hideStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            badgeDot = nil
        }
    }

    // MARK: - State dot

    private static func makeBadgeDot() -> NSView {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.isHidden = true
        return dot
    }

    private var badge: MenuBarBadge {
        guard let states = appState?.sessions.values.map(\.status) else { return .idle }
        return MenuBarBadge.resolve(states)
    }

    /// `withObservationTracking` is one-shot; re-arm from `onChange` so an idle
    /// app schedules no polling (same pattern as `PanelWindowController`).
    private func armBadgeObservation() {
        guard let appState, !isBadgeObservationArmed else { return }
        isBadgeObservationArmed = true
        withObservationTracking {
            _ = appState.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isBadgeObservationArmed = false
                self.updateBadge()
                self.armBadgeObservation()
            }
        }
    }

    private func updateBadge() {
        guard let button = statusItem?.button, let dot = badgeDot else { return }
        let state = badge
        if let color = state.color {
            dot.layer?.backgroundColor = color.cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }
        // Bottom-trailing corner of the icon: out of the way of the island mark.
        let size: CGFloat = 5
        dot.frame = NSRect(x: button.bounds.maxX - size - 1, y: 2, width: size, height: size)
        button.toolTip = state == .attention ? "CodeIsland — waiting for you" : "CodeIsland"
    }

    /// Menu-bar art is a *template* image by macOS convention (#313): alpha-only
    /// artwork that AppKit tints itself, so it tracks light/dark, the menu bar's
    /// own tint over a wallpaper, and the pressed/highlighted state. The
    /// full-colour app icon can do none of that and reads as a foreign sticker
    /// next to every system item.
    ///
    /// The mark is the island itself — a pill with the mascot's two eyes knocked
    /// out, which still resolves at 18pt where a scaled-down app icon turns to mush.
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let pill = NSRect(x: 1.5, y: 5, width: 15, height: 8)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationOut
            let eye = CGFloat(2.6)
            for dx in [-3.7, 1.1] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(
                    x: pill.midX + dx,
                    y: pill.midY - eye / 2,
                    width: eye,
                    height: eye
                )).fill()
            }
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if SettingsManager.shared.menuBarMode {
            let panel = NSMenuItem(
                title: L10n.shared["menu_bar_panel"],
                action: #selector(openPanel),
                keyEquivalent: ""
            )
            panel.target = self
            menu.addItem(panel)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(
            title: L10n.shared["settings_ellipsis"],
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.shared["quit"],
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openPanel() {
        onShowPanel?()
    }

    @objc private func openSettings() {
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
