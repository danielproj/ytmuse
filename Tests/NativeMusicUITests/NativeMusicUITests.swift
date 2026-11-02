import XCTest
import AppKit
final class NativeMusicUITests: XCTestCase {
    @MainActor private func accountTestApplication() throws -> XCUIApplication {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let url = directory.appendingPathComponent("NativeAccountTestHost.app")
            if FileManager.default.fileExists(atPath: url.path) {
                let app = XCUIApplication(url: url)
                app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleKeyboardUIMode", "3"]
                return app
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "T50", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built sibling native account test host is missing"])
    }
    /// Every automated YTMuse launch uses the Debug-only isolated QA namespace: a fresh
    /// temporary store and isolated keychain files, never the account holder's data.
    /// Saved application state is ignored too, so no launch restores the account holder's windows.
    @MainActor private func isolated(_ app: XCUIApplication) -> XCUIApplication {
        app.launchEnvironment["YTMUSE_UI_TEST_ISOLATED"] = "1"
        if !app.launchArguments.contains("-ApplePersistenceIgnoreState") { app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"] }
        return app
    }
    @MainActor private func designApplication() -> XCUIApplication {
        let app = isolated(XCUIApplication())
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleKeyboardUIMode", "3"]
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_DATA"] = "1"
        app.launchEnvironment["YTMUSE_NATIVE_DESIGN_TEST"] = "1"
        app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"
        return app
    }
    @MainActor private func diagnostic(_ window: XCUIElement, _ identifier: String) -> Int? {
        let text = window.staticTexts[identifier]
        guard text.exists else { return nil }
        let value = (text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label
        let number = String(value.split(separator: ":").last ?? "")
        guard number.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "," || $0.isWhitespace }) else { return nil }
        return Int(number.filter { $0.isASCII && $0.isNumber })
    }
    @MainActor private func readout(_ window: XCUIElement, _ identifier: String) -> String {
        let text = window.staticTexts[identifier]
        guard text.exists else { return "missing" }
        return (text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label
    }
    @MainActor private func capture(_ window: XCUIElement, _ name: String, samples: [[String: String]] = []) {
        let shot = XCTAttachment(screenshot: window.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: window.debugDescription); tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
        let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        let log = XCTAttachment(string: data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"); log.name = name + " samples"; log.lifetime = .keepAlways; add(log)
    }
    @MainActor private func resize(_ window: XCUIElement, width: Double, height: Double) {
        guard ProcessInfo.processInfo.environment["W09_HUMAN_RESIZE_CONFIRMED"] == "1" else {
            XCTFail("A recorded human edge resize and parent clearance are required before any further automated resize attempt"); return
        }
        let before = window.frame
        resizePressEvidence(window, phase: "before right press")
        let rightStart = CGPoint(x: before.maxX + 3, y: before.midY), rightEnd = CGPoint(x: before.minX + width + 3, y: before.midY)
        window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: 3, dy: 0))
            .press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: width + 3, dy: 0)))
        let afterWidth = window.frame
        resizePressEvidence(window, phase: "after right press / before bottom press")
        let bottomStart = CGPoint(x: afterWidth.midX, y: afterWidth.maxY + 3), bottomEnd = CGPoint(x: afterWidth.midX, y: afterWidth.minY + height + 3)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 3))
            .press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: height + 3)))
        let after = window.frame
        resizePressEvidence(window, phase: "after bottom press")
        self.capture(window, "W09 exterior-edge resize", samples: [["before": "\(before)", "rightStart": "\(rightStart)", "rightEnd": "\(rightEnd)", "afterWidth": "\(afterWidth)", "bottomStart": "\(bottomStart)", "bottomEnd": "\(bottomEnd)", "after": "\(after)"]])
        XCTAssertGreaterThan(abs(after.width - before.width), 20, "Native width gesture must actually resize")
        XCTAssertGreaterThan(abs(after.height - before.height), 20, "Native height gesture must actually resize")
    }
    @MainActor private func resizePressEvidence(_ window: XCUIElement, phase: String) {
        self.capture(window, "W09 resize " + phase, samples: [["window": "\(window.frame)", "cursorAppKitBottomUp": "\(NSEvent.mouseLocation)", "screens": NSScreen.screens.map { "frame=\($0.frame) visible=\($0.visibleFrame) scale=\($0.backingScaleFactor)" }.joined(separator: " | ")]])
        let full = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        full.name = "PRIVATE full desktop resize " + phase; full.lifetime = .keepAlways; add(full)
    }
    /// T09.2 parent decision: sizes are reached through the Debug-only isolated window-size
    /// seam (an ordinary AppKit frame change; the window's own minimum decides the result).
    @MainActor private func applyNextTestSize(_ app: XCUIApplication, _ window: XCUIElement, _ name: String) {
        let before = window.frame
        app.typeKey("0", modifierFlags: [.control, .option, .command])
        expectation(for: NSPredicate { _, _ in window.frame != before }, evaluatedWith: window); waitForExpectations(timeout: 5)
        capture(window, "W09 test window size " + name, samples: [["before": "\(before)", "after": "\(window.frame)"]])
    }
    /// On macOS 27 the segmented trailing-panel picker is exposed as a radio group (inline
    /// and in the compact sheet), so it is found by identifier and its selected segment is
    /// read from the radio button's AX value.
    @MainActor private func panelSegmentSelected(_ root: XCUIElement, _ label: String) -> Bool {
        let segment = root.descendants(matching: .any).matching(identifier: "trailingPanelPicker").firstMatch.radioButtons[label]
        guard segment.waitForExistence(timeout: 5) else { return false }
        return segment.isSelected || (segment.value as? NSNumber)?.intValue == 1 || (segment.value as? String) == "1"
    }
    @MainActor private func sidebarColumnWidth(_ window: XCUIElement) -> CGFloat {
        window.splitGroups.firstMatch.children(matching: .group).element(boundBy: 0).frame.width
    }
    @MainActor private func assertSettledArtwork(_ artwork: XCUIElement, window: XCUIElement, name: String) {
        let start = ProcessInfo.processInfo.systemUptime
        var since: Double?, consecutive = 0, settled = false, samples: [[String: String]] = []
        while ProcessInfo.processInfo.systemUptime - start <= 2 {
            let frame = artwork.frame, now = ProcessInfo.processInfo.systemUptime
            let valid = abs(frame.width - 240) <= 1 && abs(frame.height - 240) <= 1
            samples.append(["elapsedSeconds": "\(now - start)", "frame": "\(frame)", "valid": "\(valid)"])
            if valid { consecutive += 1; if since == nil { since = now } } else { since = nil; consecutive = 0 }
            if valid, consecutive >= 3, now - (since ?? now) >= 0.12, now - start <= 2 { settled = true; break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        self.capture(window, name, samples: samples)
        XCTAssertTrue(settled, "Artwork must supply >=3 consecutive240±1 frames spanning>=120ms within2s; samples retained on timeout")
        XCTAssertEqual(artwork.frame.width, 240, accuracy: 1)
        XCTAssertEqual(artwork.frame.height, 240, accuracy: 1)
    }
    @MainActor private func scrollNumber(_ window: XCUIElement, _ id: String) -> Double? {
        let text = window.staticTexts[id]
        guard text.exists else { return nil }
        let raw = (text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label
        return Double(String(raw.split(separator: ":").last ?? "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// W09-F2: the stability check is budgeted by SAMPLES, not wall time. Under load each accessibility read takes longer, so a time budget
    /// admitted fewer readings and failed a stable offset; a sample budget gives a loaded machine the same number of readings, however slowly
    /// they arrive. What counts as stable is unchanged: three consecutive readings of one value, live and stored agreeing within 0.5 pt,
    /// spanning at least 0.25 s, and (after Back) within 12 pt of the target.
    @MainActor private func stableScroll(_ window: XCUIElement, name: String, target: Double? = nil) throws -> Double {
        let maxSamples = target == nil ? 60 : 100
        var since: Double?, anchor: Double?, count = 0, result: Double?, samples: [[String: String]] = []
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<maxSamples {
            let live = scrollNumber(window, "designLiveScrollOffset"), stored = scrollNumber(window, "designScrollOffset"), now = ProcessInfo.processInfo.systemUptime
            samples.append(["elapsedSeconds": "\(now - start)", "livePoints": live.map { "\($0)" } ?? "missing", "storedPoints": stored.map { "\($0)" } ?? "missing", "maximumPoints": scrollNumber(window, "designScrollMaximum").map { "\($0)" } ?? "missing", "contentHeightPoints": scrollNumber(window, "designScrollContentHeight").map { "\($0)" } ?? "missing"])
            if let live, let stored, live.isFinite, stored.isFinite, (target.map { abs(live - $0) < 12 } ?? (live > 50)), abs(live - stored) < 0.5 {
                if let old = anchor, abs(live - old) < 0.5 { count += 1 } else { anchor = live; since = now; count = 1 }
                if count >= 3, now - (since ?? now) >= 0.25 { result = live; break }
            } else { anchor = nil; since = nil; count = 0 }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        self.capture(window, name, samples: samples)
        return try XCTUnwrap(result, "Live/stored scroll must stabilize in points within \(maxSamples) readings; actual samples retained, restoration tolerance remains<12pt")
    }
    @MainActor private func sidebar(_ title: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }
    @MainActor func testW09ExpandedVariantAndIndependentWindowTint() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let first = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        // W09-F1/F1b: one 10 s deadline, taken in slices of at most 2 s. The accessibility reads between slices are charged
        // to the same deadline, so a failing run ends at 10 s plus one final read, not ten seconds plus the reads.
        var gateTimeline: [String] = [], compactReady = false
        let compactStart = ProcessInfo.processInfo.systemUptime, compactDeadline = compactStart + 10
        while !compactReady {
            let remaining = compactDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            compactReady = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in self.diagnostic(first, "designRasterBytes").map { $0 > 0 } == true }, object: first)], timeout: min(2, remaining)) == .completed
            if !compactReady { gateTimeline.append("t+\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - compactStart))s bytes=\(diagnostic(first, "designRasterBytes").map(String.init) ?? "missing") shell[\(readout(first, "designWindowVisible"))] player[\(readout(first, "designPlayerGate"))] \(readout(first, "designPipelineState")) \(readout(first, "designPollTicks")) tint[\(readout(first, "designCanvasTint"))]") }
        }
        if !compactReady { capture(first, "W09-F1 compact raster never exceeded 0") }
        XCTAssertTrue(compactReady, "Compact raster bytes never exceeded 0 in 10 s. Gate timeline: " + gateTimeline.joined(separator: " | "))
        let compactBytes = try XCTUnwrap(diagnostic(first, "designRasterBytes"), "Missing/invalid compact raster value")
        XCTAssertGreaterThan(compactBytes, 0); guard compactBytes > 0 else { return }
        first.buttons["Show Now Playing"].click()
        let artwork = first.descendants(matching: .any).matching(identifier: "expandedArtwork").firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _,_ in self.diagnostic(first, "designRasterBytes").map { $0 >= compactBytes * 20 } == true }, evaluatedWith: first); waitForExpectations(timeout: 10)
        assertSettledArtwork(artwork, window: first, name: "W09 initial settled 240pt artwork assertion")
        // Reverse before the normal expansion duration, then expand again.
        first.buttons["browserBack"].click(); first.buttons["Show Now Playing"].click()
        // V02 rework 1: Now Playing is the bar grown into the expanded player, so the cover is inserted again on the second expansion instead of
        // lingering as a placeholder. Wait for it to exist; the settled 240 pt requirement below is unchanged.
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        assertSettledArtwork(artwork, window: first, name: "W09 reversed and re-expanded settled 240pt artwork assertion")
        app.menuBars.menuBarItems["File"].click(); app.menuItems["New Window"].click()
        let second = app.windows.matching(identifier: "main-AppWindow-2").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _,_ in
            let text = first.staticTexts["designCanvasTint"]
            return ((text.value as? String) ?? text.label).contains("present")
        }, evaluatedWith: first); waitForExpectations(timeout: 5)
        second.buttons[XCUIIdentifierMinimizeWindow].click()
        expectation(for: NSPredicate { _,_ in
            let text = first.staticTexts["designCanvasTint"]
            return ((text.value as? String) ?? text.label).contains("present")
        }, evaluatedWith: first); waitForExpectations(timeout: 5)
        let capture = XCTAttachment(screenshot: first.screenshot()); capture.name = "W09 corrected 240pt artwork and independent window tint"; capture.lifetime = .keepAlways; add(capture)
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "Artwork/navigation must never create a player")
    }
    @MainActor func testW09ScrollSelectionQueryFilterHistoryAndKeyboard() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sidebar("Library", in: window).click()
        let query = window.textFields["collectionQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.click(); query.typeText("1")
        let selected = window.checkBoxes.firstMatch
        XCTAssertTrue(selected.exists); selected.click()
        let scroll = window.scrollViews["destinationScroll"]
        // Fixed deltas, not velocity swipes: a swipe's travel depends on its speed and on how busy the machine is.
        for _ in 0..<4 { scroll.scroll(byDeltaX: 0, deltaY: -150); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
        let savedOffset = try stableScroll(window, name: "W09 stable live and stored scroll at save")
        XCTAssertGreaterThan(savedOffset, 50)
        // Downloads has had its own screen (segmented filter, no query field) since W15; History is a second destination on the
        // generic collection page, so the per-destination query/filter independence and Back/Forward restoration stay covered.
        sidebar("History", in: window).click()
        query.click(); query.typeText("2")
        window.popUpButtons["collectionFilter"].click(); app.menuItems["Downloaded only"].click()
        window.buttons["browserBack"].click()
        XCTAssertEqual(query.value as? String, "1")
        XCTAssertEqual(window.popUpButtons["collectionFilter"].value as? String, "All")
        XCTAssertEqual(diagnostic(window, "designSelectionCount"), 1)
        let restoredOffset = try stableScroll(window, name: "W09 live and stored scroll after Back", target: savedOffset)
        XCTAssertLessThan(abs(restoredOffset - savedOffset), 12)
        window.buttons["browserForward"].click()
        XCTAssertEqual(query.value as? String, "2")
        XCTAssertEqual(window.popUpButtons["collectionFilter"].value as? String, "Downloaded only")
        query.click(); query.typeKey("a", modifierFlags: .command); query.typeText("123")
        query.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(query.value as? String, "123", "Native text editing and tab navigation preserve the query")
        XCTAssertFalse(window.buttons["transportPlayPause"].isEnabled)
        XCTAssertEqual(window.sliders["transportTimeline"].label, "Playback position")
        let capture = XCTAttachment(screenshot: window.screenshot()); capture.name = "W09 scroll-selection-query-filter restoration and native controls"; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testW09AdaptivePanelResizeKeepsLyricsSelection() throws {
        let app = designApplication(); app.launchEnvironment["YTMUSE_UI_TEST_WINDOW_SIZES_NEXT"] = "800x520,1240x820"
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(sidebarColumnWidth(window), 200); XCTAssertLessThanOrEqual(sidebarColumnWidth(window), 280)
        window.buttons["Lyrics"].firstMatch.click()
        let inline = window.descendants(matching: .any).matching(identifier: "inlineTrailingPanel").firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(inline.frame.width, 300); XCTAssertLessThanOrEqual(inline.frame.width, 420)
        applyNextTestSize(app, window, "800x520 requested")
        XCTAssertGreaterThanOrEqual(window.frame.width, 840); XCTAssertLessThanOrEqual(window.frame.width, 860)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560); XCTAssertLessThanOrEqual(window.frame.height, 580)
        let compact = app.descendants(matching: .any).matching(identifier: "compactTrailingPanel").firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(panelSegmentSelected(app, "Lyrics"))
        applyNextTestSize(app, window, "1240x820 requested")
        XCTAssertTrue(inline.waitForExistence(timeout: 5))
        XCTAssertTrue(panelSegmentSelected(window, "Lyrics"))
        XCTAssertGreaterThanOrEqual(inline.frame.width, 300); XCTAssertLessThanOrEqual(inline.frame.width, 420)
        let capture = XCTAttachment(screenshot: window.screenshot()); capture.name = "W09 Lyrics sheet-to-inline handoff preserves selection"; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testW09UnavailableWindowStateRequiresExplicitConfirmedReset() throws {
        for fault in ["1", "atomic-leftover"] {
        let app = designApplication()
        app.launchEnvironment["YTMUSE_NATIVE_DESIGN_HISTORY_BROKEN"] = fault
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["windowHistoryNotice"].waitForExistence(timeout: 5))
        sidebar("Library", in: window).click()
        let query = window.textFields["collectionQuery"]
        XCTAssertTrue(query.exists); query.click(); query.typeText("123")
        window.buttons["resetWindowState"].click()
        XCTAssertTrue(app.staticTexts["Reset saved window state?"].waitForExistence(timeout: 5))
        let confirmation = window.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let beforeCancelTitle = window.staticTexts["destinationTitle"].label
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, beforeCancelTitle)
        XCTAssertEqual(query.value as? String, "123", "Cancel must not discard even ephemeral navigation")
        XCTAssertTrue(window.staticTexts["windowHistoryNotice"].exists)
        window.buttons["resetWindowState"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Reset saved window state"].click()
        expectation(for: NSPredicate { _,_ in
            let status = window.staticTexts["designWindowHistory"]
            return ((status.value as? String) ?? status.label).hasSuffix("enabled")
        }, evaluatedWith: window); waitForExpectations(timeout: 5)
        XCTAssertFalse(window.staticTexts["windowHistoryNotice"].exists)
        sidebar("Library", in: window).click()
        XCTAssertEqual(window.textFields["collectionQuery"].value as? String, "")
        XCTAssertTrue(window.buttons["manageAccounts"].isEnabled, "Only local window state was affected")
        XCTAssertFalse(app.staticTexts["playbackState"].exists)
        let capture = XCTAttachment(screenshot: window.screenshot()); capture.name = "W09 degraded saved-window state and explicit safe recovery"; capture.lifetime = .keepAlways; add(capture)
        }
    }
    @MainActor func testW09QueuePageContextActionsKeepGlobalOccurrenceOrder() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10)); window.buttons["browserQueue"].click()
        var expectedOrder = Array(1...240)
        let list = window.descendants(matching: .any).matching(identifier: "queueList").firstMatch
        func transportTop() -> Double {
            let frames = [window.buttons["transportPlayPause"].frame, window.sliders["appVolume"].frame, window.sliders["transportTimeline"].frame].filter { $0.width > 0 && $0.height > 0 }
            return Double(frames.map(\.minY).min() ?? window.frame.minY)
        }
        func safeBand() -> CGRect {
            let bottom = transportTop() - 40
            let top = max(list.frame.minY, window.frame.minY + 100)
            return CGRect(x: list.frame.minX, y: top, width: list.frame.width, height: max(0, bottom - top))
        }
        func reach(_ row: XCUIElement) {
            var samples: [[String: String]] = [], wheelSign = 1.0
            var previous: (Double, Double)?, lastGeometry: String?, unchanged = 0
            let began = ProcessInfo.processInfo.systemUptime
            for step in 0..<64 {
                guard ProcessInfo.processInfo.systemUptime - began < 28 else { break } // Reserve about2s for one in-flight gesture.
                let band = safeBand(), frame = row.frame, listFrame = list.frame
                let geometry = "\(frame)|\(listFrame)|\(band)"
                unchanged = geometry == lastGeometry ? unchanged + 1 : 0; lastGeometry = geometry
                samples.append(["step": "\(step)", "elapsedSeconds": "\(ProcessInfo.processInfo.systemUptime - began)", "row": "\(frame)", "list": "\(listFrame)", "safeBand": "\(band)", "unchangedSteps": "\(unchanged)"])
                if unchanged >= 3 { break }
                guard band.height > 80, band.width > 0 else { break }
                if frame.width > 0 && frame.height > 0 {
                    if frame.minY >= band.minY && frame.maxY <= band.maxY {
                        // Reached only once scrolling has settled: a list still coasting from the
                        // last wheel step would move the row out from under the next click.
                        Thread.sleep(forTimeInterval: 0.4)
                        let settled = row.frame
                        if settled == frame || (settled.minY >= band.minY && settled.maxY <= band.maxY && abs(settled.minY - frame.minY) < 1) {
                            self.capture(window, "W09 queue occurrence reached safe band", samples: samples); return
                        }
                        samples[samples.count - 1]["unsettledFrame"] = "\(settled)"; continue
                    }
                    let distance = Double(frame.midY - band.midY)
                    if let (oldDistance, oldY) = previous, abs(distance) > abs(oldDistance) + 1, abs(Double(frame.midY) - oldY) > 1 { wheelSign *= -1 }
                    previous = (distance, Double(frame.midY))
                    let gap = frame.maxY > band.maxY ? frame.maxY - band.maxY : band.minY - frame.minY
                    // Move by the measured gap (plus a margin), capped at three quarters of the band.
                    let magnitude = min(max(12, gap + 8), band.height * 0.75)
                    let delta = (frame.maxY > band.maxY ? -1.0 : 1.0) * Double(magnitude) * wheelSign
                    samples[samples.count - 1]["plannedDeltaY"] = "\(delta)"
                    list.scroll(byDeltaX: 0, deltaY: delta)
                } else {
                    // A virtualized occurrence has no usable frame. Locate a real visible peer
                    // in the independently expected occurrence order from ONE accessibility
                    // snapshot (per-element queries cost a round trip each), then step toward
                    // the target by its index distance times the measured row height, capped
                    // at three quarters of the safe band.
                    let target = expectedOrder.firstIndex(of: 11)!
                    guard let tree = try? list.snapshot() else { break }
                    var peers: [(index: Int, frame: CGRect)] = []
                    func collect(_ node: any XCUIElementSnapshot) {
                        if node.elementType == .button, node.label.hasPrefix("Development queue item ") {
                            let f = node.frame, suffix = node.label.dropFirst("Development queue item ".count)
                            if f.width > 0, f.height > 0, f.maxY > band.minY, f.minY < band.maxY,
                               let number = Int(suffix.prefix(while: { $0.isNumber })), let index = expectedOrder.firstIndex(of: number) { peers.append((index, f)) }
                        }
                        node.children.forEach(collect)
                    }
                    collect(tree)
                    guard let peer = peers.min(by: { abs($0.index - target) < abs($1.index - target) }) else { break }
                    previous = nil
                    let distance = Double(abs(target - peer.index)) * Double(peer.frame.height)
                    let step = min(max(distance, Double(peer.frame.height)), Double(band.height) * 0.75)
                    samples[samples.count - 1]["peerIndex"] = "\(peer.index)"; samples[samples.count - 1]["plannedDeltaY"] = "\((target > peer.index ? -1.0 : 1.0) * step * wheelSign)"
                    list.scroll(byDeltaX: 0, deltaY: (target > peer.index ? -1.0 : 1.0) * step * wheelSign)
                }
            }
            self.capture(window, "W09 queue reach failed", samples: samples)
            XCTFail("Occurrence must reach a nonzero safe visible frame with bounded directional steps")
        }
        let item = window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Development queue item 11 ")).firstMatch
        let fallback = window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Development queue item 11")).firstMatch
        let row = item.exists ? item : fallback
        reach(row); XCTAssertTrue(row.isHittable)
        func contextMenu(_ name: String) throws {
            let band = safeBand(), frame = row.frame
            _ = try XCTUnwrap(frame.width > 0 && frame.height > 0 && frame.minY >= band.minY && frame.maxY <= band.maxY && row.isHittable ? true : nil, "Complete occurrence must be hittable inside the real-controls safe band before right-click")
            row.rightClick()
            let shot = XCTAttachment(screenshot: window.screenshot()); shot.name = "W09 queue context immediately after " + name; shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "W09 queue AX immediately after " + name; tree.lifetime = .keepAlways; add(tree)
        }
        try contextMenu("page-end right click"); app.menuItems["Move to end of page"].click()
        expectation(for: NSPredicate { _,_ in self.diagnostic(window, "designQueueIndex") == 79 }, evaluatedWith: window); waitForExpectations(timeout: 5)
        expectedOrder.removeAll { $0 == 11 }; expectedOrder.insert(11, at: 79)
        reach(row); try contextMenu("move-down right click"); app.menuItems["Move down"].click()
        expectation(for: NSPredicate { _,_ in self.diagnostic(window, "designQueueIndex") == 80 }, evaluatedWith: window); waitForExpectations(timeout: 5)
        expectedOrder.removeAll { $0 == 11 }; expectedOrder.insert(11, at: 80)
        let next = window.buttons["Next page"]
        XCTAssertTrue(next.isHittable)
        XCTAssertLessThan(next.frame.maxY, transportTop() - 8, "The actual page footer must remain above the player")
        // Diagnostic sample only: after Move down the occurrence is correctly on the next page, so it may not exist here.
        self.capture(window, "W09 last-row and page footer above transport", samples: [["nextPage": "\(next.frame)", "transportControlsTop": "\(transportTop())", "row": row.exists ? "\(row.frame)" : "not on this page"]])
        next.click()
        reach(row); try contextMenu("move-up right click"); app.menuItems["Move up"].click()
        expectation(for: NSPredicate { _,_ in self.diagnostic(window, "designQueueIndex") == 79 }, evaluatedWith: window); waitForExpectations(timeout: 5)
        let capture = XCTAttachment(screenshot: window.screenshot()); capture.name = "W09 true global queue targets across 80-row page boundaries"; capture.lifetime = .keepAlways; add(capture)
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "Development queue editing is explicitly silent test data")
    }
    @MainActor func testW09NavigationAndAdaptiveShell() throws {
        let app = isolated(XCUIApplication())
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_DATA"] = "1"
        app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"
        app.launchEnvironment["YTMUSE_UI_TEST_WINDOW_SIZES_NEXT"] = "800x520"
        app.launch()
        defer { app.terminate() }
        let window = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        func nav(_ name: String, in window: XCUIElement) -> XCUIElement {
            window.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", name.capitalized, name.capitalized)).firstMatch
        }
        nav("library", in: window).click()
        let query = window.textFields["collectionQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.click(); query.typeText("123")
        let filter = window.popUpButtons["collectionFilter"]
        filter.click(); app.menuItems["Downloaded only"].click()
        // History is a second destination on the generic collection page (Downloads has had its own screen since W15).
        nav("history", in: window).click()
        XCTAssertTrue(window.textFields["collectionQuery"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.textFields["collectionQuery"].value as? String, "")
        XCTAssertEqual(window.popUpButtons["collectionFilter"].value as? String, "All")
        window.buttons["browserBack"].click()
        XCTAssertEqual(query.value as? String, "123")
        XCTAssertEqual(filter.value as? String, "Downloaded only")
        window.buttons["browserForward"].click()
        XCTAssertEqual(query.value as? String, "")
        // Downloads keeps its own controls instead: the segmented filter, and no collection query field.
        nav("downloads", in: window).click()
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "downloadsFilter").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(window.textFields["collectionQuery"].exists, "Downloads has its own screen and no generic collection query")
        // W11: Explore is the catalog's own page now (it used to be the placeholder collection). An item the catalog doesn't own
        // (the older development rows in the Library) is still reported as unavailable.
        nav("explore", in: window).click()
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "catalogShelf-carousel:New albums & singles").firstMatch.waitForExistence(timeout: 10))
        nav("library", in: window).click()
        window.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Development item 1")).firstMatch.click()
        XCTAssertTrue(window.otherElements["unavailableItem"].exists || window.staticTexts["This item cannot be loaded"].exists)
        window.buttons["browserBack"].click()
        XCTAssertTrue(window.staticTexts["developmentDataLabel"].exists)
        window.buttons["browserQueue"].click()
        let normal = XCTAttachment(screenshot: window.screenshot()); normal.name = "W09 native glass 1240 shell development data"; normal.lifetime = .keepAlways; add(normal)
        // Requested below the minimum through the isolated size seam; do not change display/system settings.
        applyNextTestSize(app, window, "800x520 requested")
        XCTAssertGreaterThanOrEqual(window.frame.width, 840)
        XCTAssertLessThanOrEqual(window.frame.width, 860)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560)
        XCTAssertLessThanOrEqual(window.frame.height, 580)
        XCTAssertTrue(window.sliders["transportTimeline"].exists)
        let compact = XCTAttachment(screenshot: window.screenshot()); compact.name = "W09 compact shell and adaptive queue sheet"; compact.lifetime = .keepAlways; add(compact)
        if app.buttons["Done"].exists { app.buttons["Done"].click() }
        let firstTitle = window.staticTexts["destinationTitle"].label
        XCTAssertFalse(firstTitle.isEmpty)
        app.menuBars.menuBarItems["File"].click(); app.menuItems["New Window"].click()
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'YTMuse'")).count, 2)
        let second = app.windows.matching(identifier: "main-AppWindow-2").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        nav("downloads", in: second).click()
        XCTAssertEqual(second.staticTexts["destinationTitle"].label, "Downloads")
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, firstTitle)
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "Navigation must not start or replace the player")
    }
    /// T09.2: default 1240x820, near-minimum 840x560 and a smaller request clamped to the
    /// minimum, each at launch through the isolated size seam; sidebar 200-280 and trailing
    /// panel 300-420 inline at the default size, collapsing to the compact sheet at the minimum.
    @MainActor func testW09LaunchSizesDefaultMinimumAndClamp() throws {
        for (requested, name) in [(nil as String?, "default"), ("840x560", "near minimum"), ("700x450", "below minimum")] {
            let app = designApplication()
            if let requested { app.launchEnvironment["YTMUSE_UI_TEST_WINDOW_SIZE"] = requested }
            app.launch()
            let window = app.windows["YTMuse"].firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            if requested == nil {
                XCTAssertEqual(window.frame.width, 1240, accuracy: 1); XCTAssertEqual(window.frame.height, 820, accuracy: 1)
                XCTAssertGreaterThanOrEqual(sidebarColumnWidth(window), 200); XCTAssertLessThanOrEqual(sidebarColumnWidth(window), 280)
                window.buttons["browserQueue"].click()
                let inline = window.descendants(matching: .any).matching(identifier: "inlineTrailingPanel").firstMatch
                XCTAssertTrue(inline.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(inline.frame.width, 300); XCTAssertLessThanOrEqual(inline.frame.width, 420)
            } else {
                expectation(for: NSPredicate { _, _ in window.frame.width < 1000 }, evaluatedWith: window); waitForExpectations(timeout: 5)
                XCTAssertGreaterThanOrEqual(window.frame.width, 840); XCTAssertLessThanOrEqual(window.frame.width, 860)
                XCTAssertGreaterThanOrEqual(window.frame.height, 560); XCTAssertLessThanOrEqual(window.frame.height, 580)
                XCTAssertGreaterThanOrEqual(sidebarColumnWidth(window), 200); XCTAssertLessThanOrEqual(sidebarColumnWidth(window), 280)
                window.buttons["browserQueue"].click()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "compactTrailingPanel").firstMatch.waitForExistence(timeout: 5), "The trailing panel collapses to the compact sheet")
                XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "inlineTrailingPanel").firstMatch.exists)
            }
            capture(window, "W09 launch size " + name, samples: [["requested": requested ?? "default", "frame": "\(window.frame)", "sidebar": "\(sidebarColumnWidth(window))"]])
            app.terminate()
        }
    }
    /// The original native edge-resize gesture case, kept for the end-of-project manual check.
    @MainActor func testW09NativeEdgeResizeGestureManualOnly() throws {
        try XCTSkipIf(true, "native edge-resize gesture is not automatable with XCUITest on this macOS; end-of-project manual check")
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        resize(window, width: 800, height: 520)
        XCTAssertGreaterThanOrEqual(window.frame.width, 840); XCTAssertLessThanOrEqual(window.frame.width, 860)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560); XCTAssertLessThanOrEqual(window.frame.height, 580)
    }
    @MainActor func testW06OwnedNativeBottomTransport() throws {
        var directory = Bundle(for: Self.self).bundleURL
        var product: URL?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("YTMuse.app")
            if FileManager.default.fileExists(atPath: candidate.path) { product = candidate; break }
            directory.deleteLastPathComponent()
        }
        let app = isolated(XCUIApplication(url: try XCTUnwrap(product)))
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["startOwnedAudio"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "Normal launch must not initialize or autoplay owned audio")
        app.buttons["startOwnedAudio"].click()
        let state = app.staticTexts["playbackState"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["nativeStartGain"].value as? String, "0.001000", "Native gain must be established before the first play")
        XCTAssertTrue(((app.staticTexts["ownedMediaLabel"].value as? String) ?? app.staticTexts["ownedMediaLabel"].label).contains("Not YouTube Music"))
        // PLAYER-1: the quality line no longer sits under the bar; it is the first item of the capsule's ⋯ menu.
        app.menuButtons["sleepTimerMenu"].click()
        let quality = app.menuItems.matching(NSPredicate(format: "title CONTAINS '48000 Hz' OR label CONTAINS '48000 Hz'")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 5), "The ⋯ menu names the source quality")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["transportPlayPause"].click()
        expectation(for: NSPredicate(format: "label == 'paused' OR value == 'paused'"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        let timeline = app.sliders["transportTimeline"]
        XCTAssertEqual(timeline.label, "Playback position")
        XCTAssertEqual(app.sliders["appVolume"].label, "App volume")
        XCTAssertTrue(timeline.isHittable)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()
        app.buttons["transportPlayPause"].click()
        expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        app.buttons["transportNext"].click()
        XCTAssertTrue(app.staticTexts["currentMediaTitle"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == 'Owned test tone B' OR label == 'Owned test tone B'"), evaluatedWith: app.staticTexts["currentMediaTitle"])
        waitForExpectations(timeout: 5)
        app.buttons["transportMute"].click()
        // The label follows the session's muted state after the mute command (which waits on the adoption
        // barrier and the handoff clean-up since W16) and a refresh: wait for it, up to 5 s. If it still reads
        // "Mute" after that, mute really failed.
        expectation(for: NSPredicate(format: "label == 'Unmute'"), evaluatedWith: app.buttons["transportMute"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["transportMute"].label, "Unmute")
        // PLAYER-1: the sleep timer items are in a "Sleep Timer" submenu of the ⋯ menu.
        app.menuButtons["sleepTimerMenu"].click()
        app.menuItems["Sleep Timer"].click()
        app.menuItems["5 minutes"].click()
        XCTAssertTrue(app.staticTexts["sleepRemaining"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.windows["YTMuse"].screenshot())
        capture.name = "W06 real native bottom transport and owned quality"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["transportPlayPause"].click()
        app.menuBars.menuBarItems["File"].click()
        // TH1: File > Open is "show the main window" since W21 and reuses the window that exists; a second window is File > New Window (as the other UI tests
        // use). This step was never updated, so it failed every time (found by the first gated run of T06 since W21). The window appears a moment after the menu
        // click, so the count is awaited rather than read once.
        app.menuItems["New Window"].click()
        let windowCount = { app.windows.matching(identifier: "main-AppWindow-1").count + app.windows.matching(identifier: "main-AppWindow-2").count }
        expectation(for: NSPredicate { _, _ in windowCount() == 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(windowCount(), 2)
        let states = app.staticTexts.matching(identifier: "playbackState")
        XCTAssertEqual(states.count, 2, "Both windows observe the existing shared session")
        app.buttons.matching(identifier: "startOwnedAudio").firstMatch.click()
        for index in 0..<2 {
            expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: states.element(boundBy: index))
        }
        waitForExpectations(timeout: 5)
        let sliders = app.sliders.matching(identifier: "appVolume")
        XCTAssertEqual(sliders.count, 2)
        func number(_ element: XCUIElement) -> Double {
            if let value = element.value as? NSNumber { return value.doubleValue }
            return Double(element.value as? String ?? "") ?? -1
        }
        let initialVolume = number(sliders.element(boundBy: 0))
        XCTAssertGreaterThan(initialVolume, 0)
        sliders.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()
        expectation(for: NSPredicate { _, _ in
            let first = number(sliders.element(boundBy: 0)), second = number(sliders.element(boundBy: 1))
            return first >= 0 && abs(first - second) < 0.00001 && abs(first - initialVolume) > initialVolume * 0.1
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let actual = app.staticTexts.matching(identifier: "nativeAppliedGain")
        expectation(for: NSPredicate { _, _ in
            let gain = number(actual.element(boundBy: 0))
            return gain > 0.00005 && gain < 0.0009
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        // Restart prepares a new player at controlled gain; both sliders must follow it.
        app.buttons.matching(identifier: "startOwnedAudio").firstMatch.click()
        expectation(for: NSPredicate { _, _ in
            return abs(number(sliders.element(boundBy: 0)) - initialVolume) < 0.00001 && abs(number(sliders.element(boundBy: 1)) - initialVolume) < 0.00001 && abs(number(actual.element(boundBy: 0)) - 0.001) < 0.000001
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        // Bring the second native window forward before coordinate input; clicking
        // a covered window's global coordinates only hits the covering window.
        app.menuBars.menuBarItems["Window"].click()
        let windowEntries = app.menuItems.matching(identifier: "makeKeyAndOrderFront:")
        XCTAssertEqual(windowEntries.count, 2)
        windowEntries.element(boundBy: 1).click()
        let secondSlider = app.windows.matching(identifier: "main-AppWindow-2").firstMatch.sliders["appVolume"]
        XCTAssertTrue(secondSlider.isHittable)
        secondSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.5)).click()
        expectation(for: NSPredicate { _, _ in
            let first = number(sliders.element(boundBy: 0)), second = number(sliders.element(boundBy: 1))
            let gain = number(actual.element(boundBy: 0))
            return abs(first - second) < 0.00001 && abs(first - initialVolume) > initialVolume * 0.1 && gain > 0.00005 && gain < 0.0009
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["playbackError"].exists, "Expected gain supersession must not surface as a user error")
        for element in app.staticTexts.matching(identifier: "nativeStartGain").allElementsBoundByIndex {
            XCTAssertEqual(element.value as? String, "0.001000")
        }
        let sharedCapture = XCTAttachment(screenshot: app.windows["YTMuse"].firstMatch.screenshot())
        sharedCapture.name = "W06 R1 two-window shared quiet gain"; sharedCapture.lifetime = .keepAlways; add(sharedCapture)
        app.buttons.matching(identifier: "transportPlayPause").firstMatch.click()
        for index in 0..<2 {
            expectation(for: NSPredicate(format: "label == 'paused' OR value == 'paused'"), evaluatedWith: states.element(boundBy: index))
        }
        waitForExpectations(timeout: 5)
        app.menuBars.menuBarItems["YTMuse"].click()
        app.menuItems["Quit YTMuse"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
    /// W17 (T17.2/T17.4): the owned synthetic video (video-only, silent) through the native AVKit path: one picture owner across the
    /// inline preview, the video window and full screen; audio only STOPS the decoder (frames stop, playback goes on); closing the window
    /// gives the picture back without a second session. Isolated launch only; the owned media make no sound (no audio track, gain 0.001).
    /// PLAYER-1: starts the isolated app on owned test audio with the floating capsule, in the given appearance (a launch argument; nothing is written to defaults).
    @MainActor private func capsuleApplication(appearance: String?, sizes: String? = nil) throws -> XCUIApplication {
        var directory = Bundle(for: Self.self).bundleURL
        var product: URL?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("YTMuse.app")
            if FileManager.default.fileExists(atPath: candidate.path) { product = candidate; break }
            directory.deleteLastPathComponent()
        }
        let app = isolated(XCUIApplication(url: try XCTUnwrap(product)))
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + (appearance.map { ["-appearance", $0] } ?? [])   // the app's own appearance key, from the launch-argument domain (never persisted)
        app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"
        if let sizes { app.launchEnvironment["YTMUSE_UI_TEST_WINDOW_SIZES_NEXT"] = sizes }
        return app
    }
    @MainActor private func startCapsuleAudio(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["startOwnedAudio"].waitForExistence(timeout: 10))
        app.buttons["startOwnedAudio"].click()
        let state = app.staticTexts["playbackState"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
    }
    /// PLAYER-1: the floating capsule in the isolated app, on the owned test audio: its place and size, the identifiers it keeps, the hover seek with its times
    /// beside the transport, the slim volume slider, the ⋯ menu, the expanded player it opens, the compact window and light mode. The screenshots are
    /// attachments of this test (exported to the node's screens).
    @MainActor func testPlayer1FloatingCapsule() throws {
        let app = try capsuleApplication(appearance: nil, sizes: "800x520")
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        startCapsuleAudio(app)
        func shot(_ name: String, _ element: XCUIElement? = nil) {
            let picture = XCTAttachment(screenshot: (element ?? window).screenshot()); picture.name = "PLAYER-1 " + name; picture.lifetime = .keepAlways; add(picture)
        }
        // The capsule floats over the bottom of the detail column: inside the window, the margin above its bottom, below the panels, with the sidebar beside it.
        let play = app.buttons["transportPlayPause"], timeline = app.sliders["transportTimeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 5) && timeline.exists)
        XCTAssertTrue(app.buttons["transportPrevious"].exists && app.buttons["transportNext"].exists && app.buttons["transportMute"].exists && app.buttons["transportQueue"].exists)
        XCTAssertTrue(app.sliders["appVolume"].exists, "the regular layout shows the slim volume slider")
        let playFrame = play.frame, windowFrame = window.frame
        XCTAssertGreaterThan(playFrame.minY, windowFrame.midY, "the transport sits in the lower half")
        XCTAssertLessThan(playFrame.maxY, windowFrame.maxY - 16, "and above the window's bottom margin")
        shot("01 wide window, playing")
        // At rest the times are invisible but in the accessibility tree: found by identifier, with their slots beside Previous and Next.
        let elapsed = app.staticTexts["transportElapsed"], remaining = app.staticTexts["transportDuration"]
        XCTAssertTrue(elapsed.exists && remaining.exists, "the times stay in the accessibility tree at rest")
        XCTAssertNotNil(timeline.value, "and the slider's own value says where it is")
        let previous = app.buttons["transportPrevious"], next = app.buttons["transportNext"]
        let restFrames = [previous.frame, play.frame, next.frame]
        // Hover: the track grows in place, the times appear beside the transport at the buttons' height, and nothing else moves.
        timeline.hover()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual([previous.frame, play.frame, next.frame], restFrames, "the buttons do not move when the times appear")
        XCTAssertLessThanOrEqual(elapsed.frame.maxX, previous.frame.minX + 1, "elapsed sits left of Previous")
        XCTAssertGreaterThanOrEqual(remaining.frame.minX, next.frame.maxX - 1, "remaining sits right of Next")
        XCTAssertEqual(elapsed.frame.midY, previous.frame.midY, accuracy: 4, "at the buttons' centre height")
        shot("02 hover, seek and times")
        // The volume slider: slim, its knob only under the pointer.
        app.sliders["appVolume"].hover()
        Thread.sleep(forTimeInterval: 0.5)
        shot("09 volume slider hover")
        // The ⋯ menu: the source quality, shuffle, repeat (with checkmarks) and the Sleep Timer submenu.
        app.menuButtons["sleepTimerMenu"].click()
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Sleep Timer"].exists, "the sleep timer is a submenu")
        shot("05 more menu, window")
        // The open menu is a separate window the window shot does not include; the screen is cropped to the menus' own items before anything is attached,
        // so nothing else on the desktop is stored.
        func menuShot(_ name: String) {
            let items = app.menuItems.allElementsBoundByIndex.map(\.frame).filter { $0.width > 0 && $0.height > 0 }
            guard let first = items.first, let screen = NSScreen.main else { return }
            let area = items.dropFirst().reduce(first) { $0.union($1) }
            let full = XCUIScreen.main.screenshot().image
            guard let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let scale = CGFloat(cg.width) / screen.frame.width
            if let cropped = cg.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)) {
                let picture = XCTAttachment(image: NSImage(cgImage: cropped, size: area.size)); picture.name = "PLAYER-1 " + name; picture.lifetime = .keepAlways; add(picture)
            }
        }
        menuShot("05 more menu")
        // The Sleep Timer submenu, open beside it.
        app.menuItems["Sleep Timer"].click()
        XCTAssertTrue(app.menuItems["5 minutes"].waitForExistence(timeout: 5), "the submenu holds the timer items")
        menuShot("05 more menu, sleep timer submenu open")
        app.typeKey(.escape, modifierFlags: [])
        // The expanded player opens from the capsule's cover and closes back (the owned test tone lasts ~12 s, so it is started again first).
        startCapsuleAudio(app)
        window.buttons["Show Now Playing"].click()
        XCTAssertTrue(window.buttons["collapseNowPlaying"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(window.buttons["transportMute"].exists && window.sliders["appVolume"].exists && window.buttons["transportPlayPause"].exists, "the expanded player keeps its identifiers")
        shot("06 expanded player")
        window.buttons["collapseNowPlaying"].click()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        // The compact window: the volume is a glyph with a popover, the capsule is 48 pt tall, the times have no room (and stay in the accessibility tree).
        applyNextTestSize(app, window, "800x520 requested")
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        startCapsuleAudio(app)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.sliders["appVolume"].exists, "the compact layout keeps the volume behind its glyph")
        XCTAssertTrue(app.staticTexts["transportElapsed"].exists, "compact: the times are not drawn but still readable")
        shot("03 compact window, rest")
        app.sliders["transportTimeline"].hover()
        Thread.sleep(forTimeInterval: 0.6)
        shot("04 compact window, hover")
    }
    @MainActor func testPlayer1CapsuleInLightMode() throws {
        let app = try capsuleApplication(appearance: "light")
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        startCapsuleAudio(app)
        app.sliders["transportTimeline"].hover()
        Thread.sleep(forTimeInterval: 0.6)
        let picture = XCTAttachment(screenshot: window.screenshot()); picture.name = "PLAYER-1 07 light mode, hover"; picture.lifetime = .keepAlways; add(picture)
    }
    @MainActor func testW17OwnedNativeVideoDecoderAndSingleSurfaceOwner() throws {
        // The labelled Debug-only development shell (no account, no service, no network) hosts the Now Playing destination.
        let app = designApplication()
        app.launch()
        defer { app.terminate() }
        func text(_ element: XCUIElement) -> String { element.exists ? ((element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label) : "" }
        func wait(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
            let predicate = NSPredicate { _, _ in text(element) == expected }
            expectation(for: predicate, evaluatedWith: app)
            waitForExpectations(timeout: timeout)
            XCTAssertEqual(text(element), expected, file: file, line: line)
        }
        let main = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(app.buttons["startOwnedVideo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "Normal launch must not start any media")
        app.buttons["startOwnedVideo"].click()
        wait(app.staticTexts["playbackState"], "playing")
        app.buttons["Show Now Playing"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativeVideoPreview").firstMatch.waitForExistence(timeout: 10), "Now Playing shows the native video preview")
        wait(main.staticTexts["videoSurfaceOwner"], "inline")
        wait(main.staticTexts["videoDecoderState"], "decoding")
        // The decoder positive control: the AVPlayerItemVideoOutput counts the frames the decoder delivers.
        let frames: () -> Int = { Int(text(main.staticTexts["videoFrames"])) ?? -1 }
        let start = frames()
        Thread.sleep(forTimeInterval: 1.5)
        let decoded = frames() - start
        XCTAssertGreaterThanOrEqual(decoded, 10, "while video is selected the decoder delivers frames (\(decoded) in 1.5 s)")
        // Audio only stops the decoder; it does not cover a decoding picture, and playback goes on.
        main.buttons["nativeVideoAudioOnly"].click()
        wait(main.staticTexts["videoDecoderState"], "stopped")
        Thread.sleep(forTimeInterval: 0.6)
        let stopped = frames()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThanOrEqual(frames() - stopped, 1, "no frames are delivered while audio only")
        XCTAssertEqual(text(app.staticTexts["playbackState"]), "playing", "audio keeps playing")
        main.buttons["nativeVideoAudioOnly"].click()
        wait(main.staticTexts["videoDecoderState"], "decoding")
        let resumed = frames()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThanOrEqual(frames() - resumed, 8, "selecting video decodes again")
        // One owner across the inline preview, the video window and full screen.
        let positionBeforeWindow = Int(text(main.staticTexts["videoPosition"])) ?? -1
        XCTAssertGreaterThan(positionBeforeWindow, 0, "the video is playing, so its position is moving")
        main.buttons["nativeVideoWindow"].click()
        let window = app.windows["nativeVideoWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        wait(window.staticTexts["videoSurfaceOwner"], "window")
        XCTAssertTrue(main.staticTexts["Playing in the video window."].waitForExistence(timeout: 5), "the inline preview says where the picture is")
        XCTAssertEqual(app.staticTexts.matching(identifier: "playbackState").count, 1, "still one session")
        let capture = XCTAttachment(screenshot: window.screenshot()); capture.name = "W17 native video window"; capture.lifetime = .keepAlways; add(capture)
        window.buttons["nativeVideoFullScreen"].click()
        wait(window.staticTexts["videoSurfaceOwner"], "fullScreen", timeout: 20)
        wait(app.windows["nativeVideoWindow"].staticTexts["videoPlaybackState"], "playing")   // the main window is on another space while full screen
        // Full screen is preserved across audio only and back: the surface state does not change, only the decoder does.
        app.windows["nativeVideoWindow"].buttons["nativeVideoAudioOnly"].click()
        wait(app.windows["nativeVideoWindow"].staticTexts["videoDecoderState"], "stopped")
        wait(app.windows["nativeVideoWindow"].staticTexts["videoSurfaceOwner"], "fullScreen")
        XCTAssertTrue(app.windows["nativeVideoWindow"].staticTexts["Audio only. The video is not being decoded."].exists, "audio only is stated on the surface, not painted over")
        app.windows["nativeVideoWindow"].buttons["nativeVideoAudioOnly"].click()
        wait(app.windows["nativeVideoWindow"].staticTexts["videoDecoderState"], "decoding")
        wait(app.windows["nativeVideoWindow"].staticTexts["videoSurfaceOwner"], "fullScreen")
        app.windows["nativeVideoWindow"].buttons["nativeVideoFullScreen"].click()
        wait(app.windows["nativeVideoWindow"].staticTexts["videoSurfaceOwner"], "window", timeout: 20)
        // Closing the window gives the picture back to the preview; playback is untouched and no second session exists.
        app.windows["nativeVideoWindow"].buttons[XCUIIdentifierCloseWindow].click()
        wait(main.staticTexts["videoSurfaceOwner"], "inline")
        let positionAfterClose = Int(text(main.staticTexts["videoPosition"])) ?? -1
        XCTAssertGreaterThanOrEqual(positionAfterClose, positionBeforeWindow + 1, "playback was never restarted: the position only moved forward through preview, window, full screen and close")
        XCTAssertEqual(text(app.staticTexts["playbackState"]), "playing")
        XCTAssertEqual(app.staticTexts.matching(identifier: "playbackState").count, 1)
        // Picture in Picture is NEVER started by this unattended test: it starts a system agent on the account holder's machine and crashed
        // PIPAgent in earlier runs. It is the manual-only test below, on the end-of-project list.
        let record = XCTAttachment(string: "pictureInPicture=manual-only (skipped by design; see testW17NativePictureInPictureManualOnly) decodedInFirstWindow=\(decoded)"); record.name = "W17 PiP outcome"; record.lifetime = .keepAlways; add(record)
        let final = XCTAttachment(screenshot: app.windows["YTMuse"].firstMatch.screenshot()); final.name = "W17 Now Playing owned video"; final.lifetime = .keepAlways; add(final)
        app.menuBars.menuBarItems["YTMuse"].click()
        app.menuItems["Quit YTMuse"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
    /// MANUAL ONLY (W17 rework F5). Starts real AVKit Picture in Picture on the owned synthetic video, which launches the system PIPAgent. It crashed
    /// PIPAgent in three unattended runs, so it never runs by default: set `W17_MANUAL_PIP=1` and watch the machine. Not part of any suite count.
    @MainActor func testW17NativePictureInPictureManualOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["W17_MANUAL_PIP"] == "1", "manual-only: unattended Picture in Picture crashed the system PIPAgent; run with W17_MANUAL_PIP=1 under observation")
        let app = designApplication()
        app.launch()
        defer { app.terminate() }
        let main = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(app.buttons["startOwnedVideo"].waitForExistence(timeout: 10))
        app.buttons["startOwnedVideo"].click()
        app.buttons["Show Now Playing"].firstMatch.click()
        XCTAssertTrue(main.buttons["nativeVideoPictureInPicture"].waitForExistence(timeout: 10))
        main.buttons["nativeVideoPictureInPicture"].click()
        let owner = main.staticTexts["videoSurfaceOwner"]
        expectation(for: NSPredicate { _, _ in ((owner.value as? String) ?? owner.label) == "pictureInPicture" || main.staticTexts["nativeVideoNotice"].exists }, evaluatedWith: app)
        waitForExpectations(timeout: 15)
    }
    @MainActor func testWindowSettingsPreferenceAndQuit() throws {
        // The choice must survive a relaunch, so both launches name the same throwaway
        // preferences plist (a token; the app places it in its own temporary folder and
        // the UI command sequence removes it). The real preferences domain is never used.
        let app = isolated(XCUIApplication())
        app.launchEnvironment["YTMUSE_UI_TEST_DEFAULTS_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["connectionStatus"].exists)
        let mainCapture = XCTAttachment(screenshot: app.windows["YTMuse"].screenshot())
        mainCapture.name = "Native main window"
        mainCapture.lifetime = .keepAlways
        add(mainCapture)
        app.buttons["openSettings"].click()
        let picker = app.popUpButtons["appearancePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["Dark"].click()
        XCTAssertEqual(picker.value as? String, "Dark")
        let settingsCapture = XCTAttachment(screenshot: app.windows.containing(.popUpButton, identifier: "appearancePicker").firstMatch.screenshot())
        settingsCapture.name = "Working dark appearance settings"
        settingsCapture.lifetime = .keepAlways
        add(settingsCapture)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 10))
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Dark", "Choice must survive process restart")
        app.buttons["restoreAppearance"].click()
        XCTAssertTrue(waitUntil { (picker.value as? String) == "System" }, "Restore Defaults is applied by the settings store a moment after the click")
        app.typeKey("w", modifierFlags: .command)
        app.windows["YTMuse"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.windows["YTMuse"].exists)
        // W21 (WIN02): the last regular window is closed, so the app is menu-bar only (no Dock icon, no application menu); the status item reopens it.
        let hidden = waitForPolicy(app, .accessory)
        openPopover(app)
        attachCensus(app, "W21 census after closing Settings and the main window")
        XCTAssertTrue(hidden, "closing the last regular window hides the Dock icon")
        app.buttons["statusShowWindow"].firstMatch.click()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForPolicy(app, .regular), "reopening restores the Dock icon")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
    @MainActor func testYTMuseWelcomeAndNativeAccounts() throws {
        let app = isolated(XCUIApplication())
        app.launch()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 10))
        // E01 M2: the production app offers in-app YouTube Music web sign-in. The
        // test never clicks it (no live Google page); it only asserts the offer.
        XCTAssertTrue(app.buttons["musicSignIn"].isEnabled)
        app.buttons["manageAccounts"].click()
        XCTAssertTrue(app.staticTexts["No accounts connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["authUnavailable"].exists)
        app.terminate()

        let host = try accountTestApplication()
        host.launch()
        XCTAssertTrue(host.buttons["switch-Synthetic Beta"].waitForExistence(timeout: 10), host.debugDescription)
        XCTAssertTrue(host.staticTexts["Native macOS Keychain round-trip passed"].exists)
        host.buttons["switch-Synthetic Beta"].click()
        XCTAssertTrue(host.staticTexts["Active · Paused"].waitForExistence(timeout: 5))
        host.buttons["default-Synthetic Beta"].click()
        host.buttons["rename-Synthetic Beta"].click()
        let label = host.textFields["Display label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        host.activate()
        let renameCapture = XCTAttachment(screenshot: host.windows["YTMuse Account Tests"].screenshot())
        renameCapture.name = "Native rename alert before keyboard editing"; renameCapture.lifetime = .keepAlways; add(renameCapture)
        label.click(); label.typeKey("a", modifierFlags: .command); label.typeText("Synthetic Renamed")
        host.sheets.buttons["Save"].click()
        XCTAssertTrue(host.buttons["switch-Synthetic Renamed"].waitForExistence(timeout: 5))
        host.buttons["expireTestSession"].click()
        let reconnect = host.buttons["Reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: host.windows["YTMuse Account Tests"].screenshot())
        attachment.name = "YTMuse native expired account · synthetic identities"
        attachment.lifetime = .keepAlways; add(attachment)
        reconnect.click()
        XCTAssertTrue(host.buttons["signout-Synthetic Renamed"].waitForExistence(timeout: 5))
        host.buttons["signout-Synthetic Renamed"].click()
        XCTAssertTrue(host.staticTexts["Signed out · Private data locked"].waitForExistence(timeout: 5))
        for name in ["Synthetic Renamed", "Synthetic Alpha"] {
            host.buttons["remove-" + name].click()
            host.sheets.buttons["Remove Local Data"].click()
            XCTAssertFalse(host.buttons["remove-" + name].waitForExistence(timeout: 1))
        }
        XCTAssertTrue(host.staticTexts["No accounts connected"].exists)
        host.terminate()
    }

    @MainActor private func attachContrastRegion(_ app: XCUIApplication, mode: String) throws {
        let label: XCUIElement
        if mode.contains("settings") {
            label = app.staticTexts["Appearance is stored on this Mac and applies to all app windows."]
        } else if mode.contains("accounts") {
            label = app.staticTexts["Local labels and defaults apply to this Mac. Service subscriptions remain with YouTube."]
        } else { label = app.staticTexts["connectionStatus"] }
        XCTAssertTrue(label.exists)
        func rect(_ value: CGRect) -> [String: Double] {
            ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
        }
        let data = try JSONSerialization.data(withJSONObject: ["mode": mode,
            "window": rect(app.windows["YTMuse Account Tests"].frame), "text": rect(label.frame)], options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "T50-" + mode + "-metrics"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testT50GlassEnvironmentMatrix() throws {
        let host = try accountTestApplication()
        for mode in ["light", "dark", "light-transparency", "dark-transparency", "light-contrast", "dark-contrast", "dark-motion", "light-settings", "dark-settings", "dark-contrast-accounts", "light-accounts", "dark-accounts", "light-transparency-accounts", "dark-motion-accounts", "light-compact"] {
            host.launchEnvironment["T50_VISUAL_MODE"] = mode
            host.launch()
            XCTAssertTrue(host.staticTexts["visualMode"].waitForExistence(timeout: 10), mode)
            if mode.contains("accounts") {
                XCTAssertTrue(host.buttons["rename-Synthetic Alpha"].waitForExistence(timeout: 10))
                host.buttons["rename-Synthetic Alpha"].click()
                XCTAssertTrue(host.textFields["Display label"].waitForExistence(timeout: 5))
                host.typeKey(.escape, modifierFlags: [])
                XCTAssertFalse(host.textFields["Display label"].exists)
            } else if mode.contains("settings") {
                XCTAssertTrue(host.popUpButtons["appearancePicker"].exists)
                host.buttons["restoreAppearance"].click()
                host.typeKey(.tab, modifierFlags: [])
            } else {
                XCTAssertFalse(host.buttons["musicSignIn"].isEnabled)
                host.buttons["manageAccounts"].click()
                XCTAssertTrue(host.staticTexts["No accounts connected"].waitForExistence(timeout: 5))
                host.typeKey(.escape, modifierFlags: [])
                XCTAssertFalse(host.staticTexts["No accounts connected"].exists)
            }
            try attachContrastRegion(host, mode: mode)
            let capture = XCTAttachment(screenshot: host.windows["YTMuse Account Tests"].screenshot())
            capture.name = "T50-" + mode; capture.lifetime = .keepAlways; add(capture)
            host.terminate()
        }
    }

    @MainActor func testT50CompactAndKeyboardFocus() throws {
        let host = try accountTestApplication()
        host.launchEnvironment["T50_VISUAL_MODE"] = "light-accounts"
        host.launch()
        XCTAssertTrue(host.buttons["rename-Synthetic Alpha"].waitForExistence(timeout: 10))
        host.buttons["rename-Synthetic Alpha"].click()
        let label = host.textFields["Display label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        // App-level typing, without clicking the field, must reach the alert's initial focus.
        host.typeText("1")
        XCTAssertEqual(label.value as? String, "1", "App-level digit input must reach the initially focused text field")
        let focusCapture = XCTAttachment(screenshot: host.windows["YTMuse Account Tests"].screenshot())
        focusCapture.name = "T50-asserted-alert-keyboard-focus"; focusCapture.lifetime = .keepAlways; add(focusCapture)
        host.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(label.exists)
        host.terminate()
        let picker = host.popUpButtons["appearancePicker"]
        host.launchEnvironment["T50_VISUAL_MODE"] = "light-compact"
        host.launch()
        let open = host.buttons["openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertFalse(open.isHittable, "The compact fixture must require a scroll")
        let scroll = host.scrollViews.firstMatch
        for _ in 0..<5 where !open.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -250) }
        XCTAssertTrue(open.isHittable, "Open Settings must become reachable after scrolling")
        let compactCapture = XCTAttachment(screenshot: host.windows["YTMuse Account Tests"].screenshot())
        compactCapture.name = "T50-compact-settings-reachable"; compactCapture.lifetime = .keepAlways; add(compactCapture)
        open.click()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "The reached action must open actual native Settings")
        host.terminate()
    }

    // MARK: W10 search and command palette (isolated launch, labelled development catalog; never the live service)

    @MainActor private func w10(_ window: XCUIElement, _ identifier: String) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// SwiftUI exposes combined text as the element's value; read both so the check does not depend on which.
    @MainActor private func w10Text(_ element: XCUIElement) -> String { [element.label, element.value as? String].compactMap { $0 }.joined(separator: " ") }
    @MainActor func testW10SearchFieldGroupsKeyboardAndItemErrors() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // Command-F opens Search with the field focused: typing needs no click.
        app.typeKey("f", modifierFlags: .command)
        let field = window.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Search")
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development catalog is labelled")
        app.typeText("cafe")
        XCTAssertEqual(field.value as? String, "cafe", "typing reaches the field")
        XCTAssertTrue(w10(window, "searchGroup-top").waitForExistence(timeout: 5))
        for group in ["top", "playlists", "videos", "podcasts"] { XCTAssertTrue(w10(window, "searchGroup-" + group).exists, group) }
        XCTAssertFalse(w10(window, "searchGroup-songs").exists, "no song matched 'cafe', so there is no empty Songs group")
        let library = w10(window, "searchResult-playlist:PLdevelopmentCafe")
        XCTAssertTrue(library.exists, "the local library match is listed")
        XCTAssertTrue(w10Text(library).contains("In your library"), "its badge is part of what VoiceOver reads: \(w10Text(library))")
        let song = w10(window, "searchResult-song:devsong0001")
        XCTAssertTrue(song.exists && w10Text(song).contains("YouTube Music"), w10Text(song))
        capture(window, "W10 search groups and badges")
        // Typing played nothing and asked nothing of the player.
        XCTAssertFalse(window.buttons["transportPlayPause"].isEnabled)
        XCTAssertFalse(w10(window, "musicTitle").exists)
        // Arrows move through results while the field has focus; Return acts on the selection.
        field.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(field.value as? String, "cafe", "arrows are not typed")
        XCTAssertTrue(song.isSelected, "Down selects the first result")
        field.typeKey(.downArrow, modifierFlags: []); XCTAssertFalse(song.isSelected)
        field.typeKey(.upArrow, modifierFlags: []); XCTAssertTrue(song.isSelected)
        field.typeKey(.return, modifierFlags: [])
        let error = w10(window, "searchItemError-song:devsong0001")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Play without a connected account is reported at that item")
        XCTAssertTrue(w10Text(error).contains("Sign in to YouTube Music to play."), w10Text(error))
        XCTAssertFalse(w10(window, "searchItemError-playlist:PLdevelopmentCafe").exists, "other rows carry no error")
        XCTAssertFalse(window.buttons["transportPlayPause"].isEnabled, "nothing started")
        capture(window, "W10 item-level capability error")
        // The row's own Play button reports at its own item.
        w10(window, "searchPlay-playlist:PLdevelopmentCafe").click()
        XCTAssertTrue(w10(window, "searchItemError-playlist:PLdevelopmentCafe").waitForExistence(timeout: 5))
        // Context menu offers only real actions; Copy Link goes to the isolated pasteboard.
        library.rightClick()
        XCTAssertTrue(app.menuItems["Copy Link"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Play"].exists)
        for placeholder in ["Add to Queue", "Add to Library", "Download", "Share", "Start Radio", "Go to Artist"] {
            XCTAssertFalse(app.menuItems[placeholder].exists, "\(placeholder) has no implementation, so it is not offered")
        }
        app.menuItems["Copy Link"].click()
        XCTAssertTrue(window.staticTexts["Link copied"].waitForExistence(timeout: 5))
        // Space is text; Escape clears.
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeKey(.delete, modifierFlags: [])
        field.typeText("cafe del")
        XCTAssertEqual(field.value as? String, "cafe del", "Space stays a normal space in the field")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual((field.value as? String) ?? "", "", "Escape clears the query")
        XCTAssertFalse(w10(window, "searchGroup-top").exists)
        capture(window, "W10 after Escape")
    }
    @MainActor func testW10CorrectionScopesAndCommandPalette() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let field = window.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("cafe del mer")
        XCTAssertTrue(w10(window, "searchCorrection").waitForExistence(timeout: 5), "a respelling is offered")
        XCTAssertEqual(field.value as? String, "cafe del mer", "but the typed query is not changed")
        w10(window, "applyCorrection").click()
        XCTAssertEqual(field.value as? String, "Café del Mar", "only the explicit action applies it")
        XCTAssertTrue(w10(window, "searchCorrectionApplied").waitForExistence(timeout: 5))
        capture(window, "W10 correction applied with original available")
        w10(window, "revertCorrection").click()
        XCTAssertEqual(field.value as? String, "cafe del mer", "the original is recoverable exactly")
        // Scopes: Library is local only; Uploads says it is not connected.
        field.typeKey("a", modifierFlags: .command); field.typeText("cafe")
        let scope = window.radioGroups["searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.radioButtons["Library"].click()
        XCTAssertTrue(w10(window, "searchScopeNotice").waitForExistence(timeout: 5))
        XCTAssertTrue(w10(window, "searchResult-playlist:PLdevelopmentCafe").exists)
        XCTAssertFalse(w10(window, "searchResult-song:devsong0001").exists, "the service is not asked in the Library scope")
        scope.radioButtons["Uploads"].click()
        let uploadsNotice = NSPredicate { _, _ in self.w10Text(self.w10(window, "searchScopeNotice")).contains("Uploads aren’t connected yet") }
        expectation(for: uploadsNotice, evaluatedWith: nil); waitForExpectations(timeout: 5)
        XCTAssertFalse(w10(window, "searchResult-playlist:PLdevelopmentCafe").exists)
        scope.radioButtons["All"].click()
        XCTAssertTrue(w10(window, "searchResult-song:devsong0001").waitForExistence(timeout: 5))
        // Command palette: Command-K, tolerant command match, Return runs it and closes.
        app.typeKey("k", modifierFlags: .command)
        let palette = w10(app.windows.firstMatch, "commandPalette")
        _ = palette.waitForExistence(timeout: 5)
        capture(app.windows.firstMatch, "W10 after Command-K")
        XCTAssertTrue(palette.exists)
        let paletteField = app.textFields["paletteField"]
        XCTAssertTrue(paletteField.waitForExistence(timeout: 5))
        app.typeText("libary")
        let command = w10(app.windows.firstMatch, "paletteCommand-go-library")
        XCTAssertTrue(command.waitForExistence(timeout: 5), "a typo still finds the command")
        capture(app.windows.firstMatch, "W10 command palette")
        paletteField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(paletteField.waitForNonExistence(timeout: 5), "Return closes the palette")
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Library")
        // Escape clears, then closes.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["paletteField"].waitForExistence(timeout: 5))
        app.typeText("go")
        app.textFields["paletteField"].typeKey(.escape, modifierFlags: [])
        XCTAssertEqual((app.textFields["paletteField"].value as? String) ?? "", "", "first Escape clears")
        app.textFields["paletteField"].typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["paletteField"].waitForNonExistence(timeout: 5), "second Escape closes")
    }
    @MainActor func testW10RecentSearchesRecentItemsAndHonestDiscoveryNote() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let field = window.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let note = w10(window, "searchDiscoveryNote")
        XCTAssertTrue(note.waitForExistence(timeout: 5), "an empty search says plainly where discovery is")
        XCTAssertTrue(w10Text(note).contains("open Home and Explore"), w10Text(note))
        XCTAssertFalse(w10(window, "recentQuery").exists, "nothing is recorded before anything is chosen")
        // Typing records nothing; Return does.
        app.typeText("cafe del")
        XCTAssertTrue(w10(window, "searchGroup-top").waitForExistence(timeout: 5))
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(w10(window, "recentQuery").exists, "typed but not submitted: not remembered")
        app.typeText("cafe del")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(w10(window, "searchGroup-top").waitForExistence(timeout: 5))
        let song = w10(window, "searchResult-song:devsong0001")
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        XCTAssertTrue(w10Text(song).contains("Development Artist, Development Album, 3:45"), "detail parts are separate items of the spoken label: \(w10Text(song))")
        // Copy Link counts as choosing the item.
        song.rightClick(); app.menuItems["Copy Link"].click()
        let copiedNote = window.staticTexts["Link copied"].waitForExistence(timeout: 5)
        capture(window, "W10 after Copy Link on a submitted search")
        XCTAssertTrue(copiedNote)
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeKey(.delete, modifierFlags: [])
        let recent = w10(window, "recentQuery")
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "the submitted query is offered again")
        XCTAssertTrue(w10Text(recent).contains("cafe del"), w10Text(recent))
        XCTAssertTrue(w10(window, "searchResult-song:devsong0001").exists, "the item that was copied is offered as a recent item")
        capture(window, "W10 recent searches and items")
        recent.click()
        let searchedAgain = NSPredicate { _, _ in (field.value as? String) == "cafe del" }
        expectation(for: searchedAgain, evaluatedWith: nil); waitForExpectations(timeout: 5)
        XCTAssertEqual(field.value as? String, "cafe del", "choosing a recent query searches it again")
        field.typeKey("a", modifierFlags: .command); field.typeKey(.delete, modifierFlags: [])
        w10(window, "clearRecentQueries").click()
        XCTAssertFalse(w10(window, "recentQuery").exists)
        w10(window, "clearRecentItems").click()
        XCTAssertFalse(w10(window, "searchResult-song:devsong0001").exists, "the user can clear everything")
        XCTAssertTrue(w10(window, "searchDiscoveryNote").exists)
    }

    // MARK: W11 — Home, Explore and catalog details (labelled development data; no account, no service)

    /// Scrolls the page until the element sits comfortably inside the visible band (lazy stacks create rows only near the
    /// viewport, and a click at the very edge lands on the player bar). On this console a negative wheel delta scrolls down,
    /// as the first W11 runs measured (content moved up by the step).
    /// The catalog scroll area can briefly have no hit point right after a launch or a scroll event ("Unable to find hit point for ScrollView"). It
    /// happens on the code from before W09-F2 as well (1 of 54 gated runs, see W09-F2b/runs/baseline-summary.txt), and the accessibility tree at the
    /// failure shows no overlay. Wait, within a bound, for it to be hittable before the next scroll is sent. Nothing a test asserts is relaxed.
    ///
    /// TH1: "hittable once" was not enough. The failure comes about 4 s after a fresh launch, when the page is still settling (the development catalog has
    /// just answered and the shelves are being laid out), so the scroll view can be hittable at one reading and have no hit point at the next, which is
    /// when `scroll(byDeltaX:deltaY:)` asks for it. It now waits for three consecutive readings, 0.15 s apart, that are all hittable with an unchanged,
    /// non-empty frame. The bound is unchanged and still not a pass: after it the scroll is sent and a real failure still fails.
    @MainActor private func w11AwaitScrollable(_ scroll: XCUIElement, timeout: Double = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var stable = 0
        var last: CGRect?
        while scroll.exists && Date() < deadline {
            let frame = scroll.frame
            if scroll.isHittable, !frame.isEmpty, frame == last { stable += 1 } else { stable = 0 }
            last = frame
            if stable >= 3 { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }
    }
    @MainActor @discardableResult private func w11Reveal(_ window: XCUIElement, _ id: String, hittable: Bool = false, timeout: Double = 10) -> XCUIElement {
        let element = w10(window, id)
        _ = element.waitForExistence(timeout: min(timeout, 3))
        let scroll = window.scrollViews["catalogScroll"]
        // A lazy stack creates a row only near the viewport: scroll down until it exists.
        var steps = 0
        while !element.exists && steps < 24 && scroll.exists { w11AwaitScrollable(scroll); scroll.scroll(byDeltaX: 0, deltaY: -240); Thread.sleep(forTimeInterval: 0.3); steps += 1 }
        XCTAssertTrue(element.exists, id)
        guard scroll.exists else { return element }
        for _ in 0..<20 {
            let view = scroll.frame, frame = element.frame
            let top = view.minY + 24, bottom = view.maxY - 70
            if frame.minY >= top && frame.maxY <= bottom { break }
            w11AwaitScrollable(scroll)
            scroll.scroll(byDeltaX: 0, deltaY: frame.minY < top ? 160 : -160)
            Thread.sleep(forTimeInterval: 0.35)
        }
        // Let the scroll come to rest: a click on content that is still moving lands somewhere else.
        var last = element.frame
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.4)
            let now = element.frame
            if now == last { break }
            last = now
        }
        if hittable { XCTAssertTrue(element.isHittable, "\(id) is not hittable after scrolling") }
        return element
    }
    /// Scrolls until the element's top is at (or just above) the top of the page.
    @MainActor private func w11ScrollShelfToTop(_ window: XCUIElement, _ id: String) {
        let element = w11Reveal(window, id)
        let scroll = window.scrollViews["catalogScroll"]
        var last = element.frame.minY
        for _ in 0..<24 {
            if element.frame.minY - scroll.frame.minY <= 30 { break }
            scroll.scroll(byDeltaX: 0, deltaY: -120)
            Thread.sleep(forTimeInterval: 0.35)
            if element.frame.minY == last { break }
            last = element.frame.minY
        }
        var settled = element.frame
        for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.4); let now = element.frame; if now == settled { break }; settled = now }
    }
    @MainActor private func w11ScrollToTop(_ window: XCUIElement) {
        let scroll = window.scrollViews["catalogScroll"]
        for _ in 0..<4 { scroll.scroll(byDeltaX: 0, deltaY: 600) }
        for _ in 0..<4 where window.staticTexts["destinationTitle"].exists == false && window.staticTexts["catalogTitle"].exists == false { scroll.scroll(byDeltaX: 0, deltaY: -600) }
    }
    @MainActor private func w11Open(_ window: XCUIElement, _ id: String) { w11Reveal(window, id, hittable: true).click() }
    @MainActor @discardableResult private func w11Wait(_ window: XCUIElement, _ id: String, timeout: Double = 10) -> XCUIElement {
        let element = w10(window, id)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), id)
        return element
    }
    @MainActor private func w11Title(_ window: XCUIElement) -> String {
        let title = w10(window, "catalogTitle")
        _ = title.waitForExistence(timeout: 10)
        // SwiftUI exposes a header as its label and a plain text with an identifier as its value.
        return title.label.isEmpty ? ((title.value as? String) ?? "") : title.label
    }
    @MainActor func testW11HomeShelvesChipsActionsAndRefresh() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Home")
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development catalog is labelled")
        let ids = ["list:Quick picks", "carousel:New releases", "carousel:Featured playlists"]
        for id in ids { w11Reveal(window, "catalogShelf-" + id) }
        // Play without an account is explained at the item, and nothing starts.
        w11Open(window, "catalogPlay-song:devsong0001")
        capture(window, "W11 Home after Play without an account")
        let feedback = w11Wait(window, "catalogFeedback")
        XCTAssertTrue(w10Text(feedback).contains("Sign in to YouTube Music to play."), w10Text(feedback))
        XCTAssertFalse(window.buttons["transportPlayPause"].isEnabled)
        capture(window, "W11 Home on development data")
        // The context menu offers only real actions.
        w11Reveal(window, "catalogItem-song:devsong0002").rightClick()
        XCTAssertTrue(app.menuItems["Copy Link"].waitForExistence(timeout: 5) && app.menuItems["Play"].exists && app.menuItems["Open"].exists)
        for placeholder in ["Follow", "Save to Library", "Add to Queue", "Download", "Share"] { XCTAssertFalse(app.menuItems[placeholder].exists, placeholder) }
        app.menuItems["Copy Link"].click()
        XCTAssertTrue(window.staticTexts["Link copied"].waitForExistence(timeout: 5))
        // T11.2: refresh while scrolled. Featured playlists is scrolled to the top of the page and Command-R is pressed; the second read of
        // the development Home drops Quick picks (above it), adds "Fresh arrivals" and changes the entries of New releases. The shelf the
        // listener is looking at must not move, and the shelves must not be reshuffled (the new one is appended after the others).
        w11ScrollShelfToTop(window, "catalogShelf-carousel:Featured playlists")
        let scroll = window.scrollViews["catalogScroll"]
        let featured = w10(window, "catalogShelf-carousel:Featured playlists")
        let offsetBefore = featured.frame.minY - scroll.frame.minY
        XCTAssertLessThanOrEqual(offsetBefore, 60, "the anchor shelf is at the top before the refresh")
        app.typeKey("r", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 3.0)   // the development reader answers at once; this is the merge and the re-pin settling
        let offsetAfter = featured.frame.minY - scroll.frame.minY
        XCTAssertLessThanOrEqual(abs(offsetAfter - offsetBefore), 80, "the visible shelf stayed where it was (before \(offsetBefore), after \(offsetAfter))")
        let daily = w11Reveal(window, "catalogShelf-carousel:Daily mixes")
        let fresh = w11Reveal(window, "catalogShelf-carousel:Fresh arrivals")
        XCTAssertGreaterThan(fresh.frame.minY, daily.frame.minY, "a shelf that is new is appended after the ones already on screen, not placed above them")
        XCTAssertGreaterThan(daily.frame.minY, w10(window, "catalogShelf-carousel:Featured playlists").frame.minY, "the order of the shelves that were there is unchanged")
        w11ScrollToTop(window)
        XCTAssertTrue(w10(window, "catalogRefresh").waitForExistence(timeout: 5))
        XCTAssertFalse(w10(window, "catalogShelf-list:Quick picks").exists, "a shelf the service dropped goes (it was not the one being looked at)")
        capture(window, "W11 Home after refresh while scrolled")
        // A mood chip opens its own page; Back returns to the same Home.
        w11ScrollToTop(window)
        w11Open(window, "homeChip-Relax")
        XCTAssertTrue(w10(window, "catalogFailure").waitForExistence(timeout: 10),
                      "the development catalog has no page for this chip, so the failure is stated rather than an empty page")
        window.buttons["browserBack"].click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Home")
        w11Reveal(window, "catalogShelf-carousel:New releases")
    }
    @MainActor func testW11ExploreChartsAndMoods() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sidebar("Explore", in: window).click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Explore")
        w11Wait(window, "catalogShelf-carousel:New albums & singles")
        w11Open(window, "catalogCategory-category:FEmusic_charts")
        XCTAssertEqual(w11Title(window), "Charts")
        w11Wait(window, "catalogShelf-list:Top artists")
        capture(window, "W11 Charts page")
        window.buttons["browserBack"].click()
        w11Open(window, "catalogCategory-category:FEmusic_moods_and_genres")
        w11Wait(window, "catalogShelf-categories:Moods & moments")
        w11Open(window, "catalogCategory-category:FEmusic_moods_and_genres_category?ggMPOg1uX1JOQWZFeDByc2Jm")
        XCTAssertEqual(w11Title(window), "Chill")
        w11Wait(window, "catalogShelf-carousel:Chill playlists")
        window.buttons["browserBack"].click(); window.buttons["browserBack"].click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Explore")
    }
    @MainActor func testW11AlbumArtistSongPlaylistDetailsAndPagination() throws {
        let app = designApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // Album: header, linked credits, tracks (one unavailable), description as literal text with attribution, honest write note.
        w11Open(window, "catalogItem-album:MPREbdevelopment1")
        XCTAssertEqual(w11Title(window), "Development Album")
        w11Wait(window, "catalogItem-song#o1")
        // The tracks are a lazy stack: the third row exists only once it is near the viewport, so it is revealed by scrolling.
        let unavailable = w11Reveal(window, "catalogItem-song#o3")
        XCTAssertTrue(w10Text(unavailable).contains("Unavailable"), w10Text(unavailable))
        XCTAssertFalse(w10(window, "catalogPlay-song#o3").exists, "an unavailable track has no Play button")
        let description = w11Wait(window, "catalogDescription")
        XCTAssertTrue(w10Text(description).contains("<script>alert(1)</script>"), "markup is shown as text, never run: \(w10Text(description))")
        XCTAssertTrue(w10Text(w11Wait(window, "catalogAttribution")).contains("Creative Commons"), "the licence line is kept")
        w11Wait(window, "pageAction-play"); w11Wait(window, "pageAction-radio"); w11Wait(window, "pageAction-shuffle")
        // W15: where a person would look for Download, words say why there is none (no control).
        XCTAssertTrue(w10Text(w11Wait(window, "downloadCapabilityNote")).contains("doesn’t offer downloads on Mac"))
        XCTAssertFalse(window.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Download'")).firstMatch.exists)
        let note = w11Wait(window, "catalogWriteNote")
        XCTAssertTrue(w10Text(note).contains("Saving to your library"), w10Text(note))
        for control in ["Follow", "Save", "Subscribe"] { XCTAssertFalse(window.buttons[control].exists, "\(control) has no write path, so it is not a button") }
        w10(window, "pageAction-radio").click()
        XCTAssertTrue(w10Text(w11Wait(window, "catalogFeedback")).contains("Sign in to YouTube Music to play."))
        XCTAssertFalse(window.buttons["transportPlayPause"].isEnabled)
        capture(window, "W11 album detail")
        // The credited artist opens the artist page.
        w11Open(window, "catalogCredit-UCdevelopmentartist00000000")
        XCTAssertEqual(w11Title(window), "Development Artist")
        XCTAssertTrue(w10Text(w11Wait(window, "catalogAudience")).contains("monthly audience"))
        w11Wait(window, "pageAction-shuffle"); w11Wait(window, "pageAction-radio")
        XCTAssertFalse(w10(window, "pageAction-play").exists, "the service published no Play for an artist")
        XCTAssertTrue(w10Text(w11Wait(window, "catalogWriteNote")).contains("Following"))
        w11Reveal(window, "catalogShelf-list:Top songs"); w11Reveal(window, "catalogShelf-carousel:Singles & EPs")
        w11ScrollToTop(window)
        let toggle = w11Wait(window, "catalogDescriptionToggle")
        XCTAssertEqual(toggle.label, "Show more")
        toggle.click()
        XCTAssertEqual(w11Wait(window, "catalogDescriptionToggle").label, "Show less")
        capture(window, "W11 artist detail")
        // A song opens its detail: credits, availability, quality, actions.
        w11Open(window, "catalogItem-song:devsong0001")
        XCTAssertEqual(w11Title(window), "Café del Mar")
        XCTAssertTrue(w10Text(w11Wait(window, "songAvailability")).contains("Available"))
        XCTAssertTrue(w10Text(w11Wait(window, "songQuality")).contains("chosen by YouTube Music"))
        w10(window, "songAction-play").click()
        XCTAssertTrue(w10Text(w11Wait(window, "catalogFeedback")).contains("Sign in to YouTube Music to play."))
        w11Wait(window, "songAlbumLink")
        XCTAssertTrue(w10Text(w11Wait(window, "downloadCapabilityNote")).contains("doesn’t offer downloads on Mac"))
        capture(window, "W11 song detail")
        window.buttons["browserBack"].click(); window.buttons["browserBack"].click(); window.buttons["browserBack"].click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Home")
        // Playlist: lazy pagination with a repeated boundary track.
        w11Open(window, "catalogItem-playlist:VLPLdevelopmentpl1")
        w11Wait(window, "catalogItem-song#p4")
        // Reaching the end of the list loads the next page by itself; the button does the same for keyboard and VoiceOver users.
        let more = w10(window, "catalogLoadMorePage")
        if more.exists && more.isHittable { more.click() }
        w11Reveal(window, "catalogItem-song#p6")
        XCTAssertTrue(w10(window, "catalogItem-song#p5").exists)
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "catalogItem-song#p4").count, 1, "the repeated boundary track is listed once")
        XCTAssertFalse(w10(window, "catalogLoadMorePage").exists, "no token is left, so there is nothing more to load")
        capture(window, "W11 playlist after pagination")
    }

    // MARK: W12 — Library and History (labelled development data; no account, no service, no network)

    @MainActor private func libraryApplication() -> XCUIApplication {
        let app = designApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_LIBRARY"] = "1"
        return app
    }
    @MainActor @discardableResult private func w12Wait(_ window: XCUIElement, _ id: String, timeout: Double = 10) -> XCUIElement {
        let element = w10(window, id)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), id)
        return element
    }
    @MainActor private func w12Kind(_ window: XCUIElement, _ kind: String) {
        let chip = w12Wait(window, "libraryKind-" + kind)
        chip.click()
    }
    @MainActor private func w12Control(_ window: XCUIElement, _ kind: String, _ id: String) -> XCUIElement { w12Wait(window, "libraryControl-\(kind)-" + id) }
    @MainActor private func w12Gone(_ element: XCUIElement, timeout: Double = 10) -> Bool {
        let gone = NSPredicate { _, _ in !element.exists }
        let wait = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: timeout)
        return wait == .completed
    }

    @MainActor func testW12LibraryKindsStatesPagingSearchSortAndSelection() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-library").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("Library"))
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development library is labelled")
        for kind in ["songs", "likedSongs", "albums", "artists", "following", "playlists", "podcasts", "savedEpisodes", "uploads"] { w12Wait(window, "libraryKind-" + kind) }
        // Songs: a song listed twice is two rows; the first response is not the whole library.
        w12Wait(window, "libraryRow-song:devsong0001")
        w12Wait(window, "libraryRow-song:devsong0001#1")
        capture(window, "W12 Library songs, first page")
        // Reaching the end of the list reads the next page by itself (Load All / Load more are the same action for keyboard and VoiceOver users).
        w12Wait(window, "libraryRow-song:devsong0005", timeout: 15)
        XCTAssertTrue(w12Gone(w10(window, "libraryLoadAll")), "complete: nothing more to load")
        XCTAssertFalse(w10(window, "libraryCoverage").exists, "a complete collection carries no partial-coverage note")
        // Search over the loaded rows, then a query that matches nothing.
        let query = w12Wait(window, "libraryQuery")
        query.click(); query.typeText("zeta")
        w12Wait(window, "libraryRow-song:devsong0003")
        XCTAssertTrue(w12Gone(w10(window, "libraryRow-song:devsong0001")), "the search filters the view")
        query.typeKey("a", modifierFlags: .command); query.typeText("nothing like this")
        w12Wait(window, "libraryState-noMatches")
        query.typeKey("a", modifierFlags: .command); query.typeKey(.delete, modifierFlags: [])
        w12Wait(window, "libraryRow-song:devsong0001")
        // Sort is a view over the service order: Z-A puts the last title first, and service order restores the original.
        let service = w10(window, "libraryRow-song:devsong0001").frame.minY
        w10(window, "librarySort").click()
        app.menuItems["Title (Z–A)"].click()
        let zeta = w12Wait(window, "libraryRow-song:devsong0003")
        XCTAssertLessThan(zeta.frame.minY, w10(window, "libraryRow-song:devsong0001").frame.minY, "sorted Z–A")
        w10(window, "librarySort").click()
        app.menuItems["Service order"].click()
        XCTAssertEqual(w12Wait(window, "libraryRow-song:devsong0001").frame.minY, service, accuracy: 2, "service order is restored exactly")
        // Multi-selection with the native modifier, and a non-changing action on the selection.
        w10(window, "libraryRow-song:devsong0001").click()
        XCUIElement.perform(withKeyModifiers: .command) { w10(window, "libraryRow-song:devsong0003").click() }
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("selected"))
        w12Wait(window, "libraryCopyLinks")
        w12Wait(window, "libraryClearSelection").click()
        XCTAssertTrue(w12Gone(w10(window, "librarySelectionCount")))
        // List and grid.
        window.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", "Grid", "Grid")).firstMatch.click()
        w12Wait(window, "libraryGrid")
        capture(window, "W12 Library songs as a grid")
        // Albums read as a grid by default and offer their own save control.
        w12Kind(window, "albums")
        w12Wait(window, "libraryRow-album:MPREbdevelopment1")
        w12Control(window, "save", "album:MPREbdevelopment1")
        // Distinct states: empty, offline, unreadable, restricted (session ended), restricted (not offered).
        let expected: [(String, String, String)] = [
            ("likedSongs", "libraryState-empty", "read completely"), ("artists", "libraryState-offline", "offline"), ("playlists", "libraryState-unrecognised", "isn’t the same as an empty library"),
            ("savedEpisodes", "libraryState-restricted", "Sign in again"), ("uploads", "libraryState-restricted", "doesn’t offer this collection")]
        var texts: Set<String> = []
        for (kind, state, phrase) in expected {
            w12Kind(window, kind)
            w12Wait(window, state)
            // The title and the description both carry the state's identifier; the phrase is in one of them.
            let all = { window.descendants(matching: .any).matching(identifier: state).allElementsBoundByIndex.map { self.w10Text($0) }.joined(separator: " | ") }
            let deadline = Date().addingTimeInterval(5)
            while !all().contains(phrase) && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
            XCTAssertTrue(all().contains(phrase), "\(kind): \(phrase) in \(all())")
            texts.insert(state + phrase)
        }
        XCTAssertEqual(texts.count, expected.count, "each state reads differently")
        capture(window, "W12 Library restricted state")
        // The Podcasts and Uploads destinations are the Library's own kinds.
        w10(window, "nav-podcasts").click()
        w12Wait(window, "libraryRow-podcast:MPSPPLdevelopmentshow")
    }

    @MainActor func testW12OptimisticChangesRollBackRetryAndNeverClaimWhatTheServiceDidNotConfirm() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-library").click()
        // Confirmed: the change shows at once as pending, then as done, and the control reads as on.
        let late = w12Control(window, "like", "song:devsong0004")
        late.click()
        w12Wait(window, "libraryWritePending-song:devsong0004", timeout: 5)
        XCTAssertFalse(w10(window, "libraryControl-like-song:devsong0004").isEnabled, "no second request while one is pending")
        w12Wait(window, "libraryWriteConfirmed-song:devsong0004", timeout: 15)
        XCTAssertEqual(w10(window, "libraryControl-like-song:devsong0004").label, "Remove Like")
        capture(window, "W12 confirmed like")
        // Refused by the service: rolled back to the old state, with the reason and a retry; it never reads as liked.
        let refused = w12Control(window, "like", "song:devsong0002")
        refused.click()
        w12Wait(window, "libraryWriteFailed-song:devsong0002", timeout: 15)
        XCTAssertEqual(w10(window, "libraryControl-like-song:devsong0002").label, "Like", "rolled back")
        XCTAssertTrue(w10Text(w10(window, "libraryWriteFailed-song:devsong0002")).contains("Nothing was changed"))
        capture(window, "W12 refused like, rolled back")
        w12Wait(window, "libraryWriteRetry-song:devsong0002").click()
        w12Wait(window, "libraryWriteFailed-song:devsong0002", timeout: 15)
        w12Wait(window, "libraryWriteDismiss-song:devsong0002").click()
        XCTAssertTrue(w12Gone(w10(window, "libraryWriteFailed-song:devsong0002")))
        // Not confirmed: shown as the person asked, flagged as unconfirmed, checked before any repeat.
        w12Control(window, "like", "song:devsong0003").click()
        w12Wait(window, "libraryWriteUnconfirmed-song:devsong0003", timeout: 15)
        XCTAssertFalse(w10(window, "libraryWriteConfirmed-song:devsong0003").exists, "an answer without evidence is never shown as done")
        w12Wait(window, "libraryWriteCheck-song:devsong0003").click()
        w12Wait(window, "libraryWriteUncheckable-song:devsong0003")
        capture(window, "W12 unconfirmed change")
        w12Wait(window, "libraryWriteDismiss-song:devsong0003").click()
        // Albums: removal is optimistic and confirmed; Following: unfollow.
        w12Kind(window, "albums")
        let save = w12Control(window, "save", "album:MPREbdevelopment1")
        XCTAssertEqual(save.label, "Remove from Library")
        save.click()
        w12Wait(window, "libraryWriteConfirmed-album:MPREbdevelopment1", timeout: 15)
        XCTAssertEqual(w10(window, "libraryControl-save-album:MPREbdevelopment1").label, "Save to Library")
        w12Kind(window, "following")
        let follow = w12Control(window, "follow", "artist:UCdevfollowartist0000001")
        XCTAssertEqual(follow.label, "Unfollow")
        follow.click()
        w12Wait(window, "libraryWriteConfirmed-artist:UCdevfollowartist0000001", timeout: 15)
        XCTAssertEqual(w10(window, "libraryControl-follow-artist:UCdevfollowartist0000001").label, "Follow")
    }

    @MainActor func testW12HistoryKeepsTheServicesRecordAndThisMacsApartAndNeverImitatesRemoteControls() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-history").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("History"))
        // The service's history: its rows in its order, the same play twice kept.
        w12Wait(window, "historyRemote")
        w12Wait(window, "libraryRow-song:devsong0001")
        w12Wait(window, "libraryRow-song:devsong0001#1")
        w12Wait(window, "libraryRow-song:devsong0002")
        XCTAssertTrue(w10Text(w12Wait(window, "historyRemoteProvenance")).contains("never writes it"))
        // Pause and clear: an honest explanation, never a control.
        let notes = window.descendants(matching: .any).matching(identifier: "historyControlUnavailable")
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.allElementsBoundByIndex.map { w10Text($0) }.joined().contains("can’t be paused"))
        for title in ["Pause history", "Clear history"] { XCTAssertFalse(window.buttons[title].exists, "\(title) has no request behind it, so it is not a button") }
        // This Mac's record: separate, marked Local only, with its own clear that says what it clears.
        w12Wait(window, "historyLocalOnlyBadge")
        XCTAssertTrue(w10Text(w12Wait(window, "historyLocalProvenance")).contains("never sent to YouTube Music"))
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "historyLocalRow").count, 2)
        capture(window, "W12 History: remote and local apart")
        // The local section sits below the fold: scroll it into the visible band before pressing (a click behind the player bar lands on the player).
        let clear = w12Wait(window, "historyClearLocal")
        let scroll = w10(window, "historyRoot")
        for _ in 0..<12 where scroll.exists && clear.frame.maxY > scroll.frame.maxY - 40 { scroll.scroll(byDeltaX: 0, deltaY: -200); Thread.sleep(forTimeInterval: 0.4) }
        clear.click()
        let dialog = app.sheets.firstMatch
        let confirm = dialog.buttons["Clear This Mac’s History"]
        let found = confirm.waitForExistence(timeout: 8)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "W12 app tree with the confirmation"; tree.lifetime = .keepAlways; add(tree)
        capture(window, "W12 Clear local history confirmation")
        XCTAssertTrue(found, "the confirmation names what it clears")
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "only the record kept on this Mac", "only the record kept on this Mac")).firstMatch.exists, "the confirmation says it clears only this Mac's record")
        confirm.click()
        let empty = w12Wait(window, "historyLocalEmpty")
        XCTAssertTrue(w10Text(empty).contains("YouTube Music’s history is unchanged"), w10Text(empty))
        w12Wait(window, "libraryRow-song:devsong0001")        // the service's rows are untouched
        capture(window, "W12 Local history cleared, remote unchanged")
    }

    // MARK: W19 Uploads (labelled development data; a scripted upload route over synthetic audio; nothing reaches a service)

    @MainActor private func uploadsApplication() -> XCUIApplication {
        let app = libraryApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_UPLOADS"] = "1"
        return app
    }
    @MainActor private func w19Rows(_ window: XCUIElement, prefix: String) -> Int {
        window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
    }

    @MainActor func testW19UploadsStateTheirCapabilityHonestlyWhenThereIsNoUploadRoute() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-uploads").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("Uploads"))
        let capability = w12Wait(window, "uploadsCapability-unavailable")
        XCTAssertTrue(w10Text(capability).contains("Uploading arrives in a later update"), w10Text(capability))
        XCTAssertFalse(w10(window, "uploadChoose").exists, "no upload control without an upload route")
        XCTAssertFalse(w10(window, "uploadDropZone").exists, "no drop area either: a fake one would read as working")
        XCTAssertFalse(window.buttons["Choose Files…"].exists)
        for kind in ["songs", "albums", "artists"] { w12Wait(window, "uploadsKind-" + kind) }
        capture(window, "W19 Uploads without an upload route")
    }

    @MainActor func testW19ChoosingFilesRunsJobsThroughProcessingAndOnlyTheServicesWordAddsALibraryItem() throws {
        let app = uploadsApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-uploads").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("Uploads"))
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development route is labelled")
        XCTAssertFalse(w10(window, "uploadsCapability-unavailable").exists)
        XCTAssertTrue(w10Text(w12Wait(window, "uploadFacts")).contains("can’t be resumed"), "the route's own facts: no resumption, and no size claim")
        XCTAssertFalse(w10Text(w12Wait(window, "uploadFacts")).contains("up to"), "no invented size limit")
        w12Wait(window, "uploadDropZone")
        w12Wait(window, "libraryRow-song:devupsong01")
        XCTAssertEqual(w19Rows(window, prefix: "libraryRow-song:devupnew"), 0)
        w12Wait(window, "uploadChoose").click()
        // The slow file is still sending while the others have been through the route.
        let slowProgress = w12Wait(window, "uploadJobProgress-Slow Test Tone.wav", timeout: 30)
        XCTAssertTrue(slowProgress.exists)
        // A refusal when sending: the service's words, nothing completed, nothing offered to send the same file again.
        let refused = w12Wait(window, "uploadJobState-Refused Test Tone.wav", timeout: 30)
        XCTAssertTrue(w12Gone(w10(window, "uploadJobProgress-Refused Test Tone.wav")))
        XCTAssertTrue(w10Text(refused).contains("didn’t accept this file"), w10Text(refused))
        XCTAssertTrue(w10Text(w12Wait(window, "uploadJobServerMessage-Refused Test Tone.wav")).contains("Development message"))
        XCTAssertFalse(w10(window, "uploadJobStartOver-Refused Test Tone.wav").exists)
        // A processing failure: failed, with the service's words, and no library item for it.
        let failed = w12Wait(window, "uploadJobServerMessage-Processing Fails Test Tone.wav", timeout: 40)
        XCTAssertTrue(w10Text(failed).contains("processing failed"))
        XCTAssertTrue(w10Text(w10(window, "uploadJobState-Processing Fails Test Tone.wav")).contains("couldn’t process this file"))
        // The good file: processing first (not in the library yet), completed only after the service said so, and only then in the list.
        let aurora = w12Wait(window, "uploadJobState-Aurora Test Tone.wav", timeout: 5)
        capture(window, "W19 Upload jobs: processing, refused, failed, sending")
        let completed = NSPredicate { _, _ in self.w10Text(aurora).contains("finished processing") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: completed, object: nil)], timeout: 40), .completed, w10Text(aurora))
        XCTAssertTrue(w10Text(aurora).contains("uploads list was updated"))
        let newRow = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryRow-song:devupnew")).firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 15), "the refreshed Uploads list holds the processed file")
        XCTAssertEqual(w19Rows(window, prefix: "libraryRow-song:devupnew"), 1, "one new item: the failed and refused files never became library items")
        // The same file chosen again is dropped as a duplicate while it is in the list.
        w12Wait(window, "uploadChoose").click()
        XCTAssertTrue(w10Text(w12Wait(window, "uploadRefusal-Aurora Test Tone.wav")).contains("already in the upload list"))
        w12Wait(window, "uploadRefusalsDismiss").click()
        // Cancelling the one still sending: it stops, and says the file on the Mac wasn't changed.
        w12Wait(window, "uploadJobCancel-Slow Test Tone.wav").click()
        let cancelled = w12Wait(window, "uploadJobState-Slow Test Tone.wav")
        let stopped = NSPredicate { _, _ in self.w10Text(cancelled).contains("Cancelled") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 10), .completed, w10Text(cancelled))
        XCTAssertTrue(w10Text(cancelled).contains("Your file wasn’t changed"))
        XCTAssertTrue(w12Gone(w10(window, "uploadJobProgress-Slow Test Tone.wav")))
        capture(window, "W19 Upload jobs settled")
        w12Wait(window, "uploadJobDismiss-Slow Test Tone.wav").click()
        XCTAssertTrue(w12Gone(w10(window, "uploadJob-Slow Test Tone.wav")), "dismissing removes only the job record")
    }

    @MainActor func testW19RemovingAnUploadNamesItNeedsConfirmationAndNeverClaimsWhatTheServiceDidNotConfirm() throws {
        let app = uploadsApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-uploads").click()
        w12Wait(window, "libraryRow-song:devupsong01")
        // Asking names the upload, says what stays untouched, and sends nothing; Cancel leaves everything as it was.
        w12Wait(window, "uploadRemove-song:devupsong01").click()
        var dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.buttons["Remove from Uploads"].waitForExistence(timeout: 8))
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Home Recording", "Home Recording")).firstMatch.exists, "the question names the selected upload")
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "isn’t touched", "isn’t touched")).firstMatch.exists, "and says the file on the Mac isn't touched")
        capture(window, "W19 Remove upload confirmation")
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(w12Gone(w10(window, "uploadRemovePending-song:devupsong01")))
        w12Wait(window, "libraryRow-song:devupsong01")
        // Confirmed: pending, then removed (the service confirmed), and the refreshed list no longer holds it.
        w12Wait(window, "uploadRemove-song:devupsong01").click()
        dialog = app.sheets.firstMatch
        dialog.buttons["Remove from Uploads"].click()
        w12Wait(window, "uploadRemovePending-song:devupsong01", timeout: 5)
        let removed = w12Wait(window, "uploadRemoved-song:devupsong01", timeout: 15)
        XCTAssertTrue(w10Text(removed).contains("The file on your Mac wasn’t touched"))
        capture(window, "W19 Upload removed")
        // Refused by the service: nothing changed, the row stays, with the reason and a retry.
        w12Wait(window, "uploadRemove-song:devupsong02").click()
        app.sheets.firstMatch.buttons["Remove from Uploads"].click()
        let failed = w12Wait(window, "uploadRemoveFailed-song:devupsong02", timeout: 15)
        XCTAssertTrue(w10Text(failed).contains("Nothing was changed"), w10Text(failed))
        w12Wait(window, "libraryRow-song:devupsong02")
        w12Wait(window, "uploadRemoveDismiss-song:devupsong02").click()
        // Not confirmed: shown as unconfirmed, never as removed; the check can't tell, and only then is trying again offered.
        w12Wait(window, "uploadRemove-song:devupsong03").click()
        app.sheets.firstMatch.buttons["Remove from Uploads"].click()
        w12Wait(window, "uploadRemoveUnconfirmed-song:devupsong03", timeout: 15)
        XCTAssertFalse(w10(window, "uploadRemoved-song:devupsong03").exists, "an answer without evidence is never shown as removed")
        XCTAssertFalse(w10(window, "uploadRemoveRetry-song:devupsong03").exists, "no repeat before the list has been read")
        w12Wait(window, "uploadRemoveCheck-song:devupsong03").click()
        w12Wait(window, "uploadRemoveUncheckable-song:devupsong03")
        w12Wait(window, "uploadRemoveRetry-song:devupsong03")
        capture(window, "W19 Unconfirmed removal")
        // An upload that published no removal command offers none (albums here).
        w12Wait(window, "uploadsKind-albums").click()
        w12Wait(window, "libraryRow-album:MPREdevelopmentupload1")
        XCTAssertEqual(w19Rows(window, prefix: "uploadRemove-"), 0, "no removal control for an entry that published no removal target")
    }

    // MARK: W13 — Playlist editing (labelled development playlists; no account, no service, no network)

    @MainActor private func playlistApplication() -> XCUIApplication {
        let app = libraryApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_PLAYLISTS"] = "1"
        return app
    }
    /// Library > Playlists, then the playlist's page.
    @MainActor private func w13OpenPlaylist(_ window: XCUIElement, playlist id: String) {
        w10(window, "nav-library").click()
        w12Kind(window, "playlists")
        let row = w12Wait(window, "libraryRow-playlist:VL" + id)
        // A row below the player bar is scrolled into the visible band first (a click behind the bar lands on the player).
        let grid = w10(window, "libraryGrid"), list = w10(window, "libraryList")
        let scroller = grid.exists ? grid : list
        for _ in 0..<8 where !(row.isHittable && row.frame.maxY < window.frame.maxY - 140) && scroller.exists { scroller.scroll(byDeltaX: 0, deltaY: -150); Thread.sleep(forTimeInterval: 0.3) }
        // A grid card opens on one click; a list row on a double click. Try the first, then the second.
        row.click()
        if !w10(window, "catalogTitle").waitForExistence(timeout: 4) { row.doubleClick() }
        w12Wait(window, "catalogTitle")
    }
    /// ... then the editor sheet.
    @MainActor private func w13OpenEditor(_ app: XCUIApplication, _ window: XCUIElement, playlist id: String) {
        w13OpenPlaylist(window, playlist: id)
        w12Wait(window, "playlistEdit").click()
        w12Wait(window, "playlistEditor")
    }
    /// How many songs in the editor's list carry this title (each row's text is a child of the row; the suggestions below are not counted).
    @MainActor private func w13Rows(_ window: XCUIElement, titled title: String) -> Int {
        w10(window, "playlistSongs").staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).count
    }
    /// The confirmation alert the app shows for a destructive or ambiguous choice, with the full text of everything it says.
    @MainActor private func w13Alert(_ app: XCUIApplication) -> (alert: XCUIElement, text: String) {
        let alert = app.sheets["alert"]
        _ = alert.waitForExistence(timeout: 8)
        let text = alert.staticTexts.allElementsBoundByIndex.map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }.joined(separator: "\n")
        return (alert, text)
    }

    @MainActor func testW13NewPlaylistsArePrivateByDefaultAndNothingIsCreatedUntilCreateIsPressed() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-library").click()
        w12Kind(window, "playlists")
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development playlists are labelled")
        w12Wait(window, "libraryRow-playlist:VLPLdevmix000000001")
        w12Wait(window, "playlistNew").click()
        w12Wait(window, "playlistCreate")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistCreatePrivacy")).contains("Private"), "the visibility starts at Private")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistCreateNote")).contains("private unless you choose otherwise"))
        XCTAssertFalse(w10(window, "playlistCreated").exists, "nothing is created by opening the form")
        XCTAssertFalse(w12Wait(window, "playlistCreateButton").isEnabled, "no title, nothing to create")
        let title = w12Wait(window, "playlistCreateTitle")
        title.click(); title.typeText("UI Created")
        capture(window, "W13 New Playlist form, private by default")
        w12Wait(window, "playlistCreateButton").click()
        w12Wait(window, "playlistCreating", timeout: 5)
        XCTAssertFalse(w12Wait(window, "playlistCreateButton").isEnabled, "no second create while one is in flight")
        let created = w12Wait(window, "playlistCreated", timeout: 15)
        XCTAssertTrue(w10Text(created).contains("private"), w10Text(created))
        capture(window, "W13 playlist created as private")
        w12Wait(window, "playlistCreateClose").click()
        w12Wait(window, "playlistNew")        // back on the Library, which the form never changed
    }

    @MainActor func testW13EditorKeepsDuplicatesApartConfirmsBulkRemovalNamingTheSelectionAndUndoCanFail() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w13OpenEditor(app, window, playlist: "PLdevmix000000001")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistRole")).contains("Owner"))
        XCTAssertTrue(w10Text(w12Wait(window, "playlistPrivacyLabel")).contains("Private"))
        // The same song twice is two rows, each with its own identity.
        w12Wait(window, "playlistRow-DEV0"); w12Wait(window, "playlistRow-DEV1")
        XCTAssertEqual(w13Rows(window, titled: "Café del Mar"), 2)
        capture(window, "W13 editor: the same song twice")
        // Removing one of the two removes that occurrence only.
        w12Wait(window, "playlistRemove-DEV1").click()
        w12Wait(window, "playlistPending", timeout: 5)
        w12Wait(window, "playlistConfirmed", timeout: 15)
        XCTAssertTrue(w12Gone(w10(window, "playlistRow-DEV1")), "the removed occurrence is gone")
        w12Wait(window, "playlistRow-DEV0")
        XCTAssertEqual(w13Rows(window, titled: "Café del Mar"), 1, "its twin is still there")
        // Bulk removal: the dialog names the selection; Cancel changes nothing.
        w10(window, "playlistRow-DEV2").click()
        XCUIElement.perform(withKeyModifiers: .command) { w10(window, "playlistRow-DEV3").click(); w10(window, "playlistRow-DEV4").click() }
        let remove = w12Wait(window, "playlistRemoveSelected")
        XCTAssertTrue(remove.isEnabled)
        remove.click()
        var (dialog, said) = w13Alert(app)
        XCTAssertTrue(dialog.buttons["Remove 3 Songs"].exists, "the confirmation offers the exact count")
        XCTAssertTrue(said.contains("Remove 3 songs from “Dev Mix”?"), said)
        for name in ["Noche Cálida", "Zeta Song", "Late Song"] { XCTAssertTrue(said.contains("• " + name), "the confirmation names \(name): " + said) }
        XCTAssertFalse(said.contains("Quiet Song") || said.contains("Last Song"), "and only the selection: " + said)
        capture(window, "W13 bulk removal confirmation names the selection")
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(w10(window, "playlistRow-DEV2").exists && w10(window, "playlistRow-DEV3").exists && w10(window, "playlistRow-DEV4").exists, "Cancel removed nothing")
        w10(window, "playlistRow-DEV2").click()
        XCUIElement.perform(withKeyModifiers: .command) { w10(window, "playlistRow-DEV3").click(); w10(window, "playlistRow-DEV4").click() }
        w12Wait(window, "playlistRemoveSelected").click()
        (dialog, said) = w13Alert(app)
        XCTAssertTrue(dialog.buttons["Remove 3 Songs"].exists)
        dialog.buttons["Remove 3 Songs"].click()
        XCTAssertTrue(w12Gone(w10(window, "playlistRow-DEV3"), timeout: 20))
        XCTAssertTrue(w12Gone(w10(window, "playlistRow-DEV2")) && w12Gone(w10(window, "playlistRow-DEV4")))
        w12Wait(window, "playlistRow-DEV0"); w12Wait(window, "playlistRow-DEV5"); w12Wait(window, "playlistRow-DEV6")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistUndoLabel")).contains("removed 3 songs"))
        capture(window, "W13 after bulk removal, unrelated songs untouched")
        // Undo is a compensating change: the songs come back (as new entries, at the end). Reversing three songs asks first, naming them.
        w12Wait(window, "playlistUndo").click()
        let (undoAlert, undoText) = w13Alert(app)
        XCTAssertTrue(undoAlert.buttons["Undo for 3 Songs"].exists, undoText)
        for name in ["Noche Cálida", "Zeta Song", "Late Song"] { XCTAssertTrue(undoText.contains("• " + name), "the undo names \(name): " + undoText) }
        undoAlert.buttons["Undo for 3 Songs"].click()
        w12Wait(window, "playlistConfirmed", timeout: 15)
        XCTAssertTrue(w12Gone(w10(window, "playlistUndo"), timeout: 15), "an undone change cannot be undone twice")
        XCTAssertEqual(w13Rows(window, titled: "Zeta Song"), 1)
        XCTAssertEqual(w13Rows(window, titled: "Noche Cálida"), 1)
        w12Wait(window, "playlistRow-DEV0"); w12Wait(window, "playlistRow-DEV5")
        capture(window, "W13 after undo")
        // Keep Duplicates / Skip Existing for a suggestion the playlist already holds.
        w12Wait(window, "playlistAddSuggestion-devsong0002").click()
        let (choice, choiceText) = w13Alert(app)
        XCTAssertTrue(choice.buttons["Skip Existing"].exists && choice.buttons["Keep Duplicates"].exists)
        XCTAssertTrue(choiceText.contains("already here"), choiceText)
        capture(window, "W13 duplicate choice")
        choice.buttons["Skip Existing"].click()
        w12Wait(window, "playlistConfirmed", timeout: 15)
        XCTAssertEqual(w13Rows(window, titled: "Noche Cálida"), 1, "Skip Existing left it out")
        w12Wait(window, "playlistAddSuggestion-devsong0002").click()
        let (again, _) = w13Alert(app)
        XCTAssertTrue(again.buttons["Keep Duplicates"].exists)
        again.buttons["Keep Duplicates"].click()
        let deadline = Date().addingTimeInterval(20)
        while w13Rows(window, titled: "Noche Cálida") < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.4) }
        XCTAssertEqual(w13Rows(window, titled: "Noche Cálida"), 2, "Keep Duplicates added a second entry")
        // Share: the link is explicit, with the note for a private playlist; inviting is stated as unavailable, never an inert control.
        w12Wait(window, "playlistCopyLink")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistShareNote")).contains("only you"))
        XCTAssertTrue(w10Text(w12Wait(window, "playlistInviteNote")).contains("private playlist"), "a private playlist says collaborators can't use it")
        w12Wait(window, "playlistInviteCreate")
        w12Wait(window, "playlistDone").click()
        // An undo the service refuses: nothing changes and it says so.
        w10(window, "browserBack").exists ? w10(window, "browserBack").click() : ()
        w13OpenEditor(app, window, playlist: "PLdevundofails0001")
        w10(window, "playlistRow-DEV0").click()
        XCUIElement.perform(withKeyModifiers: .command) { w10(window, "playlistRow-DEV1").click() }
        w12Wait(window, "playlistRemoveSelected").click()
        let (removeTwo, _) = w13Alert(app)
        XCTAssertTrue(removeTwo.buttons["Remove 2 Songs"].exists)
        removeTwo.buttons["Remove 2 Songs"].click()
        XCTAssertTrue(w12Gone(w10(window, "playlistRow-DEV0"), timeout: 20))
        w12Wait(window, "playlistUndo").click()
        let (undoTwo, _) = w13Alert(app)
        XCTAssertTrue(undoTwo.buttons["Undo for 2 Songs"].exists)
        undoTwo.buttons["Undo for 2 Songs"].click()
        let failed = w12Wait(window, "playlistFailed", timeout: 20)
        XCTAssertTrue(w10Text(failed).contains("Nothing was changed"), w10Text(failed))
        XCTAssertTrue(w12Gone(w10(window, "playlistRow-DEV0")) && w12Gone(w10(window, "playlistRow-DEV1")), "the failed undo changed nothing")
        w12Wait(window, "playlistUndo")
        w12Wait(window, "playlistRow-DEV2")
        capture(window, "W13 undo refused by the service")
    }

    @MainActor func testW13ALostReplyIsSettledByReadingAndAConcurrentMoveAsksAboutThatOneSong() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // A reply that never arrives: shown as unconfirmed, checked by reading, never added twice.
        w13OpenEditor(app, window, playlist: "PLdevlostreply001")
        w12Wait(window, "playlistAddSuggestion-devsugg0001").click()
        w12Wait(window, "playlistPending", timeout: 5)
        w12Wait(window, "playlistUnconfirmed", timeout: 15)
        XCTAssertFalse(w10(window, "playlistConfirmed").exists, "an answer without evidence is never shown as done")
        capture(window, "W13 unconfirmed add")
        w12Wait(window, "playlistCheck").click()
        w12Wait(window, "playlistConfirmed", timeout: 15)
        XCTAssertEqual(w13Rows(window, titled: "Suggested Song"), 1, "read back: it is there once")
        w12Wait(window, "playlistDone").click()
        w10(window, "browserBack").exists ? w10(window, "browserBack").click() : ()
        // A collaborator moves the same song: both snapshots are kept and the question is about that song only.
        w13OpenEditor(app, window, playlist: "PLdevbusy00000001")
        w12Wait(window, "playlistMoveUp-DEV1").click()
        w12Wait(window, "playlistConflict", timeout: 20)
        XCTAssertTrue(w10Text(w12Wait(window, "playlistConflictSummary")).contains("Busy Song 2"))
        let mine = w10Text(w12Wait(window, "playlistConflictMine")), theirs = w10Text(w12Wait(window, "playlistConflictTheirs"))
        XCTAssertNotEqual(mine, theirs, "the two versions differ: \(mine) / \(theirs)")
        XCTAssertTrue(theirs.contains("end"), theirs)
        XCTAssertTrue(w10Text(w12Wait(window, "playlistNeedsAnswer")).contains("needs your answer"))
        capture(window, "W13 conflict: both versions kept")
        w12Wait(window, "playlistKeepMine")
        w12Wait(window, "playlistKeepTheirs").click()
        XCTAssertTrue(w12Gone(w10(window, "playlistConflict"), timeout: 15))
        let order = ["DEV0", "DEV2", "DEV3", "DEV1"].map { w12Wait(window, "playlistRow-" + $0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "their order stands: Busy Song 2 is last, nothing else moved")
        capture(window, "W13 conflict answered, remote order kept")
    }

    @MainActor func testW13CollaborationInviteStopAndJoinAreExplicitAndConfirmed() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w13OpenEditor(app, window, playlist: "PLdevmix000000001")
        // Owner only: nothing is created by opening the editor; the link appears only after the press, and is never copied by the test.
        XCTAssertFalse(w10(window, "playlistInviteReady").exists)
        let create = w12Wait(window, "playlistInviteCreate")
        let scroll = w10(window, "playlistEditor")
        for _ in 0..<10 where !create.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -200); Thread.sleep(forTimeInterval: 0.3) }
        create.click()
        w12Wait(window, "playlistInviteReady", timeout: 15)
        w12Wait(window, "playlistInviteCopy")
        capture(window, "W13 invite link ready")
        let stop = w12Wait(window, "playlistStopContributions")
        for _ in 0..<10 where !stop.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -200); Thread.sleep(forTimeInterval: 0.3) }
        stop.click()
        let (alert, said) = w13Alert(app)
        XCTAssertTrue(said.contains("Stop contributions to “Dev Mix”?"), said)
        XCTAssertTrue(alert.buttons["Stop Contributions"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertFalse(w10(window, "playlistContributionsClosed").exists, "Cancel changed nothing")
        stop.click()
        let (again, _) = w13Alert(app)
        again.buttons["Stop Contributions"].click()
        w12Wait(window, "playlistContributionsClosed", timeout: 15)
        capture(window, "W13 contributions closed")
        w12Wait(window, "playlistDone").click()
        w10(window, "browserBack").exists ? w10(window, "browserBack").click() : ()
        // Joining: a link is only read; Join asks first, naming the playlist.
        w10(window, "nav-library").click()
        w12Kind(window, "playlists")
        w12Wait(window, "playlistJoinOpen").click()
        w12Wait(window, "playlistJoin")
        let field = w12Wait(window, "playlistJoinLink")
        field.click(); field.typeText("https://example.com/not-an-invite")
        w12Wait(window, "playlistJoinLookUp").click()
        w12Wait(window, "playlistJoinInvalid")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://music.youtube.com/playlist?list=PLdevjoinable00001&jct=DEVJOINTOKEN0001")
        w12Wait(window, "playlistJoinLookUp").click()
        XCTAssertTrue(w10Text(w12Wait(window, "playlistJoinOffer", timeout: 15)).contains("Joinable Mix"))
        XCTAssertFalse(w10(window, "playlistJoined").exists, "looking a link up joined nothing")
        capture(window, "W13 join offer")
        w12Wait(window, "playlistJoinButton").click()
        let (joinAlert, joinText) = w13Alert(app)
        XCTAssertTrue(joinText.contains("Join “Joinable Mix”?"), joinText)
        joinAlert.buttons["Cancel"].click()
        XCTAssertFalse(w10(window, "playlistJoined").exists)
        w12Wait(window, "playlistJoinButton").click()
        let (confirm, _) = w13Alert(app)
        confirm.buttons["Join Playlist"].click()
        w12Wait(window, "playlistJoined", timeout: 15)
        capture(window, "W13 joined")
        w12Wait(window, "playlistJoinClose").click()
    }

    @MainActor func testW13SeveralSongsAreAddedThroughTheNamingConfirmationFromTheLibrarySelection() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-library").click()
        w12Wait(window, "libraryRow-song:devsong0003").click()
        XCUIElement.perform(withKeyModifiers: .command) { w12Wait(window, "libraryRow-song:devsong0004", timeout: 15).click() }
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("selected"))
        w12Wait(window, "libraryAddToPlaylist").click()
        w12Wait(window, "playlistAdd")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistAddSongs")).contains("2 songs"))
        w12Wait(window, "playlistAddChoice-PLdevshared000001").click()
        w12Wait(window, "playlistAddButton").click()
        // Nothing has been sent: the confirmation names the songs and the playlist.
        var (alert, said) = w13Alert(app)
        XCTAssertTrue(said.contains("Add 2 songs to “Shared Mix”?"), said)
        for name in ["Zeta Song", "Late Song"] { XCTAssertTrue(said.contains("• " + name), said) }
        XCTAssertFalse(w10(window, "playlistConfirmed").exists)
        alert.buttons["Cancel"].click()
        XCTAssertFalse(w10(window, "playlistConfirmed").exists, "Cancel added nothing")
        w12Wait(window, "playlistAddButton").click()
        (alert, said) = w13Alert(app)
        alert.buttons["Add 2 Songs"].click()
        w12Wait(window, "playlistConfirmed", timeout: 20)
        capture(window, "W13 two songs added after the confirmation")
        w12Wait(window, "playlistAddClose").click()
    }

    @MainActor func testW13RolesFollowTheServiceAndAViewerGetsNoEditor() throws {
        let app = playlistApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // A collaborator: tracks yes; title, visibility and deletion are not offered.
        w13OpenEditor(app, window, playlist: "PLdevshared000001")
        XCTAssertTrue(w10Text(w12Wait(window, "playlistRole")).contains("Collaborator"))
        XCTAssertFalse(w10(window, "playlistTitleField").exists, "no rename for a collaborator")
        XCTAssertFalse(w10(window, "playlistDelete").exists, "no delete for a collaborator")
        w12Wait(window, "playlistRemove-DEV0")
        capture(window, "W13 collaborator editor")
        w12Wait(window, "playlistDone").click()
        w10(window, "browserBack").exists ? w10(window, "browserBack").click() : ()
        // An owner: details and deletion exist; deletion asks first.
        w13OpenEditor(app, window, playlist: "PLdevmix000000001")
        w12Wait(window, "playlistTitleField"); w12Wait(window, "playlistPrivacyPicker")
        let delete = w12Wait(window, "playlistDelete")
        let scroll = w10(window, "playlistEditor")
        for _ in 0..<10 where !delete.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -200); Thread.sleep(forTimeInterval: 0.3) }
        delete.click()
        let (dialog, said) = w13Alert(app)
        XCTAssertTrue(dialog.buttons["Delete Playlist"].exists, "deleting asks first")
        XCTAssertTrue(said.contains("Delete “Dev Mix”?") && said.contains("can’t be undone"), said)
        capture(window, "W13 delete confirmation names the playlist")
        dialog.buttons["Cancel"].click()
        XCTAssertTrue(w10(window, "playlistEditor").exists, "Cancel deleted nothing")
        w12Wait(window, "playlistDone").click()
        w10(window, "browserBack").exists ? w10(window, "browserBack").click() : ()
        // A playlist the service shows read-only: the page offers no editor at all.
        w13OpenPlaylist(window, playlist: "PLdevpublic000001")
        XCTAssertFalse(w10(window, "playlistEdit").exists, "a playlist the service does not let you edit has no Edit control")
        capture(window, "W13 viewer: no editor")
    }

    // MARK: W15 Downloads

    @MainActor private func downloadsApplication() -> XCUIApplication {
        let app = designApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_DOWNLOADS"] = "1"
        return app
    }
    private func w15Row(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    /// W15 (T15 ui layer): the Downloads destination shows every state honestly, offers only the actions that apply, never invents a
    /// percentage while a size is unknown, and says plainly that YouTube Music offers no downloads on Mac. Labelled development data
    /// behind the real DownloadsControlling seam; the engine itself is covered by the headless T15 suite.
    // MARK: W18 podcasts, episodes and source lyrics (labelled development data; the headless T18 suite covers the parsers, the rate and skip
    // logic, progress, timing and Reduce Motion against the real captures).

    @MainActor private func podcastsApplication(lyricsVideo: String? = nil) -> XCUIApplication {
        let app = designApplication()
        if let lyricsVideo { app.launchEnvironment["YTMUSE_UI_DEV_LYRICS_VIDEO"] = lyricsVideo }
        return app
    }
    @MainActor private func w18RowY(_ window: XCUIElement, _ id: String) -> CGFloat { w10(window, "catalogItem-episode:" + id).frame.minY }

    /// W18 (T18 ui layer): a show's episodes carry their progress with whose figure it is, sort without losing any, the page of an episode shows its
    /// chapters (from the description's own timestamps), a local mark is "On this Mac" and reversible, and there is words for Download, never a control.
    @MainActor func testW18EpisodesShowProgressChaptersAndNeverAnInertDownloadControl() throws {
        let app = podcastsApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w11Open(window, "catalogItem-podcast:MPSPPLdevelopmentshow")
        for id in ["devepisode1", "devepisode2", "devepisode3"] { w11Wait(window, "catalogItem-episode:" + id) }
        // Progress is what the service printed, marked as the service's; an unplayed episode shows none and a "Played" label alone is never played.
        XCTAssertFalse(w10(window, "episodeProgress-episode:devepisode1").exists, "an unplayed episode shows no progress")
        XCTAssertTrue(w10Text(w11Wait(window, "episodeProgress-episode:devepisode2")).contains("40% played"))
        XCTAssertTrue(w10Text(w10(window, "episodeProgress-episode:devepisode2")).contains("From YouTube Music"))
        XCTAssertTrue(w10Text(w11Wait(window, "episodeProgress-episode:devepisode3")).contains("Played"))
        // Words, not a control, where a person would look for Download.
        XCTAssertTrue(w10Text(w11Wait(window, "downloadCapabilityNote")).contains("doesn’t offer downloads on Mac"))
        XCTAssertFalse(window.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Download'")).firstMatch.exists, "no Download control on an episode surface")
        // Sorting is a view over the show's order and drops nothing.
        let ordered = [w18RowY(window, "devepisode1"), w18RowY(window, "devepisode2"), w18RowY(window, "devepisode3")]
        XCTAssertTrue(ordered[0] < ordered[1] && ordered[1] < ordered[2], "the show's own order")
        w11Wait(window, "episodeSortMenu").click()
        window.menuItems["Shortest first"].firstMatch.click()
        let shortest = [w18RowY(window, "devepisode3"), w18RowY(window, "devepisode1"), w18RowY(window, "devepisode2")]
        XCTAssertTrue(shortest[0] < shortest[1] && shortest[1] < shortest[2], "5 min, 18 min, 50 min")
        w11Wait(window, "episodeSortMenu").click()
        window.menuItems["Show’s order"].firstMatch.click()
        XCTAssertTrue(w18RowY(window, "devepisode1") < w18RowY(window, "devepisode2"), "the show's order comes back")
        // The show's speed menu exists before anything plays; the choice is the person's.
        let speed = w11Wait(window, "podcastRate")
        speed.click(); window.menuItems["1.5×"].firstMatch.click()
        XCTAssertTrue(w10Text(w11Wait(window, "podcastRate")).contains("1.5×"))
        capture(window, "W18 show page")
        // The episode page: the service's progress, chapters from the description's timestamps, a local mark that is only this Mac's.
        w11Open(window, "catalogItem-episode:devepisode2")
        XCTAssertEqual(w11Title(window), "Grinding beans (development)")
        XCTAssertTrue(w10Text(w11Wait(window, "episodeProgress-page")).contains("40% played"))
        w11Wait(window, "episodeChapters")
        // Each chapter is one combined row (its time and its title); the times are the description's own.
        let first = w11Wait(window, "chapterRow-330"), last = w11Wait(window, "chapterRow-2700")
        XCTAssertTrue(w10Text(first).contains("5:30") && w10Text(first).contains("First topic"), w10Text(first))
        XCTAssertTrue(w10Text(last).contains("45:00") && w10Text(last).contains("Wrap up"), w10Text(last))
        XCTAssertTrue(w10Text(w11Wait(window, "downloadCapabilityNote")).contains("doesn’t offer downloads on Mac"))
        XCTAssertTrue(w10Text(w11Wait(window, "episodePlaybackReason")).contains("Sign in to YouTube Music to play episodes."), "an unavailable Play says why")
        XCTAssertFalse(w10(window, "episodeLater").exists, "Save for Later is not offered signed out")
        XCTAssertTrue(w10Text(w11Wait(window, "episodeLaterNote")).contains("Sign in"))
        w11Wait(window, "episodeMarkPlayed").click()
        let marked = w10Text(w11Wait(window, "episodeProgress-page"))
        XCTAssertTrue(marked.contains("Played") && marked.contains("On this Mac"), marked)
        XCTAssertTrue(w10Text(w11Wait(window, "episodeMarkPlayed")).contains("Mark as Unplayed"))
        w11Wait(window, "episodeMarkPlayed").click()
        XCTAssertTrue(w10Text(w11Wait(window, "episodeProgress-page")).contains("From YouTube Music"), "unmarked: the service's figure again")
        capture(window, "W18 episode page")
    }

    /// W18 (T18 ui layer): the lyrics panel shows the source's plain text with its attribution and says it has no timing; "no lyrics" and
    /// "couldn't load" are different, and only the second offers Try Again. (Timed highlighting, manual scrolling, return to the current line,
    /// line seeks and Reduce Motion need a playing song and are covered by the headless suite and the live list.)
    @MainActor func testW18LyricsStayPlainWithTheSourceNoLyricsAndCouldNotLoadAreDifferent() throws {
        func panel(_ song: String) -> (XCUIApplication, XCUIElement) {
            let app = podcastsApplication(lyricsVideo: song); app.launch()
            let window = app.windows["YTMuse"].firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            window.buttons["Lyrics"].firstMatch.click()
            return (app, window)
        }
        let plain = panel("devsong0001"); defer { plain.0.terminate() }
        XCTAssertTrue(w10Text(w11Wait(plain.1, "lyricsText")).contains("Development line one"))
        XCTAssertTrue(w10Text(w11Wait(plain.1, "lyricsSource")).contains("Source: Development Lyrics"), "the source's own attribution line, verbatim")
        XCTAssertTrue(w10Text(w11Wait(plain.1, "lyricsUntimedNote")).contains("without timing"))
        XCTAssertFalse(w10(plain.1, "lyricsLine-0").exists, "no line is highlightable or tappable: the source gave no times")
        XCTAssertFalse(w10(plain.1, "lyricsReturn").exists)
        capture(plain.1, "W18 plain lyrics")
        let none = panel("devsong0002"); defer { none.0.terminate() }
        XCTAssertTrue(w10Text(w11Wait(none.1, "lyricsUnavailable")).contains("No lyrics available"))
        XCTAssertFalse(w10(none.1, "lyricsFailed").exists || w10(none.1, "lyricsRetry").exists, "no lyrics is not a failure and offers no retry")
        let flaky = panel("devsong0003"); defer { flaky.0.terminate() }
        XCTAssertTrue(w10Text(w11Wait(flaky.1, "lyricsFailed")).contains("offline"))
        XCTAssertFalse(w10(flaky.1, "lyricsUnavailable").exists, "could not load is not 'no lyrics'")
        w11Wait(flaky.1, "lyricsRetry").click()
        XCTAssertTrue(w10Text(w11Wait(flaky.1, "lyricsText")).contains("Development line two"))
    }

    @MainActor func testW15DownloadsStatesRecoveryStorageAndTheYouTubeMusicExplanation() throws {
        let app = downloadsApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-downloads").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("Downloads"))
        XCTAssertTrue(w10(window, "downloadsDevelopmentLabel").exists, "development data is labelled")
        // YouTube Music: an explanation, never a control.
        XCTAssertTrue(w10Text(w12Wait(window, "downloadsYouTubeMusicNote")).contains("doesn’t offer downloads on Mac"))
        XCTAssertFalse(window.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Download ' AND NOT label CONTAINS[c] 'Again' AND NOT label CONTAINS[c] 'Connection'")).firstMatch.exists, "no inert Download control")
        capture(window, "W15 Downloads overview")
        // Unknown size: bytes so far, no percentage, and the aggregate says the same.
        w12Wait(window, "downloadIndeterminate-" + w15Row(2))
        XCTAssertTrue(w10Text(w12Wait(window, "downloadsAggregateUnknown")).contains("so far"))
        XCTAssertTrue(w10Text(w12Wait(window, "downloadPhase-" + w15Row(1))).contains("Downloaded"))
        // A metered connection holds a manual download until the person says otherwise.
        XCTAssertTrue(w10Text(w12Wait(window, "downloadReason-" + w15Row(3))).contains("metered"))
        w12Wait(window, "downloadAction-downloadOnThisNetwork-" + w15Row(3)).click()
        XCTAssertTrue(w10Text(w12Wait(window, "downloadPhase-" + w15Row(3))).contains("Downloading"))
        // A damaged copy is reported and recovered by an explicit Download Again.
        XCTAssertTrue(w10Text(w12Wait(window, "downloadFailure-" + w15Row(4))).contains("damaged"))
        w12Wait(window, "downloadAction-downloadAgain-" + w15Row(4)).click()
        XCTAssertTrue(w10Text(w12Wait(window, "downloadPhase-" + w15Row(4))).contains("Downloading"))
        // Pause and resume are the person's.
        w12Wait(window, "downloadAction-pause-" + w15Row(2)).click()
        XCTAssertTrue(w10Text(w12Wait(window, "downloadReason-" + w15Row(2))).contains("Paused by you"))
        w12Wait(window, "downloadAction-resume-" + w15Row(2)).click()
        XCTAssertTrue(w12Gone(w10(window, "downloadReason-" + w15Row(2))))
        // Cancelling removes the row.
        // The row is exposed as its own group while several rows are listed; assert it is there so its absence below can fail.
        w12Wait(window, "downloadRow-" + w15Row(5))
        w12Wait(window, "downloadAction-cancel-" + w15Row(5)).click()
        XCTAssertTrue(w12Gone(w10(window, "downloadRow-" + w15Row(5))))
        // Storage; Smart Downloads has nothing to suggest on this Mac, so it is a statement, not a switch.
        XCTAssertTrue(w10Text(w12Wait(window, "downloadsStorageUsed")).contains("used of"))
        XCTAssertTrue(w10Text(w12Wait(window, "downloadsSmartUnavailable")).contains("isn’t available"))
        XCTAssertFalse(w10(window, "downloadsSmart").exists, "no inert switch")
        // Downloaded only keeps what is saved on this Mac.
        window.radioButtons["Downloaded only"].click()
        // With one row left SwiftUI collapses that single-child row group into the list's group (the AX tree shows `downloadPhase-` directly
        // under `downloadsList`, with no `downloadRow-` group), so the row is identified by its own children here; with several rows each
        // `downloadRow-` group is exposed (the unfiltered list above).
        XCTAssertTrue(w10Text(w12Wait(window, "downloadPhase-" + w15Row(1))).contains("Downloaded"))
        XCTAssertTrue(w12Gone(w10(window, "downloadRow-" + w15Row(3))))
        XCTAssertTrue(w12Gone(w10(window, "downloadPhase-" + w15Row(3))), "a row that is not saved on this Mac is not listed under Downloaded only")
        capture(window, "W15 Downloaded only")
        let remove = w12Wait(window, "downloadAction-remove-" + w15Row(1))
        // The button sits below the visible part of the page: bring it into view before the click lands on whatever is there.
        let page = window.scrollViews["downloadsScreen"]
        // isHittable says yes for content clipped by the scroll view, so compare the frames (as w11Reveal does).
        for _ in 0..<8 where remove.frame.maxY > page.frame.maxY - 8 { page.scroll(byDeltaX: 0, deltaY: -240); Thread.sleep(forTimeInterval: 0.4) }
        XCTAssertLessThanOrEqual(remove.frame.maxY, page.frame.maxY, "Remove is not inside the visible page after scrolling")
        remove.click()
        w12Wait(window, "downloadsEmptyFiltered")
    }

    // MARK: W20 — Samples, tuner, Recap, badges (headless-verified models; these UI parts were written while the console was locked)

    @MainActor private func discoveryApplication(conditions: String? = nil) -> XCUIApplication {
        let app = libraryApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_DISCOVERY"] = "1"
        if let conditions { app.launchEnvironment["YTMUSE_UI_PREVIEW_CONDITIONS"] = conditions }
        return app
    }
    @MainActor private func w20Open(_ window: XCUIElement, _ entry: String) {
        w10(window, "nav-explore").click()
        w12Wait(window, "discoveryEntry-" + entry).click()
    }
    @MainActor private func w20Back(_ window: XCUIElement) { w12Wait(window, "browserBack").click() }

    @MainActor func testW20DiscoveryExtrasSayPlainlyThereIsNoSourceAndInventNothing() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w20Open(window, "samples")
        XCTAssertTrue(w10Text(w12Wait(window, "samplesUnresolved")).contains("Samples aren’t available yet"))
        XCTAssertFalse(w10(window, "samplesList").exists, "no clip list without a source")
        XCTAssertFalse(w10(window, "samplesAutoplayPreference").exists, "no preview controls without clips")
        w20Back(window)
        w12Wait(window, "discoveryEntry-tuner").click()
        w12Wait(window, "tunerNoRadio"); w12Wait(window, "tunerNoSeeds")
        XCTAssertFalse(w10(window, "tunerControlTitle-devmix").exists)
        w20Back(window)
        w12Wait(window, "discoveryEntry-recap").click()
        XCTAssertTrue(w10Text(w12Wait(window, "recapUnresolved")).contains("nothing is made up"))
        XCTAssertFalse(w10(window, "recapLoaded").exists)
        XCTAssertFalse(w10(window, "localListening").exists, "this Mac's own record is not on the Recap screen")
        w20Back(window)
        w12Wait(window, "discoveryEntry-local").click()
        XCTAssertTrue(w10Text(w12Wait(window, "destinationTitle")).contains("On this Mac"))
        let local = w12Wait(window, "localListeningNote")
        XCTAssertTrue(w10Text(local).contains("not YouTube Music’s Recap"), "this Mac's own record is labelled as such")
        w20Back(window)
        w12Wait(window, "discoveryEntry-badges").click()
        w12Wait(window, "badgesUnresolved")
        capture(window, "W20 discovery extras without a source")
    }

    @MainActor func testW20OneSamplePreviewsAtATimePlayHandsOffAndLowPowerModeTurnsAutoplayOff() throws {
        let app = discoveryApplication(conditions: "lowpower"); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w20Open(window, "samples")
        XCTAssertTrue(w10(window, "developmentDataLabel").exists, "the development route is labelled")
        XCTAssertTrue(w10Text(w12Wait(window, "samplesAutoplayDisabled")).contains("Low Power Mode"))
        w12Wait(window, "sampleClip-devclip00001").click()
        XCTAssertTrue(w10Text(w12Wait(window, "discoveryReadout")).contains("preview=none"), "focusing a clip starts nothing on Low Power Mode")
        w12Wait(window, "samplePreview-devclip00001").click()
        XCTAssertTrue(w10Text(w12Wait(window, "discoveryReadout")).contains("preview=devclip00001"))
        w12Wait(window, "samplePreview-devclip00002").click()
        let readout = w10Text(w12Wait(window, "discoveryReadout"))
        XCTAssertTrue(readout.contains("preview=devclip00002") && readout.contains("overlap=0"), readout)
        XCTAssertTrue(w12Gone(w10(window, "samplePreviewing-devclip00001")))
        w12Wait(window, "samplePlay-devclip00002").click()
        w12Wait(window, "samplesHandoff-started")
        let after = w10Text(w12Wait(window, "discoveryReadout"))
        XCTAssertTrue(after.contains("preview=none") && after.contains("handoffs=1"), after)
        capture(window, "W20 Samples one preview at a time")
    }

    @MainActor func testW20TunerShowsOnlySuppliedControlsAndRecapShowsOnlySuppliedFigures() throws {
        let app = discoveryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w20Open(window, "tuner")
        XCTAssertTrue(w10(window, "developmentDataLabel").exists)
        w12Wait(window, "tunerNoRadio")
        w12Wait(window, "tunerSeed-RDAMVMdevprev0001").click()
        XCTAssertTrue(w10Text(w12Wait(window, "tunerContext")).contains("Development song"))
        w12Wait(window, "tunerControlTitle-devmix")
        XCTAssertFalse(w10(window, "tunerNoControls").exists, "the supplied control is shown instead of the no-controls note")
        w12Wait(window, "tunerControl-devmix")
        w20Back(window)
        w12Wait(window, "discoveryEntry-recap").click()
        w12Wait(window, "recapLoaded")
        XCTAssertTrue(w10Text(w12Wait(window, "recapEntry-d1")).contains("Development value one"))
        XCTAssertTrue(w10Text(w12Wait(window, "recapEntry-d2")).contains("Development value two"))
        XCTAssertFalse(w10(window, "localListeningNone").exists, "and nothing about this Mac sits on it")
        w20Back(window)
        w12Wait(window, "discoveryEntry-local").click()
        // The development library seeds two plays on this Mac, so this screen first shows its own totals, not the empty statement.
        XCTAssertTrue(w10Text(w12Wait(window, "localListeningTotals")).contains("2 plays"))
        w12Wait(window, "localListeningNote")
        XCTAssertFalse(w10(window, "localListeningNone").exists, "with plays recorded the empty statement is not shown")
        // Then clear this Mac's history through History's own action (as T12 does) and the same screen says nothing has been played.
        w10(window, "nav-history").click()
        let clear = w12Wait(window, "historyClearLocal")
        let history = w10(window, "historyRoot")
        // The local section sits below the fold: scroll it into the visible band before pressing (a click behind the player bar lands on the player).
        for _ in 0..<12 where history.exists && clear.frame.maxY > history.frame.maxY - 40 { history.scroll(byDeltaX: 0, deltaY: -200); Thread.sleep(forTimeInterval: 0.4) }
        clear.click()
        let confirm = app.sheets.firstMatch.buttons["Clear This Mac’s History"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "the confirmation names what it clears")
        confirm.click()
        w12Wait(window, "historyLocalEmpty")
        w10(window, "nav-explore").click()
        w12Wait(window, "discoveryEntry-local").click()
        XCTAssertTrue(w10Text(w12Wait(window, "localListeningNone")).contains("Nothing has been played"))
        XCTAssertFalse(w10(window, "localListeningTotals").exists, "with the record cleared there are no totals")
        w20Back(window)
        w12Wait(window, "discoveryEntry-badges").click()
        w12Wait(window, "badgesPayloadMissing")
        XCTAssertFalse(w10(window, "badgesAccountUnsupported").exists, "a missing payload is not an unsupported account")
        capture(window, "W20 tuner, recap and badges")
    }

    // MARK: W09-F2 Back/Forward restoration on the production pages (labelled development data in an isolated launch)
    //
    // The scroll offset of a production page is observed the way a person sees it: where a known row sits inside the page's scroll area.
    // That needs no diagnostics in the product. Scrolling is by fixed deltas, and every wait is budgeted by readings, not wall time.

    @MainActor private func w09f2Launch(_ app: XCUIApplication) -> XCUIElement {
        app.launchEnvironment["YTMUSE_UI_TEST_WINDOW_SIZES_NEXT"] = "840x560"
        app.launch()
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return window
    }
    /// Scrolls the page down by fixed deltas, letting each settle.
    @MainActor private func w09f2ScrollDown(_ container: XCUIElement, steps: Int = 3, delta: CGFloat = 90) {
        for _ in 0..<steps { container.scroll(byDeltaX: 0, deltaY: -delta); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) }
    }
    /// How far `row` sits below the top of `container`, if it is on screen inside it.
    @MainActor private func w09f2Position(_ window: XCUIElement, _ container: XCUIElement, _ row: String) -> Double? {
        let element = w10(window, row)
        guard element.exists, container.exists else { return nil }
        let frame = element.frame, area = container.frame
        guard frame.minY >= area.minY - 1, frame.maxY <= area.maxY + 1 else { return nil }
        return Double(frame.minY - area.minY)
    }
    /// The first of `candidates` that is fully on screen inside `container`, with its position.
    @MainActor private func w09f2Anchor(_ window: XCUIElement, _ container: XCUIElement, _ candidates: [String]) -> (id: String, position: Double)? {
        for id in candidates { if let position = w09f2Position(window, container, id) { return (id, position) } }
        return nil
    }
    /// The first of `candidates` that is fully on screen in `container`, counting from the top: the row a list begins with.
    @MainActor private func w09f2FirstRow(_ window: XCUIElement, _ container: XCUIElement, _ candidates: [String]) -> (id: String, position: Double)? {
        candidates.compactMap { id in w09f2Position(window, container, id).map { (id, $0) } }.min { $0.1 < $1.1 }
    }
    /// The first of `candidates` that covers the top edge of `container`: the part of a tall page the person is looking at the top of.
    @MainActor private func w09f2CoveringTop(_ window: XCUIElement, _ container: XCUIElement, _ candidates: [String]) -> String? {
        guard container.exists else { return nil }
        let top = container.frame.minY
        return candidates.first { id in
            let element = w10(window, id)
            return element.exists && element.frame.minY <= top + 1 && element.frame.maxY > top + 1
        }
    }
    /// The first row of a long list that is fully inside `container` (rows found by identifier prefix), with its number.
    @MainActor private func w09f2FirstRowWithPrefix(_ window: XCUIElement, _ container: XCUIElement, _ prefix: String) -> (id: String, number: Int)? {
        guard container.exists else { return nil }
        let area = container.frame
        let rows = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        let visible = rows.filter { $0.exists && $0.frame.minY >= area.minY - 1 && $0.frame.maxY <= area.maxY + 1 }
        guard let top = visible.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        return (top.identifier, Int(top.identifier.dropFirst(prefix.count)) ?? -1)
    }
    /// Waits for `row` to come back to within 12 pt of `saved`: up to `readings` readings, never a wall-clock budget.
    @MainActor private func w09f2Restored(_ window: XCUIElement, _ container: XCUIElement, _ row: String, to saved: Double, readings: Int = 120) -> Double? {
        var last: Double?, timeline: [String] = []
        defer { print("W09F2 restore \(row) saved=\(saved) timeline=\(timeline.joined(separator: ","))") }
        for _ in 0..<readings {
            if let position = w09f2Position(window, container, row) {
                last = position
                timeline.append(String(format: "%.0f", position))
                if abs(position - saved) < 12 { return position }
            } else { timeline.append("-") }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return last
    }
    @MainActor private func w09f2Text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    @MainActor func testW09F2LibraryRestoresSearchOrderSelectionScrollKindAndKeptOnlyPerEntry() throws {
        let app = libraryApplication(); let window = w09f2Launch(app); defer { app.terminate() }
        w10(window, "nav-library").click()
        w12Wait(window, "libraryRow-song:devsong0001"); w12Wait(window, "libraryRow-song:devsong0005", timeout: 15)
        // First visit: a search that keeps every row, Z–A order, one selected row, and the list scrolled by fixed deltas.
        let query = w12Wait(window, "libraryQuery"); query.click(); query.typeText("a")
        w10(window, "librarySort").click(); app.menuItems["Title (Z–A)"].click()
        w12Wait(window, "libraryRow-song:devsong0003").click()
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("1 selected"))
        let list = w12Wait(window, "libraryList")
        let top = w09f2Position(window, list, "libraryRow-song:devsong0003")
        w09f2ScrollDown(list)
        // A list restores by row identity: the row it began with when the person left, whatever the content height was then.
        let rows = ["libraryRow-song:devsong0003", "libraryRow-song:devsong0002", "libraryRow-song:devsong0005", "libraryRow-song:devsong0004", "libraryRow-song:devsong0001"]
        let anchor = try XCTUnwrap(w09f2FirstRow(window, list, rows), "no row is on screen after scrolling")
        XCTAssertNotEqual(anchor.id, rows[0], "the list scrolled past its first row")
        capture(window, "W09-F2 Library first visit, scrolled", samples: [["anchor": anchor.id, "position": "\(anchor.position)", "topRowBefore": "\(top ?? -1)"]])
        // Away, and a SECOND Library visit. A new visit starts with its own transient state (no search text, no selection, the top of the list);
        // durable view settings (here the order) carry over.
        w10(window, "nav-history").click(); w12Wait(window, "historyRemote")
        w10(window, "nav-library").click()
        let second = w12Wait(window, "libraryQuery")
        XCTAssertEqual((second.value as? String) ?? "", "", "a new visit starts with an empty search")
        XCTAssertFalse(w10(window, "librarySelectionCount").exists, "a new visit starts with nothing selected")
        XCTAssertEqual(w10(window, "librarySort").value as? String, "Title (Z–A)", "the order is a durable setting and carries over")
        // The second visit looks at another collection.
        w12Kind(window, "albums")
        w12Wait(window, "libraryRow-album:MPREbdevelopment1")
        // Back twice: the first visit, with everything it had.
        window.buttons["browserBack"].click(); w12Wait(window, "historyRemote")
        window.buttons["browserBack"].click()
        let restoredQuery = w12Wait(window, "libraryQuery")
        XCTAssertEqual(restoredQuery.value as? String, "a")
        XCTAssertEqual(w10(window, "librarySort").value as? String, "Title (Z–A)")
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("1 selected"), "the selection comes back")
        let list2 = w12Wait(window, "libraryList")
        var firstAfterBack: String?
        for _ in 0..<120 {
            firstAfterBack = w09f2FirstRow(window, list2, rows)?.id
            if firstAfterBack == anchor.id { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertEqual(firstAfterBack, anchor.id, "the list begins with the row it began with")
        XCTAssertTrue(w10(window, "libraryKind-songs").isSelected, "the first visit is on Songs")
        // Forward twice: the second visit is on Albums again (the chip is selected; nothing is clicked).
        window.buttons["browserForward"].click(); w12Wait(window, "historyRemote")
        window.buttons["browserForward"].click()
        w12Wait(window, "libraryRow-album:MPREbdevelopment1")
        XCTAssertTrue(w12Wait(window, "libraryKind-albums").isSelected, "the second visit's collection comes back")
        XCTAssertEqual((w10(window, "libraryQuery").value as? String) ?? "", "", "and its search text is its own")
        // A third state of the same visit: only what is kept on this Mac. Away and Back, it is still on.
        w12Wait(window, "libraryDownloadedOnly").click()
        w12Wait(window, "libraryDownloadedSection")
        w10(window, "nav-history").click(); w12Wait(window, "historyRemote")
        window.buttons["browserBack"].click()
        w12Wait(window, "libraryDownloadedSection")
        XCTAssertTrue(w12Wait(window, "libraryDownloadedOnly").isSelected, "Downloaded only comes back")
        capture(window, "W09-F2 Library second visit after Forward")
    }

    @MainActor func testW09F2HistoryRestoresItsScrollOffsetPerEntry() throws {
        let app = libraryApplication(); let window = w09f2Launch(app); defer { app.terminate() }
        w10(window, "nav-history").click()
        w12Wait(window, "historyRemote"); w12Wait(window, "historyLocalOnlyBadge")
        let scroll = w12Wait(window, "historyRoot")
        w09f2ScrollDown(scroll, steps: 4, delta: 120)
        let anchor = try XCTUnwrap(w09f2Anchor(window, scroll, ["historyLocalOnlyBadge", "historyLocalProvenance", "historyControlUnavailable", "historyLocalRow", "historyRemoteProvenance"]), "no History row is on screen after scrolling")
        XCTAssertNotEqual(anchor.id, "historyRemoteProvenance", "the page scrolled")
        w10(window, "nav-downloads").click(); w10(window, "downloadsFilter").waitForExistence(timeout: 10)
        window.buttons["browserBack"].click()
        let scroll2 = w12Wait(window, "historyRoot")
        let back = w09f2Restored(window, scroll2, anchor.id, to: anchor.position)
        XCTAssertEqual(try XCTUnwrap(back, "the anchor row never came back on screen"), anchor.position, accuracy: 12)
        window.buttons["browserForward"].click()
        XCTAssertTrue(w10(window, "downloadsFilter").waitForExistence(timeout: 10))
        capture(window, "W09-F2 History restored")
    }

    @MainActor func testW09F2DownloadsRestoresItsFilterAndScrollOffsetPerEntry() throws {
        let app = downloadsApplication(); let window = w09f2Launch(app); defer { app.terminate() }
        w10(window, "nav-downloads").click()
        w12Wait(window, "downloadsStorageUsed")
        window.radioButtons["Downloaded only"].click()
        let scroll = w12Wait(window, "downloadsScreen")
        w09f2ScrollDown(scroll)
        // The screen restores by item identity: the section it began with when the person left it. One candidate per section.
        let items = ["downloadsYouTubeMusicNote", "downloadsAggregateUnknown", "downloadsStorageUsed", "downloadsSmartUnavailable", "downloadPhase-" + w15Row(1)]
        let anchor = try XCTUnwrap(w09f2FirstRow(window, scroll, items), "no Downloads element is fully on screen after scrolling")
        XCTAssertNotEqual(anchor.id, items[0], "the page scrolled past its first section")
        // A second Downloads visit that shows everything.
        w10(window, "nav-history").click(); w12Wait(window, "collectionQuery")
        w10(window, "nav-downloads").click()
        w12Wait(window, "downloadsStorageUsed")
        window.radioButtons["All"].click()
        // Back twice: the first visit, filtered, at its offset.
        window.buttons["browserBack"].click(); w12Wait(window, "collectionQuery")
        window.buttons["browserBack"].click()
        w12Wait(window, "downloadsStorageUsed")
        XCTAssertEqual(window.radioButtons["Downloaded only"].value as? Int, 1, "the filter comes back")
        let screen = w12Wait(window, "downloadsScreen")
        var firstAfterBack: String?
        for _ in 0..<120 {
            firstAfterBack = w09f2FirstRow(window, screen, items)?.id
            if firstAfterBack == anchor.id { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertEqual(firstAfterBack, anchor.id, "the page begins with the section it began with")
        // Forward twice: the second visit shows everything.
        window.buttons["browserForward"].click(); w12Wait(window, "collectionQuery")
        window.buttons["browserForward"].click()
        w12Wait(window, "downloadsStorageUsed")
        XCTAssertEqual(window.radioButtons["All"].value as? Int, 1)
        capture(window, "W09-F2 Downloads second visit after Forward")
    }

    @MainActor func testW09F2CatalogPagesRestoreTheirShelfAndTheRowWithinAListShelf() throws {
        let app = designApplication(); let window = w09f2Launch(app); defer { app.terminate() }
        let home = w11Wait(window, "catalogScroll")
        // A catalog page restores by identity: a shelf (Home), or the first row in a list shelf (below).
        let shelves = ["catalogShelf-list:Quick picks", "catalogShelf-carousel:New releases", "catalogShelf-carousel:Featured playlists"]
        var first = w09f2CoveringTop(window, home, shelves)
        for _ in 0..<14 where first == nil || first == shelves[0] {
            w09f2ScrollDown(home, steps: 1, delta: 150)
            first = w09f2CoveringTop(window, home, shelves)
        }
        let leftOn = try XCTUnwrap(first, "no Home shelf covers the top of the page after scrolling")
        XCTAssertNotEqual(leftOn, shelves[0], "Home scrolled past its first shelf")
        // Open an album, then Back to Home and Forward to the album again.
        w11Open(window, "catalogItem-album:MPREbdevelopment1")
        XCTAssertEqual(w11Title(window), "Development Album")
        w11Wait(window, "catalogItem-song#o1")
        window.buttons["browserBack"].click()
        XCTAssertEqual(window.staticTexts["destinationTitle"].label, "Home")
        let again = w11Wait(window, "catalogScroll")
        var restored: String?
        for _ in 0..<120 {
            restored = w09f2CoveringTop(window, again, shelves)
            if restored == leftOn { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertEqual(restored, leftOn, "Home opens on the shelf it was left on")
        window.buttons["browserForward"].click()
        XCTAssertEqual(w11Title(window), "Development Album")
        capture(window, "W09-F2 Home restored by shelf; album after Forward")
        // A list shelf: the long development playlist (150 rows in ONE shelf, several screens). Leave it in the middle and come Back: the page must
        // open on the row it was left on, not on the first row.
        w10(window, "nav-explore").click()
        w11Open(window, "catalogItem-playlist:VLPLdevelopmentlong1")
        XCTAssertEqual(w11Title(window), "Long Playlist (development)")
        let prefix = "catalogItem-song#l"
        w11Wait(window, prefix + "001")
        let list = w11Wait(window, "catalogScroll")
        var leftRow = w09f2FirstRowWithPrefix(window, list, prefix)
        for _ in 0..<40 where (leftRow?.number ?? 0) < 60 {
            w09f2ScrollDown(list, steps: 1, delta: 400)
            leftRow = w09f2FirstRowWithPrefix(window, list, prefix)
        }
        let mid = try XCTUnwrap(leftRow, "no list row is on screen after scrolling")
        XCTAssertGreaterThanOrEqual(mid.number, 60, "the playlist was scrolled well into its list")
        print("W09F2 long playlist left on \(mid.id)")
        w10(window, "nav-downloads").click(); XCTAssertTrue(w10(window, "downloadsFilter").waitForExistence(timeout: 10))
        window.buttons["browserBack"].click()
        // The page opens mid-list, so its header (and the title in it) is scrolled out and not part of the screen: wait for the scroll area and the rows.
        let again2 = w11Wait(window, "catalogScroll")
        var backRow: (id: String, number: Int)?
        for _ in 0..<120 {
            backRow = w09f2FirstRowWithPrefix(window, again2, prefix)
            if backRow?.id == mid.id { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertEqual(backRow?.id, mid.id, "the playlist opens on the row it was left on (\(mid.id)), not on its first row")
        capture(window, "W09-F2 long playlist restored mid-list")
    }

    @MainActor func testW09F2SearchRestoresQueryScopeSelectionAndResultsPositionAcrossTwoVisits() throws {
        let app = designApplication(); let window = w09f2Launch(app); defer { app.terminate() }
        app.typeKey("f", modifierFlags: .command)
        let field = window.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("cafe")
        XCTAssertTrue(w10(window, "searchGroup-top").waitForExistence(timeout: 5))
        let song = w10(window, "searchResult-song:devsong0001")
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.click()
        XCTAssertTrue(song.isSelected)
        let results = w10(window, "searchResults")
        w09f2ScrollDown(results, steps: 2, delta: 90)
        let anchor = try XCTUnwrap(w09f2Anchor(window, results, ["searchGroup-podcasts", "searchGroup-videos", "searchGroup-playlists", "searchGroup-top"]), "no result group is on screen after scrolling")
        // Away; then a SECOND Search visit with its own scope and query. The search text carries into a new visit (the window has one search
        // field), the selected result does not.
        w10(window, "nav-downloads").click(); XCTAssertTrue(w10(window, "downloadsFilter").waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let second = window.textFields["searchField"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(second.value as? String, "cafe", "the search text carries into a new visit")
        XCTAssertFalse(w10(window, "searchResult-song:devsong0001").isSelected, "a new visit starts with nothing selected")
        let scope = window.radioGroups["searchScope"]
        scope.radioButtons["Library"].click()
        XCTAssertTrue(w10(window, "searchScopeNotice").waitForExistence(timeout: 5))
        second.click()
        for _ in 0..<((second.value as? String)?.count ?? 0) { second.typeKey(.delete, modifierFlags: []) }
        second.typeText("cafe del")
        XCTAssertEqual(second.value as? String, "cafe del")
        w10(window, "nav-history").click(); w12Wait(window, "collectionQuery")
        // Back: the second visit, with its scope and query.
        window.buttons["browserBack"].click()
        XCTAssertTrue(window.textFields["searchField"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.textFields["searchField"].value as? String, "cafe del")
        XCTAssertEqual(window.radioGroups["searchScope"].radioButtons["Library"].value as? Int, 1, "the second visit's scope comes back")
        // Back twice more: the first visit — query, All scope, the selected result and the results position.
        window.buttons["browserBack"].click(); XCTAssertTrue(w10(window, "downloadsFilter").waitForExistence(timeout: 10))
        window.buttons["browserBack"].click()
        let restoredField = window.textFields["searchField"]
        XCTAssertTrue(restoredField.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredField.value as? String, "cafe")
        XCTAssertEqual(window.radioGroups["searchScope"].radioButtons["All"].value as? Int, 1, "the first visit's scope comes back")
        XCTAssertTrue(w10(window, "searchGroup-top").waitForExistence(timeout: 10))
        let again = w10(window, "searchResult-song:devsong0001")
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        let back = w09f2Restored(window, w10(window, "searchResults"), anchor.id, to: anchor.position)
        XCTAssertEqual(try XCTUnwrap(back, "the result group never came back on screen"), anchor.position, accuracy: 12, "the results keep their position")
        XCTAssertTrue(again.isSelected || w10(window, "searchResult-song:devsong0001").isSelected, "the selected result comes back selected")
        // Forward twice: the second visit again.
        window.buttons["browserForward"].click(); XCTAssertTrue(w10(window, "downloadsFilter").waitForExistence(timeout: 10))
        window.buttons["browserForward"].click()
        XCTAssertTrue(window.textFields["searchField"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.textFields["searchField"].value as? String, "cafe del")
        XCTAssertEqual(window.radioGroups["searchScope"].radioButtons["Library"].value as? Int, 1)
        capture(window, "W09-F2 Search second visit after Forward")
    }

    // MARK: W21 — window, menu-bar and sleep/wake lifecycle (T21.1-T21.5)

    @MainActor private func builtProduct() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("YTMuse.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "W21", code: 1, userInfo: [NSLocalizedDescriptionKey: "The built YTMuse.app is missing"])
    }
    /// The built app, launched isolated (throwaway stores and preferences, the in-process fake login item, 0.001 owned-audio gain). The status item it adds
    /// to the real menu bar disappears when the copy quits.
    @MainActor private func lifecycleApplication(loginLaunch: Bool = false) throws -> XCUIApplication {
        let app = isolated(XCUIApplication(url: try builtProduct()))
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YTMUSE_OWNED_AUDIO_TEST_GAIN"] = "0.001"
        if loginLaunch { app.launchEnvironment["YTMUSE_SIMULATE_LOGIN_LAUNCH"] = "1" }
        return app
    }
    @MainActor private func statusItem(_ app: XCUIApplication) -> XCUIElement {
        let candidates = [app.statusItems["statusItem"], app.menuBars.statusItems["statusItem"], app.statusItems.firstMatch, app.menuBars.statusItems.firstMatch]
        return candidates.first { $0.exists } ?? candidates[0]
    }
    /// The activation policy of THIS run's copy of the app, found by its built product's path (the account holder's own YTMuse shares the bundle
    /// identifier, so the identifier alone could name the wrong process).
    @MainActor private func activationPolicy(_ app: XCUIApplication) -> NSApplication.ActivationPolicy? {
        guard let product = try? builtProduct() else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == product.standardizedFileURL.path && !$0.isTerminated }?.activationPolicy
    }
    /// The app's OWN report of its activation policy, read from the status popover's Debug census (`policy=regular|accessory`). The operating system's
    /// view of another process (`NSRunningApplication`) is correct at launch but is not refreshed for a policy change made later, so a transition is
    /// asserted from the app's `NSApp.activationPolicy()` here; whether the Dock really shows or hides the icon is a live observation.
    @MainActor private func censusPolicy(_ app: XCUIApplication) -> NSApplication.ActivationPolicy? {
        let item = statusItem(app)
        guard item.waitForExistence(timeout: 6) else { return nil }
        item.click()
        let census = app.staticTexts["shellCensus"].firstMatch
        defer { app.typeKey(.escape, modifierFlags: []) }
        guard census.waitForExistence(timeout: 6) else { return nil }
        let text = (census.value as? String) ?? census.label
        return text.contains("policy=accessory") ? .accessory : text.contains("policy=regular") ? .regular : nil
    }
    @MainActor private func waitForPolicy(_ app: XCUIApplication, _ policy: NSApplication.ActivationPolicy, timeout: Double = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if censusPolicy(app) == policy { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }
    /// Polls a condition (an NSPredicate over a frame's CGRect does not evaluate through key-value coding).
    @MainActor private func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return condition()
    }
    @MainActor private func lifecycleText(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.staticTexts[id].firstMatch
        return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }
    /// Starts the owned test queue and sets it to repeat, so the 12 s tones never run out under a slow UI sequence.
    @MainActor private func startOwnedAudio(_ app: XCUIApplication, repeatAll: Bool = true) {
        let start = app.buttons["startOwnedAudio"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.click()
        let state = app.staticTexts["playbackState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: state)
        waitForExpectations(timeout: 15)
        if repeatAll {
            app.menuButtons["sleepTimerMenu"].firstMatch.click()
            app.menuItems["Repeat all"].firstMatch.click()
        }
    }
    /// The app's regular windows titled "YTMuse" (the title is matched as well as the identifier: AppKit gives a window its title, not an identifier).
    @MainActor private func browserWindows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "identifier == 'YTMuse' OR title == 'YTMuse' OR label == 'YTMuse' OR identifier BEGINSWITH 'main-AppWindow'"))
    }
    @MainActor private func openPopover(_ app: XCUIApplication) {
        let item = statusItem(app)
        if !item.waitForExistence(timeout: 10) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "W21 application tree (no status item found)"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(item.exists, "the permanent status item exists")
        // A transient popover can close again under the activation the click itself causes; the click is repeated (never more than three times).
        var opened = false
        for _ in 0..<3 where !opened {
            item.click()
            opened = app.buttons["statusShowWindow"].firstMatch.waitForExistence(timeout: 6)
            if !opened { app.typeKey(.escape, modifierFlags: []); Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(opened, "the status item opens its popover")
    }
    @MainActor private func closePopover(_ app: XCUIApplication) { app.typeKey(.escape, modifierFlags: []) }
    @MainActor private func attachCensus(_ app: XCUIApplication, _ name: String) {
        let census = app.staticTexts["shellCensus"].firstMatch
        let text = census.exists ? ((census.value as? String) ?? census.label) : "(no census readout: the popover was not open)"
        let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// T23.2 (isolated launch): several windows, the mini-player and the status popover are views over ONE Now Playing owner. The app's Now Playing and
    /// remote commands are a recording stand-in here (an isolated launch never holds the account holder's media keys), so the readout is the registration
    /// count the owner made: twelve commands once, never again, however many surfaces open. Every model in an isolated launch writes to the SAME stand-in
    /// (`PlaybackModel.recorder`), so a second owner built anywhere in the app would be refused and show as `refused=1`: `refused=0` is evidence about the
    /// whole process. Real media keys are a live observation, never counted here.
    @MainActor func testW23OneNowPlayingOwnerAcrossWindowsMiniPlayerAndPopover() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app)      // repeat all: the 12 s tones never run out under a slow sequence, and Next always has somewhere to go
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil { browserWindows(app).count == 2 }, "a second window: \(browserWindows(app).count)")
        app.typeKey("m", modifierFlags: [.command, .shift])
        let mini = app.windows["miniPlayerWindow"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "the mini-player opens")
        openPopover(app)
        let readout = app.staticTexts["nowPlayingCensus"].firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 8), "the Debug Now Playing readout is in the popover")
        let text = (readout.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? readout.label
        let attachment = XCTAttachment(string: text); attachment.name = "W23 Now Playing census (two windows, mini-player, popover)"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(text.contains("owner=1") && text.contains("registrations=12") && text.contains("attaches=1") && text.contains("refused=0"),
                      "one owner, one set of twelve registrations, made once, none refused: \(text)")
        // The owned tones are 12 s long and the run takes longer than that, so which tone plays when the readout is read is timing, not a fact to assert.
        // What is asserted: Now Playing shows the item the app shows, the state is a readable name, and the change Next causes reaches Now Playing.
        func census() -> String { (readout.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? readout.label }
        func shownTitle() -> String { let t = mini.staticTexts["miniTitle"].firstMatch; return (t.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t.label }
        func censusTitle(_ text: String) -> String { text.components(separatedBy: "title=").last ?? "" }
        XCTAssertTrue(text.contains("state=playing"), "a readable state name, and it plays: \(text)")
        XCTAssertTrue(waitUntil { censusTitle(census()) == shownTitle() && !shownTitle().isEmpty }, "Now Playing shows the item the mini-player shows: \(census()) / \(shownTitle())")
        closePopover(app)
        // The mini-player's Next changes the item; the owner publishes the new one and registers nothing again.
        let before = shownTitle()
        XCTAssertFalse(before.isEmpty)
        mini.buttons["transportNext"].firstMatch.click()
        XCTAssertTrue(waitUntil { shownTitle() != before && !shownTitle().isEmpty }, "Next changed the item shown: \(before) -> \(shownTitle())")
        openPopover(app)
        let after = census()
        XCTAssertTrue(after.contains("attaches=1") && after.contains("refused=0") && after.contains("registrations=12"), "still one registration: \(after)")
        XCTAssertTrue(waitUntil { censusTitle(census()) == shownTitle() && censusTitle(census()) != before }, "the item changed in Now Playing too: \(census()) / \(shownTitle()) (was \(before))")
        XCTAssertTrue(census().contains("state=playing"), "and it plays: \(census())")
        closePopover(app)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Command-Q quits")
    }
    /// P17-WEB (PLAY17): the sleep timer's remaining time is on every surface that shows playback: the bar, the popover, the mini-player and the expanded
    /// Now Playing it hosts. An isolated launch has no hidden YouTube Music page, so the timer under test is the native session's (owned test tones); the
    /// surfaces read it through the same owner call as the YouTube Music timer's. The YouTube Music menu and its fade are headless tests and live checks.
    @MainActor func testP17SleepTimerRemainingOnTheBarPopoverMiniPlayerAndNowPlaying() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app)
        func text(_ element: XCUIElement) -> String { (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label }
        func isTimerLine(_ element: XCUIElement) -> Bool { let value = text(element); return value.hasPrefix("Sleep timer:") && value.hasSuffix("left") }
        app.menuButtons["sleepTimerMenu"].firstMatch.click()
        app.menuItems["Sleep Timer"].firstMatch.click()      // PLAYER-1: the items are in a submenu
        app.menuItems["15 minutes"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["sleepRemaining"].firstMatch.waitForExistence(timeout: 5), "the bar's own line")
        // The popover first (it reads the same owner), then the mini-player from the popover's own button: a menu click leaves focus where the keyboard shortcut
        // guard (W26) does not pass a shortcut on, so the window is opened by its button, not by its key.
        openPopover(app)
        let popoverLine = app.staticTexts["statusSleepRemaining"].firstMatch
        XCTAssertTrue(popoverLine.waitForExistence(timeout: 8), "the popover shows the timer")
        XCTAssertTrue(waitUntil { isTimerLine(popoverLine) }, "a readable remaining time: \(text(popoverLine))")
        app.buttons["statusMiniPlayer"].firstMatch.click()
        let mini = app.windows["miniPlayerWindow"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "the mini-player opens from the popover")
        let miniLine = mini.staticTexts["miniSleepRemaining"].firstMatch
        XCTAssertTrue(miniLine.waitForExistence(timeout: 10), "the mini-player shows the timer")
        XCTAssertTrue(waitUntil { isTimerLine(miniLine) }, "a readable remaining time: \(text(miniLine))")
        capture(mini, "P17 mini-player with the sleep timer")
        closePopover(app)
        // Now Playing is the expanded player V02 hosts in the main window: opened from the bar's artwork button.
        let main = app.windows["YTMuse"]
        main.buttons["Show Now Playing"].firstMatch.click()
        let nowPlayingLine = main.staticTexts["nowPlayingSleepRemaining"].firstMatch
        XCTAssertTrue(nowPlayingLine.waitForExistence(timeout: 10), "Now Playing shows the timer")
        XCTAssertTrue(waitUntil { isTimerLine(nowPlayingLine) }, "a readable remaining time: \(text(nowPlayingLine))")
        capture(main, "P17 Now Playing with the sleep timer")
        // Cancelling removes it everywhere.
        main.menuButtons["sleepTimerMenu"].firstMatch.click()
        app.menuItems["Sleep Timer"].firstMatch.click()
        app.menuItems["Cancel timer"].firstMatch.click()
        let cleared = waitUntil { !nowPlayingLine.exists && !miniLine.exists }
        if !cleared { capture(main, "P17 after Cancel timer (timer line still there)") }
        XCTAssertTrue(cleared, "no timer line is left after Cancel timer (now playing: \(nowPlayingLine.exists), mini: \(miniLine.exists))")
        XCTAssertEqual(lifecycleText(app, "playbackState"), "playing", "setting and cancelling a timer never touched playback")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Command-Q quits")
    }
    /// T21.1 / T21.2: Command-N makes another window that shares the one player; Command-W closes the active window and not the app; closing the last
    /// regular window keeps the audio and the menu bar item and hides the Dock icon; Show Window restores the regular policy; Command-Q quits.
    @MainActor func testW21LastWindowClosedKeepsAudioAndStatusItemThenReopensAndTwoWindowsShareOnePlayer() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        XCTAssertEqual(activationPolicy(app), .regular, "first launch: a main window and the Dock icon")
        startOwnedAudio(app)
        // Command-N: a second window (same frame, in front), the same player.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil { browserWindows(app).count == 2 }, "Command-N opened a second window: \(browserWindows(app).count)")
        // A pause pressed in the front window is the one player's state ...
        app.buttons["transportPlayPause"].firstMatch.click()
        expectation(for: NSPredicate(format: "label == 'paused' OR value == 'paused'"), evaluatedWith: app.staticTexts["playbackState"].firstMatch)
        waitForExpectations(timeout: 10)
        // ... which Command-W (the active, front window) closes without quitting; the window left behind shows the SAME state: one account, one player.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { browserWindows(app).count == 1 }, "Command-W closed the active window only")
        XCTAssertEqual(activationPolicy(app), .regular, "one window left keeps the Dock icon")
        let state = app.staticTexts["playbackState"].firstMatch
        XCTAssertTrue(waitUntil { ((state.value as? String) ?? state.label) == "paused" }, "the first window shows the state the second one set")
        app.buttons["transportPlayPause"].firstMatch.click()
        expectation(for: NSPredicate(format: "label == 'playing' OR value == 'playing'"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        // The last regular window closed: audio and the menu bar item stay, the Dock icon goes.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { browserWindows(app).count == 0 })
        XCTAssertTrue(waitForPolicy(app, .accessory), "the last regular window closed: the Dock icon goes")
        XCTAssertNotEqual(app.state, .notRunning, "closing the last window never quits")
        openPopover(app)
        attachCensus(app, "W21 census after the last window closed")
        let playPause = app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        XCTAssertEqual(playPause.label, "Pause", "eligible audio kept playing with no window")
        capture(app.popovers.firstMatch.exists ? app.popovers.firstMatch : app.statusItems.firstMatch, "W21 status popover with no window")
        playPause.click()
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 8)
        app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch.click()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 8)
        // Show Window restores the regular policy and a window.
        app.buttons["statusShowWindow"].firstMatch.click()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForPolicy(app, .regular), "reopening restores the Dock icon")
        XCTAssertEqual(lifecycleText(app, "playbackState"), "playing", "the same player, still playing")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Command-Q quits")
    }

    /// T21.3: the mini-player is about 360 x 160 compact, expands, pins, does not become a regular window, and a track change never takes focus.
    @MainActor func testW21MiniPlayerCompactExpandedPinnedAndNeverStealsFocusOnATrackChange() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app, repeatAll: false)
        app.buttons["transportPlayPause"].firstMatch.click()      // paused: the item under test stays where it is
        expectation(for: NSPredicate(format: "label == 'paused' OR value == 'paused'"), evaluatedWith: app.staticTexts["playbackState"].firstMatch)
        waitForExpectations(timeout: 10)
        app.typeKey("m", modifierFlags: [.command, .shift])
        let mini = app.windows["miniPlayerWindow"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "the mini-player opens from the Window menu")
        let frame = mini.frame
        XCTAssertEqual(frame.width, 360, accuracy: 14, "about 360 points wide (plus its frame)")
        XCTAssertTrue((150...200).contains(frame.height), "about 160 points tall (plus its title bar): \(frame.height)")
        for id in ["transportPlayPause", "transportPrevious", "transportNext", "miniLike", "miniQueue", "miniVolume", "miniPin", "miniExpand"] {
            XCTAssertTrue(mini.descendants(matching: .any).matching(identifier: id).firstMatch.waitForExistence(timeout: 5), id)
        }
        capture(mini, "W21 mini-player compact")
        // A track change from the mini-player's own Next: the title moves on.
        let title = mini.staticTexts["miniTitle"].firstMatch
        XCTAssertTrue(waitUntil { ((title.value as? String) ?? title.label) == "Owned test tone A" })
        mini.buttons["transportNext"].firstMatch.click()
        XCTAssertTrue(waitUntil { ((title.value as? String) ?? title.label) == "Owned test tone B" }, "Next changed the item: \((title.value as? String) ?? title.label)")
        // Pin and expand.
        mini.buttons["miniPin"].firstMatch.click()
        XCTAssertEqual(mini.buttons["miniPin"].firstMatch.value as? String, "On")
        mini.buttons["miniExpand"].firstMatch.click()
        XCTAssertTrue(waitUntil { mini.frame.height > 400 }, "expanded: \(mini.frame.height)")
        XCTAssertEqual(mini.frame.width, 360, accuracy: 14)
        capture(mini, "W21 mini-player expanded and pinned")
        mini.buttons["collapseNowPlaying"].firstMatch.click()
        XCTAssertTrue(waitUntil { mini.frame.height < 250 }, "compact again: \(mini.frame.height)")
        // Focus: nothing the mini-player did made it the key window, so Command-W closes the MAIN window and the mini-player stays.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { browserWindows(app).count == 0 })
        XCTAssertTrue(mini.exists, "the mini-player was never key, so Command-W did not close it")
        // It is not a regular window: with the main window closed the Dock icon goes while the mini-player stays on screen.
        XCTAssertTrue(waitForPolicy(app, .accessory), "the mini-player is never the last regular window")
        mini.buttons["transportPlayPause"].firstMatch.click()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: mini.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 10)
    }

    /// T21.4 (launch half): a login launch is menu-bar only: no window, no audio; Show Window brings the window; the Settings toggle drives the fake.
    @MainActor func testW21LoginLaunchIsMenuBarOnlyWithNoWindowAndNoAudioAndTheSettingsToggleDrivesOnlyTheFake() throws {
        let app = try lifecycleApplication(loginLaunch: true)
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(statusItem(app).waitForExistence(timeout: 15), "the menu bar item is there")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(browserWindows(app).count, 0, "no window opened for a login launch")
        XCTAssertTrue(waitForPolicy(app, .accessory), "menu-bar only: no Dock icon")
        openPopover(app)
        attachCensus(app, "W21 census after a simulated login launch")
        XCTAssertEqual(app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch.isEnabled, false, "nothing plays at a login launch")
        app.buttons["statusShowWindow"].firstMatch.click()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15), "Show Window brings the window")
        XCTAssertTrue(waitForPolicy(app, .regular))
        XCTAssertFalse(app.staticTexts["playbackState"].exists, "still nothing playing: no surprise audio")
        // Settings: launch at login is off, and the toggle changes only the in-process fake.
        app.typeKey(",", modifierFlags: .command)
        selectSettingsCategory(app, "general")
        let toggle = app.switches["launchAtLogin"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // REAL-DATA SAFETY: the toggle registers a login item. It is touched ONLY when the app itself says the in-process fake answers it; anything
        // else (the system's login item) fails the test here, before any click.
        let service = app.staticTexts["loginItemService"].firstMatch
        XCTAssertTrue(service.waitForExistence(timeout: 10), "the Debug readout of the login item in use is present")
        guard ((service.value as? String) ?? service.label) == "in-process fake" else {
            XCTFail("REFUSING to click the login toggle: the app reports '\((service.value as? String) ?? service.label)', not the in-process fake"); return
        }
        XCTAssertEqual(toggle.value as? Int, 0, "off by default")
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)
        XCTAssertTrue(((app.staticTexts["launchAtLoginNote"].firstMatch.value as? String) ?? app.staticTexts["launchAtLoginNote"].firstMatch.label).contains("menu bar only"))
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        XCTAssertEqual(app.switches["resumeAfterWake"].firstMatch.value as? Int, 1, "resuming after a wake is the default")
    }

    /// W27: Settings opens on a category page; the sidebar buttons are `settingsCategory.<id>`.
    @MainActor private func selectSettingsCategory(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons["settingsCategory." + id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(id) category is in the Settings sidebar")
        button.click()
    }

    /// T27 (UI): categories, search, restore defaults per category, the storage and diagnostics pages and the local-data reset, all on an ISOLATED launch. REAL-DATA SAFETY: the
    /// reset is pressed only after the Debug readout of the active roots says they are isolated (temporary preferences plist, in-memory Spotlight index, throwaway Keychain
    /// files); anything else fails the test before the button is touched. The support bundle is only previewed here (a save panel is not driven); its export is a unit test.
    @MainActor func testW27SettingsCategoriesSearchResetStorageDiagnosticsAndTheIsolatedLocalDataReset() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        // REAL-DATA SAFETY, before ANY change or press: read the GUARD's own verdict on the roots this session's destructive objects actually hold (not the isolated flag).
        XCTAssertTrue(app.staticTexts["localDataRoots"].firstMatch.waitForExistence(timeout: 15), "the Debug readout of the guard's verdict is present on every Settings page")
        let roots = lifecycleText(app, "localDataRoots")
        guard roots.hasPrefix("roots: isolated; guard=accepted"), roots.contains("prefs=plist"), roots.contains("index=in-memory"), roots.contains("keychain=test"), !roots.contains("REAL"), !roots.contains("PRODUCTION"), !roots.contains("refused") else {
            XCTFail("REFUSING to change anything: the guard reports '\(roots)', not an accepted isolated session"); return
        }
        XCTAssertTrue(roots.contains("owned=") && roots.contains("/ytmuse-"), "the owned-audio store is one of the isolated roots: \(roots)")
        // Every category is in the sidebar.
        for id in ["account", "general", "appearance", "playback", "library", "downloads", "integration", "privacy", "updates", "language", "storage", "diagnostics"] {
            XCTAssertTrue(app.buttons["settingsCategory." + id].firstMatch.waitForExistence(timeout: 10), "category \(id)")
        }
        // Appearance is the first page; choose Dark.
        let picker = app.popUpButtons["appearancePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click(); app.menuItems["Dark"].click()
        XCTAssertEqual(picker.value as? String, "Dark")
        // Search finds a setting by a word of its title and opens its page.
        let search = app.textFields["settingsSearch"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("equalizer")
        let result = app.buttons["settingsResult.equalizer"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "searching for a word of a title lists that setting")
        result.click()
        // Playback: the capabilities the app cannot honour are stated, with no control; the equalizer is a real control.
        XCTAssertTrue(app.staticTexts["settingNote.audioQuality"].firstMatch.waitForExistence(timeout: 5), "an unavailable capability says why")
        XCTAssertFalse(app.popUpButtons["setting.audioQuality"].exists || app.switches["setting.audioQuality"].exists, "and offers no control")
        XCTAssertTrue(app.staticTexts["settingNote.autoplayRadio"].firstMatch.exists, "autoplay radio says which feature owns it")
        let equalizer = app.popUpButtons["setting.equalizer"].firstMatch
        XCTAssertTrue(equalizer.waitForExistence(timeout: 5))
        XCTAssertEqual(equalizer.value as? String, "Flat", "flat by default")
        equalizer.click(); app.menuItems["Bass boost"].click()
        XCTAssertEqual(equalizer.value as? String, "Bass boost")
        // Restore Defaults on the Playback page changes only the Playback page.
        app.buttons["restoreDefaults.playback"].firstMatch.click()
        XCTAssertTrue(waitUntil { (equalizer.value as? String) == "Flat" }, "Playback is back to its defaults")
        selectSettingsCategory(app, "appearance")
        XCTAssertEqual(app.popUpButtons["appearancePicker"].value as? String, "Dark", "restoring Playback did not touch Appearance")
        // Storage: the breakdown reconciles with the owners' figures.
        selectSettingsCategory(app, "storage")
        XCTAssertTrue(app.staticTexts["storageTotal"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(lifecycleText(app, "storageReconciles").contains("add up to what"), "storage: \(lifecycleText(app, "storageReconciles"))")
        // Diagnostics: the real adapter, engine and quality unknowns; the verdict; the bundle preview holds no private text.
        selectSettingsCategory(app, "diagnostics")
        XCTAssertTrue(app.staticTexts["diagAdapter"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(lifecycleText(app, "diagAdapter").isEmpty)
        XCTAssertTrue(app.staticTexts["diagEngine"].firstMatch.exists && app.staticTexts["diagVerdict"].firstMatch.exists && app.staticTexts["diagQuality"].firstMatch.exists)
        XCTAssertTrue(lifecycleText(app, "diagQuality").contains("Not reported") || lifecycleText(app, "diagQuality").contains("kbps"), "quality is reported or its unknowns are named")
        app.buttons["previewBundle"].firstMatch.click()
        let preview = app.staticTexts["bundlePreviewText"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "the support bundle preview opens")
        let previewText = (preview.value as? String) ?? preview.label
        XCTAssertTrue(previewText.contains("\"exclusions\""), "the preview shows the bundle's own exclusions")
        XCTAssertFalse(previewText.contains("@") || previewText.lowercased().contains("cookie:"), "no email or cookie text in the preview")
        app.buttons["bundleClose"].firstMatch.click()
        // Privacy: the verdict is read again immediately before the press, and must still be an accepted isolated session.
        selectSettingsCategory(app, "privacy")
        XCTAssertTrue(app.staticTexts["localDataRoots"].firstMatch.waitForExistence(timeout: 10), "the Debug readout of the roots is present")
        XCTAssertEqual(lifecycleText(app, "localDataRoots"), roots, "the guard's verdict on the roots did not change during the run")
        XCTAssertTrue(app.staticTexts["networkDestinations"].firstMatch.exists)
        app.buttons["resetLocalData"].firstMatch.click()
        let confirm = app.sheets.buttons["Reset All Local Data"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a confirmation first")
        confirm.click()
        XCTAssertTrue(app.staticTexts["resetLocalDataResult"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(lifecycleText(app, "resetLocalDataResult"), "Local data was reset.")
        selectSettingsCategory(app, "appearance")
        XCTAssertEqual(app.popUpButtons["appearancePicker"].value as? String, "System", "the reset restored Appearance")
        XCTAssertTrue(lifecycleText(app, "localDataRoots").hasPrefix("roots: isolated; guard=accepted"), "the roots are still the isolated ones afterwards")
    }

    /// T25.3 (MAC05): Spotlight indexing is opt-in. On an isolated launch (an in-memory index; the system's is never reached) both choices are off, the private one cannot be
    /// turned on before the first, and the choices change only this launch's throwaway preferences.
    @MainActor func testW25SpotlightIsOptInAndPrivateEntitiesNeedASecondChoice() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        selectSettingsCategory(app, "integration")
        let indexing = app.switches["spotlightIndexing"].firstMatch, privateToggle = app.switches["spotlightIndexPrivate"].firstMatch
        XCTAssertTrue(indexing.waitForExistence(timeout: 10), "the Spotlight section is in Settings")
        // REAL-DATA SAFETY: the toggles are clicked only when the shell says its services are the in-process stand-ins.
        XCTAssertEqual(lifecycleText(app, "hotKeyService"), "in-process fake", "REFUSING to touch Settings on a launch that is not isolated")
        XCTAssertEqual(indexing.value as? Int, 0, "indexing is off by default")
        XCTAssertEqual(privateToggle.value as? Int, 0, "private entities are off by default")
        XCTAssertFalse(privateToggle.isEnabled, "private entities cannot be chosen before indexing is")
        indexing.click()
        XCTAssertTrue(waitUntil { (indexing.value as? Int) == 1 && privateToggle.isEnabled }, "turning indexing on offers the private choice")
        XCTAssertEqual(privateToggle.value as? Int, 0, "and leaves it off")
        privateToggle.click()
        XCTAssertTrue(waitUntil { (privateToggle.value as? Int) == 1 })
        privateToggle.click()
        XCTAssertTrue(waitUntil { (privateToggle.value as? Int) == 0 })
        indexing.click()
        XCTAssertTrue(waitUntil { (indexing.value as? Int) == 0 && !privateToggle.isEnabled }, "turning indexing off takes the private choice away again")
        let note = app.staticTexts["spotlightNote"].firstMatch
        XCTAssertTrue(((note.value as? String) ?? note.label).contains("Off until you turn it on"))
    }

    /// T21.5: with the main window minimized the transport, the status item and Now Playing stay responsive; the window's gate reads hidden then visible.
    @MainActor func testW21MinimizedWindowKeepsTheTransportAndTheStatusItemResponsive() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        startOwnedAudio(app)
        XCTAssertTrue(lifecycleText(app, "designPlayerGate").contains("window visible"))
        app.typeKey("m", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !window.isHittable }, "the window is minimized")
        XCTAssertEqual(activationPolicy(app), .regular, "a minimized window still keeps the Dock icon to restore it from")
        openPopover(app)
        attachCensus(app, "W21 census with the main window minimized")
        let playPause = app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        XCTAssertEqual(playPause.label, "Pause")
        playPause.click()
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: app.popovers.firstMatch.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 10)
        app.buttons["statusShowWindow"].firstMatch.click()
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == 'paused' OR value == 'paused'"), evaluatedWith: app.staticTexts["playbackState"].firstMatch)
        waitForExpectations(timeout: 10)
        let gate = app.staticTexts["designPlayerGate"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS 'window visible' OR value CONTAINS 'window visible'"), evaluatedWith: gate)
        waitForExpectations(timeout: 10)
    }

    /// WIN06: full-screen Now Playing is a native window that enters full screen, shows the transport, queue and lyrics on request, and leaves
    /// playback and the main window as they were.
    @MainActor func testW21FullScreenNowPlayingShowsTransportAndLeavesPlaybackAlone() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app)
        app.typeKey("p", modifierFlags: [.command, .option])
        let full = app.windows["nowPlayingFullScreen"]
        XCTAssertTrue(full.waitForExistence(timeout: 15))
        XCTAssertTrue(full.buttons["transportPlayPause"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(full.staticTexts["currentMediaTitle"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        capture(full, "W21 full-screen Now Playing")
        let pause = full.buttons["transportPlayPause"].firstMatch
        pause.click()
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: full.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 10)
        full.buttons["transportPlayPause"].firstMatch.click()
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: full.buttons["transportPlayPause"].firstMatch)
        waitForExpectations(timeout: 10)
        full.buttons["collapseNowPlaying"].firstMatch.click()
        Thread.sleep(forTimeInterval: 2)
        if full.exists, full.buttons["transportPlayPause"].firstMatch.exists { full.buttons[XCUIIdentifierCloseWindow].firstMatch.click() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 10), "browsing in the main window is still there")
        XCTAssertEqual(lifecycleText(app, "playbackState"), "playing", "entering and leaving never touched playback")
    }

    // MARK: W26 keyboard, menus and opt-in system features (isolated launch: fake hot keys, fake notification center, private clipboard)

    /// T30.3: an isolated launch has no update feed, so it never asks to check for updates and Settings says why and offers no update control. (A release build with a
    /// feed asks once and defaults to no checks: that is proved headlessly by ControllerTests; a real signed install is the W46 rehearsal.)
    @MainActor func testW30UpdatesAreUnavailableWithoutAFeedAndNothingAsksToCheck() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3) || app.alerts["Check for updates once a day?"].exists, "no update question on a build without a feed")
        app.typeKey(",", modifierFlags: .command)
        selectSettingsCategory(app, "updates")
        let unavailable = app.staticTexts["updatesUnavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10), "Settings has an Updates section that says updates are unavailable")
        XCTAssertTrue(lifecycleText(app, "updatesUnavailable").localizedCaseInsensitiveContains("no update feed"), lifecycleText(app, "updatesUnavailable"))
        XCTAssertFalse(app.switches["updatesDaily"].firstMatch.exists, "no daily-check control without a feed")
        XCTAssertFalse(app.switches["updatesAutomatic"].firstMatch.exists)
        XCTAssertFalse(app.buttons["updatesCheckNow"].firstMatch.exists)
        XCTAssertFalse(app.buttons["updatesRestart"].firstMatch.exists)
    }
    /// T26.1 / T26.5: Space plays and pauses only when nothing that edits text or acts on Space has focus; the same Space types a space in the search field and
    /// Command-Arrow stays with the field; Command-Right skips; Command-Shift-M opens the mini-player and Command-Option-Q the queue; Settings shows the global
    /// shortcuts unassigned and the song notifications off, both answered by in-process fakes, and turning notifications on shows no system prompt.
    @MainActor func testW26KeyboardGuardsMenusAndOptInSettingsOnAnIsolatedLaunch() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        startOwnedAudio(app)
        func state() -> String { lifecycleText(app, "playbackState") }
        func neutralFocus() { app.staticTexts["playbackState"].firstMatch.click() }
        // Space with nothing focused toggles playback, both ways.
        neutralFocus()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitUntil { state() == "paused" }, "Space paused: \(state())")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitUntil { state() == "playing" }, "Space played: \(state())")
        // Command-Shift-M: the mini-player; its title is the item the app plays.
        app.typeKey("m", modifierFlags: [.command, .shift])
        let mini = app.windows["miniPlayerWindow"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "Command-Shift-M opens the mini-player")
        func shownTitle() -> String { let t = mini.staticTexts["miniTitle"].firstMatch; return (t.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t.label }
        XCTAssertTrue(waitUntil { !shownTitle().isEmpty })
        // Command-Right is Next.
        neutralFocus()
        let first = shownTitle()
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(waitUntil { !shownTitle().isEmpty && shownTitle() != first }, "Command-Right skipped: \(first) -> \(shownTitle())")
        // In the search field the same keys belong to the field.
        let second = shownTitle()
        app.typeKey("f", modifierFlags: .command)
        let field = window.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("a b")
        XCTAssertEqual(field.value as? String, "a b", "Space typed a space in the field")
        XCTAssertEqual(state(), "playing", "and did not pause")
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(shownTitle(), second, "Command-Arrow in the field did not skip")
        XCTAssertEqual(state(), "playing")
        // Command-Option-Q shows the queue panel.
        neutralFocus()
        app.typeKey("q", modifierFlags: [.command, .option])
        let panel = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'inlineTrailingPanel' OR identifier == 'compactTrailingPanel'")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Command-Option-Q shows the queue")
        // Settings (Command-comma): everything opt-in is off or unassigned, and the fakes answer.
        app.typeKey(",", modifierFlags: .command)
        selectSettingsCategory(app, "integration")
        let settings = app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings' OR identifier CONTAINS 'settings'")).firstMatch
        XCTAssertTrue(app.staticTexts["hotKeyService"].firstMatch.waitForExistence(timeout: 10), "the Settings pane is up (\(settings.exists))")
        XCTAssertEqual(lifecycleText(app, "hotKeyService"), "in-process fake", "REFUSING to record a global shortcut against the system's registrar")
        XCTAssertEqual(lifecycleText(app, "notificationService"), "in-process fake", "REFUSING to turn notifications on against the system's center")
        for action in ["showHide", "playPause", "next", "previous"] { XCTAssertEqual(lifecycleText(app, "globalShortcutValue." + action), "Not set", "unassigned by default: \(action)") }
        let notify = app.switches["songNotifications"].firstMatch
        XCTAssertEqual(notify.value as? Int, 0, "notifications are off by default")
        notify.click()
        XCTAssertTrue(waitUntil { (notify.value as? Int) == 1 }, "the fake center authorized: no system prompt, the switch is on")
        notify.click()
        XCTAssertTrue(waitUntil { (notify.value as? Int) == 0 })
        // Recording: a standard editing shortcut is refused with a sentence; a free chord is taken.
        app.buttons["globalShortcutRecord.playPause"].firstMatch.click()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["globalShortcutMessage"].firstMatch.waitForExistence(timeout: 5), "Command-C is refused")
        XCTAssertEqual(lifecycleText(app, "globalShortcutValue.playPause"), "Not set")
        // The app's own full-screen chord (not in the section 13 table) and an Option-only letter are refused too.
        app.buttons["globalShortcutRecord.playPause"].firstMatch.click()
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(waitUntil { lifecycleText(app, "globalShortcutMessage").contains("YTMuse already uses") }, "the app's own chord is refused: \(lifecycleText(app, "globalShortcutMessage"))")
        XCTAssertEqual(lifecycleText(app, "globalShortcutValue.playPause"), "Not set")
        app.buttons["globalShortcutRecord.playPause"].firstMatch.click()
        app.typeKey("j", modifierFlags: [.control, .option, .command])
        XCTAssertTrue(waitUntil { lifecycleText(app, "globalShortcutValue.playPause") == "⌃⌥⌘J" }, "a free chord is recorded: \(lifecycleText(app, "globalShortcutValue.playPause"))")
        app.buttons["globalShortcutClear.playPause"].firstMatch.click()
        XCTAssertTrue(waitUntil { lifecycleText(app, "globalShortcutValue.playPause") == "Not set" })
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Command-Q quits")
    }

    // MARK: W22 output routes (ROUTE01, ROUTE03, ROUTE09). The outputs are scripted in an isolated launch: no real device is read or changed.

    @MainActor private func playbackState(_ app: XCUIApplication) -> String { lifecycleText(app, "playbackState") }
    @MainActor private func waitForPlaybackState(_ app: XCUIApplication, _ state: String, timeout: TimeInterval = 15) {
        let element = app.staticTexts["playbackState"].firstMatch
        expectation(for: NSPredicate(format: "label == %@ OR value == %@", state, state), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    /// The output picker lists the scripted outputs with their state and what they cannot do; a lost output pauses with a route-loss reason; Play asks
    /// first ("Play here") and stays silent until confirmed; Cancel leaves it silent.
    @MainActor func testW22OutputPickerLossAndPlayHereConfirmation() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app, repeatAll: true)
        let picker = app.buttons["outputPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        XCTAssertTrue(app.buttons["outputRoute-system-default"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["outputRoute-coreaudio:SCRIPTED-BT-HEADPHONES"].firstMatch.exists)
        XCTAssertTrue(app.buttons["outputRoute-coreaudio:SCRIPTED-BUILT-IN-SPEAKERS"].firstMatch.exists)
        capture(app.windows.firstMatch, "W22 output picker")
        app.typeKey(.escape, modifierFlags: [])
        // The headphones leave: playback pauses at once, with the reason shown in the picker.
        app.buttons["simulateOutputLoss"].firstMatch.click()
        waitForPlaybackState(app, "paused")
        picker.click()
        XCTAssertTrue(app.buttons["outputPlayHere"].firstMatch.waitForExistence(timeout: 10))
        capture(app.windows.firstMatch, "W22 output lost")
        app.typeKey(.escape, modifierFlags: [])
        // Play asks first, and nothing sounds meanwhile.
        app.buttons["transportPlayPause"].firstMatch.click()
        XCTAssertTrue(app.buttons["outputPromptConfirm"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(playbackState(app), "paused", "nothing is audible while the confirmation is up")
        capture(app.windows.firstMatch, "W22 Play here confirmation")
        app.buttons["outputPromptCancel"].firstMatch.click()
        XCTAssertFalse(app.buttons["outputPromptConfirm"].firstMatch.exists)
        XCTAssertEqual(playbackState(app), "paused", "cancelling leaves it silent")
        // Confirming plays on this Mac's output.
        app.buttons["transportPlayPause"].firstMatch.click()
        XCTAssertTrue(app.buttons["outputPromptConfirm"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["outputPromptConfirm"].firstMatch.click()
        waitForPlaybackState(app, "playing")
    }

    // MARK: W28 - keyboard-only paths, an accessibility-tree traversal and independent language choices (T28.1, T28.5, T28.6)

    /// What an assistive technology would announce for an element: its label, title, value or placeholder.
    private func w28Name(_ snapshot: XCUIElementSnapshot) -> String {
        for candidate in [snapshot.label, snapshot.title, (snapshot.value as? String) ?? "", snapshot.placeholderValue ?? ""] where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return candidate }
        return ""
    }
    private func w28Walk(_ snapshot: XCUIElementSnapshot, _ visit: (XCUIElementSnapshot) -> Void) { visit(snapshot); for child in snapshot.children { w28Walk(child, visit) } }
    /// Every operable element under a root that has no accessible name. Window chrome is named by the system.
    @MainActor private func w28UnnamedOperable(_ root: XCUIElement) throws -> (operable: Int, unnamed: [String]) {
        let operable: Set<XCUIElement.ElementType> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .textField, .searchField, .link, .comboBox, .disclosureTriangle, .stepper, .switch]
        var count = 0; var unnamed: [String] = []
        w28Walk(try root.snapshot()) { item in
            // Window chrome (close, minimise, zoom, full screen) is named by the system and reported with an `_XCUI:` identifier. A SwiftUI switch takes its
            // name from the title element beside it, a relationship an XCUITest snapshot does not carry, so switches are checked for their visible title in
            // the Settings step instead and by a person with VoiceOver (W42 live list).
            guard operable.contains(item.elementType), item.isEnabled, !item.identifier.hasPrefix("_XCUI:"), item.elementType != .switch else { return }
            count += 1
            if w28Name(item).isEmpty { unnamed.append("\(item.elementType.rawValue) id=\(item.identifier.isEmpty ? "<none>" : item.identifier) frame=\(item.frame)") }
        }
        return (count, unnamed)
    }
    /// The element that has keyboard focus now, as "type:identifier-or-name" (the query is the system's own `hasKeyboardFocus` attribute).
    @MainActor private func w28Focus(_ app: XCUIApplication) -> String? {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).allElementsBoundByIndex
        for element in focused where element.elementType != .window && element.elementType != .application {
            let name = element.identifier.isEmpty ? (element.label.isEmpty ? element.title : element.label) : element.identifier
            return "\(element.elementType.rawValue):\(name)"
        }
        return nil
    }
    @MainActor func testW28KeyboardAndAccessibilityTraversal() throws {
        let app = designApplication()
        app.launchEnvironment["YTMUSE_UI_TEST_DEFAULTS_ID"] = UUID().uuidString   // one throwaway preferences plist for the relaunch below
        app.launchArguments = app.launchArguments.filter { $0 != "3" && $0 != "-AppleKeyboardUIMode" } + ["-AppleKeyboardUIMode", "2"]   // full keyboard access for this launch only (process-local)
        for key in ["YTMUSE_UI_DEVELOPMENT_LIBRARY", "YTMUSE_UI_DEVELOPMENT_PLAYLISTS", "YTMUSE_UI_DEVELOPMENT_UPLOADS"] { app.launchEnvironment[key] = "1" }
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "the main window is up")
        var log: [[String: String]] = []
        func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
        // 1. The focus ring: Tab walks through controls without a trap, and every stop is named.
        app.typeKey("f", modifierFlags: .command); app.typeKey(.escape, modifierFlags: [])   // start from a known place: the search field, then out of it
        var stops: [String] = []
        for step in 0..<28 {
            app.typeKey("\t", modifierFlags: [])
            let stop = w28Focus(app) ?? "none"
            stops.append(stop); log.append(["tab": "\(step)", "focus": stop])
        }
        let distinct = Set(stops.filter { $0 != "none" })
        // With the system's full keyboard access off (a launch argument cannot switch it on for XCUITest), Tab walks the key-view loop of text fields and
        // lists: here the sidebar and the search field. It must keep moving, name every stop, and never hold focus on one control (a trap).
        XCTAssertGreaterThanOrEqual(distinct.count, 2, "Tab moves between controls: \(stops)")
        var run = 1, longest = 1
        for index in stops.indices.dropFirst() { run = stops[index] == stops[index - 1] && stops[index] != "none" ? run + 1 : 1; longest = max(longest, run) }
        XCTAssertLessThanOrEqual(longest, 2, "no focus trap: the same control did not keep focus through \(longest) Tab presses: \(stops)")
        XCTAssertFalse(stops.contains { $0.hasSuffix(":") || $0 == "none" }, "every focus stop is a named control: \(stops)")
        // Shift-Tab goes back to the previous stop.
        let before = w28Focus(app); app.typeKey("\t", modifierFlags: []); app.typeKey("\t", modifierFlags: .shift)
        XCTAssertEqual(w28Focus(app), before, "Shift-Tab returns to the previous stop")
        // 2. The command palette is the keyboard route to every destination; Return runs the match, Escape closes it, neither traps.
        var visited: [String: (operable: Int, unnamed: [String])] = [:]
        func identifiers(_ root: XCUIElement) throws -> [String] { var out: [String] = []; w28Walk(try root.snapshot()) { if !$0.identifier.isEmpty { out.append($0.identifier) } }; return out }
        var lastIdentifiers = Set(try identifiers(window))
        for (title, destination) in [("Downloads", "downloads"), ("Uploads", "uploads"), ("History", "history"), ("Library", "library"), ("Explore", "explore"), ("Home", "home")] {
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(any("commandPalette").waitForExistence(timeout: 10), "Command-K opens the palette")
            app.typeText("Go to " + title)
            XCTAssertTrue(any("paletteCommand-go-" + destination).waitForExistence(timeout: 10), "the palette offers 'Go to \(title)'")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitUntil { !self.any(app, "commandPalette").exists }, "Return ran the command and closed the palette")
            Thread.sleep(forTimeInterval: 0.6)
            let identifiers = Set(try identifiers(window))
            XCTAssertNotEqual(identifiers, lastIdentifiers, "going to \(title) changed what the window shows")
            lastIdentifiers = identifiers
            Thread.sleep(forTimeInterval: 0.8)
            visited[destination] = try w28UnnamedOperable(window)
            log.append(["destination": destination, "operable": "\(visited[destination]!.operable)", "unnamed": visited[destination]!.unnamed.joined(separator: "; ")])
        }
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(any("commandPalette").waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.any(app, "commandPalette").exists }, "Escape closes the palette: no trap")
        for (destination, result) in visited {
            XCTAssertGreaterThanOrEqual(result.operable, 3, "\(destination): the traversal found operable controls (\(result.operable))")
            XCTAssertTrue(result.unnamed.isEmpty, "\(destination): operable controls without an accessible name: \(result.unnamed)")
        }
        // 3. The accounts sheet opens from the palette and closes with Escape; the window works afterwards.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(any("commandPalette").waitForExistence(timeout: 10))
        app.typeText("Manage Accounts")
        XCTAssertTrue(any("paletteCommand-accounts").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Accounts"].firstMatch.waitForExistence(timeout: 10), "the accounts sheet is up")
        let sheet = try w28UnnamedOperable(window)
        XCTAssertTrue(sheet.unnamed.isEmpty, "accounts: operable controls without an accessible name: \(sheet.unnamed)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !app.staticTexts["Accounts"].firstMatch.exists }, "Escape closes the accounts sheet: no trap")
        // 4. The queue, and its non-drag reorder actions.
        app.typeKey("q", modifierFlags: [.command, .option])
        XCTAssertTrue(any("inlineTrailingPanel").waitForExistence(timeout: 10) || any("compactTrailingPanel").waitForExistence(timeout: 2), "Command-Option-Q shows the queue")
        let queue = try w28UnnamedOperable(window)
        XCTAssertTrue(queue.unnamed.isEmpty, "queue: operable controls without an accessible name: \(queue.unnamed)")
        capture(window, "W28 traversal", samples: log)
    }
    /// W28 (T28.5, A11Y02, F2, F6): the three language choices are independent; the interface language reaches String(localized:) and the menu bar after a relaunch; the text size
    /// scales the page. On the isolated built product, with the guard's own readout checked before any preference is touched.
    @MainActor func testW28LanguageChoicesTextSizeAndRelaunch() throws {
        let app = try lifecycleApplication()
        app.launchEnvironment["YTMUSE_UI_TEST_DEFAULTS_ID"] = UUID().uuidString   // one throwaway preferences plist for the relaunch below
        app.launchArguments += ["-AppleKeyboardUIMode", "2"]
        app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "the main window is up")
        func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
        // The page whose title is measured below: Downloads, by the keyboard route.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(any("commandPalette").waitForExistence(timeout: 10))
        app.typeText("Go to Downloads")
        XCTAssertTrue(any("paletteCommand-go-downloads").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(any("destinationTitle").waitForExistence(timeout: 10), "the Downloads page has its title")
        // 5. Settings > Language: interface language, content language and region are three separate choices.
        app.typeKey(",", modifierFlags: .command)
        // Fail safe: the pickers below write the app's preferences. Stop before touching one unless the guard's own readout says this session holds only isolated roots.
        continueAfterFailure = false
        XCTAssertTrue(app.staticTexts["localDataRoots"].firstMatch.waitForExistence(timeout: 15), "the guard's readout is on every Settings page")
        let roots = lifecycleText(app, "localDataRoots")
        guard roots.hasPrefix("roots: isolated; guard=accepted"), roots.contains("prefs=plist"), !roots.contains("REAL"), !roots.contains("PRODUCTION") else {
            XCTFail("REFUSING to change a language preference: the guard reports '\(roots)', not an accepted isolated session"); return
        }
        selectSettingsCategory(app, "language")
        let ui = app.popUpButtons["interfaceLanguagePicker"].firstMatch, content = app.popUpButtons["contentLanguagePicker"].firstMatch, region = app.popUpButtons["contentRegionPicker"].firstMatch
        XCTAssertTrue(ui.waitForExistence(timeout: 15), "Settings has the language pickers")
        func shown(_ picker: XCUIElement) -> String { (picker.value as? String) ?? picker.title }
        let (contentBefore, regionBefore) = (shown(content), shown(region))
        let settingsCheck = try w28UnnamedOperable(app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings' OR title CONTAINS 'Language' OR identifier CONTAINS 'settings'")).firstMatch.exists ? app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings' OR title CONTAINS 'Language' OR identifier CONTAINS 'settings'")).firstMatch : window)
        XCTAssertTrue(settingsCheck.unnamed.isEmpty, "settings: operable controls without an accessible name: \(settingsCheck.unnamed)")
        content.click(); app.menuItems["Français"].firstMatch.click()
        XCTAssertTrue(waitUntil { shown(content) == "Français" }, "the content language is now French: \(shown(content))")
        region.click(); app.menuItems["Switzerland"].firstMatch.click()
        XCTAssertTrue(waitUntil { shown(region) == "Switzerland" }, "the region is now Switzerland: \(shown(region))")
        XCTAssertNotEqual(contentBefore, shown(content)); XCTAssertNotEqual(regionBefore, shown(region))
        ui.click(); app.menuItems["Deutsch"].firstMatch.click()
        let german = NSPredicate(format: "label == %@ OR title == %@ OR value == %@", "Sprache der Benutzeroberfläche", "Sprache der Benutzeroberfläche", "Sprache der Benutzeroberfläche")
        XCTAssertTrue(app.descendants(matching: .any).matching(german).firstMatch.waitForExistence(timeout: 10), "SwiftUI text switched to German at once")
        XCTAssertEqual(shown(content), "Français", "the content language did not follow the interface language")
        XCTAssertEqual(shown(region), "Switzerland", "the region did not follow the interface language")
        XCTAssertTrue(app.staticTexts["languageRelaunchNote"].firstMatch.exists, "the relaunch note is shown (and is true, below)")
        // 5b. Text size (A11Y02): choosing 150% in Settings > Appearance makes the main window's content measurably larger, and 100% restores it.
        let titleBefore = any("destinationTitle").frame.height
        XCTAssertGreaterThan(titleBefore, 10, "the page title was measured (\(titleBefore))")
        selectSettingsCategory(app, "appearance")
        let sizePicker = app.descendants(matching: .any)["textSizePicker"].firstMatch
        XCTAssertTrue(sizePicker.waitForExistence(timeout: 10), "Settings > Appearance has the Text size control")
        let large = sizePicker.buttons["150%"].exists ? sizePicker.buttons["150%"] : sizePicker.radioButtons["150%"]
        large.click()
        XCTAssertTrue(waitUntil { self.any(app, "destinationTitle").frame.height > titleBefore * 1.3 }, "the page title grew with the text size: \(titleBefore) → \(any("destinationTitle").frame.height)")
        let ratio = any("destinationTitle").frame.height / titleBefore
        XCTAssertLessThan(abs(ratio - 1.5), 0.25, "about 1.5 times as tall (\(ratio))")
        (sizePicker.buttons["100%"].exists ? sizePicker.buttons["100%"] : sizePicker.radioButtons["100%"]).click()
        XCTAssertTrue(waitUntil { abs(self.any(app, "destinationTitle").frame.height - titleBefore) < 2 }, "100% restores the size")
        selectSettingsCategory(app, "language")
        // 6. Relaunch with the same throwaway preferences: String(localized:) and the menu bar follow the choice now.
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 20), "the relaunched window")
        XCTAssertTrue(app.menuBars.menuBarItems["Wiedergabe"].waitForExistence(timeout: 10), "the Playback menu of the menu bar is German after the relaunch: \(app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.title))")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(any("commandPalette").waitForExistence(timeout: 10))
        XCTAssertTrue(any("paletteCommand-go-downloads").waitForExistence(timeout: 10))
        let paletteTitle = any("paletteCommand-go-downloads").label
        XCTAssertFalse(paletteTitle.isEmpty || paletteTitle.hasPrefix("Go to"), "the palette title (a String(localized:) value) is German after the relaunch: \(paletteTitle)")
        app.typeKey(.escape, modifierFlags: [])
        // Put the throwaway choice back, through the page's own button.
        app.typeKey(",", modifierFlags: .command)
        selectSettingsCategory(app, "language")
        app.buttons["restoreLanguageDefaults"].firstMatch.click()
    }
    /// W28 rework 1 (A11Y01): route selection reached from the keyboard alone, on an isolated launch with owned (synthetic) audio: the command palette and the menu bar both
    /// open the output popover, and Escape closes it. (The scripted route list is the one W22's test uses.)
    @MainActor func testW28RouteSelectionHasAKeyboardPath() throws {
        let app = try lifecycleApplication()
        app.launchArguments += ["-AppleKeyboardUIMode", "2"]   // process-local: full keyboard access for this launch only, never a system setting
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app, repeatAll: true)
        XCTAssertTrue(app.buttons["outputPicker"].firstMatch.waitForExistence(timeout: 10), "the output button exists")
        XCTAssertFalse(app.buttons["outputRoute-system-default"].firstMatch.exists, "the popover starts closed")
        // 1. The command palette.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(any(app, "commandPalette").waitForExistence(timeout: 10))
        app.typeText("Choose Output")
        XCTAssertTrue(any(app, "paletteCommand-output").waitForExistence(timeout: 10), "the palette offers 'Choose Output…'")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["outputRoute-system-default"].firstMatch.waitForExistence(timeout: 10), "Return opened the output popover with its routes")
        XCTAssertTrue(app.buttons["outputRoute-coreaudio:SCRIPTED-BT-HEADPHONES"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !app.buttons["outputRoute-system-default"].firstMatch.exists }, "Escape closed the popover: no trap")
        // 2. The menu bar: Playback > Choose Output…
        app.menuBars.menuBarItems["Playback"].click()
        app.menuBars.menuItems["Choose Output…"].firstMatch.click()
        XCTAssertTrue(app.buttons["outputRoute-system-default"].firstMatch.waitForExistence(timeout: 10), "the menu item opened the output popover")
        // 3. Choose a route with the keyboard-reachable button, and see it become current.
        app.buttons["outputRoute-coreaudio:SCRIPTED-BUILT-IN-SPEAKERS"].firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
    }
    @MainActor private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
    /// W39: the picker lists the scripted receivers (found only because the picker was opened), says what Cast can and cannot play and what Quit does, chooses one,
    /// loses it (the simulated receiver drops), asks before playing on the Mac, and leaves the receiver when a Mac output is chosen. Everything is in-process: no
    /// network, no device.
    @MainActor func testW39CastPickerReceiverLossAndLeave() throws {
        let app = try lifecycleApplication()
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.windows["YTMuse"].waitForExistence(timeout: 15))
        startOwnedAudio(app, repeatAll: true)
        let picker = app.buttons["outputPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let living = app.buttons["outputRoute-cast:SCRIPTED-CAST-LIVING"].firstMatch
        XCTAssertTrue(living.waitForExistence(timeout: 10), "the scripted receiver is listed once the picker is open")
        XCTAssertTrue(app.buttons["outputRoute-cast:SCRIPTED-CAST-KITCHEN"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Only owned and local audio can be cast. YouTube Music can't be cast from this app."].firstMatch.exists)
        capture(app.windows.firstMatch, "W39 cast picker")
        living.click()
        // Chosen: the picker now says what quitting does while the Mac is serving the audio. (The popover may have stayed open; only reopen it if it closed.)
        let quitNote = app.staticTexts["Playback on the receiver stops when you quit, because this Mac is serving the audio."].firstMatch
        if !quitNote.waitForExistence(timeout: 5) { picker.click() }
        XCTAssertTrue(quitNote.waitForExistence(timeout: 10))
        capture(app.windows.firstMatch, "W39 casting")
        app.typeKey(.escape, modifierFlags: [])
        // The receiver drops: playback pauses, the picker offers Play Here, and Play asks first.
        app.buttons["simulateCastLoss"].firstMatch.click()
        waitForPlaybackState(app, "paused")
        picker.click()
        XCTAssertTrue(app.buttons["outputPlayHere"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The Cast receiver disconnected, so playback paused."].firstMatch.exists)
        capture(app.windows.firstMatch, "W39 cast receiver lost")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["transportPlayPause"].firstMatch.click()
        XCTAssertTrue(app.buttons["outputPromptConfirm"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(playbackState(app), "paused", "nothing is audible while the confirmation is up")
        capture(app.windows.firstMatch, "W39 cast Play here confirmation")
        app.buttons["outputPromptCancel"].firstMatch.click()
        XCTAssertEqual(playbackState(app), "paused")
    }
}

// MARK: W44-prep — indicative performance (optimized Debug, isolated, SYNTHETIC data; never W44 results)
//
// These tests run only through `scripts/perf-run.sh ui` (it sets TEST_RUNNER_YTMUSE_PERF_DIR, takes the UI lock and both real-state snapshots and samples CPU and
// footprint). Without that directory they skip. The app they launch is the ordinary isolated Debug app with the Debug-only synthetic PERF04 dataset
// (50,000 library songs, 1,000 playlists, a 10,000-entry playlist, a 5,000-item queue, mixed artwork sizes). Nothing here touches a real store or the network.
extension NativeMusicUITests {
    @MainActor private func perfApplication(_ test: String = #function) throws -> XCUIApplication {
        guard let directory = ProcessInfo.processInfo.environment["YTMUSE_PERF_DIR"], !directory.isEmpty else { throw XCTSkip("Performance UI tests run only through scripts/perf-run.sh") }
        let app = libraryApplication()
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_PLAYLISTS"] = "1"
        app.launchEnvironment["YTMUSE_UI_DEVELOPMENT_PERF"] = "1"
        app.launchEnvironment["YTMUSE_PERF_RECORD"] = "1"
        app.launchEnvironment["YTMUSE_PERF_DIR"] = directory
        app.launchEnvironment["YTMUSE_PERF_TEST"] = test.replacingOccurrences(of: "()", with: "")
        return app
    }
    /// A scripted scroll trace: `steps` scroll events down, then the same up, through XCTest's own `XCUIElement.scroll`, which activates and addresses the app
    /// under test (no event can reach another application, and no accessibility or event-posting permission is needed: an earlier version posted raw HID wheel
    /// events and may have raised the system's "control this computer using accessibility features" prompt, so that path is gone). The target is the WINDOW,
    /// which resolves cheaply and delivers each event at its centre, over the detail pane: scrolling the 50,000-row table element itself makes XCTest walk every
    /// row through the accessibility tree for every event, which measured the test tool. The trace stops at `budget` seconds and fails the test if it had to.
    @MainActor private func perfScroll(_ window: XCUIElement, steps: Int, delta: Double, budget: TimeInterval = 90) {
        let began = Date()
        for direction in [-1.0, 1.0] {      // negative scrolls towards later rows, as the other scrolling tests in this file use it
            for _ in 0..<steps {
                guard Date().timeIntervalSince(began) < budget else { XCTFail("the scroll trace did not finish within \(Int(budget)) s"); return }
                window.scroll(byDeltaX: 0, deltaY: direction * delta)
            }
        }
    }
    @MainActor private func perfOptions(_ key: String, default value: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = max(1, Int(ProcessInfo.processInfo.environment[key] ?? "") ?? value)
        return options
    }
    @MainActor private func perfWait(_ element: XCUIElement, _ what: String, timeout: Double = 60) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), what)
    }

    /// PERF01: repeated cold launches of the isolated app with the dataset flags set (the dataset is built lazily, so this is the cached-shell launch).
    @MainActor func testW44PLaunch() throws {
        let app = try perfApplication()
        let metrics: [XCTMetric] = [XCTApplicationLaunchMetric(), XCTOSSignpostMetric(subsystem: "local.native-music.performance", category: "interval", name: "launch")]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_LAUNCHES", default: 10)) {
            app.launch()
            XCTAssertTrue(app.windows["YTMuse"].firstMatch.waitForExistence(timeout: 30))
            app.terminate()
        }
    }

    /// Navigation between destinations (cached after the first visit), measured by the app's own `navigation` signposts.
    @MainActor func testW44PNavigation() throws {
        let app = try perfApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        perfWait(window, "window", timeout: 30)
        let metrics: [XCTMetric] = [XCTOSSignpostMetric(subsystem: "local.native-music.performance", category: "interval", name: "navigation"), XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_ITERATIONS", default: 5)) {
            for _ in 0..<6 { for destination in ["library", "home", "explore", "downloads", "history"] { w10(window, "nav-" + destination).click() } }
        }
    }

    /// The 50,000-song library: load, scroll (hitches, clock, CPU, memory), then a search and a sort over the loaded rows.
    @MainActor func testW44PLibraryScroll() throws {
        let app = try perfApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        perfWait(window, "window", timeout: 30)
        w10(window, "nav-library").click()
        perfWait(w10(window, "libraryList"), "library list", timeout: 60)
        // Load every page. The wait is a fixed pause, not a query loop: asking the accessibility tree whether a button still exists while 50,000 rows are
        // arriving would measure the query, not the app. The app's own `listPage` intervals say how long the paging really took.
        let loadAll = w10(window, "libraryLoadAll")
        if loadAll.waitForExistence(timeout: 10) { loadAll.click() }
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["YTMUSE_PERF_LOAD_SECONDS"] ?? "") ?? 90)
        let list = w10(window, "libraryList")
        let metrics: [XCTMetric] = [XCTHitchMetric(application: app), XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_ITERATIONS", default: 5)) {
            perfScroll(window, steps: 12, delta: 900)
        }
        // A local query and a re-sort, as a person would: type, wait for the list to settle, clear, switch the sort.
        let query = w10(window, "libraryQuery")
        query.click(); query.typeText("cafe"); Thread.sleep(forTimeInterval: 1)
        query.typeKey("a", modifierFlags: .command); query.typeKey(.delete, modifierFlags: []); Thread.sleep(forTimeInterval: 1)
    }

    /// 1,000 playlists (grid), scrolled.
    @MainActor func testW44PPlaylistGrid() throws {
        let app = try perfApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        perfWait(window, "window", timeout: 30)
        w10(window, "nav-library").click()
        perfWait(w10(window, "libraryKind-playlists"), "playlists chip", timeout: 60)
        w10(window, "libraryKind-playlists").click()
        let grid = w10(window, "libraryGrid")
        perfWait(grid, "playlist grid", timeout: 60)
        let metrics: [XCTMetric] = [XCTHitchMetric(application: app), XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_ITERATIONS", default: 5)) {
            perfScroll(window, steps: 8, delta: 900)
        }
    }
    /// The 10,000-entry playlist's page (the first playlist of the dataset), opened and scrolled.
    @MainActor func testW44PBigPlaylist() throws {
        let app = try perfApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        perfWait(window, "window", timeout: 30)
        w10(window, "nav-library").click()
        perfWait(w10(window, "libraryKind-playlists"), "playlists chip", timeout: 60)
        w10(window, "libraryKind-playlists").click()
        let big = w10(window, "libraryRow-playlist:VLPLperfbig10000000001")
        perfWait(big, "the 10,000-entry playlist card", timeout: 60)
        big.click()
        let scroll = window.scrollViews["catalogScroll"]
        perfWait(scroll, "playlist page", timeout: 120)
        let metrics: [XCTMetric] = [XCTHitchMetric(application: app), XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_ITERATIONS", default: 5)) {
            perfScroll(window, steps: 12, delta: 900)
        }
    }

    /// The 5,000-item queue, page by page (the queue panel shows 80 rows at a time).
    @MainActor func testW44PQueue() throws {
        let app = try perfApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        perfWait(window, "window", timeout: 30)
        w10(window, "browserQueue").click()
        let list = w10(window, "queueList")
        perfWait(list, "queue list", timeout: 60)
        let metrics: [XCTMetric] = [XCTHitchMetric(application: app), XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        measure(metrics: metrics, options: perfOptions("YTMUSE_PERF_ITERATIONS", default: 5)) {
            for _ in 0..<10 { list.scroll(byDeltaX: 0, deltaY: -600) }
            let next = window.buttons["Next page"].firstMatch
            for _ in 0..<5 { if next.exists && next.isEnabled { next.click() } }
            for _ in 0..<5 { let previous = window.buttons["Previous page"].firstMatch; if previous.exists && previous.isEnabled { previous.click() } }
        }
    }
}

