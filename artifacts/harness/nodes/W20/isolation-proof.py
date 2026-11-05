#!/usr/bin/env python3
"""W20 copy of the W19 isolation proof (every W09-W19 assertion unchanged) plus the Samples / tuner / Recap / badges / social checks.
Static + built-binary proof that every automated YTMuse UI launch is isolated.
Writes isolation-proof.json next to this file; exits 1 if any assertion fails. Launches nothing."""
import json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
ui = (ROOT / "Tests/NativeMusicUITests/NativeMusicUITests.swift").read_text()
comp = (ROOT / "Packages/NativeMusic/Sources/AppShell/LocalAccountComposition.swift").read_text()
iso = (ROOT / "Packages/NativeMusic/Sources/AppShell/IsolatedQAStorage.swift").read_text()
panel = (ROOT / "Packages/NativeMusic/Sources/AppShell/PlaybackPanel.swift").read_text()
checks = []
def check(name, ok, detail=""):
    checks.append({"name": name, "pass": bool(ok), "detail": detail})

key = re.search(r'environmentKey = "([A-Z_]+)"', iso).group(1)
check("isolation key", key == "YTMUSE_UI_TEST_ISOLATED", key)
check("helper sets key", f'app.launchEnvironment["{key}"] = "1"' in ui)
launches = re.findall(r'let app = (.*XCUIApplication\(.*)', ui)
ytmuse = [l for l in launches if "url: url" not in l]
check("every YTMuse XCUIApplication launch is wrapped by isolated(...)", ytmuse and all(l.startswith("isolated(") for l in ytmuse), launches)
host = re.findall(r'XCUIApplication\(url: url\)', ui)
check("only the separate account test host is unwrapped", len(host) == 1 and "NativeAccountTestHost.app" in ui)
check("no UI test clicks Google/YouTube sign-in", not re.search(r'musicSignIn"\]\.click|googleSignIn"\]\.click', ui))
check("no UI test presses a library Play action", "playPlaylist-" not in ui)
check("IsolatedQAStorage is Debug-only", iso.lstrip().startswith("#if DEBUG") and iso.rstrip().endswith("#endif"))
check("isolated root is a fresh temporary directory", 'temporaryDirectory.appendingPathComponent("ytmuse-ui-test-isolated-" + UUID().uuidString' in iso)
check("both vaults are isolated keychain files", iso.count("isolatedKeychainURL: root.appendingPathComponent(") == 2)
dbg = comp.split("#if DEBUG")
check("isolated path: own directory, own vault, no Google grant store",
      "appDirectory = isolated.root; vault = isolated.sessionVault; google = nil" in comp)
check("isolated path: owned audio uses isolated directory and vault",
      'AppPlaybackAuthority(directory: storage.root.appendingPathComponent("owned-audio"), offlineVault: storage.ownedVault,' in comp)
check("design mode uses the isolated root and owned vault", "if nativeDesignTesting, let isolated {" in comp and "let root = isolated.root" in comp)
check("sign-in ledger lives under the chosen app directory", 'FileMusicSignInLedger(url: appDirectory.appendingPathComponent("web-sign-in-attempts.json"))' in comp)
init_start = comp.index("    init(artworkSource: any ArtworkSource = UnconnectedArtworkSource()")
init_body = comp[init_start:comp.index("\n    }\n", init_start)]
check("isolation decided synchronously in init, before any playback owner exists",
      "var playback: PlaybackModel\n" in comp and "var playback = PlaybackModel()" not in comp
      and "guard let storage = try? IsolatedQAStorage.createNow() else {" in init_body and "preconditionFailure(" in init_body
      and init_body.index("IsolatedQAStorage.createNow()") < init_body.index("playback = PlaybackModel(authority: AppPlaybackAuthority(directory: storage.root")
      and "let isolated = isolatedStorage" in comp and "IsolatedQAStorage.create()" not in comp)
check("isolation flag is read only under #if DEBUG", all("isolatedQA" not in part.split("#endif")[1] if "#endif" in part else True for part in dbg[1:]) and "isolatedQA" not in dbg[0])
check("owned-audio UI launches request the 0.001 cap",
      ui.count('app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"') >= 3)
