// Test-only helper (never linked into the app). W22: what does the SHIPPED WebKit expose to a page for choosing an audio output or an AirPlay target?
// It loads one local document with a secure-context origin into a non-persistent WKWebView (no network, no media, no audio device is opened) and
// prints each capability it finds, one `fact name=value` line each. The tests assert the facts that `Docs/Routes.md` rests on, so a future WebKit
// that exposes a per-element output choice fails them and prompts a new decision instead of silently going unused.
// It never calls a picker (that would show system UI). The only media elements it creates are empty `new Audio()` objects with no source, so no
// audio device is opened; it measures whether `setSinkId` accepts the default and refuses an unknown identifier, nothing more.
import AppKit
import Foundation
import WebKit

@MainActor final class Loader: NSObject, WKNavigationDelegate {
    var finished: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.resume(); finished = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finished?.resume(); finished = nil }
}

_ = NSApplication.shared
Task { @MainActor in
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    print("fact defaultAllowsAirPlayForMediaPlayback=\(configuration.allowsAirPlayForMediaPlayback)")
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let loader = Loader(); webView.navigationDelegate = loader
    await withCheckedContinuation { continuation in
        loader.finished = continuation
        webView.loadHTMLString("<!doctype html><title>probe</title><body></body>", baseURL: URL(string: "https://probe.invalid/"))
    }
    let script = """
    const type = (value) => typeof value;
    const media = typeof HTMLMediaElement === 'undefined' ? null : HTMLMediaElement.prototype;
    const devices = navigator.mediaDevices;
    return {
      isSecureContext: String(window.isSecureContext),
      setSinkId: media ? type(media.setSinkId) : 'no-media-prototype',
      sinkIdProperty: media ? String('sinkId' in media) : 'no-media-prototype',
      audioContextSetSinkId: typeof AudioContext === 'undefined' ? 'no-audiocontext' : type(AudioContext.prototype.setSinkId),
      mediaDevices: type(devices),
      selectAudioOutput: devices ? type(devices.selectAudioOutput) : 'no-mediadevices',
      enumerateDevices: devices ? type(devices.enumerateDevices) : 'no-mediadevices',
      showPlaybackTargetPicker: media ? type(media.webkitShowPlaybackTargetPicker) : 'no-media-prototype',
      playbackTargetAvailabilityEvent: type(window.WebKitPlaybackTargetAvailabilityEvent),
      remotePlayback: type(window.RemotePlayback),
      remoteProperty: media ? String('remote' in media) : 'no-media-prototype'
    };
    """
    // What a page can learn about outputs WITHOUT capture permission (this app never asks for any): the device list, and whether setSinkId accepts the
    // default and rejects a made-up identifier. No element has media, so no audio device is opened and nothing is routed anywhere.
    let enumeration = """
    const out = {};
    try {
      const list = await navigator.mediaDevices.enumerateDevices();
      const outputs = list.filter(d => d.kind === 'audiooutput');
      out.enumerateTotal = String(list.length);
      out.enumerateAudioOutputs = String(outputs.length);
      out.enumerateOutputsWithLabel = String(outputs.filter(d => d.label !== '').length);
      out.enumerateOutputsWithId = String(outputs.filter(d => d.deviceId !== '').length);
    } catch (e) { out.enumerateError = e.name; }
    try { const a = new Audio(); await a.setSinkId(''); out.setSinkIdDefault = 'resolved'; } catch (e) { out.setSinkIdDefault = e.name; }
    try { const a = new Audio(); await a.setSinkId('not-a-device-identifier'); out.setSinkIdUnknown = 'resolved'; } catch (e) { out.setSinkIdUnknown = e.name; }
    return out;
    """
    do {
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        if let extra = try await webView.callAsyncJavaScript(enumeration, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] {
            for key in extra.keys.sorted() { print("fact \(key)=\(extra[key] ?? "nil")") }
        }
        if let facts = result as? [String: Any] {
            for key in facts.keys.sorted() { print("fact \(key)=\(facts[key] ?? "nil")") }
        } else { print("FAIL no facts returned"); exit(1) }
    } catch { print("FAIL script error: \(error)"); exit(1) }
    print("PASS")
    exit(0)
}
RunLoop.main.run()
