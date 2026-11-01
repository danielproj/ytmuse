#!/usr/bin/env python3
"""Builds the W13 playlist-editing fixtures from the REAL anonymous playlist capture in ../W13-real/browse-playlist.json.

That capture is a public playlist read without a session, so it carries no edit affordance at all (it is the `viewer` case, read
as it is). A signed page for a playlist the person may edit has never been captured; the owned/collaborator pages here are therefore
`synthetic-from-real-renderers`: the real capture's renderers with only the edits listed below, in the shapes the web client uses
for an editable playlist (an editable header holding the ordinary header plus an edit header; a per-row "Remove from playlist" menu
item whose command is `playlistEditEndpoint` with ACTION_REMOVE_VIDEO + setVideoId). ASSUMED, shown by no capture: those two shapes
and the write responses (edit-*.json, create-*.json, delete-*.json). They are on the end-of-project live check (Docs/Playlists.md).
Not captures of any response and not live evidence.

Run from the repository root:  python3 -I Fixtures/W13/generate.py
"""
import copy, hashlib, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.join(HERE, "..", "W13-real", "browse-playlist.json")
with open(REAL) as f:
    real = json.load(f)

def two(doc):
    return doc["contents"]["twoColumnBrowseResultsRenderer"]

def shelf(doc):
    return two(doc)["secondaryContents"]["sectionListRenderer"]["contents"][0]["musicPlaylistShelfRenderer"]

def rows(doc):
    return shelf(doc)["contents"]

def replace_everywhere(node, old, new):
    if isinstance(node, dict):
        for k, v in list(node.items()):
            if isinstance(v, str) and v == old: node[k] = new
            else: replace_everywhere(v, old, new)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            if isinstance(v, str) and v == old: node[i] = new
            else: replace_everywhere(v, old, new)

def row_ids(row):
    data = row["musicResponsiveListItemRenderer"]["playlistItemData"]
    return data["videoId"], data["playlistSetVideoId"]

def remove_item(playlist_id, video, occurrence):
    return {"menuServiceItemRenderer": {
        "text": {"runs": [{"text": "Remove from playlist"}]}, "icon": {"iconType": "REMOVE"},
        "serviceEndpoint": {"clickTrackingParams": "synthetic", "playlistEditEndpoint": {"playlistId": playlist_id, "actions": [
            {"action": "ACTION_REMOVE_VIDEO", "removedVideoId": video, "setVideoId": occurrence}]}}}}

def delete_item(playlist_id):
    return {"menuNavigationItemRenderer": {
        "text": {"runs": [{"text": "Delete playlist"}]}, "icon": {"iconType": "DELETE"},
        "navigationEndpoint": {"clickTrackingParams": "synthetic", "confirmDialogEndpoint": {"content": {"confirmDialogRenderer": {
            "confirmButton": {"buttonRenderer": {"serviceEndpoint": {"deletePlaylistEndpoint": {"playlistId": playlist_id}}}}}}}}}}

def editable(doc, playlist_id, privacy, owner):
    doc = copy.deepcopy(doc)
    sections = two(doc)["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"]
    header = sections[0]["musicResponsiveHeaderRenderer"]
    # An owner's own playlist offers no Save toggle; the real anonymous header's sign-in Save toggle is dropped.
    header["buttons"] = [b for b in header["buttons"] if "toggleButtonRenderer" not in b]
    if owner:
        for button in header["buttons"]:
            if "menuRenderer" in button: button["menuRenderer"]["items"].append(delete_item(playlist_id))
    title = header["title"]
    wrapper = {"header": {"musicResponsiveHeaderRenderer": header}}
    # ASSUMED: an owner's editable header carries the edit header (title, description, privacy); a collaborator's carries none.
    if owner:
        wrapper["editHeader"] = {"musicPlaylistEditHeaderRenderer": {"title": title, "editTitle": title, "editDescription": {"runs": [{"text": ""}]},
                                                                      "privacy": privacy, "playlistId": playlist_id}}
    sections[0] = {"musicEditablePlaylistDetailHeaderRenderer": wrapper}
    for row in rows(doc):
        # The real capture's greyed-out track has no menu at all: it publishes no remove command, so it gets none here either.
        if "menu" not in row["musicResponsiveListItemRenderer"]: continue
        video, occurrence = row_ids(row)
        row["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"].append(remove_item(playlist_id, video, occurrence))
    return doc

playlist_id = "PLvcD45uIlPVoAkPQ5LTumatKEWZlxbHYN"
out = {}

owned = editable(real, playlist_id, "PRIVATE", owner=True)
# The same song twice with two occurrence ids (the duplicate keeps its own remove command).
extra = copy.deepcopy(rows(owned)[0])
video0, set0 = row_ids(extra)
replace_everywhere(extra, set0, "DUPLICATE00000001")
for item in extra["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"]:
    edit = item.get("menuServiceItemRenderer", {}).get("serviceEndpoint", {}).get("playlistEditEndpoint")
    if edit: edit["actions"][0]["setVideoId"] = "DUPLICATE00000001"
rows(owned).insert(3, extra)
out["owned-playlist.json"] = owned

out["collaborator-playlist.json"] = editable(real, playlist_id, "PUBLIC", owner=False)

# A long playlist: the track shelf's OWN trailing continuation item (the way the web client pages tracks), distinct from the page's
# section-list token (the suggestions reload) that every one of these pages also carries.
TRACKS_TOKEN = "TRACKSPAGE2tokenAAAAAAAAAAAAAAAA%3D%3D"
def with_track_token(doc):
    doc = copy.deepcopy(doc)
    rows(doc).append({"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": TRACKS_TOKEN, "request": "CONTINUATION_REQUEST_TYPE_BROWSE"}}}})
    return doc
