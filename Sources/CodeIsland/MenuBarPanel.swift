import AppKit
import SwiftUI
import CodeIslandCore

/// What the status item's dot says at a glance.
///
/// The island itself is a *template* image (alpha only, tinted by AppKit, see
/// `StatusItemController.menuBarIcon`), so the state cannot be painted into it
/// without losing light/dark tracking. A small coloured dot next to it carries
/// the state instead.
enum MenuBarBadge: Equatable {
    /// Nothing running — no dot.
    case idle
    /// An agent is working.
    case working
    /// An agent is blocked on the user (approval or question).
    case attention

    /// Attention outranks work: a pending request is what the app is for.
    static func resolve(_ statuses: some Sequence<AgentStatus>) -> MenuBarBadge {
        var isWorking = false
        for status in statuses {
            switch status {
            case .waitingApproval, .waitingQuestion:
                return .attention
            case .processing, .running:
                isWorking = true
            case .idle:
                break
            }
        }
        return isWorking ? .working : .idle
    }

    var color: NSColor? {
        switch self {
        case .idle:
            return nil
        case .working:
            return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .attention:
            return NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1)
        }
    }
}

/// Where the drop-down window goes: centred under the status item, hanging just
/// below the menu bar, and kept on the screen it was opened on.
enum MenuBarPanelGeometry {
    /// Room kept between the menu bar and the card.
    static let gap: CGFloat = 6
    /// Room kept between the card and the screen edges.
    static let edgeMargin: CGFloat = 8
    /// The card never gets shorter than this, even if SwiftUI reports less.
    static let minimumHeight: CGFloat = 30

