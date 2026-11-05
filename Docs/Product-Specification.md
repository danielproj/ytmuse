A complete product and engineering specification for a free, open-source, fully native YouTube Music client for macOS. The primary user is a single account holder on an Apple Silicon MacBook Pro. This specifies one complete 1.0 release, including functional behavior, native integration, design, performance, security, and acceptance criteria. It contains no delivery dates, estimates, MVP, or deferred feature roadmap.

The requirements below are intended implementation behavior, not a claim that an application or every upstream integration already exists. Features dependent on YouTube access remain in scope and have explicit release gates. An unavailable dependency must not be disguised as a completed feature or silently removed.

Specification version: 1.0. Working project name: Native YouTube Music for macOS. The public brand and bundle identifier must be independently owned and must not imply endorsement by Google or Apple.

# 1 Product contract

| Decision | Required outcome |
| - | - |
| Primary purpose | A daily desktop music application with the breadth of YouTube Music and the responsiveness of a well-built Mac app |
| Platform | Apple Silicon; macOS 27.0 or later; validate against the current stable patch |
| Reference machine | The account holder's Apple Silicon MacBook Pro; record actual RAM, display refresh mode, OS build, and audio route with benchmarks |
| Native boundary | Native Swift interface and media playback; no Electron, Chromium, website renderer, hidden web player, or web-based navigation |
| Browser exception | Google authentication and explicit external links only |
| Service | YouTube Music; free and Premium accounts; multiple accounts and available channel identities |
| Backend | Direct connections from the Mac; no developer-operated API proxy, media server, or mandatory app account |
| Distribution | GitHub source and downloadable app; signed and notarized DMG for convenient public installation |
| App Store | An additional distribution option only if the complete applicable feature set can meet review requirements |
| Price | Free application, no purchases, subscriptions, paid unlocks, affiliate placement, or app advertising |
| Release scope | One complete release containing every requirement in this specification; no placeholder controls |
| Licensing | MIT for original code, subject to compatible dependency licenses and retained attribution |

Priority when implementation choices conflict: correct playback and account isolation; responsive controls; energy efficiency; visual polish. This priority governs how effects are implemented, not whether functional requirements are removed.

Apple currently lists macOS 27 as the newest major release. The deployment target above is an explicit product choice, not a claim about the exact OS installed on the user's machine. [Apple macOS versions](https://support.apple.com/en-us/109033)

# 2 Account eligibility and unresolved service dependencies

All supported account types must be able to sign in and use their service-eligible features. Do not impose a Premium-only login requirement. Region, account, content, age restrictions, and active subscription determine capabilities individually.

