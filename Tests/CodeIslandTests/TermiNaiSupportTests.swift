import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// TermiNai (com.zacharyzhang.terminai) support. TermiNai is a Rust/gpui terminal whose
/// tabs ("sessions") live inside one window. It ships no URL scheme, no AppleScript
/// dictionary, and its only CLI entry (`terminai hook`) writes agent events into the app,
/// so — like Superset and Terax — click-to-jump can only bring the app forward.
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
}
