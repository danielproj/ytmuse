#!/usr/bin/env python3
"""Builds the synthetic W11 edge-case fixtures from rows of the REAL captures in ../W11-real.

Everything here is `synthetic-test-only`: the containers (continuation envelopes, an unknown-variants page, adverse
responses) are hand-assembled, the entries inside them are copied unchanged from real responses so row shapes stay real.
Run from the repository root:  python3 -I Fixtures/W11/generate.py
"""
import copy, hashlib, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.join(HERE, "..", "W11-real")

def load(name):
    with open(os.path.join(REAL, name)) as f:
        return json.load(f)

playlist = load("browse-playlist.json")
album = load("browse-album.json")
home = load("browse-home.json")
explore = load("browse-explore.json")
secondary = playlist["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]
rows = secondary["contents"][0]["musicPlaylistShelfRenderer"]["contents"]
album_rows = album["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"][0]["musicShelfRenderer"]["contents"]
home_list = home["contents"]["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]
carousel = home_list["contents"][1]  # "New releases"
explore_list = explore["contents"]["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]

def token(value):
    return {"nextContinuationData": {"continuation": value, "clickTrackingParams": "synthetic"}}

out = {}
# A playlist shelf continuation: the last two rows of the first page repeated (the boundary), then rows not seen before.
out["continuation-playlist-shelf.json"] = {
    "responseContext": {},
    "continuationContents": {"musicPlaylistShelfContinuation": {
        "contents": rows[-2:] + album_rows[:3],
        "continuations": [token("SYNTHETICnextShelfToken-2")],
    }},
}
# The last page of a shelf: entries and no token.
out["continuation-playlist-last.json"] = {
    "responseContext": {},
    "continuationContents": {"musicPlaylistShelfContinuation": {"contents": album_rows[3:5]}},
}
# A page continuation: more sections (Home loading more shelves).
more = copy.deepcopy(carousel)
more["musicCarouselShelfRenderer"]["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"]["runs"][0]["text"] = "More shelves (synthetic)"
out["continuation-section-list.json"] = {
    "responseContext": {},
    "continuationContents": {"sectionListContinuation": {"contents": [more], "continuations": [token("SYNTHETICpageToken-3")]}},
}
# The newer envelope: appended items followed by a continuation item.
out["continuation-append-action.json"] = {
    "responseContext": {},
    "onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": album_rows[5:8] + [
        {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "SYNTHETICappendToken-4"}}}}]}}],
}
# A recognised container that is simply empty: the service says there is nothing more.
out["continuation-end.json"] = {"responseContext": {}, "continuationContents": {"musicPlaylistShelfContinuation": {"contents": []}}}
# Unknown variants: an unknown section kind, an unknown entry inside a shelf, an unreadable entry, a repeated entry, an
# entry of a page type the app does not present, and a second shelf with the same title as the first.
shelf = copy.deepcopy(carousel)
items = shelf["musicCarouselShelfRenderer"]["contents"]
repeated = copy.deepcopy(items[0])
unknown_entry = {"musicSomethingNewRenderer": {"title": {"runs": [{"text": "A renderer from the future"}]}}}
unreadable = {"musicTwoRowItemRenderer": {"title": {"runs": [{"text": ""}]}}}
profile = copy.deepcopy(items[1])
profile["musicTwoRowItemRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"] = "MUSIC_PAGE_TYPE_USER_CHANNEL"
profile["musicTwoRowItemRenderer"]["title"]["runs"][0].pop("navigationEndpoint", None)
shelf["musicCarouselShelfRenderer"]["contents"] = items[:3] + [repeated, unknown_entry, unreadable, profile]
twin = copy.deepcopy(shelf)
twin["musicCarouselShelfRenderer"]["contents"] = items[3:5]
page = copy.deepcopy(home)
page["contents"]["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"] = [
    shelf, twin, {"musicFutureShelfRenderer": {"contents": []}}]
out["unknown-variants-page.json"] = page
# Adverse responses.
out["adverse-error.json"] = {"error": {"code": 400, "message": "synthetic"}}
out["adverse-no-container.json"] = {"responseContext": {}, "contents": {"somethingElseRenderer": {}}}
out["adverse-unreadable-only.json"] = {"responseContext": {}, "contents": {"singleColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {
    "contents": [{"musicCarouselShelfRenderer": {"contents": [unreadable, unreadable]}}]}}}}]}}}
out["adverse-unknown-sections-only.json"] = {"responseContext": {}, "contents": {"singleColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {
    "contents": [{"musicFutureShelfRenderer": {}}]}}}}]}}}
out["adverse-continuation-unknown.json"] = {"responseContext": {}, "somethingNew": {}}

files = []
for name, value in sorted(out.items()):
    data = (json.dumps(value, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)
    files.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
manifest = {
    "mode": "synthetic-test-only",
    "live_eligible": False,
    "description": "Edge-case fixtures for W11 that the nine real captures (../W11-real) do not show: continuation envelopes, an unknown-variants page and adverse responses. Containers are hand-assembled by generate.py; the entries inside them are copied unchanged from the real captures. Not captures of any response and not live evidence.",
    "files": files,
}
with open(os.path.join(HERE, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1); f.write("\n")
print(len(files), "fixtures written")
