#!/usr/bin/env python3
"""Builds the W12 library fixtures from rows of the REAL anonymous captures in ../W11-real.

Library and history pages need the signed session, so no anonymous capture of them exists. Everything here is therefore
`synthetic-from-real-renderers`: the containers are hand-assembled in the shapes the web client uses for library tabs, and every
entry inside them is copied from a real capture (musicResponsiveListItemRenderer, musicTwoRowItemRenderer,
musicMultiRowListItemRenderer) with only the edits listed next to it. Three things are ASSUMPTIONS no capture shows and are
marked `assumed`: the "Shuffle all" row of a songs list, the "New playlist" tile of the playlists grid, and the signed-in form of
the write endpoints (a signed page replaces the real captures' sign-in prompt with the endpoint named in the toggle). The write
responses in write-*.json are assumed shapes as well. All of it is on the end-of-project live check list (Docs/Library.md).

Run from the repository root:  python3 -I Fixtures/W12/generate.py
"""
import copy, hashlib, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.join(HERE, "..", "W11-real")

def load(name):
    with open(os.path.join(REAL, name)) as f:
        return json.load(f)

album = load("browse-album.json")
home = load("browse-home.json")
artist = load("browse-artist.json")
charts = load("browse-charts.json")
podcast = load("browse-podcast.json")
new_releases = load("browse-new_releases.json")

def column(doc, secondary=False):
    contents = doc["contents"]
    if "twoColumnBrowseResultsRenderer" in contents:
        two = contents["twoColumnBrowseResultsRenderer"]
        return two["secondaryContents"]["sectionListRenderer"] if secondary else two["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]
    return contents["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]

def walk(node, visit):
    if isinstance(node, dict):
        visit(node)
        for v in list(node.values()): walk(v, visit)
    elif isinstance(node, list):
        for v in node: walk(v, visit)

def shelf_rows(doc, kind="musicShelfRenderer", secondary=True):
    for section in column(doc, secondary)["contents"]:
        if kind in section and section[kind].get("contents"): return section[kind]["contents"]
    raise SystemExit("no " + kind)

def carousel_items(doc, index):
    sections = [s for s in column(doc)["contents"] if "musicCarouselShelfRenderer" in s]
    return sections[index]["musicCarouselShelfRenderer"]["contents"]

album_rows = shelf_rows(album)                                   # 13 real track rows (with playlistSetVideoId)
home_albums = carousel_items(home, 1)                            # 10 real album cards ("New releases")
playlist_cards = []
for section in column(artist)["contents"]:
    items = section.get("musicCarouselShelfRenderer", {}).get("contents", [])
    if items and all(i.get("musicTwoRowItemRenderer", {}).get("title", {}).get("runs") for i in items):
        pages = set()
        walk(items, lambda n: pages.add(n["pageType"]) if "pageType" in n else None)
        if pages & {"MUSIC_PAGE_TYPE_PLAYLIST"} and "MUSIC_PAGE_TYPE_ALBUM" not in pages: playlist_cards = items; break
if not playlist_cards:
    for section in column(new_releases)["contents"]:
        for item in section.get("musicCarouselShelfRenderer", {}).get("contents", []):
            pages = set(); walk(item, lambda n: pages.add(n["pageType"]) if "pageType" in n else None)
            if "MUSIC_PAGE_TYPE_PLAYLIST" in pages and "MUSIC_PAGE_TYPE_ALBUM" not in pages: playlist_cards.append(item)
artist_rows = [r for s in column(charts)["contents"] for r in s.get("musicCarouselShelfRenderer", {}).get("contents", []) if "musicResponsiveListItemRenderer" in r]  # 40 ranked artist rows
episodes = shelf_rows(podcast, "musicShelfRenderer", True)

def token(value): return {"nextContinuationData": {"continuation": value, "clickTrackingParams": "synthetic"}}
def single(contents, header=None):
    page = {"responseContext": {}, "contents": {"singleColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": contents}}}}]}}}
    return page

def strip_occurrence(row):
    row = copy.deepcopy(row)
    data = row["musicResponsiveListItemRenderer"].get("playlistItemData")
    if data: data.pop("playlistSetVideoId", None)
    return row

def signed_in_save(card, saved=True):
    """Signed-in form of a card's library toggle: the sign-in prompt is replaced by the like endpoint the toggle itself names."""
    card = copy.deepcopy(card)
    def visit(node):
        toggle = node.get("toggleMenuServiceItemRenderer")
        if not toggle: return
        target = toggle.get("toggledServiceEndpoint", {}).get("likeEndpoint", {}).get("target")
        if not target: return
        toggle["isToggled"] = saved
        toggle["defaultServiceEndpoint"] = {"clickTrackingParams": "synthetic", "likeEndpoint": {"status": "LIKE", "target": target}}
    walk(card, visit)
    return card