check("controlled gain caps range and first play at 0.001",
      'gainRange = 0...(controlledAudioTest ? 0.001 : 1)' in panel and "maximumStartGain: controlledAudioTest ? 0.001 : nil" in panel)
check("hidden player only on explicit Play with a restored connected identity",
      "guard starts.accepts(request), let context = musicContext, let makeCookies = musicCookies else { throw DomainError.staleContext }" in panel
      and "musicContext = identity.state == .connected && context.account == identity.id ? context : nil" in panel)
# --- Preferences (UserDefaults / @AppStorage / @SceneStorage) ---
prefs = (ROOT / "Packages/NativeMusic/Sources/AppShell/AppPreferences.swift").read_text()
scenes = (ROOT / "Packages/NativeMusic/Sources/AppShell/NativeMusicScenes.swift").read_text()
sources = sorted(p for d in ("Packages/NativeMusic/Sources", "App/Sources") for p in (ROOT / d).rglob("*.swift"))
uses = []
for path in sources:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//")[0]
        if re.search(r"UserDefaults|@AppStorage|@SceneStorage|CFPreferences|defaultAppStorage", code):
            uses.append({"file": str(path.relative_to(ROOT)), "line": number, "code": code.strip()})
def classify(use):
    f, c = use["file"], use["code"]
    if f.endswith("AppShell/AppPreferences.swift"): return "resolver"
    if "@AppStorage(" in c and "store: AppPreferences.store" in c: return "explicit isolated store"
    if f.endswith("Features/PreferencesView.swift") and "@AppStorage(" in c: return "environment store via .appPreferences() on the Settings scene"
    if f.endswith("AccountSession/WebSession/WebMusicSignIn.swift") and "defaults: UserDefaults" in c: return "injected store (composition passes AppPreferences.store)"
    if f.endswith("Playback/WebMusic/WebMusicPage.swift") and "UserDefaults.standard.bool(forKey: WebKitMusicPage.orderedInKey)" in c: return "default argument; isolated composition passes an explicit AppPreferences.store reading"
    if f.endswith("Features/Search/SearchRecents.swift") and "UserDefaults" in c and ("defaults: UserDefaults" in c): return "injected store (composition passes AppPreferences.store; tests pass a temporary plist)"
    if f.endswith("AppShell/BrowserShell.swift") and "@SceneStorage(" in c: return "scene restoration state: isolated windows are non-restorable and launched with -ApplePersistenceIgnoreState YES"
    return None
for use in uses: use["coverage"] = classify(use)
check("every UserDefaults/@AppStorage/@SceneStorage use in app and package sources is covered", uses and all(u["coverage"] for u in uses), uses)
check("isolated store is a throwaway plist in the temporary folder, never the standard domain",
      "guard IsolatedQAStorage.requested(environment) else { return Resolved(store: .standard" in prefs
      and "Never fall back to the standard domain once isolation was requested." in prefs
      and 'folder.appendingPathComponent(filePrefix + UUID().uuidString + ".plist")' in prefs
      and "environment[defaultsTokenKey].flatMap(UUID.init(uuidString:))" in prefs)
check("both scene roots use the app preferences store", scenes.count(".appPreferences()") == 2 and '@AppStorage("appearance", store: AppPreferences.store)' in scenes)
check("sign-in options read the app preferences store", "MusicWebSignInOptions(defaults: AppPreferences.store)" in comp and "defaults: .standard" not in comp)
check("isolated hidden-player page reads the app preferences store",
      "makeMusicPage: { WebKitMusicPage(delegate: $0, orderHostWindowIn: AppPreferences.store.bool(forKey: WebKitMusicPage.orderedInKey)) }" in comp)
check("isolated windows persist no restorable state, frame, split-view or toolbar autosave",
      all(t in prefs for t in ("window.isRestorable = false", 'window.setFrameAutosaveName("")', "autosavesConfiguration = false", "split.autosaveName = nil")))
