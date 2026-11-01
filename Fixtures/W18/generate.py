#!/usr/bin/env python3
"""Assembles the W18 edge-case fixtures (mode `synthetic-test-only`) from the REAL renderers in Fixtures/W18-real.

Run from anywhere:  python3 -I Fixtures/W18/generate.py
Every container is built by hand around entries copied unchanged from the captures; the few values that are changed are listed in manifest.json
under `changes`. Lyrics text in the timed fixtures is invented placeholder text, not any song's lyrics. None of this is a capture of the service.
"""
import copy, hashlib, json, os

here = os.path.dirname(os.path.abspath(__file__))
real = os.path.join(here, "..", "W18-real")
def load(name):
    with open(os.path.join(real, name), encoding="utf-8") as f:
        return json.load(f)
def save(name, value):
    path = os.path.join(here, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=1, sort_keys=False)
        f.write("\n")
    return path

changes = {}

# ---- next: lyrics tab states -------------------------------------------------------------------------------------------------------
def tabs_of(doc):
    return doc["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"]
nxt = load("next-song.json")
doc = copy.deepcopy(nxt)
tabs = tabs_of(doc)
lyrics_index = next(i for i, t in enumerate(tabs) if t["tabRenderer"].get("endpoint", {}).get("browseEndpoint", {}).get("browseEndpointContextSupportedConfigs", {}).get("browseEndpointContextMusicConfig", {}).get("pageType") == "MUSIC_PAGE_TYPE_TRACK_LYRICS")
tabs[lyrics_index] = {"tabRenderer": {"title": "Lyrics", "unselectable": True, "trackingParams": "synthetic"}}
save("next-lyrics-tab-unselectable.json", doc); changes["next-lyrics-tab-unselectable.json"] = "lyrics tab replaced by an unselectable tab with no endpoint"

doc = copy.deepcopy(nxt)
tabs = tabs_of(doc)
del tabs[lyrics_index]
save("next-without-lyrics-tab.json", doc); changes["next-without-lyrics-tab.json"] = "lyrics tab removed"

doc = copy.deepcopy(nxt)
tabs = tabs_of(doc)
doc["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"] = [t for t in tabs if "musicQueueRenderer" not in json.dumps(t.get("tabRenderer", {}).get("content", {}))[:200]]
save("next-not-a-queue.json", doc); changes["next-not-a-queue.json"] = "up-next queue tab removed: not a watch-next page"

# ---- lyrics browse variants -----------------------------------------------------------------------------------------------------------
def lyrics_shell(contents):
    return {"responseContext": {"visitorData": "<redacted>"}, "contents": contents}
save("lyrics-message.json", lyrics_shell({"sectionListRenderer": {"contents": [{"messageRenderer": {"text": {"runs": [{"text": "Lyrics not available"}]}}}]}}))
changes["lyrics-message.json"] = "a message in place of lyrics (invented wording)"
save("lyrics-empty-description.json", lyrics_shell({"sectionListRenderer": {"contents": [{"musicDescriptionShelfRenderer": {"description": {"runs": [{"text": " \n "}]}}}]}}))
changes["lyrics-empty-description.json"] = "a description shelf holding only whitespace"
save("lyrics-unreadable.json", lyrics_shell({"sectionListRenderer": {"contents": [{"somethingElseRenderer": {}}]}}))
changes["lyrics-unreadable.json"] = "a layout this version does not know"

# Edges a trimming or normalising reader would change: leading and trailing newlines, tabs, runs of spaces, a split run, a line of only spaces.
save("lyrics-verbatim-edges.json", lyrics_shell({"sectionListRenderer": {"contents": [{"musicDescriptionShelfRenderer": {
    "description": {"runs": [{"text": "\n\n  Indented first line\n\tTabbed line\n   \nDouble  space and trailing spaces   "}, {"text": "\n\nSecond run, then\n\n\n"}]},
    "footer": {"runs": [{"text": "Source: "}, {"text": "Placeholder Provider "}]}}}]}}))
changes["lyrics-verbatim-edges.json"] = "invented placeholder text with whitespace edges, split over two runs, with a two-run footer"

def timed(lines, source="Source: Example Lyrics Provider"):
    return lyrics_shell({"elementRenderer": {"newElement": {"type": {"componentType": {"model": {"timedLyricsModel": {"lyricsData": {
        "timedLyricsData": lines, "sourceMessage": source}}}}}}}})
def line(text, start, end=None, as_string=False):
    cue = {"startTimeMilliseconds": str(start) if as_string else start, "metadata": {"id": "x"}}
    if end is not None: cue["endTimeMilliseconds"] = str(end) if as_string else end
    return {"lyricLine": text, "cueRange": cue}
