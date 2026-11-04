import CryptoKit
import Foundation
import JavaScriptCore
import Testing
import Domain
@testable import Playback

/// Renderer fields come from the frozen anonymous radio capture. DOM variants
/// are explicit test doubles for the primary-source compatibility observations
/// recorded in LIVE-CORE/readback.md; these tests do not claim a live page check.
@Suite @MainActor struct WebMusicReadbackCompatibilityTests {
    private func capture() throws -> (items: [[String: Any]], playlist: String, video: String) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/R1-real/next-radio.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/R1-real/manifest.json"))) as? [String: Any])
        #expect(manifest["mode"] as? String == "real-public-anonymous-capture")
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == manifest["sha256"] as? String)
        let json = try JSONSerialization.jsonObject(with: data)
        func panel(_ value: Any) -> [String: Any]? {
            if let object = value as? [String: Any] {
                if let found = object["playlistPanelRenderer"] as? [String: Any] { return found }
                for child in object.values { if let found = panel(child) { return found } }
            } else if let array = value as? [Any] {
                for child in array { if let found = panel(child) { return found } }
            }
            return nil
        }
        let queue = try #require(panel(json))
        let contents = try #require(queue["contents"] as? [[String: Any]])
        let items = try contents.map { try #require($0["playlistPanelVideoRenderer"] as? [String: Any]) }
        #expect(items.count == 50)
        let selected = items.filter { $0["selected"] as? Bool == true }
        #expect(selected.count == 1)
        let first = try #require(selected.first)
        return (items, try #require(queue["playlistId"] as? String), try #require(first["videoId"] as? String))
    }

    @Test func redesignedBareRenderersPreserveTheCapturedQueueAndObserveItsPlaylist() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        #expect(try page.value("document.querySelectorAll('ytmusic-player-queue-item').length").toInt32() == 0,
                "the old selector cannot read this layout")
        let ids = try page.value("ytmuseQueueEntries().map(function(e) { return e.renderer.videoId; })").toArray() as? [String]
        #expect(ids == real.items.compactMap { $0["videoId"] as? String })
        #expect(try page.identity() == real.playlist)
        try page.installObserver()
        let state = try #require(page.posts("state").last)
        #expect(state["playlistId"] as? String == real.playlist)
        let queue = try #require(page.posts("queue").last)
        #expect(queue["videoId"] as? String == real.video)
        let frame = WebMusicFrame(isMainFrame: true, scheme: "https", host: "music.youtube.com", port: 0)
        guard case .queue(let observed) = try WebMusicBridge.validate(queue, frame: frame, document: 1, load: 1).get().event else {
            Issue.record("not an accepted queue report"); return
        }
        #expect(observed.upcoming.count > 1)
        #expect(observed.upcoming.first?.videoID == real.items[1]["videoId"] as? String)
    }

    @Test func legacyWrapperAndPrivateDataVariantsReadTheSamePublishedRenderer() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        for assignment in [
            "n.tag = 'ytmusic-player-queue-item'; n.data = {playlistPanelVideoRenderer: n.data};",
            "n.data = {playlistPanelVideoWrapperRenderer: {primaryRenderer: {playlistPanelVideoRenderer: n.data}}};",
            "n.__data = n.data; delete n.data;"
        ] {
            let variant = try ReadbackPage(items: real.items, playing: real.video)
            try variant.value("__nodes.forEach(function(n) { \(assignment) });")
            #expect(try variant.identity() == real.playlist)
            #expect(try variant.value("ytmuseQueueEntries().length").toInt32() == Int32(real.items.count))
        }
        #expect(try page.identity() == real.playlist)
    }

    @Test func allPublishedCurrentMarkersRequireTheSamePlayingVideo() throws {
        let real = try capture()
        for marker in [
            "__nodes[0].attributes = ['selected'];",
            "__nodes[0].attributes = ['is-playlist-panel-video-renderer-selected'];",
            "__nodes[0].current = 'true';", "__nodes[0].current = 'page';",
            "__nodes[0].selectedClass = true;"
        ] {
            let page = try ReadbackPage(items: real.items, playing: real.video)
            try page.value("__nodes.forEach(function(n) { delete n.data.selected; }); \(marker)")
            #expect(try page.identity() == real.playlist)
            try page.value("__playing = __nodes[1].data.videoId;")
            #expect(try page.identity() == "", "an old marker cannot identify a new playing item")
        }
    }

    @Test func missingStaleConflictingOrAmbiguousEvidenceNeverBecomesAnIdentity() throws {
        let real = try capture()
        for change in [
            "__playing = __nodes[1].data.videoId;",
            "delete __nodes[0].data.selected;",
            "__nodes[1].data.selected = true;",
            "__nodes[0].data.navigationEndpoint.watchEndpoint.videoId = __nodes[1].data.videoId;",
            "__primary.getPlaylistId = function() { return 'PLconflicting'; };",
            "delete __nodes[0].data.selected; __movie.getVideoData = function() { return {video_id: __nodes[1].data.videoId}; }; __movie.getPlaylistId = function() { return 'PLstale'; };",
            "delete __nodes[0].data.selected; window.location.href += '&list=PLurl'; window.__ytmuseRequestedPlaylist = 'PLnative';"
        ] {
            let page = try ReadbackPage(items: real.items, playing: real.video)
            try page.value(change)
            #expect(try page.identity() == "", "refused: \(change)")
        }
    }

    @Test func matchingSecondaryPlayerCanSupplyIdentityButDisagreementCannot() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.value("__nodes = []; __movie.getVideoData = function() { return {video_id: __playing}; }; __movie.getPlaylistId = function() { return 'PLobserved'; };")
        #expect(try page.identity() == "PLobserved", "the primary API has no playlist getter")
        try page.value("__primary.getPlaylistId = function() { return 'PLother'; };")
        #expect(try page.identity() == "")
        try page.value("__primary.getPlaylistId = function() { return 'PLobserved'; };")
        #expect(try page.identity() == "PLobserved")
    }

    @Test func observerCanUseMoviePlayerWhenTheMusicPlayerLacksVideoReadback() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.value("__primary = {}; __movie.getVideoData = function() { return {video_id: __playing}; };")
        try page.installObserver()
        let state = try #require(page.posts("state").last)
        #expect(state["videoId"] as? String == real.video)
        #expect(state["playlistId"] as? String == real.playlist)
        #expect(try page.posts("queue").last?["videoId"] as? String == real.video)
    }

    @Test func nestedRowsDoNotDuplicateOccurrencesAndResponsiveRowsStayInsideTheQueue() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.value("""
        var outer = __nodes[0], nested = __makeNode(outer.data);
        nested.tag = 'ytmusic-responsive-list-item-renderer'; nested.outer = outer;
        __nodes.splice(1, 0, nested);
        var outside = __makeNode(outer.data); outside.tag = 'ytmusic-responsive-list-item-renderer'; outside.inQueue = false;
        __nodes.push(outside);
        """)
        #expect(try page.value("ytmuseQueueEntries().length").toInt32() == Int32(real.items.count))
        try page.value("__nodes[2].tag = 'ytmusic-responsive-list-item-renderer';")
        #expect(try page.value("ytmuseQueueEntries().length").toInt32() == Int32(real.items.count))
        try page.value("var again = __makeNode(__nodes[0].data); __nodes.push(again);")
        #expect(try page.value("ytmuseQueueEntries().length").toInt32() == Int32(real.items.count + 1),
                "distinct occurrences of the same song are preserved")
        #expect(try page.identity() == "", "two selected occurrences are ambiguous")
    }

    @Test func radioCommandUsesTheObserversIdentityAndKeepsItsAdmissionGuards() throws {
        let real = try capture()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "opaque%3D", playerParams: "published"))
        let call = try WebMusicCommand.updateRadioQueue(command, document: 1, load: 1, videoID: real.video, currentPlaylistID: real.playlist).invocation()
        for change in ["", "__ad = true;", "window.__ytmuseState.load = 2;", "__playing = __nodes[1].data.videoId;", "__primary.getPlaylistId = function() { return 'PLconflicting'; };"] {
            let page = try ReadbackPage(items: real.items, playing: real.video)
            try page.value(change)
            let before = try page.value("JSON.stringify(window.__ytmuseState)").toString()
            let result = try page.run(call.body, arguments: call.arguments)
            if change.isEmpty {
                #expect(result == "router")
                let routed = try #require(page.value("__routed.queueUpdateCommand.fetchContentsCommand.watchEndpoint").toDictionary() as? [String: String])
                #expect(routed == ["playlistId": "RDpublished", "params": "opaque%3D", "playerParams": "published"])
            } else {
                #expect(result == "ad" || result == "rejected")
                #expect(try page.value("__routed === null").toBool())
            }
            #expect(try page.value("JSON.stringify(window.__ytmuseState)").toString() == before)
        }
    }

    @Test func eventNavigationPreservesThePublishedRadioAndEstablishesIntentBeforeDispatch() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.enableEventRoutes()
        let call = try WebMusicCommand.loadTarget(real.playlist, videoID: real.video, params: "opaque%3D", load: 2).invocation()
        #expect(try page.run(call.body, arguments: call.arguments) == "router")
        let event = try #require(page.value("__events[0]").toDictionary() as? [String: Any])
        #expect(event["type"] as? String == "yt-navigate")
        #expect(event["bubbles"] as? Bool == true && event["composed"] as? Bool == true)
        #expect(try page.value("__intentAtDispatch").toBool())
        #expect(try page.value("__loadAtDispatch").toInt32() == 2)
        let endpoint = try #require(page.value("__events[0].detail.endpoint.watchEndpoint").toDictionary() as? [String: String])
        #expect(endpoint == ["playlistId": real.playlist, "videoId": real.video, "params": "opaque%3D"])
        #expect(try page.value("__events.length").toInt32() == 1)
    }

    @Test func anUnupgradedOrRefusingRouteCannotStampOutgoingReportsAsANewLoad() throws {
        let real = try capture()
        let call = try WebMusicCommand.loadTarget(real.playlist, videoID: real.video, params: "opaque", load: 2).invocation()
        for change in [
            "customElements.get = function() { return undefined; };",
            "__app.dispatchEvent = function() { throw new Error('not ready'); };",
            "__app.resolveCommand = function() { return false; };"
        ] {
            let page = try ReadbackPage(items: real.items, playing: real.video)
            try page.enableEventRoutes()
            try page.value(change)
            let before = try page.value("JSON.stringify(window.__ytmuseState)").toString()
            #expect(try page.run(call.body, arguments: call.arguments) == "fallback")
            #expect(try page.value("JSON.stringify(window.__ytmuseState)").toString() == before)
            #expect(try page.value("__events.length").toInt32() == 0)
        }
    }

    @Test func queueFilterUsesItsOwnActionRouteWithoutStartingPlayback() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.enableEventRoutes()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "opaque%3D", playerParams: "published"))
        let call = try WebMusicCommand.updateRadioQueue(command, document: 1, load: 1, videoID: real.video, currentPlaylistID: real.playlist).invocation()
        let before = try page.value("JSON.stringify(window.__ytmuseState)").toString()
        #expect(try page.run(call.body, arguments: call.arguments) == "router")
        #expect(try page.value("__events[0].type").toString() == "yt-action")
        #expect(try page.value("__events[0].detail.actionName").toString() == "yt-queue-update-command")
        #expect(try page.value("__events[0].detail.optionalAction === false && __events[0].detail.returnValue.length === 0").toBool())
        let endpoint = try #require(page.value("__events[0].detail.args[0].queueUpdateCommand.fetchContentsCommand.watchEndpoint").toDictionary() as? [String: String])
        #expect(endpoint == ["playlistId": "RDpublished", "params": "opaque%3D", "playerParams": "published"])
        #expect(try page.value("JSON.stringify(window.__ytmuseState)").toString() == before)
        #expect(try page.value("__events.length").toInt32() == 1)
    }

    @Test func eventQueueRouteCannotBypassAdAndScopeChecks() throws {
        let real = try capture()
        let command = try #require(MusicQueueFilterCommand(playlistID: "RDpublished", params: "opaque"))
        let call = try WebMusicCommand.updateRadioQueue(command, document: 1, load: 1, videoID: real.video, currentPlaylistID: real.playlist).invocation()
        for change in ["__ad = true;", "window.__ytmuseState.doc = 2;", "window.__ytmuseState.load = 2;", "__playing = __nodes[1].data.videoId;"] {
            let page = try ReadbackPage(items: real.items, playing: real.video)
            try page.enableEventRoutes(); try page.value(change)
            let result = try page.run(call.body, arguments: call.arguments)
            #expect(result == "ad" || result == "rejected")
            #expect(try page.value("__events.length").toInt32() == 0)
        }
    }

    @Test func choosingAnUpcomingItemUsesTheWholePublishedEndpointOnTheNavigationRoute() throws {
        let real = try capture()
        let page = try ReadbackPage(items: real.items, playing: real.video)
        try page.enableEventRoutes()
        let id = try #require(real.items[1]["videoId"] as? String)
        let call = try WebMusicCommand.playQueueItem(id).invocation()
        #expect(try page.run(call.body, arguments: call.arguments) == "ok")
        #expect(try page.value("__events[0].type").toString() == "yt-navigate")
        #expect(try page.value("JSON.stringify(__events[0].detail.endpoint) === JSON.stringify(__nodes[1].data.navigationEndpoint)").toBool())
        #expect(try page.value("__events.length").toInt32() == 1)
    }
}

