import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Renders the real collapsed bar offscreen on a red backdrop and measures what
/// the width setting does to it: the pill may shrink down to the physical notch
/// but never narrower, and no wing content may be drawn over the cutout.
final class CollapsedPillWidthTests: XCTestCase {
    // 14" MacBook Pro-ish: 27pt mascot → 41pt wings, 185pt notch.
    private let notch: CGFloat = 185

    @MainActor
    func testPillNeverGetsNarrowerThanTheNotch() throws {
        for scale in [150, 100, 90, 80, 50] {
            let g = try renderedGeometry(scale: scale)
            XCTAssertGreaterThanOrEqual(
                g.barRight - g.barLeft, notch - 1,
                "scale \(scale): the pill shrinks under the physical notch"
            )
            XCTAssertLessThanOrEqual(
                g.contentRight, g.notchLeft + 1,
                "scale \(scale): wing content is drawn over the notch"
            )
            XCTAssertGreaterThan(g.barLeft, 0, "scale \(scale): the bar runs past the panel window")
        }
    }

    @MainActor
    func testPillShrinksWithTheSetting() throws {
        let full = try renderedGeometry(scale: 100)
        let half = try renderedGeometry(scale: 50)
        XCTAssertGreaterThan(full.barRight - full.barLeft, half.barRight - half.barLeft + 10)
        // 50 % keeps a shrunken mascot beside the notch (the old bare-notch
        // pill looked empty), 100 % is notch + both wings.
        XCTAssertEqual(half.barRight - half.barLeft, notch + 40, accuracy: 1)
        XCTAssertEqual(full.barRight - full.barLeft, notch + 80, accuracy: 1)
        // The mascot still shows at 100 % …
        XCTAssertGreaterThan(full.contentRight, full.barLeft + 20)
        // … and at the smallest setting, just smaller.
        XCTAssertGreaterThan(half.contentRight, half.barLeft + 12)
    }

    /// Points from the window's left edge: the pill's edges and the right edge
    /// of whatever the left wing still draws.
    @MainActor
    func testWingContentStaysPinnedToThePillEdge() throws {
        // Every leftover point belongs to the gap, never to the row's centring:
        // the mascot keeps its distance from the pill's left end at every
        // setting instead of drifting inward as the leftover grows.
        var insets: [CGFloat] = []
        for scale in [100, 95, 90] {
            let g = try renderedGeometry(scale: scale)
            insets.append(g.contentRight - g.barLeft)
        }
        for (index, inset) in insets.enumerated() {
            XCTAssertGreaterThan(inset, 20, "case \(index): the mascot drifted away from the pill's edge")
            XCTAssertEqual(inset, insets[0], accuracy: 3, "case \(index): the mascot moved with the setting")
        }
    }

    @MainActor
    func testIdleMarkerAlsoShrinksToTheNotch() throws {
        // No sessions: the resting marker used to keep its wings at every
        // setting, which read as "the setting does nothing below 100 %". It
        // now shrinks like the active bar, mascot included.
        let full = try renderedGeometry(scale: 100, sessions: false)
        let half = try renderedGeometry(scale: 50, sessions: false)
        XCTAssertEqual(full.barRight - full.barLeft, notch + 80, accuracy: 1)
        XCTAssertEqual(half.barRight - half.barLeft, notch + 40, accuracy: 1)
        // Even then the marker still draws its mascot.
        XCTAssertGreaterThan(half.contentRight, half.barLeft + 12)
    }

    @MainActor
    private func renderedGeometry(scale: Int, sessions: Bool = true)
        throws -> (barLeft: CGFloat, barRight: CGFloat, contentRight: CGFloat, notchLeft: CGFloat) {
        _ = NSApplication.shared
        let suiteName = "CollapsedPillWidthTests"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(scale, forKey: SettingsKey.collapsedWidthScale)
        suite.set(false, forKey: SettingsKey.showToolStatus)
        MascotAnimationGate.shared.setPanelVisible(false)
        defer { MascotAnimationGate.shared.setPanelVisible(true) }

        let state = AppState()
        if sessions {
            var session = SessionSnapshot()
            session.source = "claude"
            session.cwd = "/Users/dev/code/web-app"
            session.status = .idle
            state.sessions = ["s1": session]
            state.activeSessionId = "s1"
            state.refreshDerivedState()
        }

        let windowWidth: CGFloat = 620, height: CGFloat = 64
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: notch, screenWidth: 1512)
            .environment(\.mascotStaticTime, 5.2)
            .defaultAppStorage(suite)
            .background(Color(red: 1, green: 0, blue: 0))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: windowWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let w = image.width, h = image.height
        let scaleFactor = CGFloat(w) / windowWidth
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = px + (y * w + x) * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        func isBackdrop(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
        func isBlack(_ c: (Int, Int, Int)) -> Bool { c.0 < 12 && c.1 < 12 && c.2 < 12 }
        let mid = Int(16 * scaleFactor)
        // Only the vertical middle of the bar: the pill's rounded top corners
        // blend into the backdrop there and would read as "content".
        let barRows = (mid - 3 * Int(scaleFactor))...(mid + 3 * Int(scaleFactor))
        let barLeft = try XCTUnwrap((0..<w).first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        let barRight = try XCTUnwrap((0..<w).reversed().first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        var contentRight = barLeft
        for x in stride(from: w / 2, to: barLeft, by: -1)
        where barRows.contains(where: { y in
            let c = rgb(x, y)
            return !isBlack(c) && !isBackdrop(c)
        }) {
            contentRight = x
            break
        }
        return (
            CGFloat(barLeft) / scaleFactor,
            CGFloat(barRight + 1) / scaleFactor,
            CGFloat(contentRight + 1) / scaleFactor,
            (windowWidth - notch) / 2
        )
    }
}