check("window/split-view autosave and restorability disabled at class level before any window",
      all(t in prefs for t in ("#selector(NSWindow.setFrameAutosaveName(_:))", "#selector(NSWindow.saveFrame(usingName:))",
                               "#selector(setter: NSWindow.isRestorable)", "#selector(setter: NSSplitView.autosaveName)",
                               "guard AppPreferences.resolved.isolatedPath != nil else { return }"))
      and scenes.count("Self.prepareIsolation();") == 2 and "IsolatedWindowPersistence.installIfIsolated()" in scenes)
seam = (ROOT / "Packages/NativeMusic/Sources/AppShell/IsolatedWindowSizeSeam.swift").read_text()
check("window-size seam is Debug-only, isolation-gated and never clamps",
      seam.split("#if DEBUG",1)[0].strip() == "import AppKit\nimport SwiftUI" and seam.count("#if DEBUG") == 2 and "guard IsolatedQAStorage.requested(environment) else { return (nil, []) }" in seam
      and "min(" not in seam and "max(" not in seam and scenes.count("if IsolatedWindowSizeSeam.hasNext {") == 1)
owned_start = panel.index("    func owned(request: OwnedStartRequest")
owned_first = panel[owned_start:].split("\n")[1].strip()
check("under isolation an owned start refuses production defaults before any I/O",
      owned_first == "if Self.refusesProductionDefaults(directory: directory, hasVault: offlineVault != nil, isolationRequested: isolationRequested) { throw DomainError.forbidden }"
      and "isolationRequested && (directory == nil || !hasVault)" in panel)
check("app-created throwaway plist removed at quit", prefs.count("removeOwnedIsolatedFile") == 1 and comp.count("AppPreferences.removeOwnedIsolatedFile()") == 2)
check("UI runner never touches the real preferences domain", "local.native-music.development" not in ui and "UserDefaults" not in ui and "defaults write" not in ui)
check("isolated helper forces -ApplePersistenceIgnoreState", 'app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]' in ui)
check("relaunch test names a throwaway plist by UUID token only",
      'app.launchEnvironment["YTMUSE_UI_TEST_DEFAULTS_ID"] = UUID().uuidString' in ui)


# --- W10: search and the command palette ---
dev = (ROOT / "Packages/NativeMusic/Sources/AppShell/DevelopmentSearch.swift").read_text()
sc = (ROOT / "Packages/NativeMusic/Sources/AppShell/SearchComposition.swift").read_text()
w10_tests = ui[ui.index("// MARK: W10 search and command palette"):]
check("W10 development catalog is Debug-only and needs the flag AND QA isolation", dev.lstrip().startswith("#if DEBUG") and dev.rstrip().endswith("#endif") and 'environment["YTMUSE_UI_DEVELOPMENT_DATA"] == "1" && IsolatedQAStorage.requested(environment)' in dev)
check("W10 recents live in the app preferences store (a throwaway plist under isolation)", "SearchRecents(defaults: AppPreferences.store" in sc)
check("W10 UI tests launch only through designApplication() (isolated, development catalog)", "designApplication()" in w10_tests and "XCUIApplication(" not in w10_tests)
check("W10 UI tests never open Google/YouTube sign-in or touch the real preferences domain", "musicSignIn" not in w10_tests and "defaults" not in w10_tests.lower().replace("designapplication", ""))
check("W10 search Copy Link uses a private pasteboard under isolation", "NSPasteboard(name: NSPasteboard.Name(\"local.native-music.ui-test-\" + UUID().uuidString))" in comp and "if isolatedQA {" in comp)
check("W10 development search is chosen only in a DEBUG branch of the composition", sc.index("#if DEBUG") < sc.index("DevelopmentSearch.enabled") < sc.index("#endif"))