placeholder = [line("Placeholder line one", 1500, 4000), line("Placeholder line two", 4000, 7250), line("", 7250, 9000), line("Placeholder line four", 9000, 12000, False)]
save("lyrics-timed.json", timed(placeholder)); changes["lyrics-timed.json"] = "the reference clients' timed shape with invented placeholder text (never observed from the service)"
save("lyrics-timed-strings.json", timed([line("Placeholder A", 0, 1000, True), line("Placeholder B", 1000, 2000, True)]))
changes["lyrics-timed-strings.json"] = "times as numeric strings"
save("lyrics-timed-out-of-order.json", timed([line("Placeholder A", 5000, 6000), line("Placeholder B", 1000, 2000)]))
changes["lyrics-timed-out-of-order.json"] = "a line that starts before the one before it"
save("lyrics-timed-no-cue.json", timed([line("Placeholder A", 0, 1000), {"lyricLine": "Placeholder B"}]))
changes["lyrics-timed-no-cue.json"] = "a line with no cue range"
save("lyrics-timed-end-before-start.json", timed([line("Placeholder A", 5000, 4000)]))
changes["lyrics-timed-end-before-start.json"] = "a line that ends before it starts"

# ---- episode variants ---------------------------------------------------------------------------------------------------------------
ep = load("browse-episode.json")
def header_of(doc):
    return doc["contents"]["twoColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"][0]["musicResponsiveHeaderRenderer"]
def description_of(doc):
    return doc["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]["contents"][0]["musicDescriptionShelfRenderer"]
VIDEO = "AzENYaFVxGg"

# A signed page: the add side publishes ACTION_ADD_VIDEO (the reference clients' form) in place of the sign-in modal.
doc = copy.deepcopy(ep)
toggle = header_of(doc)["buttons"][0]["toggleButtonRenderer"]
toggle["defaultServiceEndpoint"] = {"playlistEditEndpoint": {"playlistId": "SE", "actions": [{"action": "ACTION_ADD_VIDEO", "addedVideoId": VIDEO}]}}
save("episode-signed-unsaved.json", doc); changes["episode-signed-unsaved.json"] = "default (add) side of the Episodes-for-Later toggle replaced by ACTION_ADD_VIDEO"

doc = copy.deepcopy(doc)
header_of(doc)["buttons"][0]["toggleButtonRenderer"]["isToggled"] = True
progress = header_of(doc)["progress"]["musicPlaybackProgressRenderer"]
progress["playbackProgressPercentage"] = 37.5
save("episode-signed-saved-partly-played.json", doc); changes["episode-signed-saved-partly-played.json"] = "isToggled true; playbackProgressPercentage 37.5 (the scale is assumed 0-100)"

doc = copy.deepcopy(ep)
header_of(doc)["progress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = 100
save("episode-played.json", doc); changes["episode-played.json"] = "playbackProgressPercentage 100"

doc = copy.deepcopy(ep)
header_of(doc)["progress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = 250
save("episode-progress-out-of-range.json", doc); changes["episode-progress-out-of-range.json"] = "playbackProgressPercentage 250 (out of range)"

doc = copy.deepcopy(ep)
description_of(doc)["description"] = {"runs": [{"text": "Show notes for a placeholder episode.\n\n00:00 Intro\n01:30 - First topic\n(12:05) Second topic\n1:02:03 Closing thoughts\n\nLearn more about your ad choices."}]}
save("episode-chapters.json", doc); changes["episode-chapters.json"] = "description replaced by placeholder show notes with four timestamped lines"

doc = copy.deepcopy(ep)
header_of(doc)["buttons"] = [b for b in header_of(doc)["buttons"] if "musicPlayButtonRenderer" not in b]
save("episode-no-play-target.json", doc); changes["episode-no-play-target.json"] = "play button removed"

doc = copy.deepcopy(ep)
del doc["contents"]["twoColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"][0]["musicResponsiveHeaderRenderer"]["title"]
save("episode-no-title.json", doc); changes["episode-no-title.json"] = "title removed"

# ---- a show page with part-played, played and malformed progress -------------------------------------------------------------------
show = load("browse-podcast.json")
def rows(doc):
    out = []
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "musicMultiRowListItemRenderer": out.append(v)
                walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(doc)
    return out
doc = copy.deepcopy(show)
r = rows(doc)
r[0]["playbackProgress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = 100
r[1]["playbackProgress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = 37.5
r[2]["playbackProgress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = 150
r[3]["playbackProgress"]["musicPlaybackProgressRenderer"]["playbackProgressPercentage"] = True
save("show-progress.json", doc); changes["show-progress.json"] = "rows 0-3: progress 100, 37.5, 150 (out of range), true (not a number)"

manifest = {"mode": "synthetic-test-only", "live_eligible": False,
            "description": "Edge cases the W18 real captures do not show. Built by generate.py around entries copied unchanged from Fixtures/W18-real; NOT captures of the service and NOT live evidence.",
            "changes": changes, "files": {}}
for name in sorted(changes):
    with open(os.path.join(here, name), "rb") as f:
        data = f.read()
    manifest["files"][name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
with open(os.path.join(here, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1); f.write("\n")
print("wrote", len(changes), "fixtures")
