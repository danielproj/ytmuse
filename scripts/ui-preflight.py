#!/usr/bin/env python3
"""UI-run preflight: refuse to start a UI suite while a system window covers the area where the test window opens.

XCUITest clicks land on whatever is on top. A system dialog (for example FollowUpUI) or a notification banner over the
isolated test window turns every click under it into a false test failure ("Falling back to element center point"),
which cost several lanes hours on 2026-10-30/31. This check reads only process names, window positions and sizes,
never titles or contents, and never touches the windows. Exit 75 = environment blocked (same code as a locked console).

  YTMUSE_UI_TEST_AREA=x,y,w,h   screen area (top-left origin) the isolated test window occupies; default 0,0,1340,960
                                (isolated windows open at the visible frame top-left + 24 pt since W18-F1: a 1240x820 window ends at x 1264, clear of the
                                notification banner column; larger test sizes still reach further)
  --after-failure               report only (exit 0), for annotating a failed run
  --self-test                   check the overlap rules offline
"""
import os
import subprocess
import sys

# Agents whose windows float above ordinary application windows. Ordinary apps are fine: the test activates its own app
# above them. Desktop-level windows (widgets, wallpaper) and the transparent automation-mode overlay are not listed.
OVERLAY_PROCESSES = [
    "FollowUpUI", "UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn",
    "AirPlayUIAgent", "Keychain Circle Notification", "SoftwareUpdateNotificationManager", "Software Update",
    "coreautha", "LocalAuthenticationRemoteService", "AuthenticationServicesAgent", "Siri",
    "loginwindow",  # owns the "Force Quit Applications" dialog that macOS shows when memory runs out
]

SCRIPT = r'''
set out to {}
tell application "System Events"
  set liveNames to name of every process
  repeat with procName in {%s}
    set procName to procName as text
    if liveNames contains procName then
      try
        repeat with w in (windows of process procName)
          set p to position of w
          set s to size of w
          set end of out to procName & "|" & (item 1 of p) & "|" & (item 2 of p) & "|" & (item 1 of s) & "|" & (item 2 of s)
        end repeat
      end try
    end if
  end repeat
  if liveNames contains "NotificationCenter" then
    -- Banners are the children of the notification column (a scroll area that spans the screen height). The column sits
    -- one or two groups below the host window depending on state, so look at both depths.
    try
      set ncHost to UI element 1 of window "Notification Center" of process "NotificationCenter"
      set notifCols to (scroll areas of ncHost)
      repeat with ncInner in (groups of ncHost)
        set notifCols to notifCols & (scroll areas of ncInner)
      end repeat
      repeat with notifCol in notifCols
        repeat with b in (UI elements of notifCol)
          set p to position of b
          set s to size of b
          set end of out to "NotificationCenter banner|" & (item 1 of p) & "|" & (item 2 of p) & "|" & (item 1 of s) & "|" & (item 2 of s)
        end repeat
      end repeat
    end try
  end if
end tell
set AppleScript's text item delimiters to linefeed
return out as text
'''


def overlaps(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return aw > 0 and ah > 0 and bw > 0 and bh > 0 and ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def parse_area(value):
    parts = [float(p) for p in value.split(",")]
    if len(parts) != 4 or parts[2] <= 0 or parts[3] <= 0:
        raise ValueError(value)
    return tuple(parts)


def parse_lines(text):
    found = []
    for line in text.splitlines():
        fields = line.split("|")
        if len(fields) != 5:
            continue
        try:
            found.append((fields[0], tuple(float(v) for v in fields[1:])))
        except ValueError:
            continue
    return found


def self_test():
    area = (0, 0, 1320, 900)
    assert overlaps(area, (619, 451, 490, 257)), "a centred dialog blocks"
    assert not overlaps(area, (1368, 44, 344, 186)), "a top-right banner clear of the area does not block"
    assert overlaps((244, 140, 1240, 820), (1368, 44, 344, 186)), "a centred window under the banner would be blocked"
    assert not overlaps(area, (100, 100, 0, 0)), "an empty rect never blocks"
    assert parse_lines("FollowUpUI|619|451|490|257\nbad line\n") == [("FollowUpUI", (619.0, 451.0, 490.0, 257.0))]
    assert parse_area("0,0,1320,900") == (0.0, 0.0, 1320.0, 900.0)
    print("ui-preflight self-test: ok")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    area = parse_area(os.environ.get("YTMUSE_UI_TEST_AREA", "0,0,1340,960"))
    names = ", ".join('"%s"' % n for n in OVERLAY_PROCESSES)
    try:
        result = subprocess.run(["osascript", "-"], input=SCRIPT % names, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        print("ui-preflight: could not inspect system windows (%s); continuing unchecked" % error, file=sys.stderr)
        return 0
    if result.returncode != 0:
        print("ui-preflight: could not inspect system windows (%s); continuing unchecked" % result.stderr.strip()[:200], file=sys.stderr)
        return 0
    blockers = [(name, rect) for name, rect in parse_lines(result.stdout) if overlaps(area, rect)]
    if not blockers:
        return 0
    suite = os.environ.get("SUITE_ID", "suite")
    for name, (x, y, w, h) in blockers:
        if "--after-failure" in argv:
            print("%s UI ENVIRONMENT NOTE: after this run a %s window is over the test area at %d,%d %dx%d; clicks under it "
                  "fail as 'Falling back to element center point' — check that before calling a failure a product defect"
                  % (suite, name, x, y, w, h), file=sys.stderr)
        else:
            print("%s UI ENVIRONMENT BLOCKED: a %s window is over the test area at %d,%d %dx%d (not read, not touched)"
                  % (suite, name, x, y, w, h), file=sys.stderr)
    return 0 if "--after-failure" in argv else 75


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
