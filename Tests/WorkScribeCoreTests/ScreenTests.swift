import CoreGraphics
import XCTest
@testable import WorkScribeCore

final class ScreenTests: XCTestCase {
    var folder: URL!
    var store: MeetingStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ws-screen-" + UUID().uuidString)
        store = MeetingStore(root: folder.appendingPathComponent("Meetings"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: Synthetic frames

    /// A 1600×900 "slide": white, a title bar and `bullets` text-like lines; optional noise and a cursor-sized dot.
    func slide(bullets: Int, title: CGFloat = 900, shift: CGFloat = 0, noise: Bool = false, dot: Bool = false,
               dark: Bool = false) -> CGImage {
        let width = 1600, height = 900
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: dark ? 0.1 : 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: dark ? 0.9 : 0, alpha: 1)
        context.fill(CGRect(x: 100 + shift, y: 760, width: title, height: 60))
        for line in 0..<bullets {
            // Words: dashes of ink separated by gaps, like a line of text.
            for word in 0..<12 {
                context.fill(CGRect(x: 140 + CGFloat(word) * 95 + shift, y: 640 - CGFloat(line) * 90, width: 70, height: 30))
            }
        }
        if dot { context.fill(CGRect(x: 1400, y: 100, width: 6, height: 6)) }
        if noise, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var seed: UInt32 = 7
            for index in stride(from: 0, to: context.bytesPerRow * height, by: 1) {
                seed = seed &* 1_103_515_245 &+ 12_345
                let jitter = Int(seed >> 16 % 7) - 3
                bytes[index] = UInt8(clamping: Int(bytes[index]) + jitter)
            }
        }
        return context.makeImage()!
    }

    func signature(_ image: CGImage) throws -> FrameSignature { try XCTUnwrap(FrameSignature(image: image)) }

    func testFrameChangeDetectionOnSyntheticSlides() throws {
        let detector = FrameChangeDetector()
        let base = try signature(slide(bullets: 3))
        XCTAssertFalse(detector.isMeaningful(from: base, to: try signature(slide(bullets: 3))), "identical frame")
        XCTAssertFalse(detector.isMeaningful(from: base, to: try signature(slide(bullets: 3, noise: true))), "encoder noise")
        XCTAssertFalse(detector.isMeaningful(from: base, to: try signature(slide(bullets: 3, dot: true))), "cursor-sized change")
        XCTAssertTrue(detector.isMeaningful(from: base, to: try signature(slide(bullets: 4))), "a new bullet appeared")
        XCTAssertTrue(detector.isMeaningful(from: base, to: try signature(slide(bullets: 1, title: 500))), "a different slide")
        XCTAssertTrue(detector.isMeaningful(from: base, to: try signature(slide(bullets: 3, dark: true))), "inverted theme")
        XCTAssertTrue(detector.isMeaningful(from: nil, to: base), "the first frame is always kept")

        let difference = FrameChangeDetector.difference(base, try signature(slide(bullets: 3, dark: true)))
        XCTAssertGreaterThan(difference.fraction, 0.5)
        XCTAssertEqual(FrameChangeDetector.difference(base, base), .init(fraction: 0, hashDistance: 0))
    }

    func testSignatureFromLuminanceAndDHash() {
        let flat = FrameSignature(luminance: [UInt8](repeating: 128, count: FrameSignature.width * FrameSignature.height))
        XCTAssertEqual(flat.dHash, 0)
        let ramp = FrameSignature(luminance: (0..<(FrameSignature.width * FrameSignature.height)).map {
            UInt8(255 - ($0 % FrameSignature.width) * 255 / FrameSignature.width)   // brighter on the left
        })
        XCTAssertEqual(ramp.dHash.nonzeroBitCount, 64)
    }

