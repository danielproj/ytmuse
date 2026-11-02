import SwiftUI

// The named regions of the browser window, shared by the window root and the feature pages that title themselves. The anchors feed the
// window-root layout contract (`RootRegionLayoutTests`); the same tags feed the V02 layout audit. Identity in Release.

#if DEBUG
/// Layout metadata only: no view, hit-test surface or accessibility element is introduced.
public struct BrowserRegionAnchors: PreferenceKey {
  public static let defaultValue: [String: Anchor<CGRect>] = [:]
  public static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

/// Where each named browser region sits for the layout audit: its sibling group, container, leading and top keys.
public enum BrowserAuditPlacement {
  public struct Placement { public let group: String; public let kind: AuditKind; public let container: String?; public let alignLeading: String?; public let alignTop: String?; public let onGrid: Bool; public var scrolls = false }
  public static func of(_ name: String) -> Placement {
    switch name {
    // A destination's page title: every page puts it 24 pt from the panel's top-left, on the grid, at one height.
    case "destinationTitle": Placement(group: "page-top", kind: .element, container: "detailPanel", alignLeading: "pageLeading", alignTop: "pageTitleTop", onGrid: true)
    case "collectionQuery": Placement(group: "page-top", kind: .element, container: "detailPanel", alignLeading: "pageLeading", alignTop: nil, onGrid: false)
    case "developmentLabel", "collectionFilter": Placement(group: "page-top", kind: .element, container: "detailPanel", alignLeading: nil, alignTop: nil, onGrid: false)
    case "panelPicker", "queueFooter": Placement(group: "panel-content", kind: .element, container: "trailingPanel|expandedQueuePanel", alignLeading: nil, alignTop: nil, onGrid: false)
    case "queueList": Placement(group: "panel-content", kind: .element, container: "trailingPanel|expandedQueuePanel|detailPanel", alignLeading: nil, alignTop: nil, onGrid: false, scrolls: true)
    case "nextPage": Placement(group: "panel-next", kind: .layer, container: "trailingPanel|expandedQueuePanel", alignLeading: nil, alignTop: nil, onGrid: false)
    case "sidebarFooter": Placement(group: "sidebar-content", kind: .element, container: "sidebarPanel", alignLeading: nil, alignTop: nil, onGrid: false)
    case "sidebarSettings": Placement(group: "sidebar-settings", kind: .layer, container: "sidebarFooter", alignLeading: nil, alignTop: nil, onGrid: false)
    // Chrome rows between the toolbar and the panels: bands (regions without outer margins), so the audit also proves they never run under the player or each other.
    case "banner", "debugRow", "debugPlayerRow": Placement(group: "chrome", kind: .band, container: nil, alignLeading: nil, alignTop: nil, onGrid: false)
    default: Placement(group: "browser-misc", kind: .layer, container: nil, alignLeading: nil, alignTop: nil, onGrid: false)
    }
  }
}
#endif

extension View {
  @ViewBuilder public func browserRegion(_ name: String) -> some View {
    #if DEBUG
    let placement = BrowserAuditPlacement.of(name)
    self.transformAnchorPreference(key: BrowserRegionAnchors.self, value: .bounds) { values, anchor in values[name] = anchor }
      .audit(name, group: placement.group, kind: placement.kind, within: placement.container, alignLeading: placement.alignLeading, alignTop: placement.alignTop, onGrid: placement.onGrid, scrolls: placement.scrolls)
    #else
    self
    #endif
  }
}
