import XCTest
@testable import CodeIslandCore

/// DSH has no Stop hook. Its bridge (dsh-island) reports the agent lifecycle
/// as a Notification — "Agent status: running|idle" — and nothing else ever
/// says the turn is over, so the island has to read the idle transition as
/// the Stop. These pin that reading, including the cases it must not fire on.
final class DshTurnEndTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    @discardableResult
    private func reduce(
        _ payload: [String: Any],
        _ sessions: inout [String: SessionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HookEventReduction {
        reduceHookEvent(
            sessions: &sessions,
            event: try hookEvent(payload, file: file, line: line),
            maxHistory: 20
        )
    }

    private func startedSession(_ sessions: inout [String: SessionSnapshot], file: StaticString = #filePath, line: UInt = #line) throws {
        try reduce([
            "hook_event_name": "SessionStart",
            "session_id": "dsh-1",
            "cwd": "/repo",
            "_source": "dsh",
        ], &sessions, file: file, line: line)
    }

    private func status(_ value: String, sessionId: String = "dsh-1") -> [String: Any] {
        [
            "hook_event_name": "Notification",
            "session_id": sessionId,
            "agent_id": sessionId,
            "_source": "dsh",
            "message": "Agent status: \(value)",
        ]
    }

    func testRunningToIdleEndsTheTurn() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try startedSession(&sessions)
        try reduce(status("running"), &sessions)
        XCTAssertEqual(sessions["dsh-1"]?.status, .processing)

        let idle = try reduce(status("idle"), &sessions)

        XCTAssertTrue(idle.facts.appliedToSession)
        XCTAssertTrue(idle.facts.endedTurn, "DSH's idle is the Stop it never sends")
        XCTAssertFalse(idle.facts.subagentTurn, "the agent id of a status message is the session's own")
        XCTAssertEqual(idle.facts.eventName, "Stop", "the cue and completion key off the Stop name")
        XCTAssertEqual(sessions["dsh-1"]?.status, .idle)
    }

    func testIdleWithoutARunningTurnIsNotACompletion() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try startedSession(&sessions)

        let idle = try reduce(status("idle"), &sessions)

        XCTAssertFalse(idle.facts.endedTurn, "a fresh, never-running agent has not finished a turn")
        XCTAssertEqual(sessions["dsh-1"]?.status, .idle)
    }

    func testIdleWhileWaitingIsNotACompletion() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try startedSession(&sessions)
        try reduce(status("running"), &sessions)
        // An approval the island queued owns the card; AppState raises that
        // status when a PermissionRequest arrives.
        sessions["dsh-1"]?.status = .waitingApproval

        let idle = try reduce(status("idle"), &sessions)

        XCTAssertFalse(idle.facts.endedTurn, "a wait for approval still owns the card")
        XCTAssertEqual(sessions["dsh-1"]?.status, .waitingApproval)
    }

    func testAnotherSourcesNotificationIsUntouched() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce([
            "hook_event_name": "SessionStart",
            "session_id": "claude-1",
            "cwd": "/repo",
            "_source": "claude",
        ], &sessions)

        let idle = try reduce([
            "hook_event_name": "Notification",
            "session_id": "claude-1",
            "agent_id": "claude-1",
            "_source": "claude",
            "message": "Agent status: idle",
        ], &sessions)

        XCTAssertFalse(idle.facts.endedTurn)
    }

    func testTheCompletionBringsTheTurnEndSound() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try startedSession(&sessions)
        try reduce(status("running"), &sessions)

        let idle = try reduceEvent(
            sessions: &sessions,
            event: try hookEvent(status("idle")),
            maxHistory: 20
        )

        XCTAssertTrue(idle.contains(.enqueueCompletion(sessionId: "dsh-1")))
        XCTAssertTrue(idle.contains(.playSound("Stop")), "the turn-end jingle, not Notification's silence")
    }
}