KASET = os.path.join(HERE, "..", "W12-kaset-real", "artist_lofi_girl_episodes_more.json")
def real_signed_toggles():
    """The 'Mark as played' and 'Pin to Listen again' toggles exactly as a REAL signed capture (Kaset fixture) publishes them."""
    doc = json.load(open(KASET)); found = {}
    def visit(node):
        t = node.get("toggleMenuServiceItemRenderer")
        if t:
            icon = t.get("defaultIcon", {}).get("iconType")
            if icon in ("CHECK", "KEEP") and icon not in found: found[icon] = copy.deepcopy(node)
    walk(doc, visit)
    return found["CHECK"], found["KEEP"]

def library_toggle(scheme, n):
    """A signed-in song library toggle. ASSUMED shapes: no capture we hold shows a signed song's library toggle; these follow the
    convention ytmusicapi and Kaset both parse, where each side's ICON names the action its own endpoint performs.
      add-default       default BOOKMARK_BORDER = add token, toggled BOOKMARK = remove token, isToggled false  -> not in library
      kaset-saved       default BOOKMARK = remove token, toggled BOOKMARK_BORDER = add token, isToggled false  -> in library
      toggled-saved     default BOOKMARK_BORDER = add token, toggled BOOKMARK = remove token, isToggled true   -> in library
      ambiguous         both icons name an add action                                                           -> not a library toggle"""
    add = {"clickTrackingParams": "synthetic", "feedbackEndpoint": {"feedbackToken": "synthetic-add-token-%04d" % n}}
    remove = {"clickTrackingParams": "synthetic", "feedbackEndpoint": {"feedbackToken": "synthetic-remove-token-%04d" % n}}
    def toggle(d_icon, d_ep, t_icon, t_ep, toggled):
        return {"toggleMenuServiceItemRenderer": {"defaultText": {"runs": [{"text": "(default)"}]}, "defaultIcon": {"iconType": d_icon}, "defaultServiceEndpoint": d_ep,
                "toggledText": {"runs": [{"text": "(toggled)"}]}, "toggledIcon": {"iconType": t_icon}, "toggledServiceEndpoint": t_ep, "isToggled": toggled}}
    if scheme == "add-default": return toggle("BOOKMARK_BORDER", add, "BOOKMARK", remove, False)
    if scheme == "kaset-saved": return toggle("BOOKMARK", remove, "BOOKMARK_BORDER", add, False)
    if scheme == "toggled-saved": return toggle("BOOKMARK_BORDER", add, "BOOKMARK", remove, True)
    if scheme == "ambiguous": return toggle("BOOKMARK_BORDER", add, "BOOKMARK_BORDER", remove, False)
    raise SystemExit(scheme)

def signed_in_song(row, liked="INDIFFERENT", scheme=None, n=1, extra_toggles=()):
    """Sets the rating's state and replaces the row's library toggle (the real anonymous one, whose add side is a sign-in prompt)
    with the signed form for `scheme` (None: no library toggle), then appends any other toggles unchanged."""
    row = copy.deepcopy(row)
    for node in [row]:
        def visit(n_):
            like = n_.get("likeButtonRenderer")
            if like: like["likeStatus"] = liked
        walk(node, visit)
    items = row["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"]
    items[:] = [i for i in items if not ("toggleMenuServiceItemRenderer" in i and "feedbackEndpoint" in i["toggleMenuServiceItemRenderer"].get("toggledServiceEndpoint", {}))]
    if scheme: items.append(library_toggle(scheme, n))
    items.extend(copy.deepcopy(t) for t in extra_toggles)
    return row

def retype(item, page_type=None, browse_id=None, video_type=None):
    item = copy.deepcopy(item)
    def visit(node):
        if page_type and "pageType" in node: node["pageType"] = page_type
        if browse_id and "browseId" in node and node.get("browseId", "").startswith(("VL", "MPRE", "UC", "MPSP")): node["browseId"] = browse_id
        if video_type and "musicVideoType" in node: node["musicVideoType"] = video_type
    walk(item, visit)
    return item

out = {}
# 1. Library songs: control row (assumed), real track rows without occurrence ids, one song listed twice (both are kept), a token.
shuffle_all = {"musicResponsiveListItemRenderer": {"flexColumns": [{"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Shuffle all"}]}}}],
                                                  "navigationEndpoint": {"watchPlaylistEndpoint": {"playlistId": "LM", "params": "wAEB"}}}}
