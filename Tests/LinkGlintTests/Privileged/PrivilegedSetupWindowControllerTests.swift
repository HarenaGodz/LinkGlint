import XCTest
@testable import LinkGlint

final class PrivilegedSetupWindowControllerTests: XCTestCase {
    func testGuidancePhaseShowsConfigureControls() {
        let controller = PrivilegedSetupWindowController(guidance: .firstRun)
        XCTAssertEqual(controller.currentPhase, .guidance(.firstRun))
        XCTAssertEqual(controller.primaryButtonTitle, "开始配置")
        XCTAssertFalse(controller.isQuitButtonHidden)
    }

    func testBusyPhaseDisablesPrimaryButton() {
        let controller = PrivilegedSetupWindowController(guidance: .repair)
        controller.setBusy(true)
        XCTAssertEqual(controller.currentPhase, .busy(.repair))
        XCTAssertEqual(controller.primaryButtonTitle, "开始修复")
        XCTAssertFalse(controller.isQuitButtonHidden)
    }

    func testCompletionPhaseShowsStartButtonAndHidesQuit() {
        let controller = PrivilegedSetupWindowController(guidance: .firstRun)
        controller.showCompletion(onDismiss: nil)
        XCTAssertEqual(controller.currentPhase, .completed)
        XCTAssertEqual(controller.primaryButtonTitle, PrivilegedAccessCompletionCopy.actionTitle)
        XCTAssertTrue(controller.isQuitButtonHidden)
    }

    func testCompletionOnlyInitializerStartsInCompletedPhase() {
        let controller = PrivilegedSetupWindowController(completionOnly: true)
        XCTAssertEqual(controller.currentPhase, .completed)
        XCTAssertEqual(controller.primaryButtonTitle, PrivilegedAccessCompletionCopy.actionTitle)
        XCTAssertTrue(controller.isQuitButtonHidden)
    }

    func testApplyGuidanceIgnoredAfterCompletion() {
        let controller = PrivilegedSetupWindowController(guidance: .firstRun)
        controller.showCompletion(onDismiss: nil)
        controller.apply(guidance: .repair)
        XCTAssertEqual(controller.currentPhase, .completed)
        XCTAssertEqual(controller.primaryButtonTitle, PrivilegedAccessCompletionCopy.actionTitle)
    }

    func testBlockedInteractionUsesSetupForLeftClickAndRestrictedMenuForRightClick() {
        XCTAssertEqual(
            PrivilegedBlockedInteractionPolicy.action(blocked: true, rightClick: false),
            .presentSetup
        )
        XCTAssertEqual(
            PrivilegedBlockedInteractionPolicy.action(blocked: true, rightClick: true),
            .presentRestrictedMenu
        )
        XCTAssertEqual(
            PrivilegedBlockedInteractionPolicy.action(blocked: false, rightClick: true),
            .continueNormally
        )
    }
}
