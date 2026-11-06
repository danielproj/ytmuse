/// Return follows the transaction state: successful sheets close; disabled submissions own no Return key.
enum PlaylistSheetDefaultAction: Equatable {
    case submit, done, none

    static func resolve(completed: Bool, canSubmit: Bool) -> Self {
        if completed { return .done }
        return canSubmit ? .submit : .none
    }
}
