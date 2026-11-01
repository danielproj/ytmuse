import AppKit

/// A native container for a picture. It is a NON-INTERACTIVE surface (rework F2): it never answers a hit test, so no mouse event reaches
/// whatever it holds (the hidden player's web view, an AVPlayerLayer), never becomes first responder, and offers no context menu. Every
/// control around a picture is native and goes through the command layer.
public final class VideoPictureView: NSView {
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    public override var menu: NSMenu? { get { nil } set {} }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    public override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor }
    public required init?(coder: NSCoder) { nil }
}