The application adds no advertising. That does not establish ad-free YouTube playback for a free account. YouTube describes free music as ad-supported and identifies background music, audio-only music, and music downloads as Premium benefits, with different eligibility for podcasts. Consequently, universal ad-free music on free accounts is not a promised capability. [YouTube account features](https://support.google.com/youtubemusic/answer/6313529?hl=en)

| Capability | Free account behavior | Premium account behavior |
| - | - | - |
| Sign in and account management | Available for service-supported account types | Available |
| Library and social actions | Use available service permissions | Use available service permissions |
| Music playback | Native service-compatible playback, including required source advertising | Native playback using subscribed benefits |
| Quality | Best stream the service actually grants | Best entitled stream, with explicit quality selection |
| Music while hidden or locked | Follow verified account and regional eligibility | Required |
| Music offline | Only where service entitlement permits | Required once an authorized technical route is verified |
| Podcasts | Follow item-specific permissions, including eligible free downloads | Follow item-specific permissions; do not promise removal of creator advertising |
| Restricted or supervised identity | Honor actual restrictions and explain unavailable actions | Same rule; subscription does not override restrictions |

Model each capability as supported, restricted, temporarily unavailable, unknown, or failed. Unknown must not be treated as permission or denial. Show a concise explanation only at the affected action.

The documented YouTube Data API is not a verified complete solution for this product's playback and Music-specific account requirements. Existing unofficial work such as ytmusicapi demonstrates request-based access to useful metadata and account operations. It is a protocol research reference, not the application's Python runtime and not proof of Premium stream or offline access. [YouTube Data API](https://developers.google.com/youtube/data/reference/rest) · [ytmusicapi](https://ytmusicapi.readthedocs.io/en/stable/)

| Gate | Evidence required before full release |
| - | - |
| G01 Authentication | Real free and Premium sessions established without manual cookie copying; refresh, logout, switching and revocation verified |
| G02 Native media access | Actual playable media resolved and played in the native engine, including seek, URL renewal, restricted content and long sessions |
| G03 Free account playback | Source advertising and eligibility handled by a verified native-compatible integration; no silent omission of required ads |
| G04 Premium quality | Confirm actual delivered codec and bitrate on the user's account, not just an account badge |
| G05 Offline | Verify media access, entitlement validation, expiry/renewal, playback while disconnected, and deletion |
| G06 Service parity | Every service feature in the inventory has an implemented native flow or a genuine account/content restriction |
| G07 Casting | Authenticate and control playback on real AirPlay and Cast targets without exposing credentials |
| G08 System integration | Confirm actual framework and Siri behavior on the deployment OS and supported languages |
| G09 Distribution | Release artifacts install, update and launch with signing, notarization and verified integrity |

These are internal verification gates for the single release. An unresolved gate affecting a mandatory capability blocks the claim that 1.0 is complete. Publishing source for inspection is different from claiming a finished product.

App Store review is not a prerequisite for the GitHub release. Apple requires permission to use third-party services and explicit authorization for media downloading; direct distribution does not itself resolve the service's access terms. [App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/)

# 3 Complete feature inventory and navigation

The inventory is the release checklist. Functional parity means reproducing the available account's music workflows in native UI, not copying website HTML or continually promising every future service experiment.

| Destination | Contents and actions |
| - | - |
| Home | Personalized shelves, quick picks, mixes, recently played, recommended releases and resumable listening |
| Explore | Releases, charts, moods, genres and discovery collections |
| Search | Suggestions, recent queries, grouped results, filters, correction hints and local library results |
| Library | Playlists, songs, albums, artists, subscriptions, podcasts and downloaded items |
| Playlist | Metadata, ordering, play/shuffle/radio, editing, collaboration, sharing and downloads |
| Album | Artwork, artist links, track list, editions when available, credits, save, play and download |
| Artist | Top tracks, albums, singles, videos, related artists and follow state |
| Song details | Credits, album/artist navigation, quality, availability and contextual actions |
| Podcast | Show details, episodes, follow, saved episodes and download controls |
| Episode | Description, chapters if supplied, playback progress, speed and resume |
| Downloads | Media, progress, errors, entitlement status, storage and playlist updates |
| History | Remote history and clearly distinguished local playback history; clearing and pausing |
| Samples | Native short discovery clips where the service exposes them |
| Music tuner | Artist/seed selection and service-provided diversity/discovery controls |
| Recap and badges | Account-provided summaries and achievements; no invented service statistics |
| Queue | Current item, user additions, context sequence, recommendations and playback history |
| Now Playing | Artwork or video, transport, queue, lyrics and output selection |
| Settings | Account, playback, appearance, downloads, integration, language, privacy and diagnostics |

Use Home, Explore, Library and Downloads as primary sidebar items. Search stays immediately accessible. History, Podcasts and saved playlists are subordinate destinations. Discovery features such as Samples and Tuner are reachable from Explore without crowding the primary sidebar.

Back and forward preserve destination, selection, scroll offset, filters and search query. Navigation never resets the queue. Opening an unavailable deep link shows a meaningful item state and recovery action rather than an empty screen.

At implementation validation, compare this inventory with actual free and Premium YouTube Music sessions. Record account/region-specific variants, playlist ownership roles, and service experiments in a parity manifest. Future upstream additions do not automatically alter the frozen 1.0 contract.

# 4 Onboarding and account management

AUTH01. First launch opens a native welcome screen with Sign in with Google and an optional browse-without-sign-in entry when public service access is available. Explain that the application is independent and that service subscriptions remain with YouTube.

AUTH02. Authentication opens the system browser or an approved system authentication session. A native-only promise does not imply collecting the user's Google password in a native text field. Passwords, recovery codes and second-factor secrets must never enter application storage or diagnostics.

AUTH03. Prefer a verified public-client authentication flow with proper state validation and PKCE where that flow supports the required service. Do not assume a standard OAuth token grants the private Music session. If another session mechanism is required, document and validate its safe transfer and renewal. Manual cookie/header export is a developer diagnostic procedure, not a release onboarding flow.

AUTH04. Store session credentials in macOS Keychain, scoped to a stable account and channel identity. Keep public profile information in the local database. Never package a confidential client secret as though a desktop executable could protect it.

AUTH05. Support add account, rename local display label, choose default, switch channel where supported, sign out, remove local data and reconnect expired sessions. Do not set an arbitrary application account limit.

AUTH06. Switching accounts pauses the old session, persists its queue and position, cancels its pending UI requests, detaches its system controls, and opens the new account's state paused. Every outstanding response carries an account generation so late results cannot populate another account.

AUTH07. Downloads, private artwork, history, caches and mutations are partitioned by account. Shared public catalog metadata may be deduplicated only if it contains no user state.

AUTH08. Session expiry preserves local navigation, queue and unsent operations. Show Reconnect without destroying state or repeatedly opening the browser. Any continued offline playback must satisfy the stored entitlement.

AUTH09. Sign-out removes credentials and makes account-private data inaccessible. Offer deletion of that account's local files. Removing an account deletes its session, private caches, download keys and pending writes; it does not delete Google account data.

AUTH10. Supervised, organization-managed, region-limited and unavailable service identities receive accurate service errors. The app must not bypass age, region or content restrictions.

Acceptance: sign in to a free and Premium account, switch rapidly during search and download activity, expire one session, reconnect it, then remove one account. No data or request may cross account boundaries.

# 5 Search and discovery

SEARCH01. A persistent search field and Command-F focus search. Command-K opens a native command palette for navigation, playback and account-aware library actions.

SEARCH02. Empty search shows recent queries, recent items and useful discovery entry points. Typed search shows cached local matches immediately, then remote suggestions and results after a 180 ms debounce. Cancel outdated work; only the latest query/account generation may update the screen.

SEARCH03. Group results into Top results, Songs, Albums, Artists, Playlists, Videos, Podcasts and Episodes where supported. Provide a Library scope. Keep result types visually distinct and preserve explicit-content and availability badges.

SEARCH04. Support case-insensitive matching, diacritics, Unicode normalization, tolerant local matching and source-provided corrections. Preserve the original query. Never silently replace it with a suggestion.

SEARCH05. Keyboard arrows navigate, Return activates the selected action, Escape dismisses suggestions, and normal text-editing shortcuts remain intact. Results support context menus, play next, queue, save, like, download and share according to capability.

SEARCH06. Remote search must not be reimplemented using fabricated catalog results. Local fuzzy matching can improve access to cached items but cannot claim completeness across the entire service.

DISC01. Recommendations, radio, charts, mixes and discovery sections use the active account and service region. Cache sections for immediate display with a discreet stale indicator when necessary.

DISC02. Refreshing Home must preserve scroll position and should not reshuffle currently visible content unexpectedly. Fetch and decode artwork asynchronously. Load additional shelves and pages as needed.

DISC03. Radio and music tuner use actual service-provided context and controls. User-created local listening statistics may exist separately, but must not be presented as YouTube's recommendations or Recap.

DISC04. Samples use native video surfaces, one active preview at a time, with no audio overlap. Disable autoplay previews by default on Low Power Mode and constrained connections. An explicit Play action hands off to the shared playback session.

# 6 Library and playlist management

LIB01. Support service library songs, liked tracks, albums, artists, followed channels, playlists, podcasts, saved episodes. Empty, loading, offline, stale and restricted states must be distinct.

LIB02. Offer list and grid views where appropriate, search within a collection, stable sorting by title/artist/recent addition where data permits, and native multi-selection. Use service ordering as the default; local view sorting must not rewrite remote order.

LIB03. Read incrementally paginated collections completely without discarding duplicates. Do not assume the first response is the entire library. Store collection membership separately from catalog items.

LIB04. Like, dislike where exposed, save/remove and follow/unfollow update optimistically with visible pending/error state. Roll back failed writes or provide a clear retry, rather than leaving a false success.

LIST01. Create, rename, describe, delete and change playlist visibility where authorized. Preserve privacy by default: newly created playlists are private unless the user chooses otherwise.

LIST02. Add, remove, reorder and move multiple tracks; support drag-and-drop from search, albums, artists and the queue. Preserve duplicate occurrences and the service's playlist item identifiers.

LIST03. Support owned, saved, public and collaborative playlists with accurate permissions. Collaboration includes joining through supported links, adding/editing where allowed, and reflecting remote changes. Invite or sharing operations require an explicit user action.

LIST04. Provide playlist suggestions and append selected suggestions. Detect duplicates and offer Keep duplicates or Skip existing; default to preserving the user's chosen operation rather than deleting existing content.

LIST05. Destructive bulk operations require a native confirmation describing the actual selection. Offer Undo for reversible actions. Remote undo is a compensating operation and may fail; report that failure accurately.

LIST06. Share by copying the canonical service link or opening the macOS share sheet. Never upload library data to an app-specific sharing service.

LIST07. Keep a playlist's downloaded membership synchronized when the user has enabled Download this playlist. New entries join the download queue; removed entries are deleted only if no other retained collection or manual pin references them.

LIB05. Maintain the service's pause/clear history controls when available. Local history controls are separate and must not imply a remote deletion that was not confirmed.

Acceptance: a large playlist with duplicate tracks, collaborative edits, pagination, concurrent reorder and temporary network loss converges without deleting unrelated items or duplicating retried additions.

# 7 Native playback and audio quality

PLAY01. A single application playback session owns the active account, queue, selected route, transport state and current item. All windows, menu controls, widgets and commands observe and control that session.

PLAY02. Use AVFoundation for native remote/local media playback, with AVPlayer or AVQueuePlayer as the primary implementation. Audio DSP, decoded-buffer playback or codec adapters may use AVAudioEngine, Core Audio and narrowly scoped native libraries where measurements and format support require them. The engine abstraction must permit this without altering UI behavior. [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)

PLAY03. Resolve actual available media variants, codec/container compatibility, duration, seekability, authorization requirements and expiry. The stream resolver is a separate service adapter. A metadata endpoint returning a song ID is not a playable stream.

PLAY04. Default to Best available for the current account. Expose Auto, Best available and Data saver in advanced settings. Best available never silently reduces source quality during a slow connection; show buffering and offer Auto. Prefer a natively decodable format of comparable quality over a format requiring expensive conversion, while reporting the selected stream honestly.

PLAY05. The quality panel shows observed source codec, bitrate when known, sample rate when known, and output route. Use Unknown instead of invented measurements. Do not label lossy audio lossless or infer stream quality solely from subscription status.

YouTube currently describes high-quality Premium audio as up to 256 kbps AAC/Opus. This is a source limit, not a guaranteed result of this client or an immutable maximum for future service formats. Native playback cannot reconstruct information absent from the source. [YouTube audio quality](https://support.google.com/youtubemusic/answer/9076559?hl=en)

PLAY06. Do not transcode or normalize by default. Avoid unnecessary sample conversions; let the system route operate at supported formats. Bluetooth and wireless output can impose additional transformations and must not be described as bit-perfect.

PLAY07. Include gapless playback for compatible consecutive media. Prebuffer the next eligible item within bounded memory and source permissions. Validate the boundary with test assets of known timing; account for encoder delay/padding. AVQueuePlayer alone is not proof of gapless behavior.

PLAY08. Include optional crossfade from 0 to 12 seconds, default 0; a native 10-band EQ, default flat/off; loudness normalization, default off; balance and independent app volume. Compensate gain to avoid clipping. When EQ, normalization and crossfade are off, bypass processing.

PLAY09. DSP may require a different native playback backend or access to decoded audio. If the actual media route does not permit it, this is an implementation gate; do not display a functional-looking effect that does nothing. Crossfade must not overlap required advertisements, spoken episodes by default, or unavailable media.

PLAY10. Music defaults to 1x. Podcasts and long-form content support 0.5x to 3x, pitch preservation where available, per-show speed and configurable 15-second back/30-second forward actions.

PLAY11. Play/pause, previous/next, seek, repeat, shuffle, volume, mute, like and save respond immediately in UI. Previous restarts a track after 3 seconds of playback, otherwise moves to the previous item. Expose a direct previous-item action in the command palette.

PLAY12. While seeking, show a scrub preview and commit the final target once the gesture ends. Coalesce keyboard seeks. For live media, expose only the service-supported seek window and a Go live action.

PLAY13. Renew expired stream access before expiry where supported. On an authorization failure, attempt one refreshed resolution, then present the correct account or content error. Never retry indefinitely.

PLAY14. Resume a temporary network interruption only if playback was active and no later user pause, route loss, account switch or quit has superseded it. Preserve intended position; avoid replaying minutes of audio after reconnect.

PLAY15. Keep source advertising separate from user media state. Honor source constraints on skip, seek, reporting and presentation. The native free-account advertising path requires verification; a hidden web player is not an accepted fallback.

PLAY16. Unavailable queue items remain identifiable. During unattended sequential playback, skip a failed/unavailable item with an explanatory history entry; stop after three consecutive failures. An explicitly selected failed item shows Retry and must not silently play something else.

PLAY17. Include a sleep timer with 5, 15, 30 and 60 minute presets, a custom duration, and End of track / End of episode. Show remaining time in Now Playing and the menu popover. At expiry, fade app-controlled audio over 5 seconds and pause without changing queue position. Cancel the timer on account switch or explicit quit. A timer that expired during sleep must prevent wake auto-resume. If a remote route cannot honor the timer, explain that before enabling it.

# 8 Queue semantics

QUEUE01. Model distinct segments: current item, explicit Play next items, remaining source context, Add to queue items and autoplay recommendations. Show segment labels when useful without exposing provider protocol details.

QUEUE02. Play next places the selected items immediately after the current item, in selection order. Add to queue appends to the user-controlled upcoming sequence before autoplay recommendations. New explicit Play next additions take precedence over previous upcoming additions.

QUEUE03. Starting a different album, playlist or radio replaces context. If there are explicit pending user additions, ask once whether to replace them or keep them. Remember that preference in advanced settings; default to ask.

QUEUE04. Reordering works across editable upcoming segments using drag-and-drop and keyboard commands. Disallow moving already consumed source advertisements or other immutable service items.

QUEUE05. Shuffle rearranges eligible context items while preserving the current item and explicit user additions. Switching shuffle off restores original context order without losing additions or replaying consumed items. Repeat modes are off, all and one, with service-supported semantics.

QUEUE06. Autoplay is enabled by default when supported. Recommendations append after the deliberate queue, avoid immediately replaying the same item, and keep their source context. Disabling autoplay removes only unplayed recommendations.

QUEUE07. Queue occurrences have unique IDs independent of track ID. Playing the same song twice is valid. Undo queue edits locally. Store queue, shuffle seed, context cursor, consumed entries and current position atomically.

QUEUE08. Restore the queue after restart or crash without auto-playing. Continue an existing session through normal window closure. A remote queue from another device is imported only through verified service support; never claim cross-device queue synchronization based on local persistence.

QUEUE09. Support clear upcoming, remove selected, save queue as playlist, go to current track and a bounded recently played view. Queue editing and persistence must remain usable when disconnected.

# 9 Offline playback and downloads

OFF01. Include native download actions for eligible tracks, albums, playlists and episodes, and a Downloads destination. Offline media is a first-release requirement, subject to G05; cached artwork or metadata alone does not satisfy it.

OFF02. Persist an explicit download job with account, media ID, collection references, selected variant, size if known, completed ranges, integrity state, retry state, entitlement and renewal information. Restarting the app resumes eligible interrupted work.

OFF03. Default media storage budget is 20 GiB across accounts, adjustable. Keep at least 5 GiB or 5% of the volume free, whichever is larger. Metadata/artwork caches have separate budgets. If pinned media fills the budget, pause new downloads and show storage choices rather than deleting pinned content.

OFF04. Manual downloads are pinned until removed. Smart Downloads is included but off by default and requires an explicit switch. When enabled, use service recommendations and reserve no more than 25% of the configured media budget for automatic content.

OFF05. Default concurrency is two downloads, reduced to one in Low Power Mode. Prioritize current playback and the user's newest explicit download. Pause automatic downloads on constrained/expensive connections; allow a user override for a manual download. Network policy is based on measured path properties, not the assumption that all Wi-Fi is unlimited.

OFF06. Download states are queued, resolving, downloading, paused, validating, available, renewing, expired and failed. Show aggregate and item progress without inventing percentages if total size is unknown.

OFF07. Use resumable ranges only when supported by the actual endpoint. Re-resolve expired URLs. Never append bytes from different media variants into one object. Validate completeness before exposing the item as available.

OFF08. The Premium offline mechanism of an official YouTube application must not be presumed accessible to this app. Store and obey actual entitlement/expiry information; do not invent a 30-day rule or grant permanent access merely because a download succeeded. Source restrictions and region changes can invalidate media.

OFF09. App-managed retained media is private to the app and account. Use authenticated encryption with account-specific keys in Keychain, stream decryption with bounded memory, and remove partial cleartext files. Compatibility with any source-provided encryption remains a separate integration requirement.

OFF10. Play eligible local media before attempting a network fetch. An offline queue can mix available and unavailable items, with clear badges. Provide Downloaded only filtering and navigation to cached albums and playlists.

OFF11. Playlist membership updates reconcile retained media references. If two downloaded playlists use the same asset for the same account/variant, keep one stored object with two references. Manual pinning prevents removal when a collection changes.

OFF12. Sign-out/revocation, subscription change, insufficient storage, corrupted files and missing keys have explicit recovery states. Never substitute another account's credentials or downloads.

OFF13. Use bounded retries with exponential backoff and jitter. Reconnect or resume does not spawn duplicate jobs. On exit, safely checkpoint work; downloads do not keep an explicitly quit app running.

Acceptance: download a playlist, disconnect the network, restart the app, play and seek every retained item, reconnect with expired stream URLs, change playlist membership, exceed the disk budget, revoke the account, and verify correct recovery and isolation.

# 10 Videos podcasts and lyrics

MEDIA01. Songs, albums, music videos, live music streams, podcasts and episodes have native detail and playback views. Content comes from the YouTube Music experience; this is not a general YouTube browsing client.

MEDIA02. Audio/video switching preserves position when the service exposes corresponding versions and a reliable mapping. Different recordings are not interchangeable merely because titles match. Report a restart when exact continuation is impossible.

MEDIA03. Render video natively with AVFoundation/AVKit, preserve aspect ratio, support full screen and Picture in Picture where the selected OS/media path allows it. Disable video decoding when an eligible audio-only representation is selected; covering a running video with artwork is not equivalent.

MEDIA04. Podcast views include show follow state, episode sorting, saved episodes, chapters, playback position, played/unplayed status and eligible downloads. Sync service-supported state and retain clearly marked local-only progress where the service lacks it.

MEDIA05. Live content shows Live, current availability, any seekable window and reconnect status. Do not expose download or crossfade controls for content that cannot support them.

MEDIA06. Reserved. Music uploads and management of uploaded music are excluded from the app by user decision (2026-11-04).

MEDIA07. Use lyrics supplied by YouTube Music when available. Display timed lyrics only when reliable timing is present; otherwise show plain lyrics. Show credits/attribution as supplied. No fabricated timing, invented text or default third-party lyric provider.

MEDIA08. Timed lyrics follow playback with gentle motion, highlight one current line, allow manual scrolling, and offer Return to current line. Selecting a line seeks only when timing and the media permit it. Reduced Motion changes the highlight without animated scrolling.

MEDIA09. Contextual credits, source descriptions, album editions, explicit labels, content availability and canonical service links remain accessible. Treat remote rich text as untrusted data; render a supported native subset.

MEDIA10. Service-provided comments, ratings, collaboration invitations and discovery metadata belong to the feature inventory when present for the account. Implement native read/write/moderation actions that the account is permitted to use; do not scrape arbitrary external websites or invent missing account permissions.

# 11 Window lifecycle and background operation

WIN01. The top menu bar is the permanent background control surface. It has a compact status icon, optional track tooltip, a native popover with artwork/metadata/transport/volume, and a context menu with Open, Mini-player, Settings and Quit.

WIN02. First launch opens the main window. Closing the last visible player window keeps the eligible playback session running and leaves the menu bar item available. Hide the Dock icon when no regular window is visible; restore normal Dock presence when reopening a main window. Keep this activation-policy transition stable under Mission Control and multiple Spaces.

WIN03. Command-W closes the active window; closing the main window does not quit. Command-Q stops local or app-owned playback, checkpoints state and quits. Cast behavior on explicit quit follows the documented remote-session choice in section 12.

WIN04. One main browser window is the default. Command-N can open an additional native browser window with independent navigation and a shared active account/player. Account switching affects all windows together. Only one system Now Playing owner exists.

WIN05. Include a separate resizable mini-player with artwork, transport, like, queue access, volume and a pin-on-top option. Default size is approximately 360 by 160 points in compact mode; expanded artwork mode is user-selectable. It must not steal keyboard focus when track metadata changes.

WIN06. Include full-screen Now Playing with artwork/video, transport, queue and optional lyrics. Entering/exiting preserves current focus and playback. Normal macOS full-screen browsing remains available.

WIN07. Closing a display or locking the screen must not pause account-eligible background playback while the Mac remains awake. Actual system sleep and laptop lid closure may suspend playback; do not promise audio during system sleep. Do not disable system sleep merely to maintain decorative UI or background downloads.

WIN08. After wake, restore UI and output discovery. Resume only a previously playing session if no user pause, route-loss pause, account change, quit or sleep-resume preference forbids it. Default is resume an interrupted active session once a safe route is confirmed.

WIN09. Manual cold launch restores the last account, windows, browsing state, queue and position, paused. Login launch is off by default; when enabled, start as a menu bar app without audible autoplay.

WIN10. Background operation must stop hidden-window animation, lyric scrolling, waveform work, unnecessary image decoding and view refresh. Keep only playback, bounded persistence and relevant state updates active.

Acceptance: repeatedly open/close main and mini windows, lock/unlock, use full screen across Spaces, switch account, sleep/wake, then quit. No duplicate audio, orphaned process, missing menu item or unintentional speaker playback is allowed.

# 12 Audio routes AirPlay and Chromecast

ROUTE01. A single output picker lists available local outputs and verified wireless targets, indicating current route, connection state, route-specific volume and unsupported actions.

ROUTE02. Default to the system output until the user explicitly selects a route. Persist a preferred route ID, not a display name; if unavailable on launch, do not automatically start playing through another route.

ROUTE03. On headphones or external-device disconnection, pause immediately and record a route-loss pause reason. Reconnection does not automatically resume. A remembered route must not override a later user-selected route.

ROUTE04. Include AirPlay discovery, route selection, playback control and recovery through supported macOS audio APIs. Validate physical devices, buffering, latency, volume support and wake/reconnect behavior. Multiroom selection is available only to the extent the native system route exposes and supports it; do not pretend every route supports arbitrary grouping.

ROUTE05. Include Chromecast as an explicit full-release requirement with a separate native provider. Google documents Android, iOS and Web sender SDKs, so a Mac-native route requires independent implementation and real-device validation; an iOS SDK must not be assumed to work in a native Mac target. [Google Cast architecture](https://developers.google.com/cast/docs/overview)

ROUTE06. Resolve whether the receiving device can access the source media and authorized playback context itself. Never give a receiver the user's general Google cookies or refresh tokens. The default Cast receiver is not presumed able to play authenticated YouTube Music URLs.

ROUTE07. Prefer direct receiver playback. If a local Mac relay is technically and contractually required, it must be an explicit local-only service: bounded lifetime, scoped random session token, restricted methods, no filesystem traversal, no public Internet exposure, and no developer backend. Measure the extra CPU/network cost separately.

ROUTE08. Route changes retain the queue and position where possible, mute/stop the old local engine before the new route starts, and reconcile delayed receiver events by session ID. Never allow two uncontrolled simultaneous players.

ROUTE09. Show remote playback position and capability from the receiver, not a guessed local timer. Route loss shows Reconnect or Play here; Play here requires explicit confirmation before starting audio on speakers.

ROUTE10. On explicit Quit while casting, ask whether to stop remote playback or leave it on the device if the receiver supports independent continuation. Remember the choice; default Stop. If the Mac is relaying media, explain that playback cannot continue after quitting.

ROUTE11. AirPods pause/resume and device buttons are handled through supported system events. Do not implement private Bluetooth protocols or promise Apple-exclusive pairing/automatic-switching behavior. Test USB DAC changes and sample-rate transitions without disrupting unrelated applications.

# 13 macOS integration and keyboard behavior

MAC01. Publish title, artist, album, artwork, duration, playback rate, elapsed position and playback state through MediaPlayer Now Playing APIs. Register the supported remote commands and relinquish ownership when inactive. Let macOS decide which system surfaces display this information. [Now Playing](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) · [Remote commands](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)

MAC02. Handle hardware media keys and supported accessory commands through the public command system. Do not install a global keyboard tap to steal controls from other media apps.

MAC03. App Intents and App Shortcuts expose play/pause/resume, next/previous, seek, play song/album/artist/playlist/mix, search, like/save, queue, show player and set a sleep timer. Resolve entities against the current account and disambiguate ambiguous titles. Source-dependent mutations retain the same confirmation and entitlement rules as in-app actions.

MAC04. Adopt applicable audio schemas and media search integration where their deployment-platform availability is confirmed. Test actual Siri phrases such as Play my Supermix in this app and Like this song. Shortcuts support alone must not be marketed as proof that every natural-language Siri request works. Siri language availability follows the OS and cannot be promised for every translated UI language. [App Intents](https://developer.apple.com/documentation/appintents) · [Audio schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)

MAC05. Provide Spotlight indexing of opted-in saved public catalog items and app actions. Private playlists/history are excluded by default. Removing an account removes its indexed private entities.

MAC06. Include a small and medium native widget showing the last/current item and supported transport actions. Display cached data; no independent player or continuous polling. Locked or signed-out accounts use a redacted state.

MAC07. Support canonical YouTube Music links, accepted YouTube song/video links and an app URL scheme. Validate link hosts, identifiers and action parameters. A link opens a native destination and never executes arbitrary commands. Only register universal links for a domain the project actually controls.

MAC08. Native menu commands, Services/share integration where appropriate, drag-and-drop of supported links, Login Items registration, native notifications and standard Settings behavior must be present. Request permissions only for a user-invoked function.

MAC09. Optional global shortcuts for show/hide, play/pause and next/previous are configurable and unassigned by default. Detect conflicts and avoid overriding system shortcuts.

MAC10. Native accessibility, full-screen behavior, window tiling, Spaces, trackpad scrolling, back/forward gestures and standard text controls follow the target macOS conventions.

MAC11. Provide a documented AppleScript dictionary for transport, current-track metadata, queue insertion and opening a service URL. AppleScript actions use the same command layer; do not expose account tokens or raw authenticated requests.

MAC12. Handoff activities may advertise public content URLs and navigation context, without private credentials. Actual continuation depends on a compatible receiving application; no iPhone companion or Spotify Connect-like server is implied.

| Shortcut | Default action |
| - | - |
| Command-F | Focus search |
| Command-K | Open command palette |
| Space | Play/pause when focus is not editing text or another control |
| Command-Right / Command-Left | Next track / previous behavior |
| Command-Shift-Right / Command-Shift-Left | Seek forward/back |
| Command-L | Reveal current item |
| Command-Option-Q | Show queue |
| Command-M | Standard macOS minimize |
| Command-Shift-M | Open or focus mini-player |
| Command-comma | Settings |
| Command-W / Command-Q | Close active window / quit application |

All shortcuts appear in native menus, use localized labels, and can be remapped where sensible without changing standard macOS editing behavior.

# 14 Visual design and motion

DESIGN01. Follow current macOS Human Interface Guidelines, native window chrome, semantic colors, SF Symbols and platform typography. Build an original visual identity using music artwork and restrained color. No custom imitation traffic lights, web-style title bar or mobile UI stretched across a desktop.

DESIGN02. Use a clear sidebar/content/bottom-player structure. Default main window size is approximately 1240 by 820 points with a minimum near 840 by 560; smaller screens collapse secondary panels rather than clipping controls.

DESIGN03. Home and Explore use expressive artwork grids. Library, playlists and queue use compact readable rows. Resizable sidebar is approximately 200–280 points; an optional trailing queue/lyrics panel is approximately 300–420 points. All dimensions adapt to text, localization and accessibility.

DESIGN04. Bottom player includes artwork and metadata, transport, timeline, volume, output and queue. Less common actions live in native context menus and Settings. The progress indicator is stable while artwork loads.

DESIGN05. Follow system light/dark appearance by default, with Light and Dark overrides. Extract a subdued accent palette from the current artwork off the main thread. Ensure contrast independently of album colors. Transparent materials are applied selectively, never as a readability obstacle.

DESIGN06. Define reusable native components: MediaRow, ArtworkCard, SectionShelf, TransportBar, QueueList, LyricsPanel, DownloadRow, AccountSwitcher, RoutePicker, ErrorState and EmptyState. Consistent focus, hover, disabled and pending states are required.

| Interaction | Motion specification |
| - | - |
| Hover and press | 80–140 ms opacity/scale feedback; no layout reflow |
| Navigation | 180–240 ms restrained directional or crossfade transition |
| Artwork expansion | 280–360 ms continuous geometry transition into Now Playing |
| Queue reorder | Interactive movement follows the pointer; stable insertion marker |
| Play/pause | Short symbol transition; transport action executes immediately |
| Artwork color change | 600–900 ms subdued interpolation, only while visible |
| Lyrics | 180–260 ms movement/highlight when timing exists |
| Mini-player expansion | 200–280 ms interruptible layout transition |
| Loading replacement | 100–160 ms crossfade without jumping content |

MOTION01. Durations are design tokens, not mandatory delays. Every transition can be interrupted or reversed; no animation queues up navigation or delays playback.

MOTION02. Scrolling follows the display's actual refresh rate. Use frame pacing and hitch measurements rather than running a hardcoded 120 Hz timer. Playback progress uses a media clock and efficient presentation updates, not whole-view invalidation every frame.

MOTION03. Low Power Mode removes decorative background motion, reduces expensive materials and stops autoplay previews. Preserve clear transport and navigation feedback. Reduce Motion uses immediate state changes or short opacity transitions and never parallax or moving gradients.

MOTION04. Hidden, minimized, occluded and background windows stop decorative rendering. Static artwork remains static; the app must not continuously animate merely to look active.

MOTION05. No full-screen shimmer or infinite decorative animation by default. Loading placeholders appear only when needed and are bounded. Show cached content immediately; replace only the changed section.

DESIGN07. Artwork assets are source content. App icons, welcome art and screenshots use original or properly licensed assets; do not use YouTube or Apple logos in a way that implies an official app.

# 15 Accessibility and localization

A11Y01. Complete keyboard-only navigation, predictable focus order, visible focus rings, standard menu accessibility and VoiceOver labels/actions are required. Reordering, downloading and route selection must have non-drag alternatives.

A11Y02. Honor Reduce Motion, Reduce Transparency, Increase Contrast and system text preferences. Provide scalable content text; fixed-height rows must expand or use an accessible alternate layout.

A11Y03. Use WCAG AA contrast as a project target: 4.5:1 for normal text and 3:1 for large text/important control boundaries. Album art may decorate but cannot carry essential text without a contrast layer.

A11Y04. Announce significant transport/error/account changes, not every playback second or lyric line. Explicit content, download status and selection cannot be conveyed by color alone.

A11Y05. Error messages identify the failed action and a useful recovery. Destructive actions name the affected object or count. Screen-reader users can inspect timing, queue segments and current output.

L10N01. English is the source language. Ship a broad, explicit European locale set rather than leaving all European languages undefined. Include the official EU languages and the additional languages listed below; locale variants share translations where appropriate but respect formatting and script.

| Group | Locale identifiers |
| - | - |
| EU languages | bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, ga, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv |
| Additional national and regional languages | ru, uk, be, nb, nn, is, sq, bs, mk, sr, sr-Latn, tr, ca, eu, gl, cy, gd, rm, lb, ka, hy, az, fo |
| Regional formatting variants | en-GB, en-US, fr-CH, de-CH, it-CH, pt-PT and applicable system-selected region formats |

L10N02. Use String Catalogs, plural rules, localized dates/numbers, natural sorting and locale-aware search. Never assemble translated sentences from fragments. Preserve artist/song names as supplied.

L10N03. UI language, source content language and content region are separate settings. Default UI language to macOS; fall back to English only when the requested translation is absent. Source region does not bypass geographic restrictions.

L10N04. Include pseudo-localization and long-text layouts. Support Unicode and mixed scripts even when a content language is not an interface locale. Layout architecture must tolerate right-to-left content.

L10N05. All shipped locales require complete core strings, reviewed authentication/error/privacy wording, and layout tests. Machine translation may seed catalogs, but generated text alone is not evidence of translation quality.

L10N06. The release manifest lists exactly which locale catalogs are complete. It must not advertise every European language or dialect when only the explicit set above has been implemented.

# 16 Settings and chosen defaults

Use native Settings categories. Most users should sign in, choose music and play without configuration.

| Setting | Default |
| - | - |
| Appearance | System |
| Artwork accent | Enabled, subdued |
| Motion | Full while visible; follows system accessibility and power state |
| Launch at login | Off |
| Background control | Menu bar; last window closure keeps eligible playback active |
| Dock icon | Visible with regular windows; hidden when operating only in menu bar |
| Restore session | On, paused after manual launch |
| Headphone disconnect | Pause; no automatic resume on reconnect |
| Crossfade / EQ / normalization | Off / flat and off / off |
| Autoplay radio | On where supported |
| Replace explicit queue | Ask |
| Download storage | 20 GiB aggregate |
| Automatic downloads on expensive networks | Off |
| Output | System default until user selects another |
| Song/video preference | Audio when account and content permit |
| Mini-player always on top | Off |
| New playlist visibility | Private |
| Track-change notifications | Off |
| Download/error notifications | In-app by default; system notifications opt-in |
| Spotlight private library indexing | Off |
| Global shortcuts | Unassigned |
| Analytics and remote crash submission | Off; no analytics SDK |
| Update checking | Ask once; daily background check only after opt-in |
| Automatic installation | Off while playing; explicit restart required |

Audio quality and Smart Downloads were removed from Settings on 2026-11-05. YouTube Music's own player chooses the audio quality, and YouTube Music offers no downloads on the Mac, so neither can be configured. The download engine keeps its Smart Downloads switch for a future source that permits keeping music; nothing shows it today.

Include Settings search, restore defaults per category, account-local cache clearing and a complete local-data reset. Resetting preferences must not delete playlists or remote account content. Display storage breakdown by account and by pinned/automatic/cache data.

# 17 Application architecture

Use a modular Swift application with SwiftUI views, AppKit integration and Swift concurrency. Pin the current stable Xcode/Swift toolchain that supports macOS 27 in the repository and CI configuration. Do not pin an unverified toolchain version in this specification.

| Module | Responsibility and boundary |
| - | - |
| AppShell | Process lifecycle, scenes, windows, menu bar, Settings and dependency composition |
| DesignSystem | Tokens and reusable native components; no service requests |
| Features | Home, Search, Library, Playlists, Downloads, Now Playing, Podcasts and Settings |
| Domain | Stable models, commands, capability rules and use cases without UI or provider JSON |
| AccountSession | Keychain references, account generations, session renewal and active identity |
| YouTubeMusicAdapter | Authentication integration, request construction, parsing, pagination and service mutations |
| StreamResolver | Media variant discovery, authorization context and URL renewal; no UI |
| Playback | Playback actor, engine backends, DSP, position, transitions and gapless scheduling |
| Queue | Occurrence identity, context order, shuffle, repeat, undo and persistence |
| Downloads | Job scheduling, storage, verification, local media access and entitlement renewal |
| Persistence | SQLite, migrations, normalized entities, full-text local search and durable outbox |
| Artwork | Request coalescing, bounded memory/disk caches, downsampling and palette extraction |
| SystemIntegration | Now Playing, App Intents, shortcuts, widgets, Spotlight, login items and AppleScript |
| OutputRoutes | Local/Core Audio, AirPlay and Cast providers with explicit capabilities |
| Diagnostics | Redacted local logs, signposts, performance counters and user-exported support bundle |

ARCH01. SwiftUI views render feature-scoped observable state. Do not publish every playback tick into an application-wide observable object. Use a dedicated timeline representation and update coarse labels only at the required cadence.

ARCH02. MainActor owns UI mutation. Session, playback, database and download coordinators have explicit actor isolation. Media decoding, network parsing, image decoding, hashing and collection diffing run off the main thread. Never block the audio render callback or main thread on disk/network access.

ARCH03. The command layer is the only path to playback and remote account mutations. Mouse actions, Siri, widgets and AppleScript invoke the same use cases and permission checks.

ARCH04. Inject a clock, network transport, credential store, persistence store, playback engine and provider capabilities. Use deterministic fake providers for tests; live adapters remain replaceable.

ARCH05. Prefer native frameworks and a small dependency set. Do not ship Python, Node, a browser runtime, a remote executable-update system or a dependency that requires one. Native C/C++ libraries are acceptable only for a measured requirement, with compatible licensing and reproducible builds.

ARCH06. Keep YouTube protocol details isolated. Internal identifiers and continuation tokens must not be spread through view code. Maintain sanitized fixtures for observed provider responses, including absent fields, mixed content and unknown variants.

ARCH07. A reference library's claimed feature support does not replace a tested Swift implementation. Adapter changes must preserve typed contracts and fail locally when upstream formats change. Do not remotely download and execute new adapter code.

ARCH08. For collection rows, use stable identities, incremental loading and bounded view creation. If measured SwiftUI list/grid performance cannot meet budgets, use an AppKit collection/table implementation inside the same native feature.

ARCH09. Package the widget and intent extensions with shared access to a minimal App Group snapshot and command channel. They do not receive general Google credentials or create independent playback/network sessions.

ARCH10. No cloud state store, account proxy or developer media relay is required. GitHub release hosting and an optional static update feed are distribution infrastructure, not a playback backend.

# 18 Domain contracts and persistent data

Define typed service boundaries rather than allowing screens to assemble endpoint calls.

| Contract | Required operations |
| - | - |
| MusicCatalog | Home sections, search/suggestions, entity details, paginated library, radio/tuner and canonical links |
| AccountService | List identities, authenticate, refresh, capabilities, switch, revoke and remove local identity |
| LibraryService | Save/remove, like/dislike, follow/unfollow, history controls and reconciliation |
| PlaylistService | Read pages, create/edit/delete, add/remove/move occurrences, collaboration and suggestions |
| PlaybackResolver | Resolve variants, validate eligibility, refresh media authorization and report service-required events |
| PlaybackEngine | Prepare, play, pause, seek, stop, gain/rate, next-item scheduling, state and failure events |
| OfflineMediaStore | Resolve local asset, verify integrity, validate entitlement, pin/unpin and delete |
| RouteProvider | Discover, connect, disconnect, capabilities, remote transport and session state |
| LyricsProvider | Source lyrics, timing if present, attribution and availability |
| MutationOutbox | Enqueue, reconcile, commit, fail, cancel and report operation status |

Every async result includes the account context and request generation when user-specific. Returned errors distinguish unauthorized, forbidden, unsupported, unavailable content, region restriction, rate-limited, offline, malformed response, expired media and transient transport failure.

| Entity | Key fields and invariants |
| - | - |
| Account | Local UUID, stable service identity, channel identity, region, display name and Keychain reference |
| AccountCapabilities | Feature states, source, checked time, expiry and account/region context |
| MediaItem | Stable service ID, kind, title, artists, duration, artwork refs, explicit flag and availability |
| Album / Artist / Podcast | Stable ID, metadata, related entities and pagination context |
| Playlist | Owner identity, privacy, permissions, provider version when available and local snapshot version |
| PlaylistItem | Provider occurrence ID or stable synthetic occurrence identity; never track ID alone |
| QueueSession | Account, queue version, current occurrence, position, shuffle seed, repeat and autoplay |
| QueueEntry | Unique occurrence ID, media ref, source segment, original order and consumed state |
| PlaybackSnapshot | Session generation, state, item, monotonic clock anchor, rate, route and pause reason |
| MediaVariant | Codec/container, actual quality metadata, expiry, seekability and protected authorization reference |
| DownloadJob | Account, media/variant, ranges, state, size, retries, references and verification |
| OfflineEntitlement | Source-granted rights, expiration/renewal data and last validation outcome |
| LibraryMembership | Account/entity pair, service status, pending operation and local sort data |
| HistoryEntry | Account, item, actual listening timestamps, source/local provenance and sync state |
| PendingMutation | Operation UUID, account, target, intent, precondition, attempts and outcome |
| ArtworkCacheEntry | Source key, dimensions, cache policy, content hash and usage |
| Preferences | Global, account and window scopes with schema version |

DATA01. Use SQLite with transactional migrations, WAL where appropriate, indexes for account/collection access and full-text local search. Do not load the entire library or all artwork into memory to render one page.

DATA02. Credential values and reusable signed media authorization are not ordinary database fields. Persist only references where possible; secrets remain in Keychain or ephemeral memory.

DATA03. Use one active-account generation and one playback generation to reject stale asynchronous events. Switching items, accounts or routes invalidates obsolete completions.

DATA04. A database migration is atomic and recoverable. Keep a versioned backup before a destructive migration, check free space, and restore on failure. New app versions must not silently erase library state to recover from a schema error.

DATA05. All app-private files use least-access permissions. Media encryption does not imply that every local metadata field is encrypted. Disclose actual storage behavior and minimize private metadata retention.

DATA06. Use wall-clock timestamps for user-visible history and server expiry, and a monotonic clock for playback and latency. Reconcile wall-clock changes without bypassing entitlement validation.

DATA07. Keep a bounded recent queue/history representation in memory. Retain full durable history according to user settings and applicable source rules; clear it without affecting unrelated remote content.

# 19 State transitions synchronization and recovery

The playback coordinator has explicit states: idle, resolving, preparing, ready, playing, paused, buffering, seeking, ended and failed. Source advertising is a playback segment with its own restrictions, not a second independent player. Remote playback adds a route session while retaining one transport owner.

| Event | Required transition or effect |
| - | - |
| Play selected item | Resolve identity/eligibility, prepare media, then play when ready |
| User pauses during preparation | Record paused intent; preparation completion cannot start audio |
| Temporary network loss | Buffer or pause; preserve intent and position |
| Headphone disconnection | Pause with route-loss reason; cancel any auto-resume |
| Account switch | Stop old session, invalidate generations, restore new account paused |
| Seek while resolving | Retain latest seek target and apply after preparation |
| Stream expiry | Refresh once and restore position when permitted |
| End of item | Apply repeat/queue/autoplay rules; no duplicate advancement |
| Actual system sleep | Checkpoint state; reconcile route and intent on wake |
| Explicit quit | Stop/checkpoint, cancel background work and exit |
| Source entitlement revoked | Stop affected playback/access and explain the source restriction |

SYNC01. The service is authoritative for remote playlists, saved items, likes and supported history. The Mac is authoritative for window layout, local queue, preferences and local-only enhancements.

SYNC02. Show cached data first, then refresh visible collections when stale. Use source cache headers and retention restrictions. Coalesce identical reads and avoid full library scans on every launch or foreground event.

SYNC03. Default metadata staleness thresholds: 5 minutes for visible dynamic Home/history, 15 minutes for visible library membership and 24 hours for stable catalog metadata, unless source policy or a mutation requires earlier refresh. Hidden-window timers do not trigger continuous polling.

SYNC04. Optimistic mutations have pending, confirmed, failed and needs-reconciliation states. A successful HTTP transport response is not enough if the provider reports an operation failure.

SYNC05. Preserve operation IDs locally. For endpoints without idempotency support, a timeout after submission is an ambiguous outcome; read the remote state before retrying. Never duplicate playlist entries because a response was lost.

SYNC06. Reconcile playlist reorder against occurrence identities. If the remote collection changed concurrently, merge nonconflicting operations. When intent is ambiguous, preserve both snapshots and ask the user to choose the specific conflicting result. Do not silently replace the whole remote playlist.

SYNC07. Offline mutations can queue only when meaningful and authorized. Show Pending sync. A feature implemented locally because no remote operation exists must display Local only and must never appear as successfully synchronized.

SYNC08. Playback history must reflect actual listening events and the service's semantics. Do not manufacture plays, likes, completed episodes or recommendation signals to approximate missing APIs.

SYNC09. Rate-limit requests per account and host; start with a maximum of six in-flight metadata requests and two media downloads, reducing under contention. Honor Retry-After and use bounded exponential backoff with jitter. Authentication failure must not become a retry storm.

SYNC10. Maintain remote pagination cursors only within their valid context. If a cursor expires, restart safely and deduplicate by stable occurrence identity. Do not assume a cursor is portable between accounts or regions.

SYNC11. Network reachability is a hint, not proof that a request will succeed. Captive portals, DNS failures, 403, 429, 5xx and malformed data have distinct diagnostics and appropriate user actions.

SYNC12. A provider schema failure should disable only the affected feature with a useful error while keeping existing eligible playback and cached browsing available. Do not label a degraded feature complete in release acceptance.

# 20 Performance and energy acceptance budgets

These are adopted engineering targets, not measured results. Validate on the reference machine with the actual RAM, screen mode, OS build, route, app build and power conditions recorded. Use release builds and repeatable datasets.

Primary audio tests use an already authenticated account, 50 Mbps or faster network, median RTT no higher than 40 ms, zero injected loss, and actual source media. Also test constrained and offline conditions separately. Do not count browser sign-in time, source advertising duration or network outages as local UI rendering time, but report total end-to-end wait alongside component timing.

| Metric | Acceptance target |
| - | - |
| Cold process launch to interactive cached shell | p95 at most 1,000 ms; no network dependency |
| Warm reopen of main window | p95 at most 250 ms |
| Cached navigation | p95 at most 100 ms |
| User action to visible transport feedback | p95 at most 50 ms |
| Play command to first decoded audible sample | p95 at most 2,000 ms under the primary audio conditions |
| Cached offline item start | p95 at most 250 ms |
| Local library query | p95 at most 50 ms on 50,000 indexed items |
| Scroll and transition cadence | Follow actual 60/120 Hz display; fewer than 1% missed display intervals in the standard interaction trace |
| Long visible hitch | No attributable main-thread stall over 100 ms in the standard trace |
| Hidden audio-only app CPU | Mean at most 2% of one logical core over 10 minutes after warm-up |
| Paused hidden CPU | Mean at most 0.2% of one logical core, excluding an explicit task |
| Hidden steady audio memory | Physical footprint at most 200 MiB |
| Visible normal browsing memory | Physical footprint at most 350 MiB for the standard fixture |
| Eight-hour audio soak | No crash, unexpected stop or unbounded memory/resource growth |
| Post-warm-up memory trend | At most 20 MiB sustained growth over the soak after cache stabilization and comparable state |
| Decorative background rendering | Zero ongoing decorative animation work while all windows are hidden |

PERF01. Record p50, p95 and worst case. Use at least 50 launches for startup, 200 item-start samples across a representative corpus, and repeated scripted scrolling/navigation traces. Report failed operations separately; do not omit failures to improve percentile statistics.

PERF02. CPU is aggregated across all app-owned processes and helpers; 100% means one fully utilized logical core. Also record attributable system audio/network activity and route differences instead of hiding them outside the app number.

PERF03. Memory is physical footprint, not only Swift heap size. Include extensions during relevant tests. Separate audio, video, casting and bulk download scenarios; audio budgets cannot be claimed for an unrelated empty screen.

PERF04. The standard dataset includes 50,000 catalog/library items, 1,000 playlists, a 10,000-entry playlist, a 5,000-item queue, mixed artwork sizes and duplicate occurrences. These are synthetic stress fixtures, not assertions about service limits or the user's actual library.

PERF05. Use Instruments Time Profiler, SwiftUI profiling, Allocations/Leaks, animation hitches, signposts and energy diagnostics. Compare against the official web experience under matched content, route and quality; publish observed ratios without claiming automatic superiority from the language choice. [SwiftUI performance tooling](https://developer.apple.com/videos/play/wwdc2025/306/)

PERF06. Artwork is downsampled to display size before decode, coalesced by URL/size and capped at 64 MiB memory by default with pressure-aware eviction. The disk artwork cache defaults to 512 MiB, governed by source cache rules. Avoid synchronous disk reads while scrolling.

PERF07. Prefetch only nearby visible content and the next eligible playback item. Cancel speculative work on fast navigation or account switch. Do not prefetch entire albums into RAM merely to improve one benchmark.

PERF08. Recalculate expensive color palettes once per artwork variant. Avoid full-view invalidation on progress, volume or network-byte updates. Persist position periodically and on transitions, not every rendered frame.

PERF09. Benchmarks run on AC and battery, in normal and Low Power Mode, on 60 Hz and ProMotion screens, and with local and wireless output. Log thermal pressure and low-power state.

PERF10. If a target is missed, identify the attributable bottleneck and repair or explicitly revise the target with evidence. Do not quietly redefine the test or remove functionality to claim success.

# 21 Privacy security and diagnostics

SEC01. No developer-operated telemetry, listening-history collection, advertising SDK or remote crash reporting. A user may explicitly export a redacted diagnostic bundle. The app remains functional without sending diagnostics.

SEC02. Enumerate network destinations by purpose: Google authentication/music/media/artwork, selected local devices, and opt-in update hosting. Do not send account data to an unrelated service for search, lyrics, translation or recommendations.

SEC03. Logs redact cookies, authorization headers, tokens, signed query parameters, email addresses, private playlist names and private search strings. Use opaque local correlation IDs. Diagnostic export offers a preview and excludes media files and credentials.

SEC04. Use Keychain for secrets, standard TLS validation and secure session callbacks. Do not weaken certificate checks, ask for a Google password in app UI, intercept another app's session, or depend on browser database scraping.

SEC05. Validate all deep links, media URL redirects, source metadata and downloaded artwork. Bound image dimensions, metadata size, decompression cost and media probing. An arbitrary link must not become an unrestricted local network request.

SEC06. Use least-required entitlements, hardened runtime and sandbox-compatible design where technically applicable. Document any direct-distribution entitlement that prevents an App Store build. Request local-network, notification or automation permissions only when the user activates the feature.

SEC07. Background remote mutations are limited to explicit user actions and configured behaviors such as keeping a selected downloaded playlist current. No automated likes, fabricated listening events or unsolicited sharing.

SEC08. Account removal deletes credentials, keys, private snapshots, related indexes and queued writes. A privacy reset can remove all local state without deleting remote playlists or the Google account.

SEC09. Validate update signatures, version ordering and release provenance. No unsigned remote configuration may execute code, change trust policy or reveal credentials.

SEC10. Protect release signing credentials and CI secrets; never include production sessions in fixtures, screenshots, recordings or repository history.

DIAG01. Include a local Diagnostics screen with app/OS version, adapter version, account-capability status without identity secrets, recent error categories, cache sizes, playback engine and actual media quality. Advanced details stay out of normal listening flows.

DIAG02. Collect opt-in profiling locally with bounded files. Keep deterministic reproductions for upstream parser changes and native playback failures. A source outage must be distinguishable from a local crash.

# 22 Repository build and distribution

Create a new GitHub repository when implementation is authorized. This specification does not claim that a repository or application has already been created.

| Repository area | Required contents |
| - | - |
| App | macOS app target, entitlements, composition root and scenes |
| Packages | The modules defined in section 17, with public boundaries and unit tests |
| Extensions | Widget and App Intents targets as required by platform behavior |
| Resources | Assets, String Catalogs, icons and licensed fixtures |
| Tests | Domain, adapter, integration, UI, accessibility and performance suites |
| Fixtures | Sanitized provider response examples and synthetic media/library data |
| Docs | This specification, architecture decisions, service capability matrix and contributor guide |
| Build scripts | Reproducible local build, test, packaging and verification commands |
| GitHub workflows | Build/test checks, dependency/license checks and signed release packaging |

BUILD01. Use Swift Package Manager for dependencies and a checked-in Xcode project or deterministic project generation with a documented command. Pin dependencies and the toolchain; a clean checkout must build without private developer files.

BUILD02. Keep development fixtures separate from live credentials. Automated pull-request tests run without Google accounts. Live integration tests use separately provisioned accounts and never run against the user's personal playlists without a deliberate test action.

BUILD03. Provide original-code LICENSE, dependency notices, README, CONTRIBUTING, SECURITY, privacy statement, screenshots using nonprivate data, and a feature/capability matrix. Explain independent project status.

BUILD04. Produce an arm64 release app and DMG, checksum, release notes, source tag and dependency inventory. Sign with Developer ID, enable hardened runtime, notarize and staple the result. Source builds remain available when a contributor lacks signing credentials.

BUILD05. A free application may still require developer distribution infrastructure and Apple signing credentials; the user-facing app must never turn those costs into mandatory app purchases.

BUILD06. For direct distribution, use a maintained native updater such as Sparkle only after checking current compatibility and licensing. Host a signed static update feed with release assets. Ask before enabling automatic checks and avoid update installation during playback. An App Store build uses the store's update mechanism.

BUILD07. The GitHub release is the primary delivery path. An App Store variant must use the same core functionality for eligible accounts and cannot hide features from review or activate unreviewed downloading later.

BUILD08. No public repository, release, App Store submission or signing identity is created by the act of writing this specification.

# 23 Verification and complete release acceptance

Every feature in the inventory must map to an implementation, an automated test where appropriate, and a manual verification when external hardware or live service behavior is involved. Native mock data is useful for tests but cannot demonstrate live integration success.

| ID | Acceptance scenario |
| - | - |
| AC01 | Clean install, browser authentication, cancel sign-in, reconnect and revoked-session recovery |
| AC02 | Free and Premium accounts both sign in; account-specific capabilities and actual source advertising are correct |
| AC03 | Two accounts and channel identities remain isolated during concurrent search, mutation and download work |
| AC04 | Home, Explore, artist, album and song pages load real service data with complete pagination |
| AC05 | Search filters, suggestions, typos, Unicode and offline local results work without stale-query replacement |
| AC06 | Library save/remove, like/dislike and follow operations confirm against remote state |
| AC07 | Create, edit, reorder, share and delete owned playlists; collaborative roles are respected |
| AC08 | Duplicate tracks and a timed-out mutation do not cause accidental deletion or duplicate additions |
| AC09 | Remote edits made in YouTube Music reconcile with pending local changes |
| AC10 | Native playback starts, pauses, seeks, advances and renews expiring media across representative content |
| AC11 | Delivered Premium quality is measured and shown accurately; unavailable metrics remain unknown |
| AC12 | Gapless and crossfade pass timing tests; EQ/normalization actually affect the selected native engine |
| AC13 | Shuffle/repeat/play-next/add-to-queue and undo preserve occurrence identity and order; sleep timers pause at the intended boundary |
| AC14 | Queue and position recover after crash/restart without unexpected autoplay |
| AC15 | Temporary network loss recovers; user pause or route-loss pause prevents auto-resume |
| AC16 | Music videos, audio/video switching, native full screen and supported PiP preserve correct state |
| AC17 | Podcast progress, chapters, speed, saved episodes and eligible downloads operate correctly |
| AC18 | Reserved — music uploads removed from scope (2026-11-04) |
| AC19 | Source lyrics render correctly; missing lyrics and timing do not produce invented content |
| AC20 | Samples, tuner, radio, Recap, badges and source-present social flows match available service behavior |
| AC21 | Downloads survive disconnect and restart, validate integrity and enforce actual entitlement |
| AC22 | Download quota, disk-full, expired URLs, corruption, reauthentication and playlist changes recover safely |
| AC23 | Closing the last window keeps eligible playback and menu bar controls; Dock behavior matches the contract |
| AC24 | Multiple windows and mini-player share one playback session without focus theft |
| AC25 | Lock, sleep, wake, login launch and explicit quit follow section 11 |
| AC26 | Removing headphones or a selected output pauses without speaker leakage or automatic reconnect playback |
| AC27 | Local outputs, a real AirPlay target and a real Cast target pass selection/control/reconnect tests |
| AC28 | Now Playing metadata, media keys and supported accessory actions match current playback |
| AC29 | Siri and Shortcuts scenarios are tested on the actual deployment platform and supported languages |
| AC30 | Widgets, Spotlight opt-in, links, share actions, AppleScript and login items use the same account/command rules |
| AC31 | Keyboard-only operation and VoiceOver cover sign-in, browsing, queue, downloads and settings |
| AC32 | Reduced Motion, increased contrast, reduced transparency and long-text translations remain usable |
| AC33 | All declared locale catalogs are complete and reviewed; search/content language remains separate |
| AC34 | Performance budgets pass on the reference Mac with reproducible reports |
| AC35 | Eight-hour playback and memory/resource soak tests complete successfully |
| AC36 | Logs, exports, callbacks, storage and account removal pass credential/privacy checks |
| AC37 | Adverse provider responses, 403/429/5xx, captive portal and malformed data produce bounded recovery |
| AC38 | Database migration failure restores a usable state without deleting user data |
| AC39 | Clean source checkout builds and tests without private credentials |
| AC40 | Signed/notarized DMG installs and launches; signature/checksum/update checks reject tampered artifacts |
| AC41 | Every required service gate G01–G09 has attached evidence; no unresolved native playback/offline/casting gate is silently waived |
| AC42 | No placeholder button, hidden browser playback, unimplemented setting or fabricated synced state exists in the release |

Testing layers:

- Domain tests cover queue semantics, account generation, capability resolution, conflict handling, retry rules and pause reasons.

- Property-based tests cover duplicate occurrences, shuffle restoration, repeated pagination and mutation replay.

- Adapter contract tests use sanitized fixtures for each supported response shape, including unknown fields and partial responses.

- Engine integration tests use owned or licensed test audio with known boundaries, injected failures, audio-route changes and bounded resource measurements.

- UI tests cover navigation, keyboard behavior, screen-reader labels, window lifecycle and state restoration.

- Live service tests verify account-dependent behavior, native streams, source write confirmation and offline access.

- Hardware tests verify real AirPlay, Cast, Bluetooth/headphones and external displays.

- Release tests verify installation, signatures, updates, migrations and crash recovery.

A test result must record app commit, adapter version, OS build, account class, source/content conditions and test device. Do not report a mock pass as a live pass.

Full release acceptance requires all mandatory behaviors and all applicable account-eligible scenarios to pass. Genuine service restrictions are tested behavior, not missing implementation. An integration the developer has not solved is an unresolved requirement, even if the UI explains that it is unavailable.

# 24 Engineering decisions and evidence references

The remaining product choices have been resolved here: broad account support, browser-only authentication, menu-bar background operation, pause on output loss, private default playlists, separate account state, one shared player with multiple optional windows, complete offline management, all stated native integrations, and GitHub distribution. There is no delivery schedule.

The unresolved items are technical evidence requirements rather than unanswered preferences: authenticated native media access, correct free-account advertising, Premium stream quality, offline entitlement, native Cast playback, and the exact Siri/platform capabilities. Resolving them can change the internal adapter/engine design. Removing a mandatory feature would require an explicit change to the product contract; it is not authorized by this specification.

| Source | What it establishes |
| - | - |
| [Apple macOS versions](https://support.apple.com/en-us/109033) | Current major system baseline |
| [YouTube Music account features](https://support.google.com/youtubemusic/answer/6313529?hl=en) | Free/Premium service distinctions and podcast exceptions |
| [YouTube audio quality](https://support.google.com/youtubemusic/answer/9076559?hl=en) | Documented quality settings; not proof of this client's access |
| [YouTube Data API reference](https://developers.google.com/youtube/data/reference/rest) | Scope of the documented public data API |
| [YouTube developer policies](https://developers.google.com/youtube/terms/developer-policies) | Applicable API constraints; not a substitute for validating the chosen access route |
| [ytmusicapi project documentation](https://ytmusicapi.readthedocs.io/en/stable/) | Existing unofficial metadata/account-operation research |
| [Apple AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) | Native media playback framework |
| [Apple Now Playing](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) | System metadata integration |
| [Apple App Intents](https://developer.apple.com/documentation/appintents) | System actions and discovery |
| [Apple audio schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-audio) | Audio intent model requiring platform validation |
| [Google Cast overview](https://developers.google.com/cast/docs/overview) | Sender/receiver architecture and documented SDK platforms |
| [Apple SwiftUI profiling](https://developer.apple.com/videos/play/wwdc2025/306/) | Performance measurement tooling |
| [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | Conditions relevant to optional App Store distribution |

Source documentation describes the external services and frameworks. The detailed UI behavior, defaults, architecture, budgets, locale set and test contract are engineering decisions made for this application. No benchmark, permission, stream entitlement or integration result is claimed to have been validated by writing this specification.
