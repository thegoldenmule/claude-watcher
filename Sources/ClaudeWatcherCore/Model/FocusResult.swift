public enum FocusResult: Sendable, Equatable {
    case focused
    case appActivatedOnly(reason: String)
    case failed(reason: String)
}
