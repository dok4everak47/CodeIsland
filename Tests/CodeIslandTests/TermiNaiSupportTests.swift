import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// TermiNai (com.zacharyzhang.terminai) support. TermiNai is a Rust/gpui terminal whose
/// tabs ("sessions") live inside one window. Its `terminai focus` mode shows the session a
/// tty, a pid or a folder names and exits 0 when it did, so a card click lands on the
/// session the agent runs in; when nothing names one, the click still raises the app.
final class TermiNaiSupportTests: XCTestCase {

    private let termiNaiBundleId = "com.zacharyzhang.terminai"

    /// The core fix: TermiNai must be a recognized terminal twice over. Without the
    /// knownTerminals entry its bundle id is unknown, so resolveHostClientBundleId()
    /// treats the terminal itself as a host GUI client and the click never reaches the
    /// terminal path at all.
    func testTermiNaiIsRecognizedTerminal() {
        XCTAssertTrue(
            TerminalActivator.knownTerminals.contains { $0.bundleId == termiNaiBundleId },
            "TermiNai must be in knownTerminals so click-to-jump routes to it deterministically"
        )
    }

    /// TermiNai hosts a CLI; it is not an IDE integrated terminal and not native-app mode.
    func testTermiNaiClaudeSessionClassification() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = termiNaiBundleId
        session.termApp = "terminai"

        XCTAssertFalse(session.isIDETerminal)
        XCTAssertFalse(session.isNativeAppMode)
    }

    /// Its brand is "TermiNai", not the lowercased TERM_PROGRAM value, on both lookup paths.
    func testTermiNaiDisplayName() {
        var byBundle = SessionSnapshot()
        byBundle.source = "claude"
        byBundle.termBundleId = termiNaiBundleId
        XCTAssertEqual(byBundle.terminalName, "TermiNai")

        var byTermProgram = SessionSnapshot()
        byTermProgram.source = "claude"
        byTermProgram.termApp = "terminai"
        XCTAssertEqual(byTermProgram.terminalName, "TermiNai")
    }

    // MARK: - `terminai focus`, which shows the session a click names

    /// The tty names exactly one session, so it goes first; the pid guards the jump against
    /// a terminal number the OS handed to a newer session.
    func testFocusNamesTheSessionByItsTtyAndPid() {
        let args = TerminalActivator.terminaiFocusArguments(
            ttyPath: "/dev/ttys004", pid: 4711, cwd: "/x/y"
        )
        XCTAssertEqual(args, ["focus", "--tty", "/dev/ttys004", "--pid", "4711"])
    }

    /// A hook whose daemon lost its terminal still names the process, which the app resolves
    /// to the session that process runs under.
    func testFocusFallsBackToThePid() {
        let args = TerminalActivator.terminaiFocusArguments(ttyPath: nil, pid: 4711, cwd: "/x/y")
        XCTAssertEqual(args, ["focus", "--pid", "4711"])
    }

    /// A folder alone answers only when exactly one session holds it; the app refuses when two do.
    func testFocusFallsBackToTheFolder() {
        let args = TerminalActivator.terminaiFocusArguments(ttyPath: nil, pid: nil, cwd: "/x/y")
        XCTAssertEqual(args, ["focus", "--folder", "/x/y"])
    }

    /// Nothing names a session, so no CLI runs and the click only raises the app.
    func testNoArgumentsWhenNothingNamesASession() {
        XCTAssertNil(TerminalActivator.terminaiFocusArguments(ttyPath: nil, pid: nil, cwd: nil))
        XCTAssertNil(TerminalActivator.terminaiFocusArguments(ttyPath: "  ", pid: 0, cwd: " "))
        XCTAssertNil(TerminalActivator.terminaiFocusArguments(ttyPath: "/dev/tty", pid: nil, cwd: nil))
    }
}