# --- W11: Home, Explore and catalog details ---
devcat = (ROOT / "Packages/NativeMusic/Sources/AppShell/DevelopmentCatalog.swift").read_text()
cc = (ROOT / "Packages/NativeMusic/Sources/AppShell/CatalogComposition.swift").read_text()
cache = (ROOT / "Packages/NativeMusic/Sources/Features/Catalog/CatalogPageModel.swift").read_text()
artsrc = (ROOT / "Packages/NativeMusic/Sources/Features/Catalog/CatalogArtwork.swift").read_text()
w11_tests = ui[ui.index("// MARK: W11"):]
check("W11 development catalog is Debug-only", devcat.lstrip().startswith("#if DEBUG") and devcat.rstrip().endswith("#endif"))
check("W11 development catalog uses the W10 gate: the flag AND QA isolation", "static var enabled: Bool { DevelopmentSearch.enabled }" in devcat)
depth = 0; unguarded = []
for number, line in enumerate(cc.splitlines(), 1):
    t = line.strip()
    if t.startswith("#if DEBUG"): depth += 1
    elif t.startswith("#endif"): depth -= 1
    if "DevelopmentCatalog" in t and not t.startswith("//") and depth <= 0: unguarded.append(number)
check("W11 every use of the development catalog sits inside a DEBUG block", not unguarded, unguarded)
check("W11 a UI-automation launch without the development catalog never reaches the network", "} else if Self.automationIsolated(ProcessInfo.processInfo.environment) {" in cc and "reader = { _ in throw MusicSessionError.policy }" in cc and 'environment[IsolatedQAStorage.environmentKey] == "1" || environment["YTMUSE_NATIVE_DESIGN_TEST"] == "1"' in cc)
check("W11 catalog UI tests launch only through designApplication() (isolated, development catalog)", "designApplication()" in w11_tests and "XCUIApplication(" not in w11_tests)
check("W11 catalog UI tests never open sign-in or touch the real preferences domain", "musicSignIn" not in w11_tests and "defaults" not in w11_tests.lower().replace("designapplication", ""))
check("W11 the catalog cache is memory-only (no file or database API in the model)", "FileManager" not in cache and "SQLite" not in cache and "write(to" not in cache and "UserDefaults" not in cache)
check("W11 catalog artwork is retained in memory only, never on disk", ".disk(" not in artsrc and artsrc.count(".memory(") >= 2)
catalog_sources = [p for d in ("Features/Catalog", "Features/Home", "Features/Explore", "Features/CatalogDetails") for p in (ROOT / "Packages/NativeMusic/Sources" / d).rglob("*.swift")]
check("W11 catalog sources name no production store, Keychain item or app-support path",
      catalog_sources and all(not re.search(r"applicationSupportDirectory|Keychain|SecItem|ProductionDirectory|local\.native-music\.development", p.read_text()) for p in catalog_sources), [p.name for p in catalog_sources])
# --- W12: Library, History and library changes ---
S = ROOT / "Packages/NativeMusic/Sources"
devlib = (S / "AppShell/DevelopmentLibrary.swift").read_text()
libcomp = (S / "AppShell/LibraryComposition.swift").read_text()
histstore = (S / "AppShell/LocalHistoryStore.swift").read_text()
w12_tests = ui[ui.index("// MARK: W12"):]
check("W12 development library is Debug-only", devlib.lstrip().startswith("#if DEBUG") and devlib.rstrip().endswith("#endif"))
check("W12 development library needs the development flag, its own flag AND QA isolation",
      "DevelopmentSearch.isEnabled(environment) && environment[\"YTMUSE_UI_DEVELOPMENT_LIBRARY\"] == \"1\"" in devlib and "static func isEnabled(_ environment: [String: String]) -> Bool {\n        environment[\"YTMUSE_UI_DEVELOPMENT_DATA\"] == \"1\" && IsolatedQAStorage.requested(environment)" in dev)
depth = 0; unguarded = []
for number, line in enumerate(libcomp.splitlines(), 1):
    t = line.strip()
    if t.startswith("#if DEBUG"): depth += 1
    elif t.startswith("#endif"): depth -= 1
    if ("DevelopmentLibrary" in t or "DevelopmentLocalHistory" in t) and not t.startswith("//") and depth <= 0: unguarded.append(number)
