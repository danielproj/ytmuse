import Features
import Foundation
import Testing

/// Source validation (MEDIA06): local checks only. What the service accepts is the service's answer, so nothing here claims a format list or a quota.
@Suite struct UploadSourceTests {
    private func inspect(_ url: URL, limit: Int64? = nil, root: URL? = nil, metadata: @escaping UploadSourceInspector.MetadataReader = { _ in nil },
                         tracks: @escaping UploadSourceInspector.TrackReader = { _ in nil }) async -> Result<UploadSource, UploadRefusalReason> {
        await UploadSourceInspector(maximumFileBytes: limit, testRoot: root, metadata: metadata, tracks: tracks).inspect(url)
    }
    /// An `ftyp` box with a major brand and compatible brands.
    private func mp4(major: String, compatible: [String]) -> Data {
        let brands = compatible.flatMap { Array($0.utf8) }
        let size = 16 + brands.count
        return Data([0, 0, 0, UInt8(size)] + Array("ftyp".utf8) + Array(major.utf8) + [0, 0, 0, 0] + brands + [UInt8](repeating: 0, count: 64))
    }
    private func bytes(_ prefix: [UInt8], count: Int = 64) -> Data { Data(prefix + [UInt8](repeating: 0, count: max(0, count - prefix.count))) }

