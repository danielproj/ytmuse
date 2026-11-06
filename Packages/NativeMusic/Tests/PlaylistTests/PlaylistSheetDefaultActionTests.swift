import Testing
@testable import Features

@Suite struct PlaylistSheetDefaultActionTests {
    @Test(arguments: [false, true]) func completionAlwaysMovesReturnToDone(canSubmit: Bool) {
        #expect(PlaylistSheetDefaultAction.resolve(completed: true, canSubmit: canSubmit) == .done)
    }

    @Test func pendingSubmissionOwnsReturnOnlyWhenEnabled() {
        #expect(PlaylistSheetDefaultAction.resolve(completed: false, canSubmit: true) == .submit)
        #expect(PlaylistSheetDefaultAction.resolve(completed: false, canSubmit: false) == .none)
    }
}
