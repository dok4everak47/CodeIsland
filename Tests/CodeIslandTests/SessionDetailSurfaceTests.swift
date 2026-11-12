import AppKit
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The details surface a card click opens now, the setting that can put the
/// terminal jump back on the click, and the page's duration labels.
final class SessionDetailSurfaceTests: XCTestCase {

    // MARK: - Surface

    func testDetailIsAnExpandedSurfaceOfItsOwnSession() {
        let surface = IslandSurface.sessionDetail(sessionId: "abc")
        XCTAssertTrue(surface.isExpanded)
        XCTAssertEqual(surface.sessionId, "abc", "a removed session's page has to fold")
        XCTAssertEqual(surface.detailSessionId, "abc")
        // It is not a card: shortcuts that address approvals / questions must
        // not treat the page as one.
        XCTAssertNil(surface.approvalSessionId)
        XCTAssertNil(surface.questionSessionId)
    }

    func testOtherSurfacesAreNotDetails() {
        XCTAssertNil(IslandSurface.sessionList.detailSessionId)
        XCTAssertNil(IslandSurface.collapsed.detailSessionId)
        XCTAssertNil(IslandSurface.approvalCard(sessionId: "a").detailSessionId)
        XCTAssertNil(IslandSurface.questionCard(sessionId: "a").detailSessionId)
        XCTAssertNil(IslandSurface.completionCard(sessionId: "a").detailSessionId)
    }

    /// Hovering the notch re-opens the session list; it must not drop a page
    /// the user opened on purpose (approvals and questions are kept for the
    /// same reason).
    func testHoverExpansionLeavesThePageAlone() {
        XCTAssertFalse(NotchHoverInteraction.hoverExpansionMayReplace(.sessionDetail(sessionId: "a")))
        XCTAssertFalse(NotchHoverInteraction.hoverExpansionMayReplace(.approvalCard(sessionId: "a")))
        XCTAssertTrue(NotchHoverInteraction.hoverExpansionMayReplace(.sessionList))
        XCTAssertTrue(NotchHoverInteraction.hoverExpansionMayReplace(.collapsed))
    }

    // MARK: - Click behaviour

    func testClickOpensTheDetailsUnlessToldOtherwise() {
        XCTAssertEqual(CardClickAction(storedValue: nil), .detail)
        XCTAssertEqual(CardClickAction(storedValue: ""), .detail)
        XCTAssertEqual(CardClickAction(storedValue: "nonsense"), .detail)
        XCTAssertEqual(CardClickAction(storedValue: "detail"), .detail)
        XCTAssertEqual(CardClickAction(storedValue: "terminal"), .terminal)
        XCTAssertEqual(CardClickAction.allCases.count, 2)
    }

    func testTheShippedDefaultOpensTheDetails() {
        XCTAssertEqual(SettingsDefaults.cardClickAction, CardClickAction.detail.rawValue)
        XCTAssertEqual(CardClickAction(storedValue: SettingsDefaults.cardClickAction), .detail)
    }

    // MARK: - Durations

    func testDurationLabels() {
        XCTAssertEqual(SessionDetailFormat.short(0), "0s")
        XCTAssertEqual(SessionDetailFormat.short(59), "59s")
        XCTAssertEqual(SessionDetailFormat.short(60), "1m")
        XCTAssertEqual(SessionDetailFormat.short(3599), "59m")
        XCTAssertEqual(SessionDetailFormat.short(3600), "1h")
        XCTAssertEqual(SessionDetailFormat.short(86_399), "23h")
        XCTAssertEqual(SessionDetailFormat.short(86_400), "1d")
        // A clock that went backwards (a session restored from a snapshot)
        // reads as 0, never as a negative.
        XCTAssertEqual(SessionDetailFormat.short(-90), "0s")
    }
}

/// The details page's life in `AppState`: it opens only for a session that
/// exists, and it never outlives that session.
@MainActor
final class SessionDetailStateTests: XCTestCase {
    private func session(_ status: AgentStatus = .idle) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.status = status
        return value
    }

    func testOpeningThePageNeedsASession() {
        let app = AppState()
        app.sessions = ["a": session()]
        app.surface = .sessionList

        app.openSessionDetail("missing")
        XCTAssertEqual(app.surface, .sessionList, "no page for a session that is gone")

        app.openSessionDetail("a")
        XCTAssertEqual(app.surface, .sessionDetail(sessionId: "a"))
        XCTAssertEqual(app.activeSessionId, "a")
    }

    func testARemovedSessionsPageFallsBackToTheList() {
        let app = AppState()
        app.sessions = ["a": session(), "b": session()]
        app.surface = .sessionDetail(sessionId: "a")

        app.removeSession("a")

        XCTAssertEqual(app.surface, .sessionList, "an empty page would be all that is left")
    }

    /// The page belongs to `a`; `b` coming and going is none of its business.
    func testAnotherSessionLeavingKeepsThePage() {
        let app = AppState()
        app.sessions = ["a": session(), "b": session()]
        app.surface = .sessionDetail(sessionId: "a")

        app.removeSession("b")

        XCTAssertEqual(app.surface, .sessionDetail(sessionId: "a"))
    }

    /// A turn finishing anywhere must not cut the page off — nor queue a card
    /// that would pop at a random moment after it closes.
    func testAFinishedTurnLeavesThePageAlone() {
        let app = AppState()
        app.sessions = ["a": session(.running), "b": session(.running)]
        app.surface = .sessionDetail(sessionId: "a")

        let card = AttentionDecision(
            completion: .init(turnFailed: false, presentation: .card)
        )
        app.announceCompletion(card, sessionId: "b")
        app.announceCompletion(card, sessionId: "a")

        XCTAssertEqual(app.surface, .sessionDetail(sessionId: "a"))
        XCTAssertNil(app.justCompletedSessionId, "nothing queued behind the page")
    }

    /// Closing the page goes back to the list, where the other sessions are.
    func testClosingReturnsToTheList() {
        let app = AppState()
        app.sessions = ["a": session(), "b": session()]
        app.openSessionDetail("b")

        app.surface = .sessionList
        XCTAssertEqual(app.surface.sessionId, nil)
    }
}