@MainActor private final class ReadbackPage {
    let context = JSContext()!
    init(items: [[String: Any]], playing: String) throws {
        let data = String(decoding: try JSONSerialization.data(withJSONObject: items), as: UTF8.self)
        let id = String(decoding: try JSONSerialization.data(withJSONObject: playing, options: .fragmentsAllowed), as: UTF8.self)
        try value("""
        var __playing = \(id), __ad = false, __routed = null, __posted = [];
        function __makeNode(data) {
          return { data: data, tag: 'ytmusic-player-queue-item-renderer', inQueue: true, attributes: [], current: null,
            hasAttribute: function(name) { return this.attributes.indexOf(name) >= 0; },
            getAttribute: function(name) { return name === 'aria-current' ? this.current : null; },
            classList: { contains: function() { return false; } },
            closest: function() { return this.outer || (this.tag === 'ytmusic-responsive-list-item-renderer' ? null : this); }
          };
        }
        var __nodes = \(data).map(__makeNode);
        __nodes.forEach(function(n) { n.classList.contains = function(name) { return name === 'selected' && n.selectedClass === true; }; });
        var __primary = { getVideoData: function() { return {video_id: __playing}; } };
        var __movie = { classList: { contains: function(name) { return __ad && name === 'ad-showing'; } } };
        var __video = { paused: true, ended: false, readyState: 4, currentTime: 10, duration: 200, addEventListener: function() {} };
        var __app = { resolveCommand: function(command) { __routed = command; } };
        var document = {
          querySelectorAll: function(selector) {
            var selectors = selector.split(',').map(function(s) { return s.trim(); });
            return __nodes.filter(function(n) { return selectors.some(function(s) {
              return s === 'ytmusic-player-queue ytmusic-responsive-list-item-renderer'
                ? n.tag === 'ytmusic-responsive-list-item-renderer' && n.inQueue : n.tag === s;
            }); });
          },
          querySelector: function(selector) {
            if (selector === 'ytmusic-player') { return {playerApi: __primary}; }
            if (selector === 'video') { return __video; }
            if (selector === 'ytmusic-app') { return __app; }
            return null;
          },
          getElementById: function(id) { return id === 'movie_player' ? __movie : null; },
          addEventListener: function() {}, body: {innerText: ''}
        };
        var setInterval = function() {}, setTimeout = function() {};
        var window = { location: {hostname: 'music.youtube.com', href: 'https://music.youtube.com/watch?v=' + __playing},
          __ytmuseState: {doc: 1, load: 1, intent: false, observing: false, meta: null},
          webkit: {messageHandlers: {\(WebMusicBridge.handlerName): {postMessage: function(m) { __posted.push(m); }}}}
        };
        window.top = window;
        \(WebMusicScripts.adDetection)
        \(WebMusicScripts.queueDetection)
        """)
    }
    @discardableResult func value(_ script: String) throws -> JSValue {
        context.exception = nil
        let result = context.evaluateScript(script)
        #expect(context.exception == nil, "JavaScript error: \(context.exception?.toString() ?? "")")
        return try #require(result)
    }
    func identity() throws -> String { try value("ytmuseObservedPlaylistID(__playing)").toString() ?? "" }
    func installObserver() throws { try value(WebMusicScripts.observer) }
    func enableEventRoutes() throws {
        try value("""
        var __events = [], __intentAtDispatch = null, __loadAtDispatch = null;
        var customElements = {get: function(name) { return name === 'ytmusic-app' ? function() {} : undefined; }};
        var CustomEvent = function(type, options) { this.type = type; Object.assign(this, options); };
        delete __app.resolveCommand;
        __app.dispatchEvent = function(event) {
          __intentAtDispatch = window.__ytmuseState.intent; __loadAtDispatch = window.__ytmuseState.load;
          __events.push(event); return true;
        };
        """)
    }
    func posts(_ type: String) throws -> [[String: Any]] {
        (try value("__posted").toArray() as? [[String: Any]] ?? []).filter { $0["type"] as? String == type }
    }
    func run(_ body: String, arguments: [String: Any]) throws -> String {
        let names = arguments.keys.sorted()
        let encoded = try names.map { key in
            String(decoding: try JSONSerialization.data(withJSONObject: arguments[key]!, options: .fragmentsAllowed), as: UTF8.self)
        }
        try value("var __result = 'pending'; (async function(\(names.joined(separator: ","))) { \(body) })(\(encoded.joined(separator: ","))).then(function(result) { __result = result; });")
        return try value("__result").toString() ?? ""
    }
}
