import Foundation

/// The page scripts installed into the hidden YouTube Music player, and the fixed
/// command bodies native code may run. Every script is a constant: values reach
/// a command only as `callAsyncJavaScript` arguments, never by interpolation.
///
/// Provenance: the ad detection in `adDetection` is adapted from Kaset's
/// `PlaybackAdDetectionScript.swift` (MIT, sozercan/kaset at 4c59ff2); see
/// THIRD_PARTY_NOTICES.md. The rest is original to YTMuse.
public enum WebMusicScripts {
    /// Document start, main frame only. Reads the native document/load generation
    /// and play intent from the navigation URL, blocks any playback start without
    /// native intent (no surprise audio), and takes the page's media session away
    /// from WebKit so the app's Now Playing and remote commands own media keys.
    public static let bootstrap = """
    (function () {
      "use strict";
      if (window.top !== window || window.location.hostname !== "music.youtube.com") { return; }
      if (window.__ytmuseState) { return; }
      var params = new URLSearchParams(window.location.search);
      function generation(name) {
        var raw = params.get(name);
        var value = raw === null || raw === "" ? NaN : Number(raw);
        return Number.isSafeInteger(value) && value > 0 ? value : -1;
      }
      var state = { doc: generation("ytmuse_doc"), load: generation("ytmuse_load"), intent: false, meta: null, observing: false };
      state.intent = params.get("ytmuse_play") === "1" && state.doc > 0 && state.load > 0;
      Object.defineProperty(window, "__ytmuseState", { value: state, writable: false, enumerable: false, configurable: false });
      // Read once, then removed: a page-initiated reload of this URL is a document
      // native code did not reserve (no generation, no play intent).
      try {
        if (params.has("ytmuse_doc") || params.has("ytmuse_load") || params.has("ytmuse_play")) {
          params.delete("ytmuse_doc"); params.delete("ytmuse_load"); params.delete("ytmuse_play");
          var query = params.toString();
          window.history.replaceState(window.history.state, "", window.location.pathname + (query ? "?" + query : "") + window.location.hash);
        }
      } catch (e) {}
      // Any media start the user did not ask for natively is paused immediately.
      document.addEventListener("play", function (event) {
        if (state.intent) { return; }
        var media = event.target;
        if (media && typeof media.pause === "function") { try { media.pause(); } catch (e) {} }
      }, true);
      try {
        var session = navigator.mediaSession;
        if (session) {
          var clear = session.setActionHandler.bind(session);
          // The page may not register media-key handlers; native remote commands own them.
          session.setActionHandler = function (action) { try { clear(action, null); } catch (e) {} };
          // Keep the page's metadata for the observer, but never hand it to WebKit's Now Playing.
          Object.defineProperty(session, "metadata", {
            configurable: false, enumerable: true,
            get: function () { return null; },
            set: function (value) { state.meta = value || null; }
          });
          try { Object.defineProperty(session, "playbackState", { configurable: false, get: function () { return "none"; }, set: function () {} }); } catch (e) {}
        }
      } catch (e) {}
    })();
    """

    /// Ad signals: player type 2 (including server-stitched segments) or the
    /// `ad-showing`/`ad-interrupting` player classes, plus Kaset's ad-pod
    /// continuity: once an ad creative's video ID is seen, ad state holds until
    /// the requested content's video ID returns (signals briefly clear between
    /// creatives). Detection only — nothing here blocks, skips, mutes, hides or
    /// speeds up an ad.
    static let adDetection = """
      function ytmuseAdAPIs() {
        var movie = document.getElementById("movie_player");
        var music = document.querySelector("ytmusic-player");
        var api = music && music.playerApi;
        return [movie, api].filter(function (candidate, index, all) { return candidate && all.indexOf(candidate) === index; });
      }
      function ytmusePlayingVideoID() {
        var apis = ytmuseAdAPIs().reverse();
        for (var i = 0; i < apis.length; i += 1) {
          try {
            var data = typeof apis[i].getVideoData === "function" ? apis[i].getVideoData() : null;
            var id = data && (data.video_id || data.videoId);
            if (typeof id === "string" && id) { return id; }
          } catch (e) {}
        }
        return "";
      }
      function ytmuseAdShowing() {
        var signal = ytmuseAdSignal();
        var content = "";
        try { content = new URL(window.location.href).searchParams.get("v") || ""; } catch (e) {}
        var playing = ytmusePlayingVideoID();
        if (signal && content && playing && playing !== content) { window.__ytmuseAdVideo = playing; }
        var adVideo = window.__ytmuseAdVideo || "";
        var awaitingContent = adVideo !== "" && adVideo !== content && playing !== content;
        if (!signal && !awaitingContent) { try { delete window.__ytmuseAdVideo; } catch (e) { window.__ytmuseAdVideo = ""; } }
        return signal || awaitingContent;
      }
      function ytmuseAdSignal() {
        var movie = document.getElementById("movie_player");
        if (movie && movie.classList && (movie.classList.contains("ad-showing") || movie.classList.contains("ad-interrupting"))) { return true; }
        var apis = ytmuseAdAPIs();
        for (var i = 0; i < apis.length; i += 1) {
          try { if (typeof apis[i].getPresentingPlayerType === "function" && apis[i].getPresentingPlayerType(true) === 2) { return true; } } catch (e) {}
        }
        return false;
      }
      function ytmusePlayerAPI() {
        var music = document.querySelector("ytmusic-player");
        return (music && music.playerApi) || document.getElementById("movie_player");
      }
    """

