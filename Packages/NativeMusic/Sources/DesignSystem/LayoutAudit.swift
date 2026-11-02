import SwiftUI

// V02 layout audit (GLASS07). Views tag themselves with `.audit(...)`; a test (or a Debug build) reads the frames
// they report through a preference and checks overlaps, containment, grid alignment and outer margins.
// In Release every call is the identity, so nothing ships.

public enum AuditKind: String, Sendable {
  /// A glass or panel region. Margins and grid offsets are checked.
  case region
  /// An ordinary element. Must not overlap siblings in its group and must sit inside its container.
  case element
  /// A deliberate layer (glass over content, a badge on artwork). Exempt from the overlap rule.
  case layer
  /// A full-width chrome row between the toolbar and the panels (history banner, QA readouts): excluded from every other region like a panel is,
  /// but flush with its column by design, so the outer-margin rule does not apply to it.
  case band
  /// A region that floats over the window by design (the player capsule): mutually exclusive with every other region and inside the window like a region, but not
  /// held to the one outer margin the panels share.
  case floating
}

/// What a tagged view declares about itself.
public struct AuditTag: Equatable, Sendable {
  public let name: String
  /// Siblings: elements of one group must not overlap each other.
  public let group: String
  public let kind: AuditKind
  /// The name of the element this one must lie inside. `a|b` means the first of them that was reported (the same list is a panel in
  /// one layout and a destination in another).
  public let container: String?
  /// Leading edges of everything with the same key must coincide.
  public let alignLeading: String?
  /// Top edges of everything with the same key must coincide (page titles share one height).
  public let alignTop: String?
  /// Offsets from the container's origin must sit on the 4-point grid.
  public let onGrid: Bool
  /// Content of a scroll view: it may run past the container vertically (that is what scrolling is), never horizontally.
  public let scrolls: Bool
}

public struct AuditFrame: Equatable, Sendable {
  public let tag: AuditTag
  public let rect: CGRect
  public init(tag: AuditTag, rect: CGRect) { self.tag = tag; self.rect = rect }
}

public struct AuditViolation: Equatable, Sendable, CustomStringConvertible {
  public enum Rule: String, Sendable { case overlap, containment, grid, leadingAlignment, topAlignment, outerMargin, missing, empty }
  public let rule: Rule
  public let detail: String
  public var description: String { "\(rule.rawValue): \(detail)" }
}

#if DEBUG
public struct AuditEntry: @unchecked Sendable {
  public let tag: AuditTag
  public let anchor: Anchor<CGRect>
}
public struct AuditPreferenceKey: PreferenceKey {
  public static let defaultValue: [AuditEntry] = []
  public static func reduce(value: inout [AuditEntry], nextValue: () -> [AuditEntry]) { value.append(contentsOf: nextValue()) }
}
#endif

extension View {
  /// Reports this view's frame to the audit. The identity in Release.
  @ViewBuilder public func audit(_ name: String, group: String = "root", kind: AuditKind = .element, within container: String? = nil,
                                 alignLeading: String? = nil, alignTop: String? = nil, onGrid: Bool = false, scrolls: Bool = false) -> some View {
    #if DEBUG
    let tag = AuditTag(name: name, group: group, kind: kind, container: container, alignLeading: alignLeading, alignTop: alignTop, onGrid: onGrid, scrolls: scrolls)
    transformAnchorPreference(key: AuditPreferenceKey.self, value: .bounds) { $0.append(AuditEntry(tag: tag, anchor: $1)) }
    #else
    self
    #endif
  }
  /// Resolves every tag below into window coordinates and hands them to `report`. The identity in Release.
  @ViewBuilder public func auditRoot(_ report: @escaping ([AuditFrame]) -> Void) -> some View {
    #if DEBUG
    overlayPreferenceValue(AuditPreferenceKey.self) { entries in
      GeometryReader { proxy in
        let frames = [AuditFrame(tag: AuditTag(name: LayoutAudit.windowName, group: "window", kind: .layer, container: nil, alignLeading: nil, alignTop: nil, onGrid: false, scrolls: false), rect: CGRect(origin: .zero, size: proxy.size))]
          + entries.map { AuditFrame(tag: $0.tag, rect: proxy[$0.anchor]) }
        Color.clear.allowsHitTesting(false).onChange(of: frames, initial: true) { _, value in report(value) }
      }.allowsHitTesting(false)
    }
    #else
    self
    #endif
  }
}