out["owned-playlist-long.json"] = with_track_token(owned)
out["collaborator-playlist-long.json"] = with_track_token(out["collaborator-playlist.json"])

# An owned page where one row's remove command names ANOTHER playlist while the header names this one: that row is not removable.
foreign = copy.deepcopy(owned)
for item in rows(foreign)[2]["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"]:
    edit = item.get("menuServiceItemRenderer", {}).get("serviceEndpoint", {}).get("playlistEditEndpoint")
    if edit: edit["playlistId"] = "PLsomeoneElsesPlaylist00000000000000"
out["owned-playlist-foreign-command.json"] = foreign

# What the section-list token answers: the suggested songs. A real row of the capture, with the placeholder the service documents
# (ytmusicapi get_playlist) where a member's occurrence id would be. None of these is ever a member.
sug = []
for index, source in enumerate((rows(real)[4], rows(real)[5])):
    row = copy.deepcopy(source)
    video, occurrence = row_ids(row)
    replace_everywhere(row, occurrence, "to_be_updated_by_client")
    sug.append(row)
out["suggestions-answer.json"] = {"continuationContents": {"sectionListContinuation": {"contents": [{"musicShelfRenderer": {"contents": sug}}]}}}

# The second page of the owned playlist: a continuation answer with three more occurrences (new occurrence ids; one repeats a song).
page2_rows = []
for index, source in enumerate((rows(owned)[1], rows(owned)[2], rows(owned)[0])):
    row = copy.deepcopy(source)
    video, occurrence = row_ids(row)
    new = "PAGETWO0000000%d" % (index + 1)
    replace_everywhere(row, occurrence, new)
    for item in row["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"]:
        edit = item.get("menuServiceItemRenderer", {}).get("serviceEndpoint", {}).get("playlistEditEndpoint")
        if edit: edit["actions"][0]["setVideoId"] = new
    page2_rows.append(row)
out["owned-playlist-page2.json"] = {"continuationContents": {"musicPlaylistShelfContinuation": {"contents": page2_rows}}}

# An owned page where one row lost its remove command and one names another occurrence (neither is a removal control).
partial = copy.deepcopy(owned)
prow = rows(partial)
prow[1]["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"] = [
    i for i in prow[1]["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"] if "playlistEditEndpoint" not in json.dumps(i)]
for item in prow[2]["musicResponsiveListItemRenderer"]["menu"]["menuRenderer"]["items"]:
    edit = item.get("menuServiceItemRenderer", {}).get("serviceEndpoint", {}).get("playlistEditEndpoint")
    if edit: edit["actions"][0]["setVideoId"] = "SOMEOTHEROCCURRENCE"
out["owned-playlist-partial-removals.json"] = partial

# Write answers (ASSUMED shapes; STATUS_SUCCEEDED is the status the web client's edit answer carries).
out["edit-succeeded.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED", "playlistEditResults": [
    {"playlistEditVideoAddedResultData": {"videoId": "dQw4w9WgXcQ", "setVideoId": "ADDED00000000001"}}]}
out["edit-succeeded-flat.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED", "playlistEditResults": [
    {"videoId": "dQw4w9WgXcQ", "setVideoId": "ADDED00000000001"}]}
out["edit-succeeded-no-results.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED"}
out["edit-invite-link.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED", "collaborationInviteLink": "https://music.youtube.com/playlist?list=" + playlist_id + "&jct=kM9wXdRj2p8v_qL3sHBkTz"}
out["edit-invite-link-foreign.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED", "collaborationInviteLink": "https://evil.example/playlist?list=" + playlist_id + "&jct=kM9wXdRj2p8v_qL3sHBkTz"}
out["edit-failed.json"] = {"responseContext": {}, "status": "STATUS_FAILED"}
out["edit-no-status.json"] = {"responseContext": {}}
out["edit-error.json"] = {"error": {"code": 400, "message": "Request contains an invalid argument.", "status": "INVALID_ARGUMENT"}}
out["create-ok.json"] = {"responseContext": {}, "playlistId": "PLsyntheticCreated0000000000000000001"}
out["create-missing-id.json"] = {"responseContext": {}}
out["create-wrong-kind-id.json"] = {"responseContext": {}, "playlistId": "OLAK5uy_notAUserPlaylist00000000000"}
out["delete-ok.json"] = {"responseContext": {}, "status": "STATUS_SUCCEEDED"}
out["delete-bare.json"] = {"responseContext": {}}

files = []
for name in sorted(out):
    data = (json.dumps(out[name], indent=1, sort_keys=True) + "\n").encode()
    with open(os.path.join(HERE, name), "wb") as f: f.write(data)
    files.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
manifest = {
    "mode": "synthetic-from-real-renderers", "live_eligible": False,
    "description": "Playlist-editing pages and write answers for W13. The page renderers are the real anonymous playlist capture in ../W13-real/browse-playlist.json with only the edits generate.py lists (editable header + edit header, a per-row ACTION_REMOVE_VIDEO command, one duplicated occurrence, a continuation page). ASSUMED, shown by no capture: the editable-header and per-row remove shapes, the edit/create/delete answers. Not captures of any response and not live evidence; the end-of-project live check is in Docs/Playlists.md.",
    "source": "../W13-real/browse-playlist.json", "files": files}
with open(os.path.join(HERE, "manifest.json"), "w") as f: f.write(json.dumps(manifest, indent=1) + "\n")
print("wrote", len(files), "files")