    /// W17: standard media-element and player signals for the picture, the live window and the presentation of the playing item.
    /// Read-only. `seekable` and `getVideoPlaybackQuality()` are WebKit's own media-element APIs; `isLive`, `musicVideoType` and the
    /// queue item's `counterpart` are undocumented YouTube Music signals, accepted only in the exact shape the service publishes
    /// (the item's own video id must match), so an unrecognised layout reports nothing rather than a guess.
    static let mediaDetection = """
      function ytmuseVideo() { return document.querySelector("video"); }
      function ytmuseIsLive() {
        var video = ytmuseVideo();
        if (video && video.duration === Infinity) { return true; }
        var api = ytmusePlayerAPI();
        try { var data = api && typeof api.getVideoData === "function" ? api.getVideoData() : null; if (data && data.isLive === true) { return true; } } catch (e) {}
        return false;
      }
      // The oldest point a live stream can still be sought to; positions reported to native code are relative to it.
      function ytmuseLiveBase() {
        var video = ytmuseVideo();
        try { if (video && video.seekable && video.seekable.length > 0) { return video.seekable.start(0); } } catch (e) {}
        return 0;
      }
      function ytmuseLiveEnd() {
        var video = ytmuseVideo();
        try { if (video && video.seekable && video.seekable.length > 0) { return video.seekable.end(video.seekable.length - 1); } } catch (e) {}
        return 0;
      }
      function ytmuseQueueEntry(current) {
        try {
          var items = document.querySelectorAll("ytmusic-player-queue-item");
          for (var i = 0; i < items.length && i < 200; i += 1) {
            var data = items[i].data;
            var wrapper = data && data.playlistPanelVideoWrapperRenderer;
            var primary = wrapper && wrapper.primaryRenderer && wrapper.primaryRenderer.playlistPanelVideoRenderer;
            if (primary && primary.videoId === current) { return { wrapper: wrapper, primary: primary }; }
          }
        } catch (e) {}
        return null;
      }
      function ytmuseVideoType(current) {
        var api = ytmusePlayerAPI();
        try {
          var response = api && typeof api.getPlayerResponse === "function" ? api.getPlayerResponse() : null;
          var type = response && response.videoDetails && response.videoDetails.musicVideoType;
          if (typeof type === "string" && type) { return type; }
        } catch (e) {}
        try {
          var entry = ytmuseQueueEntry(current);
          var config = entry && entry.primary.navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig;
          if (config && typeof config.musicVideoType === "string") { return config.musicVideoType; }
        } catch (e) {}
        return "";
      }
      function ytmuseKind(current) {
        if (ytmuseIsLive()) { return "live"; }
        var type = ytmuseVideoType(current);
        if (type === "MUSIC_VIDEO_TYPE_ATV") { return "audio"; }
        if (type === "MUSIC_VIDEO_TYPE_OMV" || type === "MUSIC_VIDEO_TYPE_UGC" || type === "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC") { return "video"; }
        return "";
      }
      function ytmuseCounterpart(current) {
        try {
          var entry = ytmuseQueueEntry(current);
          var other = entry && entry.wrapper.counterpart && entry.wrapper.counterpart[0] && entry.wrapper.counterpart[0].counterpartRenderer
            && entry.wrapper.counterpart[0].counterpartRenderer.playlistPanelVideoRenderer;
          var id = other && other.videoId;
          return typeof id === "string" && /^[A-Za-z0-9_-]{11}$/.test(id) && id !== current ? id : "";
        } catch (e) { return ""; }
      }
      function ytmuseQuality() {
        var api = ytmusePlayerAPI(), token = /^[a-z0-9]{2,12}$/;
        var result = { current: "", levels: [] };
        try {
          var current = api && typeof api.getPlaybackQuality === "function" ? api.getPlaybackQuality() : "";
          if (typeof current === "string" && token.test(current)) { result.current = current; }
          var levels = api && typeof api.getAvailableQualityLevels === "function" ? api.getAvailableQualityLevels() : [];
          if (Array.isArray(levels)) { result.levels = levels.filter(function (level) { return typeof level === "string" && token.test(level); }).slice(0, 12); }
        } catch (e) {}
        return result;
      }
      function ytmuseCaptions() {
        var api = ytmusePlayerAPI();
        try {
          var tracks = api && typeof api.getOption === "function" ? api.getOption("captions", "tracklist") : null;
          if (!tracks || !tracks.length) { return "unavailable"; }
          var track = api.getOption("captions", "track");
          return track && track.languageCode ? "on" : "off";
        } catch (e) { return "unavailable"; }
      }
      function ytmusePictureInPicture() {
        var video = ytmuseVideo();
        if (!video || typeof video.webkitSetPresentationMode !== "function") { return "unsupported"; }
        try {
          if (video.webkitPresentationMode === "picture-in-picture") { return "active"; }
          if (typeof video.webkitSupportsPresentationMode === "function" && video.webkitSupportsPresentationMode("picture-in-picture")) { return "available"; }
        } catch (e) {}
        return "unsupported";
      }
    """