check("W12 every use of the development library sits inside a DEBUG block", not unguarded, unguarded)
check("W12 a UI-automation launch without the development library never reaches the network",
      "reader = { _ in throw MusicSessionError.policy }; continuer = { _ in throw MusicSessionError.policy }; writer = { _ in throw MusicSessionError.policy }" in libcomp and "Self.automationIsolated(ProcessInfo.processInfo.environment)" in libcomp)
check("W12 the development library performs no network request and its local history never touches a file",
      "URLSession" not in devlib and "https://" not in devlib and "FileManager" not in devlib and "actor DevelopmentLocalHistory" in devlib)
check("W12 library UI tests launch only through designApplication() (isolated)", "libraryApplication()" in w12_tests and "XCUIApplication(" not in w12_tests and "let app = designApplication()" in w12_tests)
check("W12 library UI tests never open sign-in or touch the real preferences domain", "musicSignIn" not in w12_tests and "defaults" not in w12_tests.lower().replace("designapplication", "") and "UserDefaults" not in w12_tests)
check("W12 the local history file lives under the chosen app directory (the isolated root under QA)", 'LocalHistoryFileStore(directory: appDirectory.appendingPathComponent("local-history"))' in comp)
check("W12 the history store takes its directory by injection and names no production path", "applicationSupportDirectory" not in histstore and "local.native-music.development" not in histstore and "init(directory: URL" in histstore)
library_sources = [p for d in ("Features/Library", "Features/History") for p in (S / d).rglob("*.swift")] + [S / "AppShell/LibraryComposition.swift"]
check("W12 library and history sources name no production store, Keychain item or app-support path",
      library_sources and all(not re.search(r"applicationSupportDirectory|Keychain|SecItem|ProductionDirectory|local\.native-music\.development", p.read_text()) for p in library_sources), [p.name for p in library_sources])
check("W12 library models and the ledger have no file, database or preferences API", all(not re.search(r"FileManager|SQLite|UserDefaults|write\(to|\.write\(" , (S / p).read_text().replace(".write(request)", "").replace("writer(", "")) for p in ("Features/Library/LibraryCollectionModel.swift", "Features/History/ListeningHistoryRecorder.swift", "Features/History/HistoryModel.swift")))
callers = [str(p.relative_to(ROOT)) for p in sorted(S.rglob("*.swift")) if re.search(r"awaitedMusic\(\)\.write\(|music\.write\(|coordinator\.write\(", p.read_text())]
check("W12 the coordinator's write is called from exactly one place: the ledger's writer closure in the composition", callers == ["Packages/NativeMusic/Sources/AppShell/LibraryComposition.swift"], callers)
check("W12 no test or UI test target constructs the live signed transport (DirectSignedMusicTransport())",
      all("DirectSignedMusicTransport()" not in p.read_text() for p in (ROOT / "Packages/NativeMusic/Tests").rglob("*.swift") if p.name != "LibraryGuardTests.swift") and "DirectSignedMusicTransport()" not in ui)
adapter_signed = (S / "YouTubeMusicAdapter/SignedMusic.swift").read_text()
check("W12 the live signed transport refuses to be constructed in a test process (initialiser precondition; no session can be injected)",
      'precondition(!LiveTransportGuard.isTestProcess' in adapter_signed and "init(protocolClasses: [AnyClass])" in adapter_signed and "init(session: URLSession)" not in adapter_signed)
check("W12 the application target is the only place the live signed client is composed", "SignedMusicClient(publicClient:" in (ROOT / "App/Sources/NativeMusicApp.swift").read_text())
check("W12/W19 the write path set is exactly the six rate/subscribe/feedback paths plus the one confirmed upload removal",
      '"/youtubei/v1/subscription/subscribe", "/youtubei/v1/subscription/unsubscribe", "/youtubei/v1/feedback",\n                                                 "/youtubei/v1/music/delete_privately_owned_entity"]' in adapter_signed
      and adapter_signed.count("/youtubei/v1/") >= 7)
