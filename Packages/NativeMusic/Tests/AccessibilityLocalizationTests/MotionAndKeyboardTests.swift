import Testing
import Foundation
import SwiftUI
import DesignSystem
@testable import Features

// W28 T28.3 (motion) and T28.1 (keyboard and VoiceOver paths without dragging).

@Suite struct MotionTests {
  @Test func reduceMotionKeepsOnlyShortCrossfades() {
    for motion in MusicMotion.allCases {
      let seconds = motion.duration(reduceMotion: true, lowPower: false, visible: true)
      #expect(seconds <= 0.1 + 1e-9, "\(motion) under Reduce Motion lasts \(seconds) s")
      if !(motion == .hoverPress || motion == .loading || motion == .reveal || motion == .playerMorph) {
        #expect(seconds == 0 && motion.animation(reduceMotion: true, lowPower: false, visible: true) == nil, "\(motion) is an immediate change under Reduce Motion")
      }
    }
    // The moving things the specification names: lyrics, artwork colour interpolation, artwork expansion, queue reorder.
    for moving in [MusicMotion.lyrics, .artworkColor, .artworkExpansion, .queueReorder, .navigation, .miniPlayer] {
      #expect(moving.duration(reduceMotion: true, lowPower: false, visible: true) == 0, "\(moving)")
    }
    // Control: without Reduce Motion these do move.
    #expect(MusicMotion.lyrics.duration(reduceMotion: false, lowPower: false, visible: true) > 0 && MusicMotion.artworkColor.duration(reduceMotion: false, lowPower: false, visible: true) > 0)
  }
  @Test func hiddenWindowsAndLowPowerStopDecorativeMotion() {
    for motion in MusicMotion.allCases { #expect(motion.duration(reduceMotion: false, lowPower: false, visible: false) == 0, "\(motion) animates while hidden") }
    for motion in [MusicMotion.artworkColor, .artworkExpansion, .playerMorph] { #expect(motion.duration(reduceMotion: false, lowPower: true, visible: true) == 0, "\(motion) in Low Power Mode") }
  }
  @Test func glassNeverAnimatesUnderReduceMotionOrLowPowerOrWhileInactive() {
    for reduce in [false, true] { for power in [false, true] { for active in [false, true] {
      let policy = GlassPolicy(reduceTransparency: false, increasedContrast: false, reduceMotion: reduce, lowPower: power, active: active)
      #expect(policy.animates == (!reduce && !power && active))
    } } }
  }
  @Test func lyricsJumpInsteadOfScrollingUnderReduceMotionButStillFollowTheLine() {
    let reduced = LyricsAutoScroll.action(current: 7, shown: 3, mode: .following, reduceMotion: true)
    #expect(reduced?.index == 7 && reduced?.animated == false, "follows the line, without animating")
    #expect(LyricsAutoScroll.action(current: 7, shown: 3, mode: .following, reduceMotion: false)?.animated == true, "control")
    #expect(LyricsAutoScroll.action(current: 7, shown: 3, mode: .manual, reduceMotion: true) == nil, "a person who scrolled away is not dragged back")
  }
  /// There is no parallax, moving gradient or looping animation anywhere in the sources (MOTION03/05); a new one fails here and must be justified.
  @Test func noParallaxMovingGradientOrInfiniteAnimationExists() {
    let forbidden = ["repeatForever", "phaseAnimator", "keyframeAnimator", "KeyframeAnimator", "MeshGradient", "TimelineView(.animation", "CADisplayLink", "parallax", "Parallax"]
    var offenders: [String] = []
    let files = Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources")
    #expect(files.count > 100, "the sweep saw the sources (\(files.count) files)")
    for (path, text) in files { let code = Repo.code(text); for word in forbidden where code.contains(word) { offenders.append("\(path): \(word)") } }
    #expect(offenders.isEmpty, "moving decoration: \(offenders)")
    // Control: the sweep does see a planted word.
    #expect(Repo.code("let x = 1 // parallax").contains("parallax") == false && Repo.code("view.repeatForever()").contains("repeatForever"))
  }
  @Test func everyGradientIsStaticAndOffUnderReducedTransparency() {
    var gradients: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") {
      let code = Repo.code(text)
      for kind in ["LinearGradient(", "RadialGradient(", "AngularGradient(", "EllipticalGradient("] where code.contains(kind) { gradients.append("\((path as NSString).lastPathComponent): \(kind)") }
    }
    // The only gradients: the canvas wash (hidden by Reduce Transparency and Increase Contrast) and the expanded player's light (same condition, one layer).
    #expect(Set(gradients) == ["DesignSystem.swift: LinearGradient(", "ExpandedPlayer.swift: RadialGradient("], "gradients: \(gradients)")
    let canvas = (try? Repo.text("Packages/NativeMusic/Sources/DesignSystem/DesignSystem.swift")) ?? ""
    #expect(canvas.contains("if !reduceTransparency && contrast != .increased {\n        LinearGradient("))
    let light = (try? Repo.text("Packages/NativeMusic/Sources/AppShell/ExpandedPlayer.swift")) ?? ""
    #expect(light.contains("if let tint, !reduceTransparency, contrast != .increased {"))
  }
}

@Suite struct KeyboardAndVoiceOverPathTests {
  /// Every drag affordance in the app, and the file that offers its non-drag alternative with the label that alternative must carry.
  struct Alternative { let drag: String; let file: String; let labels: [String]; let what: String }
  static let alternatives: [Alternative] = [
    .init(drag: "Packages/NativeMusic/Sources/DesignSystem/Components.swift", file: "Packages/NativeMusic/Sources/DesignSystem/Components.swift", labels: ["Move up", "Move down", "Move to end of page"], what: "queue reorder"),
    .init(drag: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistEditorView.swift", file: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistEditorView.swift", labels: ["Move Up", "Move Down"], what: "playlist reorder"),
    .init(drag: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistDragDrop.swift", file: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistEntries.swift", labels: ["Add to Playlist…"], what: "drag a song onto a playlist"),
    .init(drag: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistEntries.swift", file: "Packages/NativeMusic/Sources/Features/Playlists/PlaylistAddViews.swift", labels: ["Skip Existing"], what: "drop songs into a playlist"),
    .init(drag: "Packages/NativeMusic/Sources/Features/Uploads/UploadsView.swift", file: "Packages/NativeMusic/Sources/Features/Uploads/UploadsView.swift", labels: ["Choose Files…"], what: "drop audio files to upload"),
    .init(drag: "Packages/NativeMusic/Sources/AppShell/BrowserShell.swift", file: "Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift", labels: ["Open Link from Clipboard"], what: "drop a link on the window"),
  ]
  @Test func everyDragHasAKeyboardAndVoiceOverAlternative() throws {
    for item in Self.alternatives {
      let text = try Repo.text(item.file)
      for label in item.labels { #expect(text.contains("\"\(label)\""), "\(item.what): '\(label)' is missing from \(item.file)") }
    }
  }
  @Test func noDragIsOfferedWithoutBeingListed() {
    let listed = Set(Self.alternatives.map(\.drag))
    var unlisted: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources") + Repo.swiftFiles(under: "App/Sources") {
      let code = Repo.code(text)
      let drags = code.contains(".onMove") || code.contains(".draggable(") || code.contains("dropDestination(") || code.contains(".onDrag") || code.contains(".onDrop(")
      if drags && !listed.contains(path) { unlisted.append(path) }
    }
    #expect(unlisted.isEmpty, "drag affordances with no listed alternative (add one, then list it): \(unlisted)")
  }
  @Test func reorderAlternativesAreRealButtonsThatNameTheirTarget() throws {
    let editor = try Repo.text("Packages/NativeMusic/Sources/Features/Playlists/PlaylistEditorView.swift")
    #expect(editor.contains("playlistMoveUp-") && editor.contains("playlistMoveDown-"), "identified, so a keyboard or script drives them")
    #expect(editor.contains(".accessibilityActions {") && editor.contains("Button(\"Move Up\") { move(snapshot, index: index, by: -1) }") && editor.contains("Button(\"Move Down\") { move(snapshot, index: index, by: 1) }"), "playlist rows expose Move Up / Move Down as accessibility actions that call the same move")
    let routes = try Repo.text("Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift") + (try Repo.text("Packages/NativeMusic/Sources/AppShell/SearchShell.swift"))
    #expect(routes.contains("Button(\"Choose Output…\")") && routes.contains("id: \"output\""), "route selection has a menu item and a palette command")
    let queue = try Repo.text("Packages/NativeMusic/Sources/DesignSystem/Components.swift")
    #expect(queue.contains("QueuePageMoves.up") && queue.contains("QueuePageMoves.drag"), "the queue's buttons use the same move rules as the drag")
    // VoiceOver's actions rotor: the same three moves as accessibility actions, not only in a context menu.
    #expect(queue.contains(".accessibilityActions {"), "queue rows carry accessibility actions")
    for label in ["Move up", "Move down", "Move to end of page"] { #expect(queue.components(separatedBy: "Button(\"\(label)\")").count - 1 >= 2, "'\(label)' is both a context-menu item and an accessibility action") }
  }
  /// A text row never has a fixed height (A11Y02): longer translations and larger text must be able to grow it. Artwork, glyph and spacer frames are fixed
  /// by design and carry no text.
  @Test func noTextCarriesAFixedHeight() {
    var offenders: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources/Features") + Repo.swiftFiles(under: "Packages/NativeMusic/Sources/AppShell") + Repo.swiftFiles(under: "Packages/NativeMusic/Sources/DesignSystem") {
      for (index, line) in Repo.code(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        guard line.range(of: #"\.frame\([^)]*\bheight: [^,)]+"#, options: .regularExpression) != nil, !line.contains("maxHeight"), !line.contains("minHeight"), !line.contains("idealHeight") else { continue }
        if line.contains("Text(") || line.contains("Label(") || line.contains("Button(\"") { offenders.append("\(path):\(index + 1)") }
      }
    }
    #expect(offenders.isEmpty, "fixed-height text: \(offenders)")
    #expect("Text(x).frame(height: 20)".range(of: #"\.frame\([^)]*\bheight: [^,)]+"#, options: .regularExpression) != nil, "control: the pattern matches a fixed-height frame")
  }
  @Test func everySheetAndPopoverCanBeClosedFromTheKeyboard() throws {
    // A sheet with no Escape/Cancel/Done path is a focus trap. The view each `.sheet(` presents must bind `.cancelAction` or carry a Done/Close/Cancel button.
    let files = Repo.swiftFiles(under: "Packages/NativeMusic/Sources")
    let exits = [".cancelAction", "Button(\"Done\"", "Button(\"Close\"", "Button(\"Cancel\"", "dismiss()", "Done\")", "Close\")", "Cancel\")"]
    var traps: [String] = [], checked = 0
    let typeName = try NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9]+)\("#)
    for (path, text) in files {
      let code = Repo.code(text)
      var search = code.startIndex..<code.endIndex
      while let range = code.range(of: ".sheet(", range: search) {
        search = range.upperBound..<code.endIndex
        let tail = String(code[range.upperBound...].prefix(300))
        // The first capitalised initializer after the closure's opening brace is the presented view.
        guard let brace = tail.firstIndex(of: "{") else { continue }
        let body = String(tail[brace...])
        guard let match = typeName.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let r = Range(match.range(at: 1), in: body) else { continue }
        let type = String(body[r])
        guard let owner = files.first(where: { $0.text.contains("struct \(type)") || $0.text.contains("struct \(type)<") }) else { continue }
        checked += 1
        let ownerCode = Repo.code(owner.text)
        if !exits.contains(where: { ownerCode.contains($0) }) { traps.append("\(path) → \(type) (\(owner.path))") }
      }
    }
    #expect(checked >= 6, "the sweep resolved \(checked) presented views")
    #expect(traps.isEmpty, "presented views with no keyboard way out: \(traps)")
  }
  @Test func iconOnlyControlsCarryALabel() {
    // An image-only Button/Toggle/Menu must carry an accessibility label on the same statement (the traversal test checks the rendered tree; this checks the source).
    var bare: [String] = []
    for (path, text) in Repo.swiftFiles(under: "Packages/NativeMusic/Sources/Features") + Repo.swiftFiles(under: "Packages/NativeMusic/Sources/AppShell") + Repo.swiftFiles(under: "Packages/NativeMusic/Sources/DesignSystem") {
      let lines = Repo.code(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      for (index, line) in lines.enumerated() where line.contains("Button {") || line.contains("Button(action:") {
        let window = lines[index..<min(index + 12, lines.count)].joined(separator: " ")
        let imageOnly = window.contains("Image(systemName:") && !window.contains("Label(") && !window.contains("Text(")
        if imageOnly && !window.contains("accessibilityLabel") && !window.contains(".help(") && !window.contains("labelStyle(.iconOnly)") { bare.append("\(path):\(index + 1)") }
      }
    }
    #expect(bare.isEmpty, "image-only buttons without a label: \(bare)")
  }

  /// L2: the moves the queue's VoiceOver actions perform are the real ones (the same `QueuePageMoves` rules the drag and the buttons use).
  @Test func theQueueMovesDoWhatTheirNamesSay() {
    let rows = (0..<5).map { QueueRow(id: UUID(), title: "Track \($0)", segment: "", current: false) }
    let boundary = QueuePageBoundary()
    let up = QueuePageMoves.up(rows: rows, boundary: boundary, index: 2), down = QueuePageMoves.down(rows: rows, boundary: boundary, index: 2)
    #expect(up != nil && down != nil)
    #expect(up?.occurrences == [rows[2].id] && up?.before == rows[1].id, "up moves the row before its predecessor")
    #expect(down?.occurrences == [rows[2].id] && down?.before == rows[4].id, "down moves the row before the one after its successor (below its successor)")
    #expect(QueuePageMoves.up(rows: rows, boundary: boundary, index: 0) == nil && QueuePageMoves.down(rows: rows, boundary: boundary, index: 4) == nil, "no move past either end")
    let end = QueuePageMoves.drag(rows: rows, boundary: boundary, source: IndexSet(integer: 1), destination: rows.count)
    #expect(end?.occurrences == [rows[1].id] && end?.before == nil, "to the end of the page: before nothing")
  }
  /// L4: the badges are drawn with the audited colours, not their own.
  @Test func theBadgesAreDrawnWithTheAuditedColours() throws {
    let glass = Repo.code(try Repo.text("Packages/NativeMusic/Sources/DesignSystem/Glass.swift"))
    for audited in ["MusicPalette.liveBadgeAtEdge", "MusicPalette.liveBadgeBehind", "MusicPalette.badgeText", "MusicPalette.advertisementFill", "MusicPalette.advertisementText"] { #expect(glass.contains(audited), "\(audited) is used by the badge view") }
    for own in ["Color.red", "Color.gray", "Color.yellow", "Color.white", "Color.black"] { #expect(!glass.contains(own), "the badge view must not state its own colour: \(own)") }
  }
}