    func testKeyframeSamplerPacesAndKeepsOnlyChanges() throws {
        var sampler = KeyframeSampler(interval: 2.5)
        let a = try signature(slide(bullets: 2)), b = try signature(slide(bullets: 5))
        XCTAssertTrue(sampler.isDue(0))
        XCTAssertTrue(sampler.consider(a, at: 0))
        XCTAssertFalse(sampler.isDue(1.0))
        XCTAssertTrue(sampler.isDue(2.5))
        XCTAssertFalse(sampler.consider(a, at: 2.5), "unchanged")
        XCTAssertTrue(sampler.consider(b, at: 5))
        XCTAssertFalse(sampler.consider(b, at: 7.5))
        sampler.reset()
        XCTAssertTrue(sampler.consider(b, at: 10), "after a pause the next frame is read again")
    }

    // MARK: Moments

    let agenda = "Q3 Marketing Budget Review\nCut advertising spend by a third\nHire a product designer"

    func testBuilderMergesSameScreenAndSplitsOnChange() {
        var builder = ScreenMomentBuilder()
        guard case .started(let first, nil) = builder.add(.init(time: 10, text: agenda, app: "Keynote", bundleID: "com.apple.iWork.Keynote"), id: "a", thumbnail: "screen/a.jpg") else {
            return XCTFail("first frame starts a moment")
        }
        XCTAssertEqual(first, "a")
        // The same slide with one more bullet built in: same moment, fuller text.
        XCTAssertEqual(builder.add(.init(time: 12.5, text: agenda + "\nInvoice INV-4821 due on signature", app: "Keynote",
                                         bundleID: "com.apple.iWork.Keynote"), id: "b"), .extended(id: "a"))
        XCTAssertEqual(builder.open?.frames, 2)
        XCTAssertTrue(builder.open?.text.contains("INV-4821") ?? false)
        builder.extend(to: 20)
        XCTAssertEqual(builder.open?.end, 20)

        // A different slide starts a new moment and closes the first at that time.
        let outcome = builder.add(.init(time: 25, text: "Hiring plan\nTwo engineers and one designer\nStart dates in November",
                                        app: "Keynote", bundleID: "com.apple.iWork.Keynote"), id: "c")
        guard case .started("c", let closed?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(closed.id, "a"); XCTAssertEqual(closed.start, 10); XCTAssertEqual(closed.end, 25)
        XCTAssertEqual(closed.thumbnail, "screen/a.jpg")

        // Same text in another app is a new moment.
        if case .started = builder.add(.init(time: 30, text: "Hiring plan\nTwo engineers and one designer\nStart dates in November",
                                             app: "Preview", bundleID: "com.apple.Preview"), id: "d") {} else { XCTFail("app change") }

        // A frame without readable text (faces on a call) ends the open moment and starts nothing.
        guard case .ignored(let ended?) = builder.add(.init(time: 40, text: "  \n ok"), id: "e") else { return XCTFail("no text") }
        XCTAssertEqual(ended.id, "d"); XCTAssertEqual(ended.end, 40)
        XCTAssertNil(builder.open)
        XCTAssertEqual(builder.closed.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(builder.add(.init(time: 41, text: ""), id: "f"), .ignored(closed: nil))

        // A long-lived screen is split so links land near the spot.
        builder.add(.init(time: 50, text: agenda), id: "g")
        builder.add(.init(time: 200, text: agenda), id: "h")
        if case .started("i", _) = builder.add(.init(time: 360, text: agenda), id: "i") {} else { XCTFail("maximum duration") }
        let all = builder.finish(at: 400)
        XCTAssertEqual(all.map(\.id), ["a", "c", "d", "g", "i"])
        XCTAssertEqual(all.last?.end, 400)
    }

    func testSimilarity() {
        XCTAssertEqual(ScreenMomentBuilder.similarity(agenda, agenda), 1)
        XCTAssertEqual(ScreenMomentBuilder.similarity(agenda, agenda + "\nMore words added here"), 1, "containment")
        XCTAssertLessThan(ScreenMomentBuilder.similarity(agenda, "Hiring plan for engineers in November"), 0.3)
        XCTAssertLessThan(ScreenMomentBuilder.similarity("Agenda", agenda + " " + String(repeating: "lorem ipsum dolor sit amet ", count: 4)), 0.6,
                          "one shared word against a full page is not the same moment")
    }

    func testChunksCarryTimesThumbnailAnchorAndSplitLongText() {
        var meeting = Meeting(title: "Planning")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 30, text: "Welcome everyone."),
                            Segment(source: "system", speaker: "system:speaker-1", start: 30, end: 60, text: "Let us look at the budget.")]
        let long = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let moments = [ScreenMoment(id: "m1", start: 42, end: 70, text: agenda, app: "Keynote", window: "Q3.key", thumbnail: "screen/m1.jpg"),
                       ScreenMoment(id: "m2", start: 5, end: 9, text: "ok"),
                       ScreenMoment(id: "m3", start: 80, end: 90, text: long)]
        let chunks = ScreenSource.chunks(moments, meeting: meeting, folder: URL(fileURLWithPath: "/meetings/X"))
        XCTAssertEqual(chunks.first?.kind, .screen)
        XCTAssertEqual(chunks.first?.start, 42); XCTAssertEqual(chunks.first?.end, 70)
        XCTAssertEqual(chunks.first?.thumbnail, "/meetings/X/screen/m1.jpg")
        XCTAssertEqual(chunks.first?.window, "Keynote — Q3.key")
        XCTAssertEqual(chunks.first?.anchorSegment, meeting.segments[1].id)
        XCTAssertTrue(chunks.first?.embeddedText.hasPrefix("Keynote — Q3.key\n\nQ3 Marketing") ?? false)
        XCTAssertFalse(chunks.contains { $0.start == 5 }, "too few words to be a moment")
        XCTAssertGreaterThan(chunks.filter { $0.start ?? 0 >= 80 }.count, 1, "long text is split")
        XCTAssertTrue(chunks.allSatisfy { ($0.text ?? "").split(whereSeparator: \.isWhitespace).count <= 74 })
    }