# --- W19: uploads (REMOVED from the product; MF-C3 restated this block to current truth) ---
# The original W19 clauses read Features/Uploads, AppShell/UploadComposition.swift and AppShell/DevelopmentUploads.swift, which the core redesign
# deleted (commit b7b7095c). Reading them crashed the proof before any W20 clause ran. What stays true, and is asserted instead: none of them is
# back, nothing names them, and the one signed write call site is still the Library ledger's writer closure. Uploads are NOT restored by this.
upload_leftovers = [str(p.relative_to(ROOT)) for p in [S / "AppShell/UploadComposition.swift", S / "AppShell/DevelopmentUploads.swift"] if p.exists()] \
    + [str(p.relative_to(ROOT)) for p in (S / "Features/Uploads").rglob("*.swift")]
check("W19 uploads are removed: no upload composition, development upload data or upload feature source exists", not upload_leftovers, upload_leftovers)
check("W19 nothing in the sources or UI tests names the removed upload composition, development uploads or their flag",
      all(not re.search(r"UploadComposition|DevelopmentUploads|YTMUSE_UI_DEVELOPMENT_UPLOADS|UploadTransport|UploadJobFileStore", p.read_text()) for p in sources if p.name not in ("DiscoveryComposition.swift",))
      and "MARK: W19 Uploads" not in ui and "uploadsApplication" not in ui)
check("W19 the removal writer is the Library ledger's one writer closure (still one awaitedMusic().write call site)",
      callers == ["Packages/NativeMusic/Sources/AppShell/LibraryComposition.swift"] and "writer: writer" in (S / "AppShell/LibraryComposition.swift").read_text())
# --- W20: Samples, tuner, Recap, badges, comments / moderation / invitations ---
devdisc = (S / "AppShell/DevelopmentDiscovery.swift").read_text()
disccomp = (S / "AppShell/DiscoveryComposition.swift").read_text()
w20_sources = [p for d in ("Features/DiscoveryExtras", "Features/Social") for p in (S / d).rglob("*.swift")] + [S / "AppShell/DiscoveryComposition.swift", S / "AppShell/DevelopmentDiscovery.swift"]
w20_ui = ui[ui.index("// MARK: W20"):]
check("W20 the development discovery data is Debug-only and needs the library flags, its own flag AND QA isolation",
      devdisc.lstrip().startswith("#if DEBUG") and devdisc.rstrip().endswith("#endif") and 'environment["YTMUSE_UI_DEVELOPMENT_DISCOVERY"] == "1"' in devdisc and "DevelopmentLibrary.isEnabled(environment)" in devdisc)
depth = 0; unguarded = []
for number, line in enumerate(disccomp.splitlines(), 1):
    t = line.strip()
    if t.startswith("#if DEBUG"): depth += 1
    elif t.startswith("#endif"): depth -= 1
    if ("DevelopmentDiscovery" in t or "scripted" in t) and not t.startswith("//") and depth <= 0: unguarded.append(number)
check("W20 every use of the development discovery data sits inside a DEBUG block", not unguarded, unguarded)
# MF-C3: restated to current truth. The tuner (QueueRadioControlsSource), Recap (SignedRecapSummarySource) and comments (the coordinator read transport)
# are the PRODUCTION sources and each reaches the account coordinator through one named read; isolated automation keeps all three unresolved; Samples
# and badges still have no route and stay unresolved; the scripted sources exist only inside DEBUG (the clauses above and below).
commentscomp = (S / "AppShell/CommentsComposition.swift").read_text()
def code_only(text): return "\n".join(l for l in text.splitlines() if not l.strip().startswith("//"))
disc_code, comments_code = code_only(disccomp), code_only(commentscomp)
check("W20 production composes the tuner queue controls, the Recap reader and the comments coordinator read transport; isolated automation keeps all three unresolved; Samples and badges stay unresolved",
      all(t in disc_code for t in ("var samplesSource: any SamplesSource = UnresolvedSamplesSource()",
                                   "var controlsSource: any RadioControlsSource = QueueRadioControlsSource {",
                                   "if Self.automationIsolated(launchEnvironment) { controlsSource = UnresolvedRadioControlsSource() }",
                                   "isolated ? UnresolvedSummarySource() : SignedRecapSummarySource(reader: recap)",
                                   "var badgesUnresolved: String? { UnresolvedSummarySource().unresolved }",
                                   "commentsTransport(isolated: isolatedLaunch)"))
      and all(t in comments_code for t in ("isolated ? UnresolvedCommentsTransport() : CoordinatorCommentsTransport(reader: reader)",
                                           "var unresolved: String? { nil }", "func post(", "throw CommentsFailure.writesUnavailable")))