    /// Document end, main frame only. Reports bounded state from the `<video>`
    /// element and the player to the native bridge; it never acts on the page.
    public static let observer = """
    (function () {
      "use strict";
      if (window.top !== window || window.location.hostname !== "music.youtube.com") { return; }
      var state = window.__ytmuseState;
      if (!state || state.observing || state.doc < 0) { return; }
      var handlers = window.webkit && window.webkit.messageHandlers;
      var bridge = handlers && handlers.\(WebMusicBridge.handlerName);
      if (!bridge) { return; }
      state.observing = true;
    \(adDetection)
    \(mediaDetection)
      function bounded(value, limit) {
        if (typeof value !== "string") { return ""; }
        value = value.trim();
        return value.length > limit ? value.slice(0, limit) : value;
      }
      function finite(value) { return typeof value === "number" && isFinite(value) && value >= 0 && value <= 86400 ? value : 0; }
      function videoID() {
        var api = ytmusePlayerAPI();
        try {
          var data = api && typeof api.getVideoData === "function" ? api.getVideoData() : null;
          var id = data && (data.video_id || data.videoId);
          if (typeof id === "string" && /^[A-Za-z0-9_-]{11}$/.test(id)) { return id; }
        } catch (e) {}
        return "";
      }
      function playlistID() {
        var api = ytmusePlayerAPI();
        try {
          var id = api && typeof api.getPlaylistId === "function" ? api.getPlaylistId() : "";
          if (typeof id === "string" && /^[A-Za-z0-9_-]{2,128}$/.test(id)) { return id; }
        } catch (e) {}
        return "";
      }
      function contentVideoID() {
        try {
          var id = new URL(window.location.href).searchParams.get("v") || "";
          return /^[A-Za-z0-9_-]{11}$/.test(id) ? id : "";
        } catch (e) { return ""; }
      }
      function signedIn() {
        try {
          var value = window.ytcfg && typeof window.ytcfg.get === "function" ? window.ytcfg.get("LOGGED_IN") : undefined;
          return typeof value === "boolean" ? value : undefined;
        } catch (e) { return undefined; }
      }
      // Best effort: the player bar's shuffle toggle as the page shows it. Undefined when the page does not say.
      function shuffleOn() {
        try {
          var button = document.querySelector("ytmusic-player-bar .shuffle");
          if (!button) { return undefined; }
          var pressed = button.getAttribute("aria-pressed");
          if (pressed === "true") { return true; }
          if (pressed === "false") { return false; }
          return undefined;
        } catch (e) { return undefined; }
      }
      function metadata() {
        var meta = state.meta, title = "", artist = "", artwork = "";
        try {
          if (meta) {
            title = meta.title || ""; artist = meta.artist || "";
            var images = meta.artwork || [];
            if (images.length > 0 && images[images.length - 1] && typeof images[images.length - 1].src === "string") { artwork = images[images.length - 1].src; }
          }
        } catch (e) {}
        if (!title) { var t = document.querySelector("ytmusic-player-bar .title"); title = t ? t.textContent : ""; }
        if (!artist) { var b = document.querySelector("ytmusic-player-bar .byline"); artist = b ? (b.textContent || "").split("\\u2022")[0] : ""; }
        if (!artwork) { var i = document.querySelector("ytmusic-player-bar img"); artwork = i && typeof i.src === "string" ? i.src : ""; }
        return { title: bounded(title, 300), artist: bounded(artist, 300), artwork: artwork.length <= 2048 && artwork.indexOf("https://") === 0 ? artwork : "" };
      }
      function post(message) {
        message.doc = state.doc; message.load = state.load;
        try { bridge.postMessage(message); } catch (e) {}
      }
      var lastPost = 0, lastSignature = "";
      function report(force) {
        var now = Date.now();
        if (!force && now - lastPost < 450) { return; }
        lastPost = now;
        var video = document.querySelector("video");
        var info = metadata();
        var message = {
          type: "state",
          playing: !!video && !video.paused && !video.ended,
          buffering: !!video && !video.paused && video.readyState < 3,
          position: video ? finite(ytmuseIsLive() ? video.currentTime - ytmuseLiveBase() : video.currentTime) : 0,
          duration: video ? finite(video.duration) : 0,
          videoId: videoID(), title: info.title, artist: info.artist, artwork: info.artwork,
          ad: ytmuseAdShowing(),
          playlistId: playlistID(),
          contentId: contentVideoID()
        };
        var logged = signedIn();
        if (typeof logged === "boolean") { message.signedIn = logged; }
        var shuffled = shuffleOn();
        if (typeof shuffled === "boolean") { message.shuffle = shuffled; }
        // P5-1: a periodic or throttled report that says nothing new is not posted, so a
        // paused or idle page wakes the app for nothing. Events (force) and a new native
        // load generation always post.
        var signature = JSON.stringify(message) + "|" + state.doc + "|" + state.load;
        if (!force && signature === lastSignature) { return; }
        lastSignature = signature;
        post(message);
        reportMedia();
      }
      // W17: the picture, the live window and the presentation of the playing item. Posted only when it changes (frames advance while a
      // picture decodes, so a decoding video posts about as often as its position does; an audio item posts once).
      var lastMedia = "";
      function reportMedia() {
        var video = document.querySelector("video");
        var id = videoID();
        var kind = ytmuseKind(id);
        var message = { type: "media", videoId: id, kind: kind, counterpart: id ? ytmuseCounterpart(id) : "", width: 0, height: 0, frames: 0,
                        pip: ytmusePictureInPicture(), isolated: !!window.__ytmusePresenting, captions: ytmuseCaptions() };
        var quality = ytmuseQuality();
        if (quality.current) { message.quality = quality.current; }
        if (quality.levels.length > 0) { message.qualities = quality.levels.join(","); }
        if (video) {
          // W18 (read only): the speed the element is ACTUALLY playing at, so the app reconciles instead of believing a one-time confirmation.
          var speed = video.playbackRate;
          if (typeof speed === "number" && isFinite(speed) && speed > 0 && speed <= 16) { message.rate = Math.round(speed * 1000) / 1000; }
          message.width = Math.max(0, Math.min(16384, Math.floor(video.videoWidth || 0)));
          message.height = Math.max(0, Math.min(16384, Math.floor(video.videoHeight || 0)));
          try {
            var quality = typeof video.getVideoPlaybackQuality === "function" ? video.getVideoPlaybackQuality() : null;
            message.frames = quality && isFinite(quality.totalVideoFrames) ? Math.max(0, Math.min(2147483647, Math.floor(quality.totalVideoFrames))) : 0;
          } catch (e) {}
        }
        if (kind === "live") {
          var base = ytmuseLiveBase();
          message.seekStart = 0;
          message.seekEnd = finite(Math.floor(ytmuseLiveEnd() - base));
        }
        if (message.counterpart === "") { delete message.counterpart; }
        var signature = JSON.stringify(message) + "|" + state.doc + "|" + state.load;
        if (signature === lastMedia) { return; }
        lastMedia = signature;
        post(message);
      }
      var bound = null;
      function bind() {
        var video = document.querySelector("video");
        if (!video || video === bound) { return; }
        bound = video;
        ["play", "playing", "pause", "waiting", "seeked", "durationchange", "loadedmetadata", "emptied", "resize", "ratechange", "webkitpresentationmodechanged"].forEach(function (name) {
          video.addEventListener(name, function () { if (video === bound) { report(true); } });
        });
        video.addEventListener("timeupdate", function () { if (video === bound) { report(false); } });
        video.addEventListener("ended", function () {
          if (video !== bound || ytmuseAdShowing()) { return; }
          post({ type: "ended", videoId: videoID() });
        });
        report(true);
      }
      var errorHooked = null;
      function hookErrors() {
        var api = ytmusePlayerAPI();
        if (!api || api === errorHooked || typeof api.addEventListener !== "function" || typeof api.getPresentingPlayerType !== "function") { return; }
        errorHooked = api;
        try {
          api.addEventListener("onError", function (event) {
            var code = typeof event === "number" ? event : (event && event.data);
            if (typeof code === "number" && isFinite(code) && code >= 0 && code <= 9999) { post({ type: "error", code: Math.floor(code) }); }
          });
          ["onAdStart", "onAdEnd", "onAdStateChange", "onStateChange"].forEach(function (name) {
            try { api.addEventListener(name, function () { report(true); }); } catch (e) {}
          });
        } catch (e) {}
      }
      var classObserved = null;
      function observeClasses() {
        var movie = document.getElementById("movie_player");
        if (!movie || movie === classObserved || typeof MutationObserver !== "function") { return; }
        classObserved = movie;
        new MutationObserver(function () { report(true); }).observe(movie, { attributes: true, attributeFilter: ["class"] });
      }
      function refresh() { bind(); hookErrors(); observeClasses(); }
      refresh();
      // PL1: say at once whether this document is the YouTube Music app. YouTube's
      // "not optimized for your browser" page (and any other non-app document) has
      // no ytmusic-app; the app may attach it late, so absence is final only later.
      var pageReported = false;
      function checkPage(final) {
        if (pageReported) { return; }
        var app = !!document.querySelector("ytmusic-app");
        var text = (document.body && document.body.innerText) || "";
        var unsupported = /not optimi[sz]ed for your browser|try google chrome|browser is no longer supported/i.test(text);
        if (app || unsupported || final) {
          pageReported = true;
          // P5-3: the app element is authoritative. A banner inside a working app
          // document is not "unsupported"; only a document without the app can be.
          post({ type: "page", app: app, unsupported: !app && unsupported });
        }
      }
      checkPage(false);
      setTimeout(function () { checkPage(false); }, 2000);
      setTimeout(function () { checkPage(true); }, 8000);
      // Hidden pages throttle timers; media events above carry the timely updates.
      setInterval(function () { refresh(); report(false); }, 1000);
    })();
    """

