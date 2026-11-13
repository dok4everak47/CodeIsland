import AppKit
import Combine
import CoreGraphics

/// #219 — on external screens the simulated notch sits centered in the menu
/// bar, which can overlap third-party status items (Bartender's bar, iStat
/// menus, …). This helper reads the geometry of visible status-bar windows
/// (bounds/layer/owner only — no Screen Recording permission needed) and
/// nudges the island into the nearest clear gap.
enum MenuBarIconAvoidance {

    /// NSStatusItem windows live on this CGWindow layer.
    private static let statusBarWindowLayer = 25

    /// Never move the island further than this fraction of the screen width
    /// away from its preferred position — a packed menu bar shouldn't shove
    /// the island into a corner.
    static let maxShiftFraction: CGFloat = 0.25

    /// Breathing room kept between the island and the nearest status icon.
    static let margin: CGFloat = 8

    /// X-intervals (AppKit coordinates) of the visible status items.
    ///
    /// The window list below is the cheap path, but macOS 26 composites the
    /// whole menu bar into one WindowServer window and it comes up empty there;
    /// every status item still exposes its frame as an `AXExtrasMenuBar` child
    /// of its app, so this is the fallback. Read-only, and CodeIsland already
    /// holds the accessibility grant for terminal detection. Takes the pids so
    /// the caller can read `NSWorkspace` on the main thread and walk the apps
    /// off it.
    nonisolated static func accessibilityStatusItemRanges(pids: [pid_t]) -> [ClosedRange<CGFloat>] {
        guard AXIsProcessTrusted() else { return [] }
        var ranges: [ClosedRange<CGFloat>] = []
        for pid in pids where pid > 0 {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &extrasRef) == .success,
                  let extras = extrasRef,
                  CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extras as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children {
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionRef) == .success,
                      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                      let positionRef, let sizeRef,
                      CFGetTypeID(positionRef) == AXValueGetTypeID(),
                      CFGetTypeID(sizeRef) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero
                var size = CGSize.zero
                guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
                      size.width > 0 else { continue }
                ranges.append(origin.x...(origin.x + size.width))
            }
        }
        return ranges
    }

    /// X-intervals (AppKit coordinates, in `screen`'s space) of visible
    /// status-bar windows on `screen`'s menu bar, excluding our own windows.
    @MainActor
    static func occupiedMenuBarRanges(on screen: NSScreen) -> [ClosedRange<CGFloat>] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        // CGWindowList uses a global top-left origin anchored at the primary
        // screen; AppKit uses bottom-left. Convert via the primary screen height.
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryHeightCG = primary.frame.maxY

        let menuBarHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        let menuBarTopY = screen.frame.maxY
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)

        var ranges: [ClosedRange<CGFloat>] = []
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == statusBarWindowLayer,
                  let ownerPid = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != ownPid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            guard let x = boundsDict["X"], let y = boundsDict["Y"],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 0, height > 0 else { continue }

            // Convert the window's CG top-left Y to AppKit bottom-left.
            let appKitMaxY = primaryHeightCG - y
            // Keep only windows whose top edge sits in this screen's menu bar band.
            guard appKitMaxY <= menuBarTopY + 1,
                  appKitMaxY >= menuBarTopY - menuBarHeight - 1 else { continue }
            // And which horizontally belong to this screen.
            let minX = x
            let maxX = x + width
            guard maxX > screen.frame.minX, minX < screen.frame.maxX else { continue }

            ranges.append(max(minX, screen.frame.minX)...min(maxX, screen.frame.maxX))
        }
        return ranges
    }

    /// Pure: gap between the notch's right edge and the nearest range to its
    /// right, `.infinity` when nothing is in the way.
    static func freeSpaceRight(notchRight: CGFloat, occupied: [ClosedRange<CGFloat>]) -> CGFloat {
        guard let nearest = occupied.map(\.lowerBound).filter({ $0 >= notchRight }).min() else {
            return .infinity
        }
        return Swift.max(0, nearest - notchRight)
    }

    /// Cuts a wing's room down so it ends `clearance` before the nearest icon.
    static func clampedToMenuBar(slot: CGFloat, freeSpaceRight: CGFloat, clearance: CGFloat) -> CGFloat {
        guard freeSpaceRight.isFinite else { return slot }
        return Swift.max(0, Swift.min(slot, freeSpaceRight - clearance))
    }

    /// Pure placement: returns the X for `panelWidth` that avoids `occupied`
    /// ranges while staying as close to `preferredX` as possible. Falls back to
    /// `preferredX` when there is no clear gap within the allowed shift.
    static func resolvedX(
        preferredX: CGFloat,
        panelWidth: CGFloat,
        occupied: [ClosedRange<CGFloat>],
        screenMinX: CGFloat,
        screenMaxX: CGFloat,
        maxShift: CGFloat
    ) -> CGFloat {
        let merged = mergeRanges(occupied)
        guard overlaps(x: preferredX, width: panelWidth, ranges: merged) else { return preferredX }

        var candidates: [CGFloat] = []
        for range in merged {
            candidates.append(range.lowerBound - margin - panelWidth) // slide in on the left
            candidates.append(range.upperBound + margin)              // slide in on the right
        }

        let viable = candidates.filter { x in
            x >= screenMinX
                && x + panelWidth <= screenMaxX
                && abs(x - preferredX) <= maxShift
                && !overlaps(x: x, width: panelWidth, ranges: merged)
        }

        return viable.min(by: { abs($0 - preferredX) < abs($1 - preferredX) }) ?? preferredX
    }

    static func mergeRanges(_ ranges: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound + margin {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func overlaps(x: CGFloat, width: CGFloat, ranges: [ClosedRange<CGFloat>]) -> Bool {
        let panelRange = x...(x + width)
        return ranges.contains { $0.overlaps(panelRange) }
    }
}

/// Menu-bar room around the notch, measured off the status items and shared
/// with the SwiftUI bar. Kept out of the view so the measurement can refresh on
/// a timer instead of on every render.
final class MenuBarSpace: ObservableObject {
    /// Points between the notch's right edge and the nearest status item.
    /// `.infinity` means the menu bar is clear.
    @Published private(set) var freeSpaceRight: CGFloat = .infinity

    func update(freeSpaceRight newValue: CGFloat) {
        // Ignore sub-point churn so a pulsing icon doesn't relayout the bar.
        let snapped = newValue.isFinite ? (newValue * 2).rounded() / 2 : .infinity
        guard snapped != freeSpaceRight else { return }
        freeSpaceRight = snapped
    }
}