check("W20 no discovery or social source names a network API, a host, a URL request or a decoder",
      all(not re.search(r"URLSession|URLRequest|https?://|JSONDecoder|JSONSerialization|WKWebView|NWConnection", "\n".join(l for l in p.read_text().splitlines() if not l.strip().startswith("//"))) for p in w20_sources), [p.name for p in w20_sources])
check("W20 no discovery or social source names a production store, Keychain item or app-support path",
      all(not re.search(r"applicationSupportDirectory|Keychain|SecItem|ProductionDirectory|local\.native-music\.development|UserDefaults|FileManager", p.read_text()) for p in w20_sources))
check("W20 the only Network.framework use is the passive path monitor", [p.name for p in w20_sources if "import Network" in p.read_text()] == ["DiscoveryComposition.swift"]
      and "NWPathMonitor()" in disccomp and "NWConnection" not in disccomp and "monitor.start(queue:" in disccomp)
# MF-C3: the old clause banned every `awaitedMusic` in the discovery composition, but the accepted tuner has called it since 8fa17bac and Recap and comments
# read through it. The stronger statement: the one signed write call site is still the Library's, and the discovery and comments compositions reach the
# coordinator ONLY through the named reads (Recap's recap(), comments(), the tuner's radioQueue()); never a write, a playlist edit or a direct transport.
direct_reads = set(re.findall(r"awaitedMusic\(\)\s*\.(\w+)\(", disc_code + comments_code))
bound_reads = set(re.findall(r"\bmusic\.(\w+)\(", disc_code + comments_code))
forbidden_words = re.compile(r"\.write\(|editPlaylist\(|writer|MusicWriteRequest\(|MusicPlaylistRequest|DirectSignedMusicTransport|SignedMusicClient\(|PublicMusicClient\(")
check("W20 neither composition adds a signed write: still one awaitedMusic().write call site (the Library's); discovery and comments reach the coordinator only through recap(), comments() and the tuner's radioQueue()",
      callers == ["Packages/NativeMusic/Sources/AppShell/LibraryComposition.swift"]
      and direct_reads == {"recap", "comments"} and bound_reads == {"radioQueue"} and "let music = try await self.awaitedMusic()" in disc_code
      and not forbidden_words.search(disc_code + comments_code),
      {"direct": sorted(direct_reads), "bound": sorted(bound_reads)})
check("W20 the social surface writes only through the Library ledger and the playlist edit session (no direct request type)",
      all(t not in (S / "Features/Social/SocialSurface.swift").read_text() for t in ("MusicWriteRequest(", "MusicPlaylistRequest.edit", ".apply(", "writer(")))
check("W20 development discovery launches never press a library Play or open sign-in", "musicSignIn" not in w20_ui and "libraryPlay-" not in w20_ui and "UserDefaults" not in w20_ui)
check("W20 UI tests launch only through discoveryApplication()/libraryApplication() (isolated), never XCUIApplication directly",
      "discoveryApplication(" in w20_ui and "XCUIApplication(" not in w20_ui.replace("private func discoveryApplication(conditions: String? = nil) -> XCUIApplication", ""))
queue_src = (S / "YouTubeMusicAdapter/MusicRadioQueue.swift").read_text()
check("W20 rework: the radio-queue seam is a pure parser and request body: it names no network API, host or session and sends nothing",
      not re.search(r"URLSession|URLRequest|https?://|dataTask|\.send\(|awaitedMusic", queue_src) and "public static func body" in queue_src and "public static func parse" in queue_src)
check("W20 rework: AppShell does not construct raw radio-queue requests (production uses the coordinator read)",
      all("MusicRadioQueueParser.body" not in p.read_text() and "MusicRadioQueueRequest" not in p.read_text() for p in (S / "AppShell").rglob("*.swift") if p.name != "DevelopmentDiscovery.swift"))