played, pinned = real_signed_toggles()
SCHEMES = {0: "add-default", 1: "kaset-saved", 2: "toggled-saved", 3: "ambiguous", 4: None, 5: "add-default"}
song_rows = [signed_in_song(strip_occurrence(r), liked="LIKE" if i == 1 else "INDIFFERENT", scheme=SCHEMES.get(i, "add-default"), n=i + 1,
                            extra_toggles=(played, pinned) if i == 4 else ()) for i, r in enumerate(album_rows)]
page1 = [shuffle_all] + song_rows[:6] + [copy.deepcopy(song_rows[2])]
out["library-songs.json"] = single([{"musicShelfRenderer": {"contents": page1, "continuations": [token("LIBSONGS-2")]}}])
out["library-songs-page2.json"] = {"responseContext": {}, "continuationContents": {"musicShelfContinuation": {"contents": song_rows[6:11], "continuations": [token("LIBSONGS-3")]}}}
out["library-songs-page3.json"] = {"responseContext": {}, "continuationContents": {"musicShelfContinuation": {"contents": song_rows[11:13]}}}
# 2. Albums grid: signed-in save toggles (isToggled true), a token.
def kaset_saved_card(card):
    """A saved album card in the convention where the default side is the current state: default BOOKMARK = remove (status INDIFFERENT),
    toggled BOOKMARK_BORDER = add (status LIKE), isToggled false. ASSUMED shape (see library_toggle)."""
    card = copy.deepcopy(card)
    def visit(node):
        toggle = node.get("toggleMenuServiceItemRenderer")
        if not toggle: return
        target = toggle.get("toggledServiceEndpoint", {}).get("likeEndpoint", {}).get("target")
        if not target: return
        toggle["defaultIcon"] = {"iconType": "BOOKMARK"}; toggle["toggledIcon"] = {"iconType": "BOOKMARK_BORDER"}; toggle["isToggled"] = False
        toggle["defaultServiceEndpoint"] = {"clickTrackingParams": "synthetic", "likeEndpoint": {"status": "INDIFFERENT", "target": target}}
        toggle["toggledServiceEndpoint"] = {"clickTrackingParams": "synthetic", "likeEndpoint": {"status": "LIKE", "target": target}}
    walk(card, visit)
    return card