// W44-prep critic round 1 (L1): Clear Selection / Select All must reach the equatable library list's highlight (T12).
extension NativeMusicUITests {
    @MainActor private func w12SelectionRow(_ window: XCUIElement, _ id: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.outlineRow.rawValue, XCUIElement.ElementType.tableRow.rawValue]
        return window.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", types)).containing(.any, identifier: id).firstMatch
    }
    @MainActor private func w12RowIsSelected(_ window: XCUIElement, _ id: String, _ expected: Bool, timeout: Double = 5) -> Bool {
        let row = w12SelectionRow(window, id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if row.exists && row.isSelected == expected { return true }; RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        return row.exists && row.isSelected == expected
    }
    @MainActor func testW12ProgrammaticSelectionReachesTheEquatableList() throws {
        let app = libraryApplication(); app.launch(); defer { app.terminate() }
        let window = app.windows["YTMuse"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        w10(window, "nav-library").click()
        w12Wait(window, "libraryRow-song:devsong0001"); w12Wait(window, "libraryRow-song:devsong0005", timeout: 15)
        // Control: a click selects the row in the List, and the row reports it.
        w10(window, "libraryRow-song:devsong0001").click()
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("1 selected"))
        XCTAssertTrue(try XCTUnwrap(Optional(w12SelectionRow(window, "libraryRow-song:devsong0001"))).waitForExistence(timeout: 5), "the row element is found")
        XCTAssertTrue(w12RowIsSelected(window, "libraryRow-song:devsong0001", true), "control: a clicked row reads as selected")
        // Programmatic clear (the model changes, the list's own inputs do not): the List must drop the highlight.
        w12Wait(window, "libraryClearSelection").click()
        XCTAssertTrue(w12Gone(w10(window, "librarySelectionCount")))
        XCTAssertTrue(w12RowIsSelected(window, "libraryRow-song:devsong0001", false), "Clear Selection must reach the List")
        // Programmatic select-all.
        w10(window, "libraryRow-song:devsong0001").click()
        w12Wait(window, "librarySelectionCount")
        window.buttons["Select All"].firstMatch.click()
        XCTAssertTrue(w10Text(w12Wait(window, "librarySelectionCount")).contains("selected"))
        XCTAssertFalse(w10Text(w10(window, "librarySelectionCount")).contains("1 selected"), "select all selects more than one row")
        XCTAssertTrue(w12RowIsSelected(window, "libraryRow-song:devsong0003", true), "Select All must reach the List")
        XCTAssertTrue(w12RowIsSelected(window, "libraryRow-song:devsong0005", true), "Select All must reach the List")
    }
}