    // MARK: Persistence

    func testMeetingDecodingIsBackwardCompatible() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old","startedAt":"2025-01-02T03:04:05Z","status":"complete",
         "segments":[{"id":"s1","source":"microphone","speaker":"microphone:speaker-1","start":1,"end":2,"text":"Hi"}],
         "partials":{}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(old.screen)
        XCTAssertEqual(store.loadScreenMoments(old.id), [])
        XCTAssertTrue(MeetingIndexer.isIndexable(old))
        XCTAssertFalse(MeetingSource.fingerprint(old).contains("+s"), "audio-only fingerprints are unchanged")

        var meeting = Meeting(title: "New")
        meeting.status = "complete"
        meeting.screen = ScreenCaptureInfo(file: ScreenFiles.video, offset: 1.25, target: "display", state: "complete", momentCount: 1)
        try store.save(meeting)
        let moment = ScreenMoment(start: 3, end: 9, text: agenda, lines: [ScreenTextLine(text: "Q3", x: 0.1, y: 0.8, width: 0.3, height: 0.05)])
        try store.saveScreenMoments([moment], id: meeting.id)
        let loaded = try store.load(meeting.id)
        XCTAssertEqual(loaded.screen, meeting.screen)
        XCTAssertEqual(store.loadScreenMoments(meeting.id), [moment])
        XCTAssertTrue(MeetingIndexer.isIndexable(loaded), "screen-only meetings are searchable")
    }

    func testDeleteScreenCaptureKeepsAudioAndTranscript() throws {
        var meeting = Meeting(title: "Private")
        meeting.status = "complete"
        meeting.segments = [Segment(source: "microphone", speaker: "microphone:speaker-1", start: 0, end: 2, text: "Hello")]
        meeting.screen = ScreenCaptureInfo(file: ScreenFiles.video, offset: 0.5, state: "complete", momentCount: 1)
        try store.save(meeting)
        let dir = try store.directory(meeting.id)
        try Data("video".utf8).write(to: dir.appendingPathComponent(ScreenFiles.video))
        try Data("wav".utf8).write(to: dir.appendingPathComponent("microphone.wav"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(ScreenFiles.thumbnails), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: dir.appendingPathComponent(ScreenFiles.thumbnail("m")))
        try store.saveScreenMoments([ScreenMoment(id: "m", start: 0, end: 1, text: agenda)], id: meeting.id)

        let updated = try store.deleteScreenCapture(meeting.id, trash: false)
        XCTAssertEqual(updated.screen?.state, "deleted")
        XCTAssertNil(updated.screen?.file)
        XCTAssertNotNil(updated.screen?.deletedAt)
        for name in [ScreenFiles.video, ScreenFiles.thumbnails, ScreenFiles.moments] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("microphone.wav").path))
        XCTAssertEqual(try store.load(meeting.id).segments.count, 1)
    }

    // MARK: Index

    func testScreenMomentsIndexRoundTripAndMCP() async throws {
        let indexURL = folder.appendingPathComponent("Index/index.sqlite")
        let index = try SearchIndex(url: indexURL)
        var meeting = Meeting(title: "Weekly sync")
        meeting.status = "complete"
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 700, end: 760, text: "Let me share my screen.")]
        meeting.screen = ScreenCaptureInfo(file: ScreenFiles.video, offset: 0.4, state: "complete", momentCount: 2)
        try store.save(meeting)
        try store.saveScreenMoments([
            ScreenMoment(id: "slide", start: 760, end: 800, text: "Q3 advertising budget\nCut marketing spend by a third",
                         app: "Keynote", window: "Q3 plan.key", thumbnail: ScreenFiles.thumbnail("slide")),
            ScreenMoment(id: "doc", start: 820, end: 900, text: "Postmortem: database outage took checkout down",
                         app: "Safari", window: "Incident doc"),
        ], id: meeting.id)

        let embedder = FakeEmbedder()
        let report = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        XCTAssertEqual(report.indexed, 1)
        let results = try index.search(SearchRequest("advertising spend slide", kinds: [.screen]),
                                       queryVector: embedder.vector("advertising spend slide"), queryModelID: embedder.modelID)
        let hit = try XCTUnwrap(results.hits.first)
        XCTAssertEqual(hit.kind, .screen)
        XCTAssertEqual(hit.ref, meeting.id)
        XCTAssertEqual(hit.start, 760)
        XCTAssertEqual(hit.window, "Keynote — Q3 plan.key")
        XCTAssertEqual(hit.thumbnail, try store.directory(meeting.id).appendingPathComponent("screen/slide.jpg").path)
        XCTAssertEqual(hit.link, .meeting(id: meeting.id, seconds: 760, segment: meeting.segments[0].id))
        let again = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        XCTAssertEqual(again.unchanged, 1)

        // MCP: semantic_search returns the moment with its thumbnail; get_screen_moments finds what was up at 12:50.
        let server = MCPServer(store: store, embedder: embedder, openIndex: { try SearchIndex(url: indexURL) })
        _ = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let response = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": args]])!
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
            let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let search = try call("semantic_search", ["query": "database outage", "kinds": ["screen"]])
        let first = try XCTUnwrap((search["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["kind"] as? String, "screen")
        XCTAssertEqual(first["meeting_id"] as? String, meeting.id)
        XCTAssertEqual(first["start_seconds"] as? Double, 820)
        XCTAssertEqual(first["window"] as? String, "Safari — Incident doc")
        XCTAssertTrue(first.keys.contains("thumbnail_path"))
        let at = try call("get_screen_moments", ["meeting_id": meeting.id, "at_seconds": 770])
        XCTAssertEqual((at["moment"] as? [String: Any])?["moment_id"] as? String, "slide")
        XCTAssertTrue(((at["moment"] as? [String: Any])?["thumbnail_path"] as? String)?.hasSuffix("screen/slide.jpg") ?? false)
        XCTAssertEqual((at["screen"] as? [String: Any])?["video_offset_seconds"] as? Double, 0.4)
        XCTAssertEqual((try call("get_screen_moments", ["meeting_id": meeting.id])["moments"] as? [[String: Any]])?.count, 2)

        // Deleting the screen recording drops its moments from search on the next pass.
        try store.deleteScreenCapture(meeting.id, trash: false)
        let afterDelete = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        XCTAssertEqual(afterDelete.indexed, 1)
        XCTAssertTrue(try index.search(SearchRequest("advertising", kinds: [.screen])).hits.isEmpty)
        XCTAssertFalse(try index.search(SearchRequest("share my screen")).hits.isEmpty, "the transcript stays searchable")
    }

    func testVersionOneIndexMigratesAndKeepsRows() throws {
        let url = folder.appendingPathComponent("old.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let db = try Database(path: url.path)
            try db.execute(SearchIndex.migrations[0])
            try db.execute("PRAGMA user_version = 1")
            try db.run("INSERT INTO sources(kind, ref, fingerprint) VALUES('file', '/a.txt', 'f')")
            try db.run("INSERT INTO chunks(source, kind, modality, text) VALUES(1, 'document', 'text', 'legacy row')")
            try db.run("INSERT INTO fts(rowid, title, speakers, body) VALUES(1, 'a', '', 'legacy row')")
        }
        let index = try SearchIndex(url: url)
        XCTAssertEqual(index.userVersion, SearchIndex.schemaVersion)
        let hit = try XCTUnwrap(index.search(SearchRequest("legacy")).hits.first)
        XCTAssertNil(hit.thumbnail)
        XCTAssertEqual(hit.text, "legacy row")
    }

    // MARK: Live context

    func testScreenContextAndLiveContext() {
        let context = ScreenContext()
        XCTAssertNil(context.current())
        let now = Date()
        context.publish(ScreenSnapshot(text: "Q3 budget", capturedAt: now.addingTimeInterval(-40), app: "Keynote"))
        XCTAssertNotNil(context.current())
        XCTAssertNil(context.current(maxAge: 30, now: now), "stale text isn't 'now'")
        context.clear()
        XCTAssertNil(context.current())

        var meeting = Meeting(title: "Live")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 10, end: 14, text: "Old remark."),
                            Segment(source: "system", speaker: "system:speaker-1", start: 760, end: 765, text: "As you can see on this slide.")]
        let moments = [ScreenMoment(start: 700, end: 755, text: "Hiring plan for Q4", app: "Keynote"),
                       ScreenMoment(start: 755, end: 770, text: agenda, app: "Keynote", window: "Q3.key")]
        let text = LiveContext.compose(meeting: meeting, screen: moments, now: 770, window: 120,
                                       current: ScreenSnapshot(text: agenda, capturedAt: now, app: "Keynote", window: "Q3.key"))
        XCTAssertTrue(text.contains("[12:40] Speaker 1: As you can see on this slide."))
        XCTAssertFalse(text.contains("Old remark"))
        XCTAssertTrue(text.contains("Now (Keynote — Q3.key):\nQ3 Marketing Budget Review"))
        XCTAssertTrue(text.contains("[11:40–12:35] Keynote:\nHiring plan for Q4"))
        XCTAssertEqual(text.components(separatedBy: "Q3 Marketing Budget Review").count, 2, "current text isn't repeated")
    }

    func testPrivacyDenyList() {
        XCTAssertTrue(ScreenPrivacy.isDenied("com.1password.1password"))
        XCTAssertTrue(ScreenPrivacy.isDenied("com.apple.keychainaccess"))
        XCTAssertTrue(ScreenPrivacy.isDenied("COM.APPLE.MOBILESMS"))
        XCTAssertFalse(ScreenPrivacy.isDenied("com.apple.iWork.Keynote"))
        XCTAssertFalse(ScreenPrivacy.isDenied(nil))
        XCTAssertTrue(ScreenPrivacy.isDenied("com.example.vault", list: ["com.example.vault"]))
    }
}