    /// - Parameters:
    ///   - contentSize: the card's own size (`NotchPanelView.onCardSizeChange`).
    ///   - anchor: the status item button in screen coordinates.
    ///   - screenFrame: the screen the item lives on, in Cocoa coordinates.
    static func frame(contentSize: CGSize, anchor: NSRect, screenFrame: NSRect) -> NSRect {
        let usableWidth = max(120, screenFrame.width - edgeMargin * 2)
        let width = min(max(contentSize.width, 120), usableWidth)
        let top = anchor.minY - gap
        let available = max(minimumHeight, top - screenFrame.minY - edgeMargin)
        let height = min(max(contentSize.height, minimumHeight), available)
        let centred = anchor.midX - width / 2
        let x = min(max(centred, screenFrame.minX + edgeMargin), screenFrame.maxX - edgeMargin - width)
        return NSRect(
            x: x.rounded(),
            y: (top - height).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

/// Borderless panel for the drop-down. Same key-window treatment as the notch
/// island's panel so the question card's text field and the reply box can take
/// typing, and AppKit must not shove the window off the menu bar.
private final class MenuBarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The menu-bar presentation of the island (Settings › Behavior › Menu bar
/// panel): nothing is drawn at the notch, the status item is the entry point,
/// and clicking it drops the full panel down under the icon.
@MainActor
final class MenuBarPanelController: NSObject {
    private let appState: AppState
    private var panel: MenuBarPanelWindow?
    private var hostingView: NSHostingView<NotchPanelView>?
    /// The card's own size, cached so a re-open lands at the right size before
    /// SwiftUI has laid the content out again.
    private var cardSize: CGSize = .zero
    private var contentScreen: NSScreen?
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private var isSurfaceObservationArmed = false
    private var isWatching = false
    private var isAwaitingFirstSize = false

    /// The status item button in screen coordinates — the card hangs under it.
    var anchorProvider: () -> NSRect? = { nil }

    private(set) var isOpen = false

    /// The drop-down itself, for tests.
    var debugWindow: NSWindow? { panel }

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    // MARK: - Lifecycle

    /// Start watching the surface: a permission request opening while the panel
    /// is closed has to come to the user, exactly like the notch version.
    func activate() {
        appState.followUps.isPointerOverPanel = { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return false }
            return panel.frame.contains(NSEvent.mouseLocation)
        }
        isWatching = true
        armSurfaceObservation()
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        guard let screen = (anchorProvider().map(screenContaining)) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        isOpen = true
        let panel = panel ?? makePanel()
        self.panel = panel
        rebuildContent(for: screen)

        // Nothing to list yet: the drop-down stays the compact bar with the
        // mascot instead of opening an empty list.
        if appState.surface == .collapsed, !appState.sessions.isEmpty {
            appState.surface = .sessionList
        }
        // The card is invisible until SwiftUI has reported its size: a guess at
        // the height would flash a wrongly sized black slab.
        isAwaitingFirstSize = true
        panel.alphaValue = 0
        applyFrame(for: screen)
        panel.orderFrontRegardless()
        revealWhenSized()
        // Safety net: a layout pass that reports nothing must not leave an
        // invisible panel in front of the user's work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.revealWhenSized(force: true)
        }
        installMonitors()
        MascotAnimationGate.shared.setPanelVisible(true)
    }

    func close() {
        guard isOpen else { return }
        guard canDismiss else { return }
        isOpen = false
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        removeMonitors()
        MascotAnimationGate.shared.setPanelVisible(false)
        withAnimation(NotchAnimation.close) {
            appState.surface = .collapsed
            appState.cancelCompletionQueue()
        }
    }

    /// An unanswered request keeps the card in front — the same rule the notch
    /// panel applies to clicks outside it (PanelWindowController).
    private var canDismiss: Bool {
        switch appState.surface {
        case .approvalCard, .questionCard:
            return false
        default:
            return true
        }
    }

    // MARK: - Panel construction

    private func makePanel() -> MenuBarPanelWindow {
        let panel = MenuBarPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.alphaValue = 0
        return panel
    }

    private func rebuildContent(for screen: NSScreen) {
        let menuBarHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        let maxVisible = UserDefaults.standard.object(forKey: SettingsKey.maxVisibleSessions) as? Int
            ?? SettingsDefaults.maxVisibleSessions
        let budget = PanelHeightMetrics.desiredHeight(maxVisibleSessions: maxVisible)
        let root = NotchPanelView(
            appState: appState,
            hasNotch: false,
            notchHeight: menuBarHeight,
            notchW: 0,
            screenWidth: screen.frame.width,
            placement: .menuBar,
            cardSpaceBudget: budget,
            onCardSizeChange: { [weak self] size in
                self?.cardSizeChanged(size)
            }
        )
        contentScreen = screen
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.autoresizingMask = [.width, .height]
            panel?.contentView = hosting
            hostingView = hosting
        }
    }

    // MARK: - Sizing and placement

    private func cardSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width - cardSize.width) > 0.5 || abs(size.height - cardSize.height) > 0.5
        cardSize = size
        guard isOpen, let screen = contentScreen else { return }
        if changed || isAwaitingFirstSize {
            applyFrame(for: screen)
        }
        revealWhenSized()
    }

    private func applyFrame(for screen: NSScreen) {
        guard let panel else { return }
        let anchor = anchorProvider() ?? fallbackAnchor(on: screen)
        let size = cardSize == .zero ? CGSize(width: 580, height: 360) : cardSize
        let frame = MenuBarPanelGeometry.frame(
            contentSize: size,
            anchor: anchor,
            screenFrame: screen.frame
        )
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Before the size arrives: a stand-in anchor at the icon end of the menu bar.
    private func fallbackAnchor(on screen: NSScreen) -> NSRect {
        let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        return NSRect(
            x: screen.frame.maxX - 40,
            y: screen.frame.maxY - height,
            width: 24,
            height: height
        )
    }

    private func screenContaining(_ rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func revealWhenSized(force: Bool = false) {
        guard isOpen, isAwaitingFirstSize, let panel else { return }
        guard force || cardSize != .zero else { return }
        isAwaitingFirstSize = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Dismissal

    private func installMonitors() {
        guard outsideMonitor == nil, escapeMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                let point = NSEvent.mouseLocation
                // The status item toggles the panel itself; letting the monitor
                // close it first would make the click reopen it.
                if self.anchorProvider()?.contains(point) == true { return }
                if self.panel?.frame.contains(point) == true { return }
                self.close()
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isOpen, let panel = self.panel else { return event }
            // The monitor is app-wide: only the drop-down's own Esc belongs to
            // it, never the Settings window's, which has its own to worry about.
            guard event.window === panel || event.window == nil else { return event }
            guard self.canDismiss else { return nil }
            self.close()
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideMonitor = nil
        escapeMonitor = nil
    }

    // MARK: - Surface

    private func armSurfaceObservation() {
        guard isWatching, !isSurfaceObservationArmed else { return }
        isSurfaceObservationArmed = true
        withObservationTracking {
            _ = appState.surface
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSurfaceObservationArmed = false
                self.surfaceChanged()
                self.armSurfaceObservation()
            }
        }
    }

    private func surfaceChanged() {
        guard isWatching else { return }
        if isOpen {
            if appState.surface == .collapsed {
                // Something else collapsed the island (a card shortcut, the
                // completion queue): the drop-down has nothing to show.
                isOpen = false
                panel?.orderOut(nil)
                panel?.alphaValue = 0
                removeMonitors()
                MascotAnimationGate.shared.setPanelVisible(false)
            }
            return
        }
        if shouldOpenAutomatically(for: appState.surface) {
            open()
        }
    }

    /// A card opens the panel by itself — the Behaviour switches (Auto-expand
    /// on Permission / on Question, completion style) are already applied where
    /// `AppState` decides the surface, so a card surface *is* the decision to
    /// show it. Lists only ever open on a click.
    private func shouldOpenAutomatically(for surface: IslandSurface) -> Bool {
        switch surface {
        case .approvalCard, .questionCard, .completionCard:
            return true
        case .collapsed, .sessionList, .sessionDetail:
            return false
        }
    }
}