products = Path(os.environ.get("BUILD_DIR") or ROOT / ".build/xcode")
release = products / "Build/Products/Release/YTMuse.app/Contents/MacOS/YTMuse"
debug = products / "Build/Products/Debug/YTMuse.app"
if release.exists():
    data = release.read_bytes()
    check("Release binary carries no isolation switch", key.encode() not in data and b"ytmuse-ui-test-isolated-" not in data, str(release))
    check("Release binary carries no preferences redirect", b"YTMUSE_UI_TEST_DEFAULTS_ID" not in data and b"ytmuse-ui-test-defaults-" not in data)
    check("Release binary carries no window-persistence override", b"ytmuseIsolatedSetFrameAutosaveName" not in data)
    check("Release binary carries no window-size seam", all(t not in data for t in (b"YTMUSE_UI_TEST_WINDOW_SIZE", b"YTMUSE_UI_TEST_WINDOW_SIZES_NEXT", b"Apply Next Test Window Size")))
    check("Release binary carries no development search catalog", b"Development Artist" not in data and b"PLdevelopmentCafe" not in data)
    check("Release binary carries no W11 development catalog", b"devplaylisttoken1" not in data and b"UCdevelopmentartist" not in data and b"Caf\xc3\xa9 Collection (development)" not in data)
    check("Release binary carries no W12 development library", b"UCdevfollowartist" not in data and b"devsongs2" not in data and b"YTMUSE_UI_DEVELOPMENT_LIBRARY" not in data)
    check("Release binary carries no W19 development uploads or scripted upload route", all(t not in data for t in (b"YTMUSE_UI_DEVELOPMENT_UPLOADS", b"Aurora Test Tone", b"devupload-song", b"DevelopmentUploadTransport", b"upload-samples")))
    check("Release binary carries no W20 development discovery data or scripted comments", all(t not in data for t in (b"YTMUSE_UI_DEVELOPMENT_DISCOVERY", b"YTMUSE_UI_PREVIEW_CONDITIONS", b"devclip00001", b"Development clip one", b"Development recap", b"A development comment", b"devprev0001")))
else:
    check("Release binary carries no isolation switch", False, "release binary not built")
    check("Release binary carries no preferences redirect", False, "release binary not built")
    check("Release binary carries no window-persistence override", False, "release binary not built")
    check("Release binary carries no window-size seam", False, "release binary not built")
    check("Release binary carries no development search catalog", False, "release binary not built")
    check("Release binary carries no W11 development catalog", False, "release binary not built")
    check("Release binary carries no W12 development library", False, "release binary not built")
    check("Release binary carries no W19 development uploads or scripted upload route", False, "release binary not built")
    check("Release binary carries no W20 development discovery data or scripted comments", False, "release binary not built")
dylib = sorted(debug.glob("Contents/MacOS/*")) if debug.exists() else []
found = any(key.encode() in p.read_bytes() for p in dylib if p.is_file())
check("Debug test product contains the isolation switch", found, [str(p) for p in dylib])
ok = all(c["pass"] for c in checks)
# Rework 1 (F11): a test run never rewrites a tracked file. The default output is the build directory; the record committed with a candidate is made
# deliberately with `--out <path>` after the candidate commit, and it names that commit and whether the tree was clean.
if "--out" in sys.argv: out = Path(sys.argv[sys.argv.index("--out") + 1])
else: out = products / "w20-isolation-proof.json"
out.parent.mkdir(parents=True, exist_ok=True)
head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
dirty = [l for l in subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout.splitlines() if str(out.relative_to(ROOT) if out.is_relative_to(ROOT) else out) not in l]
out.write_text(json.dumps({"source": head, "tree_clean": not dirty, "uncommitted_paths": dirty[:20], "binary_root": str(products), "pass": ok, "checks": checks}, indent=1) + "\n")
for c in checks: print(("PASS " if c["pass"] else "FAIL ") + c["name"])
sys.exit(0 if ok else 1)