    @Test func aSyntheticWAVIsAcceptedAndDescribedFromItsOwnBytes() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Tone.wav")
        let source = try await inspect(url).get()
        #expect(source.format == .wav && source.contentConfirmed)
        #expect(source.byteCount == Int64(try scratch.data(url).count) && source.displayName == "Tone.wav")
        #expect(source.metadata.title == "Tone" && source.metadata.titleFromFilename, "no tags: the title is the file name, and says so")
        #expect(source.path == url.resolvingSymlinksInPath().path)
    }
    @Test func theDefaultMetadataReaderReadsTheRealDurationOfARealFile() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Tone.wav")
        let read = try #require(await UploadMetadataReader.read(url))
        let seconds = try #require(read.durationSeconds)
        #expect(abs(seconds - 0.2) < 0.05, "3200 bytes of 8 kHz 16-bit mono is 0.2 s: \(seconds)")
        #expect(read.titleFromFilename && read.artist == nil, "nothing is invented for tags the file doesn't carry")
    }
    @Test func theFirstBytesNameTheContainerWhateverTheExtension() async throws {
        let scratch = try Scratch()
        let cases: [(String, [UInt8], UploadAudioFormat)] = [
            ("a.bin", Array("ID3".utf8) + [3, 0], .mp3), ("b.bin", [0xFF, 0xFB, 0x90, 0x00], .mp3), ("c.bin", Array("fLaC".utf8), .flac), ("d.bin", Array("OggS".utf8), .ogg),
            ("e.bin", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0, 0xAA, 0, 0x62, 0xCE, 0x6C], .windowsMedia),
            ("f.bin", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8), .aiff),
            ("g.bin", [0, 0, 0, 0x20] + Array("ftypM4A ".utf8), .mpeg4Audio),
        ]
        for (name, head, format) in cases {
            let source = try await inspect(try scratch.file(name, bytes(head))).get()
            #expect(source.format == format && source.contentConfirmed, Comment(rawValue: name))
        }
    }
    @Test func aFileThatIsNotAudioIsRefusedForWhatItIs() async throws {
        let scratch = try Scratch()
        func reason(_ name: String, _ data: Data) async throws -> UploadRefusalReason? {
            if case .failure(let reason) = await inspect(try scratch.file(name, data)) { return reason }
            return nil
        }
        #expect(try await reason("notes.txt", Data("hello".utf8)) == .notAudio)
        #expect(try await reason("empty.wav", Data()) == .empty)
        #expect(try await reason("film.m4v", mp4(major: "M4V ", compatible: ["M4V ", "mp42", "isom"])) == .video, "a video brand")
        #expect(try await reason("clip.mov", mp4(major: "qt  ", compatible: ["qt  "])) == .video)
        #expect(try await reason("bought.m4p", bytes([0, 0, 0, 0x20] + Array("ftypM4P ".utf8))) == .protectedAudio)
        #expect(try await reason("renamed.m4a", bytes([0, 0, 0, 0x20] + Array("ftypM4P ".utf8))) == .protectedAudio)
        let folder = try scratch.folder("Album")
        if case .failure(let r) = await inspect(folder) { #expect(r == .folder) } else { Issue.record("a folder was accepted") }
        if case .failure(let r) = await inspect(URL(string: "https://example.com/a.mp3")!) { #expect(r == .notAFile) } else { Issue.record("a web address was accepted") }
        if case .failure(let r) = await inspect(scratch.root.appendingPathComponent("missing.mp3")) { #expect(r == .unreadable) } else { Issue.record("a missing file was accepted") }
    }
    @Test func anAudioOnlyMPEG4WhateverItsMajorBrandIsNotCalledVideo() async throws {
        let scratch = try Scratch()
        // `mp42` as the major brand with M4A among the compatible ones: audio, said by the brands themselves.
        let withBrand = try await inspect(try scratch.file("Voice Memo.m4a", mp4(major: "mp42", compatible: ["M4A ", "mp42", "isom"]))).get()
        #expect(withBrand.format == .mpeg4Audio && withBrand.contentConfirmed)
        // No brand says audio or video: the file's real tracks decide.
        let generic = mp4(major: "isom", compatible: ["isom", "mp42"])
        let audioOnly = try await inspect(try scratch.file("a.m4a", generic), tracks: { _ in (audio: true, video: false) }).get()
        #expect(audioOnly.format == .mpeg4Audio && audioOnly.contentConfirmed)
        let withPicture = await inspect(try scratch.file("b.m4a", generic), tracks: { _ in (audio: true, video: true) })
        if case .failure(let reason) = withPicture { #expect(reason == .video, "a video track makes it video whatever its name says") } else { Issue.record("a file with a video track was accepted") }
        let silent = await inspect(try scratch.file("c.m4a", generic), tracks: { _ in (audio: false, video: false) })
        if case .failure(let reason) = silent { #expect(reason == .notAudio) } else { Issue.record("a file with no audio track was accepted") }
        // Tracks that cannot be read: the name decides only for an audio extension, and it is not called confirmed.
        let named = try await inspect(try scratch.file("d.m4a", generic)).get()
        #expect(named.format == .mpeg4Audio && !named.contentConfirmed)
        let unnamed = await inspect(try scratch.file("e.mp4", generic))
        if case .failure(let reason) = unnamed { #expect(reason == .notAudio) } else { Issue.record("an unreadable .mp4 was accepted") }
    }
    @Test func theRealTrackReaderSeesTheTracksOfARealFile() async throws {
        let scratch = try Scratch()
        let wav = try scratch.wav("Tone.wav")
        let kinds = try #require(await UploadMetadataReader.trackKinds(wav))
        #expect(kinds.audio && !kinds.video)
        #expect(await UploadMetadataReader.trackKinds(try scratch.file("junk.m4a", Data("not media at all".utf8))) == nil)
    }
    @Test func anAudioExtensionWithUnreadableContentIsPassedOnButNotClaimedAsConfirmed() async throws {
        let scratch = try Scratch()
        let source = try await inspect(try scratch.file("odd.mp3", Data("not really mp3".utf8))).get()
        #expect(source.format == .mp3 && !source.contentConfirmed, "the name said audio, the bytes didn't confirm it; the service has the last word")
    }
    @Test func noLimitIsAssumedOnlyAPublishedOneIsEnforced() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Big.wav", extra: 100_000)
        _ = try await inspect(url, limit: nil).get()
        if case .failure(let reason) = await inspect(url, limit: 50_000) { #expect(reason == .tooLarge(limit: 50_000)) } else { Issue.record("a published limit was ignored") }
        _ = try await inspect(url, limit: 1_000_000).get()
        for reason in [UploadRefusalReason.notAFile, .folder, .unreadable, .empty, .notAudio, .video, .protectedAudio, .changedWhileReading, .outsideTestFiles, .duplicate(of: "x.wav"), .uploadsUnavailable, .needsAccount] {
            let text = reason.message.lowercased()
            #expect(!text.contains("quota") && !text.contains("megabyte") && !text.contains(" mb") && !text.contains("format is not supported"), Comment(rawValue: text))
        }
    }
    @Test func testModeAcceptsOnlyTheAppsOwnSyntheticFolderEvenThroughALink() async throws {
        let scratch = try Scratch(), outside = try Scratch()
        let owned = try scratch.wav("Samples/Owned.wav")
        let foreign = try outside.wav("Foreign.wav")
        let root = scratch.root.appendingPathComponent("Samples")
        _ = try await inspect(owned, root: root).get()
        if case .failure(let reason) = await inspect(foreign, root: root) { #expect(reason == .outsideTestFiles) } else { Issue.record("a file outside test mode's folder was accepted") }
        let link = root.appendingPathComponent("Link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        if case .failure(let reason) = await inspect(link, root: root) { #expect(reason == .outsideTestFiles, "a link is followed before the check") } else { Issue.record("a link out of the folder was accepted") }
        // A sibling folder that merely starts with the same characters is not inside it.
        let sibling = try scratch.wav("SamplesExtra/Other.wav")
        if case .failure(let reason) = await inspect(sibling, root: root) { #expect(reason == .outsideTestFiles) } else { Issue.record("a sibling folder with the same prefix was accepted") }
    }
    @Test func aFileThatChangesWhileItIsReadIsNotAccepted() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Growing.wav")
        let result = await inspect(url, metadata: { file in
            if let handle = try? FileHandle(forWritingTo: file) { try? handle.seekToEnd(); try? handle.write(contentsOf: Data([1, 2, 3])); try? handle.close() }
            return nil
        })
        if case .failure(let reason) = result { #expect(reason == .changedWhileReading) } else { Issue.record("a file that changed during the read was accepted") }
    }
}

/// Read access is held per job, released at once, and refuses a file that is no longer the file that was chosen. Nothing here writes to a file.
@Suite struct UploadFileAccessTests {
    @Test func accessIsReadOnlyAndReleaseIsIdempotent() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Tone.wav")
        let before = try scratch.data(url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let source = try await UploadSourceInspector(metadata: { _ in nil }).inspect(url).get()
        let lease = try ScopedUploadFileAccess().open(source)
        #expect(!lease.isReleased, "held until released")
        #expect(lease.url.path == source.path, Comment(rawValue: "\(lease.url.path) vs \(source.path)"))
        lease.release(); lease.release()
        #expect(lease.isReleased)
        #expect(try scratch.data(url) == before && (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == modified, "opening and releasing leaves the file as it was")
    }
    @Test func aFileThatIsNoLongerTheOneChosenIsRefused() async throws {
        let scratch = try Scratch()
        let url = try scratch.wav("Tone.wav")
        let source = try await UploadSourceInspector(metadata: { _ in nil }).inspect(url).get()
        try Data("different and longer content".utf8).write(to: url)
        #expect(throws: UploadFileAccessError.changed) { _ = try ScopedUploadFileAccess().open(source) }
        try FileManager.default.removeItem(at: url)
        #expect(throws: UploadFileAccessError.unreadable) { _ = try ScopedUploadFileAccess().open(source) }
    }
}