albums1 = [kaset_saved_card(c) if i % 2 else signed_in_save(c) for i, c in enumerate(home_albums[:6])]
out["library-albums.json"] = single([{"gridRenderer": {"items": albums1, "continuations": [token("LIBALBUMS-2")]}}])
# The same two pages with the wrapper layer both reference clients also read: sectionList > itemSection > shelf / grid.
def wrapped(page):
    page = copy.deepcopy(page)
    lst = page["contents"]["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]
    lst["contents"] = [{"itemSectionRenderer": {"contents": lst["contents"]}}]
    return page
out["library-albums-wrapped.json"] = wrapped(out["library-albums.json"])
out["library-songs-wrapped.json"] = wrapped(out["library-songs.json"])
out["library-albums-page2.json"] = {"responseContext": {}, "continuationContents": {"gridContinuation": {"items": [signed_in_save(c) for c in home_albums[6:10]]}}}
# 3. Artists: real ranked-artist rows; the first three carry the library artist page type.
if artist_rows:
    rows = [copy.deepcopy(r) for r in artist_rows[:6]]
    rows = [retype(r, page_type="MUSIC_PAGE_TYPE_LIBRARY_ARTIST") if i < 3 else r for i, r in enumerate(rows)]
    out["library-artists.json"] = single([{"musicShelfRenderer": {"contents": rows}}])
    out["library-following.json"] = single([{"musicShelfRenderer": {"contents": [retype(r, page_type="MUSIC_PAGE_TYPE_LIBRARY_ARTIST") for r in rows]}}])
# 4. Playlists grid: the "New playlist" tile (assumed) then real playlist cards.
new_tile = {"musicTwoRowItemRenderer": {"title": {"runs": [{"text": "New playlist"}]}, "navigationEndpoint": {"createPlaylistEndpoint": {"title": ""}}}}
out["library-playlists.json"] = single([{"gridRenderer": {"items": [new_tile] + [signed_in_save(c) for c in playlist_cards[:4]]}}])
# 5. Podcasts: show cards (a playlist card retyped as a show: the captures hold no show card).
shows = []
for i, card in enumerate(playlist_cards[:2]):
    shows.append(signed_in_save(retype(card, page_type="MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE", browse_id="MPSPPLsyntheticshow%d" % i)))
out["library-podcasts.json"] = single([{"gridRenderer": {"items": shows}}])
# 6. Saved episodes: the real episode rows of the podcast capture.
out["library-saved-episodes.json"] = single([{"musicShelfRenderer": {"contents": episodes[:8]}}])
# 7. Uploads: track rows retyped as the library's uploaded-track type.
out["library-uploads.json"] = single([{"musicShelfRenderer": {"contents": [retype(r, video_type="MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK") for r in song_rows[:4]]}}])
# 8. History: day shelves of real rows; the same song twice on one day; a token.
out["history.json"] = single([
    {"musicShelfRenderer": {"title": {"runs": [{"text": "Today"}]}, "contents": [song_rows[0], song_rows[1], copy.deepcopy(song_rows[0])]}},
    {"musicShelfRenderer": {"title": {"runs": [{"text": "Yesterday"}]}, "contents": [song_rows[3], song_rows[4]], "continuations": [token("HISTORY-2")]}}])
out["history-page2.json"] = {"responseContext": {}, "continuationContents": {"musicShelfContinuation": {"contents": [song_rows[5], copy.deepcopy(song_rows[3])]}}}
# 9. A library page of another kind (an albums page that also holds a playlist and an artist), and pages that must be refused.
mixed = [signed_in_save(home_albums[0]), signed_in_save(playlist_cards[0]), copy.deepcopy(artist_rows[0]) if artist_rows else song_rows[0]]
out["library-albums-wrong-kinds.json"] = single([{"gridRenderer": {"items": mixed}}])
out["library-unrecognised.json"] = single([{"musicFutureShelfRenderer": {"contents": []}}])
out["library-unreadable-only.json"] = single([{"gridRenderer": {"items": [{"musicTwoRowItemRenderer": {"title": {"runs": [{"text": ""}]}}}] * 3}}])
# 10. Write responses (ASSUMED shapes; the live shapes are on the end-of-project list).
out["write-actions.json"] = {"responseContext": {}, "actions": [{"addToToastAction": {"item": {"notificationActionRenderer": {"responseText": {"runs": [{"text": "Done"}]}}}}}]}
out["write-error.json"] = {"error": {"code": 400, "message": "synthetic refusal", "status": "INVALID_ARGUMENT"}}
out["write-actions-empty.json"] = {"responseContext": {}, "actions": []}
out["write-empty.json"] = {"responseContext": {}}
out["write-feedback-processed.json"] = {"responseContext": {}, "feedbackResponses": [{"isProcessed": True}]}
out["write-feedback-not-processed.json"] = {"responseContext": {}, "feedbackResponses": [{"isProcessed": False}]}
out["write-feedback-missing.json"] = {"responseContext": {}, "feedbackResponses": []}
out["write-errors-list.json"] = {"responseContext": {}, "errors": [{"status": "FAILED"}]}

files = []
for name, value in sorted(out.items()):
    data = (json.dumps(value, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
    with open(os.path.join(HERE, name), "wb") as f: f.write(data)
    files.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
manifest = {
    "mode": "synthetic-from-real-renderers",
    "live_eligible": False,
    "description": "Library and history pages for W12. No anonymous capture of a library page exists (they need the signed session), so containers are hand-assembled in the shapes the web client uses for library tabs and every entry is copied from a real anonymous capture in ../W11-real, with only the edits generate.py lists (occurrence ids stripped, signed-in toggle endpoints, retyped page/video types). ASSUMED, shown by no capture: the 'Shuffle all' row, the 'New playlist' tile, the signed-in forms of the library toggles (song feedback tokens in four icon schemes, album/playlist like endpoints in two), the itemSectionRenderer-wrapped variants, and the write responses (write-*.json). The library browseIds are on the end-of-project live check list (Docs/Library.md). Not captures of any response and not live evidence.",
    "browse_ids_relied_on": {
        "songs": "FEmusic_liked_videos", "likedSongs": "VLLM", "albums": "FEmusic_liked_albums", "artists": "FEmusic_library_corpus_track_artists",
        "following": "FEmusic_library_corpus_artists", "playlists": "FEmusic_liked_playlists", "podcasts": "FEmusic_library_non_music_audio_list",
        "savedEpisodes": "VLSE", "uploads": "FEmusic_library_privately_owned_tracks", "history": "FEmusic_history"},
    "files": files,
}
with open(os.path.join(HERE, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1); f.write("\n")
print(len(files), "fixtures written")