/// The checks. Pure functions of reported frames, so they are unit-testable without a window.
public enum LayoutAudit {
  /// The frame the root reports for itself: the bounds the outer-margin rule measures from.
  public static let windowName = "__window"
  /// Native controls round to pixels and text has intrinsic heights; this is the slack the rules allow.
  public static let tolerance: CGFloat = 0.75
  /// Overlap area, in square points, below which two frames only touch.
  public static let overlapSlack: CGFloat = 1

  public static func evaluate(_ frames: [AuditFrame], bounds: CGRect, expecting required: [String] = [], marginGroup: String? = nil) -> [AuditViolation] {
    var violations: [AuditViolation] = []
    let byName = Dictionary(frames.map { ($0.tag.name, $0) }, uniquingKeysWith: { first, _ in first })
    for name in required where byName[name] == nil { violations.append(.init(rule: .missing, detail: "\(name) was not reported")) }
    for frame in frames where frame.rect.width <= 0 || frame.rect.height <= 0 || !frame.rect.origin.x.isFinite || !frame.rect.origin.y.isFinite {
      if frame.tag.kind != .layer { violations.append(.init(rule: .empty, detail: "\(frame.tag.name) has an empty or non-finite frame \(frame.rect)")) }
    }
    // Overlap: siblings of a group (layers are deliberate and exempt).
    let groups = Dictionary(grouping: frames.filter { $0.tag.kind != .layer && !$0.rect.isEmpty }, by: { $0.tag.group })
    for (group, members) in groups {
      for i in members.indices {
        for j in members.indices where j > i {
          let overlap = members[i].rect.intersection(members[j].rect)
          if !overlap.isNull, overlap.width * overlap.height > overlapSlack, overlap.width > tolerance, overlap.height > tolerance {
            violations.append(.init(rule: .overlap, detail: "\(members[i].tag.name) overlaps \(members[j].tag.name) in \(group) by \(rounded(overlap))"))
          }
        }
      }
    }
    // Regions (panels, the player, banners) are mutually exclusive whatever group they were tagged in: a player floating over a
    // panel, or a banner under the toolbar edge, is an occlusion even though each sits in its own group. Declared layers are exempt.
    let regionFrames = frames.filter { ($0.tag.kind == .region || $0.tag.kind == .band || $0.tag.kind == .floating) && !$0.rect.isEmpty }
    for i in regionFrames.indices {
      for j in regionFrames.indices where j > i {
        let overlap = regionFrames[i].rect.intersection(regionFrames[j].rect)
        if !overlap.isNull, overlap.width > tolerance, overlap.height > tolerance {
          violations.append(.init(rule: .overlap, detail: "region \(regionFrames[i].tag.name) is covered by region \(regionFrames[j].tag.name) by \(rounded(overlap))"))
        }
      }
    }
    // Regions and bands stay inside the window's content area: a banner pushed under the toolbar edge, or a panel past the window, is an escape.
    for frame in regionFrames where !contains(bounds, frame.rect) {
      violations.append(.init(rule: .containment, detail: "\(frame.tag.name) \(rounded(frame.rect)) leaves the window content \(rounded(bounds))"))
    }
    // Containment and grid, against the declared container.
    for frame in frames {
      guard let declared = frame.tag.container else { continue }
      let alternatives = declared.split(separator: "|").map(String.init)
      let containerName = alternatives.first { byName[$0] != nil } ?? declared
      guard let container = byName[containerName] else { violations.append(.init(rule: .missing, detail: "\(frame.tag.name) names container \(containerName), which was not reported")); continue }
      if frame.tag.kind != .layer, !contains(container.rect, frame.rect, horizontalOnly: frame.tag.scrolls) {
        violations.append(.init(rule: .containment, detail: "\(frame.tag.name) \(rounded(frame.rect)) lies outside \(containerName) \(rounded(container.rect))"))
      }
      if frame.tag.onGrid {
        let dx = frame.rect.minX - container.rect.minX, dy = frame.rect.minY - container.rect.minY
        if !MusicSpace.isOnGrid(dx, tolerance: tolerance) || !MusicSpace.isOnGrid(dy, tolerance: tolerance) {
          violations.append(.init(rule: .grid, detail: "\(frame.tag.name) is offset (\(fmt(dx)), \(fmt(dy))) from \(containerName), off the 4 pt grid"))
        }
      }
    }
    // Grid for tags without a container: offsets from the window.
    for frame in frames where frame.tag.onGrid && frame.tag.container == nil {
      let dx = frame.rect.minX - bounds.minX, dy = frame.rect.minY - bounds.minY
      if !MusicSpace.isOnGrid(dx, tolerance: tolerance) || !MusicSpace.isOnGrid(dy, tolerance: tolerance) {
        violations.append(.init(rule: .grid, detail: "\(frame.tag.name) is offset (\(fmt(dx)), \(fmt(dy))) from the window, off the 4 pt grid"))
      }
    }
    // Leading edges that must coincide.
    for (key, members) in Dictionary(grouping: frames.filter { $0.tag.alignLeading != nil }, by: { $0.tag.alignLeading! }) {
      guard let reference = members.first else { continue }
      for other in members.dropFirst() where abs(other.rect.minX - reference.rect.minX) > tolerance {
        violations.append(.init(rule: .leadingAlignment, detail: "\(other.tag.name) leads at \(fmt(other.rect.minX)) but \(reference.tag.name) at \(fmt(reference.rect.minX)) (\(key))"))
      }
    }
    // Top edges that must coincide.
    for (key, members) in Dictionary(grouping: frames.filter { $0.tag.alignTop != nil }, by: { $0.tag.alignTop! }) {
      guard let reference = members.first else { continue }
      for other in members.dropFirst() where abs(other.rect.minY - reference.rect.minY) > tolerance {
        violations.append(.init(rule: .topAlignment, detail: "\(other.tag.name) starts at y \(fmt(other.rect.minY)) but \(reference.tag.name) at \(fmt(reference.rect.minY)) (\(key))"))
      }
    }
    // Outer margins: regions near a window edge keep one grid-aligned inset per edge.
    let regions = frames.filter { $0.tag.kind == .region && (marginGroup == nil || $0.tag.group == marginGroup) }
    for edge in Edge.allCases {
      let insets = regions.compactMap { frame -> (String, CGFloat)? in
        let inset = edge.inset(of: frame.rect, in: bounds)
        return inset <= edge.reach ? (frame.tag.name, inset) : nil
      }
      guard let first = insets.first else { continue }
      for (name, inset) in insets {
        if !MusicSpace.isOnGrid(inset, tolerance: tolerance) { violations.append(.init(rule: .outerMargin, detail: "\(name) sits \(fmt(inset)) from the \(edge) edge, off the 4 pt grid")) }
        if abs(inset - first.1) > tolerance { violations.append(.init(rule: .outerMargin, detail: "\(name) sits \(fmt(inset)) from the \(edge) edge but \(first.0) sits \(fmt(first.1))")) }
      }
    }
    return violations
  }

  private enum Edge: CaseIterable, CustomStringConvertible {
    case leading, trailing, bottom, top
    var reach: CGFloat { 40 }
    var description: String { switch self { case .leading: "leading"; case .trailing: "trailing"; case .bottom: "bottom"; case .top: "top" } }
    func inset(of rect: CGRect, in bounds: CGRect) -> CGFloat {
      switch self { case .leading: rect.minX - bounds.minX; case .trailing: bounds.maxX - rect.maxX; case .bottom: bounds.maxY - rect.maxY; case .top: rect.minY - bounds.minY }
    }
  }
  private static func contains(_ outer: CGRect, _ inner: CGRect, horizontalOnly: Bool = false) -> Bool {
    let horizontal = inner.minX >= outer.minX - tolerance && inner.maxX <= outer.maxX + tolerance
    return horizontalOnly ? horizontal : horizontal && inner.minY >= outer.minY - tolerance && inner.maxY <= outer.maxY + tolerance
  }
  private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
  private static func rounded(_ rect: CGRect) -> String { "(\(fmt(rect.minX)), \(fmt(rect.minY)), \(fmt(rect.width))×\(fmt(rect.height)))" }
}