    // MARK: Fixed command bodies (arguments only; see WebMusicCommand)

    static let loadPlaylist = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    state.load = load; state.intent = true;
    var app = document.querySelector("ytmusic-app");
    if (!app || typeof app.resolveCommand !== "function") { return "fallback"; }
    try { app.resolveCommand({ watchEndpoint: { playlistId: playlistId } }); return "router"; } catch (e) { return "fallback"; }
    """
    /// Like `loadPlaylist`, with the endpoint exactly as the service published it: from a given video, and/or with its own
    /// parameters (the shuffle flag). Empty strings mean "not given".
    static let loadTarget = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    state.load = load; state.intent = true;
    var app = document.querySelector("ytmusic-app");
    if (!app || typeof app.resolveCommand !== "function") { return "fallback"; }
    var endpoint = { playlistId: playlistId };
    if (videoId !== "") { endpoint.videoId = videoId; }
    if (params !== "") { endpoint.params = params; }
    var command = (videoId === "" && params !== "") ? { watchPlaylistEndpoint: endpoint } : { watchEndpoint: endpoint };
    try { app.resolveCommand(command); return "router"; } catch (e) { return "fallback"; }
    """
    static let play = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    state.intent = true;
    \(adDetection)
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.playVideo === "function") { api.playVideo(); return "ok"; } } catch (e) {}
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    try { await video.play(); return "ok"; } catch (e) { return "rejected"; }
    """
    static let pause = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    state.intent = false;
    \(adDetection)
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.pauseVideo === "function") { api.pauseVideo(); } } catch (e) {}
    var video = document.querySelector("video");
    if (video && !video.paused) { try { video.pause(); } catch (e) {} }
    return "ok";
    """
    static let seek = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    \(mediaDetection)
    if (ytmuseAdShowing()) { return "ad"; }
    // A live stream is sought in its own relative window: 0 is the oldest point the player can reach.
    if (ytmuseIsLive()) {
      var live = ytmuseVideo();
      if (!live) { return "no-media"; }
      live.currentTime = ytmuseLiveBase() + seconds; return "ok";
    }
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.seekTo === "function") { api.seekTo(seconds, true); return "ok"; } } catch (e) {}
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    video.currentTime = seconds; return "ok";
    """
    /// Go live: the player's own jump to the live edge, or the end of the seekable window. Refused during an ad and for anything not live.
    static let goLive = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    \(mediaDetection)
    if (ytmuseAdShowing()) { return "ad"; }
    if (!ytmuseIsLive()) { return "rejected"; }
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.seekToLiveHead === "function") { api.seekToLiveHead(); return "ok"; } } catch (e) {}
    var video = ytmuseVideo();
    if (!video) { return "no-media"; }
    video.currentTime = ytmuseLiveEnd(); return "ok";
    """
    /// Reduces the page to the `<video>` picture for a native surface, or restores it exactly. Nothing is removed or restyled inline: the
    /// video's ancestors are marked and a stylesheet scales them to the viewport, while their siblings are only made `visibility: hidden`.
    /// ADVERTISING IS NEVER COVERED (rework F1): no ancestor gets a z-index or any stacking above the player's own layers. The player root
    /// and everything above it fill the viewport (`position: fixed`, no z-index); everything between the root and the video only fills its
    /// parent (`position: relative`, no z-index), so the page's ad layers (`ytp-ad…`, `video-ads`), which are positioned after the video
    /// container inside the player root, keep painting above the picture exactly as the page lays them out. The video is `object-fit: contain`
    /// (aspect ratio kept). Turning it off removes the marks and the stylesheet, which restores every original style.
    static let presentVideo = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    var existing = document.getElementById("ytmuse-video-presentation");
    if (!on) {
      if (window.__ytmusePresentationObserver) { try { window.__ytmusePresentationObserver.disconnect(); } catch (e) {} window.__ytmusePresentationObserver = null; }
      Array.prototype.forEach.call(document.querySelectorAll("[data-ytmuse-chain],[data-ytmuse-inner],[data-ytmuse-video],[data-ytmuse-hidden]"), function (node) {
        node.removeAttribute("data-ytmuse-chain"); node.removeAttribute("data-ytmuse-inner"); node.removeAttribute("data-ytmuse-video"); node.removeAttribute("data-ytmuse-hidden");
      });
      if (existing) { existing.remove(); }
      window.__ytmusePresenting = false;
      return "ok";
    }
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    if (existing) { return "ok"; }
    var keep = '[class*="ytp-ad"], .video-ads';
    var chain = [];
    for (var node = video.parentElement; node && node !== document.body && node !== document.documentElement; node = node.parentElement) { chain.push(node); }
    // The player root (YouTube's own player element) and what lies above it are 'outer'; what lies between it and the video is 'inner'.
    var rootIndex = -1;
    for (var i = 0; i < chain.length; i += 1) { if (chain[i].id === "movie_player" || (chain[i].classList && chain[i].classList.contains("html5-video-player"))) { rootIndex = i; break; } }
    if (rootIndex < 0) { rootIndex = chain.length - 1; }
    function hideSiblings() {
      chain.concat([video]).forEach(function (member) {
        var parent = member.parentElement;
        if (!parent) { return; }
        Array.prototype.forEach.call(parent.children, function (sibling) {
          if (sibling === member || chain.indexOf(sibling) >= 0 || sibling === video || sibling.id === "ytmuse-video-presentation") { return; }
          if (sibling.matches(keep) || sibling.querySelector(keep)) { return; }
          sibling.setAttribute("data-ytmuse-hidden", "");
        });
      });
      var body = document.body;
      Array.prototype.forEach.call(body.children, function (sibling) {
        if (chain.indexOf(sibling) >= 0 || sibling.id === "ytmuse-video-presentation") { return; }
        if (sibling.matches(keep) || sibling.querySelector(keep)) { return; }
        sibling.setAttribute("data-ytmuse-hidden", "");
      });
    }
    var style = document.createElement("style");
    style.id = "ytmuse-video-presentation";
    style.textContent =
      "html, body { background: #000 !important; overflow: hidden !important; margin: 0 !important; }" +
      "[data-ytmuse-hidden] { visibility: hidden !important; }" +
      "[data-ytmuse-chain] { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; margin: 0 !important; padding: 0 !important;" +
      " transform: none !important; border: 0 !important; background: #000 !important; overflow: hidden !important; visibility: visible !important; opacity: 1 !important; }" +
      "[data-ytmuse-inner] { position: relative !important; width: 100% !important; height: 100% !important; margin: 0 !important; padding: 0 !important; background: #000 !important; }" +
      "[data-ytmuse-video] { position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important; object-fit: contain !important; margin: 0 !important;" +
      " transform: none !important; visibility: visible !important; opacity: 1 !important; background: #000 !important; }";
    document.head.appendChild(style);
    chain.forEach(function (member, index) { member.setAttribute(index >= rootIndex ? "data-ytmuse-chain" : "data-ytmuse-inner", ""); });
    video.setAttribute("data-ytmuse-video", "");
    hideSiblings();
    if (typeof MutationObserver === "function") {
      var observer = new MutationObserver(function () { hideSiblings(); });
      chain.concat([document.body]).forEach(function (member) { observer.observe(member, { childList: true }); });
      window.__ytmusePresentationObserver = observer;
    }
    window.__ytmusePresenting = true;
    return "ok";
    """
    /// Picture in Picture through WebKit's own presentation mode of the `<video>` element, only where it says it supports it.
    static let pictureInPicture = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    if (typeof video.webkitSetPresentationMode !== "function") { return "unsupported"; }
    try {
      if (on) {
        if (typeof video.webkitSupportsPresentationMode === "function" && !video.webkitSupportsPresentationMode("picture-in-picture")) { return "unsupported"; }
        video.webkitSetPresentationMode("picture-in-picture"); return "ok";
      }
      video.webkitSetPresentationMode("inline"); return "ok";
    } catch (e) { return "rejected"; }
    """
    /// The page player's own quality setting, limited to a level it offered. Not a stream choice: the player still decides what it fetches.
    static let quality = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    \(mediaDetection)
    var api = ytmusePlayerAPI();
    if (!api || typeof api.getAvailableQualityLevels !== "function") { return "unsupported"; }
    try {
      var levels = api.getAvailableQualityLevels();
      if (!Array.isArray(levels) || levels.indexOf(level) < 0) { return "rejected"; }
      if (typeof api.setPlaybackQualityRange === "function") { api.setPlaybackQualityRange(level, level); }
      if (typeof api.setPlaybackQuality === "function") { api.setPlaybackQuality(level); }
      return "ok";
    } catch (e) { return "rejected"; }
    """
    /// The page player's own captions: the first track it lists, or none. Unsupported when it lists no track.
    static let captions = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    var api = ytmusePlayerAPI();
    if (!api || typeof api.getOption !== "function" || typeof api.setOption !== "function") { return "unsupported"; }
    try {
      if (typeof api.loadModule === "function") { api.loadModule("captions"); }
      var tracks = api.getOption("captions", "tracklist");
      if (!tracks || !tracks.length) { return "unsupported"; }
      if (on) { api.setOption("captions", "track", tracks[0]); }
      else { api.setOption("captions", "track", {}); }
      return "ok";
    } catch (e) { return "rejected"; }
    """
    /// A one-off measurement of the decoder (a diagnostic read, never part of the periodic report).
    static let measureVideo = """
    var video = document.querySelector("video");
    if (!video) { return { present: false }; }
    var quality = null;
    try { quality = typeof video.getVideoPlaybackQuality === "function" ? video.getVideoPlaybackQuality() : null; } catch (e) {}
    var rect = video.getBoundingClientRect();
    // Rework F1: nothing may paint above an advertising layer. For every ad layer with a box, a hit test at its centre must land on it (or inside it).
    var adNodes = Array.prototype.filter.call(document.querySelectorAll('[class*="ytp-ad"], .video-ads'), function (node) { var r = node.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
    function onTop(node) {
      var r = node.getBoundingClientRect();
      var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return !!hit && (hit === node || node.contains(hit)) && getComputedStyle(node).visibility === "visible";
    }
    var live = (video.seekable && video.seekable.length > 0) ? [video.seekable.start(0), video.seekable.end(video.seekable.length - 1)] : [];
    return { present: true, width: video.videoWidth || 0, height: video.videoHeight || 0, frames: quality ? quality.totalVideoFrames : 0,
             dropped: quality ? quality.droppedVideoFrames : 0, paused: video.paused, time: video.currentTime, muted: video.muted, volume: video.volume,
             rect: [rect.left, rect.top, rect.width, rect.height], viewport: [window.innerWidth, window.innerHeight], seekable: live,
             presenting: !!window.__ytmusePresenting, visibility: document.visibilityState, readyState: video.readyState, fit: getComputedStyle(video).objectFit,
             hidden: document.querySelectorAll("[data-ytmuse-hidden]").length, styleInstalled: !!document.getElementById("ytmuse-video-presentation"),
             adOverlayCount: adNodes.length, adOverlaysOnTop: adNodes.length === 0 ? true : adNodes.every(function (node) { return onTop(node); }),
             origin: performance.timeOrigin, digest: (function () { var text = document.documentElement.outerHTML, hash = 5381; for (var i = 0; i < text.length; i += 1) { hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0; } return hash; })() };
    """
    static let skip = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    if (ytmuseAdShowing()) { return "ad"; }
    var api = ytmusePlayerAPI();
    var method = forward ? "nextVideo" : "previousVideo";
    try { if (api && typeof api[method] === "function") { state.intent = true; api[method](); return "ok"; } } catch (e) {}
    var button = document.querySelector(forward ? "ytmusic-player-bar .next-button" : "ytmusic-player-bar .previous-button");
    if (!button || typeof button.click !== "function") { return "unavailable"; }
    state.intent = true; button.click(); return "ok";
    """
    /// W18: listening speed. The `<video>` keeps its pitch (`preservesPitch`); the page's own player API is asked first, and the element's
    /// rate is read back so a page that ignored the request answers "rejected" instead of "ok". Refused during an ad (ads play at their speed).
    static let rate = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    if (ytmuseAdShowing()) { return "ad"; }
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.setPlaybackRate === "function") { api.setPlaybackRate(rate); } } catch (e) {}
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    try { video.preservesPitch = true; video.webkitPreservesPitch = true; } catch (e) {}
    if (Math.abs(video.playbackRate - rate) > 0.001) { try { video.playbackRate = rate; } catch (e) {} }
    return Math.abs(video.playbackRate - rate) <= 0.001 ? "ok" : "rejected";
    """
    /// W18: returns the element to normal speed. It exists for one case: an advertisement must always play at 1x, and the app saw the element
    /// report another speed during one. It only ever sets 1 (never a faster or slower speed), so it cannot speed an ad up beyond normal.
    /// It re-checks inside the page that an advertisement is showing, like `rate`, `seek` and `skip`: a restore that lands after the ad ended does nothing.
    static let normalSpeed = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    if (!ytmuseAdShowing()) { return "not-ad"; }
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.setPlaybackRate === "function") { api.setPlaybackRate(1); } } catch (e) {}
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    if (Math.abs(video.playbackRate - 1) > 0.001) { try { video.playbackRate = 1; } catch (e) {} }
    return Math.abs(video.playbackRate - 1) <= 0.001 ? "ok" : "rejected";
    """
    /// P17-WEB: one step of the sleep timer's fade, on the `<video>` element's own volume only (never the player's saved volume, so nothing is
    /// persisted). The level the element had when the fade began is kept in the page (`__ytmuseFade`) and a factor of 1 puts it back. The
    /// advertising rule is enforced HERE, in the page, at the moment of the step: while an advertisement shows, the step refuses (`ad`), puts the
    /// level back if a fade had already lowered it, and changes nothing else. Raising the level back is not muting; lowering it during an ad would be.
    static let fadeVolume = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    var video = document.querySelector("video");
    if (!video) { return "no-media"; }
    var fade = window.__ytmuseFade;
    function putBack() {
      if (fade && fade.video === video) { try { video.volume = fade.base; } catch (e) {} }
      try { delete window.__ytmuseFade; } catch (e) { window.__ytmuseFade = null; }
    }
    if (factor >= 1) { putBack(); return "ok"; }
    if (ytmuseAdShowing()) { putBack(); return "ad"; }
    if (!fade || fade.video !== video) { fade = { base: video.volume, video: video }; window.__ytmuseFade = fade; }
    try { video.volume = Math.max(0, Math.min(1, fade.base * factor)); } catch (e) { return "rejected"; }
    return "ok";
    """
    static let volume = """
    var state = window.__ytmuseState;
    if (!state || state.doc < 0) { return "unavailable"; }
    \(adDetection)
    // A person's own volume takes over from a running sleep-timer fade: the fade's remembered level is dropped, and its next step starts from this one.
    try { delete window.__ytmuseFade; } catch (e) { window.__ytmuseFade = null; }
    var api = ytmusePlayerAPI();
    try { if (api && typeof api.setVolume === "function") { api.setVolume(Math.round(level * 100)); } } catch (e) {}
    var video = document.querySelector("video");
    if (video) { video.volume = level; }
    return "ok";
    """
}
