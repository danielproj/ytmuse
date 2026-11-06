import DesignSystem

extension CatalogActionPlan {
    /// Collection and artist pages promote their first published action; song pages keep link utilities inline.
    public static func pageRole(of action: CatalogAction, in offers: [CatalogActionOffer], song: Bool) -> MusicActionRole {
        if song {
            switch action {
            case .play: return .primary
            case .copyLink, .share: return .inline
            default: return .secondary
            }
        }
        return action == offers.first?.action ? .primary : .secondary
    }
}
