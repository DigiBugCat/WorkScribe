import AppKit
import Darwin
import Foundation
import WorkScribeCore

/// Controlled screen timelines, authored boundaries, and real on-device EG2/OCR. No user screen is read.
enum ScreenSceneBenchmark {
    struct Frame { var time: Double; var image: CGImage; var app: String }
    struct Fixture { var name: String; var frames: [Frame]; var boundaries: [Double]; var query: String; var representative: Int }
    @MainActor static func run(directory: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = makeFixtures()
        if CommandLine.arguments.contains("--ocr-only") {
            var rows: [[String: Any]] = []
            for fixture in fixtures {
                var sampler = KeyframeSampler(), calls = 0, readable = 0, wall = 0.0, cpu = 0.0
                for frame in fixture.frames where sampler.consider(FrameSignature(image: frame.image)!, at: frame.time) {
                    calls += 1; let c = cpuSeconds(), start = Date(); let result = await ScreenOCR.read(frame.image)
                    if !result.text.isEmpty { readable += 1 }
                    cpu += cpuSeconds()-c; wall += Date().timeIntervalSince(start)
                }
                rows.append(["fixture": fixture.name, "sampled_frames": fixture.frames.count, "marked_boundaries": fixture.boundaries,
                             "old_ocr_calls_per_minute": calls, "readable_ocr_calls": readable, "old_ocr_cpu_seconds_per_minute": cpu, "old_ocr_wall_seconds_per_minute": wall])
                let bitmap = NSBitmapImageRep(cgImage: fixture.frames[fixture.representative].image)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(fixture.name+".png"))
            }
            let result: [String: Any] = ["scope": "Five authored 60-second timelines; OCR baseline only. No EG2 quality or performance claim.", "fixtures": rows]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
            try data.write(to: output.appendingPathComponent("ocr-baseline.json")); FileHandle.standardOutput.write(data); return
        }
        guard let embedder = CoreMLEmbedder(directory: directory), embedder.supportsImages else { throw CaptureError.message("Vision model missing") }
        var vectors: [[[Float]]] = [], gated: [[Bool]] = [], rows: [[String: Any]] = []
        let cold = Date(); _ = try await embedder.image(fixtures[0].frames[0].image)
        let coldSeconds = Date().timeIntervalSince(cold)
        for fixture in fixtures {
            var sampler = KeyframeSampler(), embeds: [[Float]] = [], keep: [Bool] = []
            var embeddingWall = 0.0, embeddingCPU = 0.0, ocrWall = 0.0, ocrCPU = 0.0, changed = 0
            for frame in fixture.frames {
                let signature = FrameSignature(image: frame.image)!
                let kept = sampler.consider(signature, at: frame.time); keep.append(kept)
                // Record every sampled embedding for threshold replay, including static confirmation frames.
                var cpu = cpuSeconds(), clock = Date()
                embeds.append(try await embedder.image(frame.image))
                embeddingCPU += cpuSeconds() - cpu; embeddingWall += Date().timeIntervalSince(clock)
                if kept {
                    changed += 1; cpu = cpuSeconds(); clock = Date()
                    _ = await ScreenOCR.read(frame.image)
                    ocrCPU += cpuSeconds() - cpu; ocrWall += Date().timeIntervalSince(clock)
                }
            }
            vectors.append(embeds); gated.append(keep)
            rows.append(["fixture": fixture.name, "frames": fixture.frames.count, "old_ocr_calls": changed,
                         "embedding_wall_seconds_all_samples": embeddingWall, "embedding_cpu_seconds_all_samples": embeddingCPU,
                         "old_ocr_wall_seconds_per_minute": ocrWall, "old_ocr_cpu_seconds_per_minute": ocrCPU,
                         "marked_boundaries": fixture.boundaries])
        }
        func replay(_ index: Int, threshold: Float) -> ([ScreenMoment], Int) {
            var config = ScreenSceneDetector.Configuration(); config.boundaryCosine = threshold; config.returnCosine = min(0.995, threshold + 0.025)
            var detector = ScreenSceneDetector(configuration: config), count = 0
            var last: FrameSignature?
            for (n, frame) in fixtures[index].frames.enumerated() {
                guard gated[index][n] || detector.needsConfirmation else { detector.extend(to: frame.time); continue }
                count += 1
                let signature = FrameSignature(image: frame.image)!
                let stable = last.map { 1 - FrameChangeDetector.difference($0, signature).fraction } ?? 0
                last = signature
                detector.add(.init(time: frame.time, vector: vectors[index][n], frameID: String(n), stability: stable,
                                   app: frame.app, bundleID: frame.app), modelID: embedder.modelID)
            }
            return (detector.finish(at: 60), count)
        }
        func score(_ expected: [Double], _ actual: [Double]) -> (Int, Int, Int) {
            var remaining = expected; var tp = 0
            for value in actual {
                if let i = remaining.indices.min(by: { abs(remaining[$0]-value) < abs(remaining[$1]-value) }), abs(remaining[i]-value) <= 2.5 {
                    tp += 1; remaining.remove(at: i)
                }
            }
            return (tp, actual.count - tp, remaining.count)
        }
        var sweep: [[String: Any]] = []; var best: (Float, Double) = (0.88, -.infinity)
        for threshold in stride(from: 0.75, through: 0.985, by: 0.005) {
            var tp = 0, fp = 0, fn = 0
            for i in 0..<3 { let v = score(fixtures[i].boundaries, replay(i, threshold: Float(threshold)).0.dropFirst().map(\.start)); tp += v.0; fp += v.1; fn += v.2 }
            let f1 = 2 * Double(tp) / Double(max(1, 2*tp+fp+fn))
            sweep.append(["threshold": threshold, "tp": tp, "fp": fp, "fn": fn, "f1": f1])
            if f1 > best.1 { best = (Float(threshold), f1) }
        }
        var representatives: [[Float]] = []
        for (i, fixture) in fixtures.enumerated() {
            let (scenes, calls) = replay(i, threshold: best.0)
            let counts = score(fixture.boundaries, scenes.dropFirst().map(\.start))
            var wall = 0.0, cpu = 0.0
            for scene in scenes {
                let n = min(fixture.frames.count-1, Int((scene.representativeTime ?? scene.start) / 2.5))
                let start = Date(), c = cpuSeconds(); _ = await ScreenOCR.read(fixture.frames[n].image)
                wall += Date().timeIntervalSince(start); cpu += cpuSeconds()-c
            }
            rows[i]["detected_boundaries"] = scenes.dropFirst().map(\.start)
            rows[i]["tp"] = counts.0; rows[i]["fp"] = counts.1; rows[i]["fn"] = counts.2
            rows[i]["new_embedding_calls"] = calls; rows[i]["new_lazy_ocr_calls"] = scenes.count
            rows[i]["new_ocr_wall_seconds_per_minute"] = wall; rows[i]["new_ocr_cpu_seconds_per_minute"] = cpu
            // Replay calls share uniform mean cost; this estimate is explicitly distinguished from timed OCR.
            rows[i]["estimated_embedding_wall_seconds_per_minute"] = (rows[i]["embedding_wall_seconds_all_samples"] as! Double) * Double(calls) / Double(fixture.frames.count)
            rows[i]["estimated_embedding_cpu_seconds_per_minute"] = (rows[i]["embedding_cpu_seconds_all_samples"] as! Double) * Double(calls) / Double(fixture.frames.count)
            representatives.append(vectors[i][fixture.representative])
            let url = output.appendingPathComponent(fixture.name + ".png")
            let bitmap = NSBitmapImageRep(cgImage: fixture.frames[fixture.representative].image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
        // Exercise the production compact-vector + full-vector reranking path, with no OCR words in the chunks.
        let search = try SearchIndex(url: output.appendingPathComponent("search.sqlite")); try search.adopt(modelID: embedder.modelID)
        for i in fixtures.indices {
            try search.replace(kind: .meeting, ref: "fixture-\(i)", title: fixtures[i].name, startedAt: Date(), fingerprint: "1",
                modelID: embedder.modelID, voiceRevision: 0,
                chunks: [Chunk(kind: .screen, modality: .image, start: 0, end: 60, vector: representatives[i])])
        }
        let queries = try await embedder.texts(fixtures.map(\.query), role: .query)
        var correct = 0, retrieval: [[String: Any]] = []
        for i in fixtures.indices {
            let hits = try search.search(SearchRequest(fixtures[i].query, limit: 5, perSource: 1), queryVector: queries[i], queryModelID: embedder.modelID)
            let found = hits.hits.first?.ref ?? "none"
            if found == "fixture-\(i)" { correct += 1 }
            retrieval.append(["query": fixtures[i].query, "expected": "fixture-\(i)", "top1": found, "ranked": hits.hits.map(\.ref)])
        }
        let result: [String: Any] = ["scope": "Five authored 60-second synthetic screen timelines; boundaries at authored transitions. First three calibrate, last two hold out. Not real-call performance.",
            "model_id": embedder.modelID, "cold_seconds": coldSeconds, "threshold": best.0, "return_threshold": min(0.995, best.0+0.025),
            "boundary_tolerance_seconds": 2.5, "sweep": sweep, "fixtures": rows, "visual_only_search_top1": correct,
            "queries": retrieval, "gpu_counter": "Unavailable: Core ML accelerator execution is included in wall latency, not process CPU time."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]))
        await embedder.release()
    }
    private static func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1e6 }
    @MainActor private static func makeFixtures() -> [Fixture] {
        let names = ["slideshow", "scrolling-document", "call-grid", "app-switches", "game-stream"]
        let queries = ["presentation slides about a quarterly marketing plan", "long written document with paragraphs", "video conference with six people", "dashboard with charts and metrics", "video game landscape with health and inventory"]
        return names.enumerated().map { k, name in
            let frames = (0..<24).map { n -> Frame in
                let scene = k == 0 || k == 3 ? n / 8 : 0
                let app = k == 3 ? ["dashboard", "terminal", "mail"][scene] : name
                return Frame(time: Double(n)*2.5, image: render(kind: k, frame: n, scene: scene), app: app)
            }
            return Fixture(name: name, frames: frames, boundaries: k == 0 || k == 3 ? [20,40] : [], query: queries[k], representative: 0)
        }
    }
    @MainActor private static func render(kind: Int, frame: Int, scene: Int) -> CGImage {
        let image = NSImage(size: NSSize(width:1200,height:750), flipped:false) { rect in
            func box(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:NSColor) { color.setFill(); NSBezierPath(rect:NSRect(x:x,y:y,width:w,height:h)).fill() }
            func text(_ value:String,_ x:Double,_ y:Double,_ size:Double=22,_ color:NSColor = .labelColor) { value.draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color]) }
            box(0,0,1200,750,.white)
            box(0,708,1200,42,.init(white:0.94,alpha:1)); text(["Keynote","Editor","Video meeting","Workspace","Stream"][kind],18,720,16,.black)
            switch kind {
            case 0:
                box(0,0,28,708,[.systemBlue,.systemOrange,.systemGreen][scene]); text(["Quarterly marketing plan","Engineering architecture","Product release schedule"][scene],90,590,44,.black)
                for i in 0..<4 { text(["Campaign budget and channels","Database replication and failover","Testing, launch and customer support"][scene],100,450-Double(i)*85,27,.darkGray) }
                box(800,100,240,Double(100+scene*90),[.systemBlue,.systemOrange,.systemGreen][scene])
            case 1:
                box(0,0,210,708,.init(white:0.92,alpha:1)); text("Documents",20,655,24,.black)
                for i in 0..<14 { text("Section \(i+frame): The team reviews implementation details and open questions.",255,660-Double(i)*47,20,.black) }
            case 2:
                box(0,0,1200,708,.init(white:0.12,alpha:1))
                for i in 0..<6 {
                    let x = Double(i%3)*392+16, y = Double(i/3)*330+40
                    box(x,y,375,310,.init(hue:Double(i)/7,saturation:0.3,brightness:0.6+Double((frame+i)%3)*0.035,alpha:1))
                    NSColor.systemOrange.setFill(); NSBezierPath(ovalIn:NSRect(x:x+130+Double(frame%3)*3,y:y+100,width:100,height:130)).fill()
                    text("Participant \(i+1)",x+14,y+16,18,.white)
                }
            case 3:
                if scene == 0 {
                    text("Analytics overview",35,650,36,.black)
                    for i in 0..<6 { let x=Double(i%3)*385+25,y=Double(i/3)*260+75; box(x,y,355,220,.init(white:0.96,alpha:1));text(["Revenue","Active users","Conversion"][i%3],x+18,y+170,24,.black);for b in 0..<6 { box(x+18+Double(b)*49,y+25,30,Double(35+(b*17+i*13)%100),.systemBlue) } }
                } else if scene == 1 { box(0,0,1200,708,.black);for i in 0..<18 {text("developer@workstation % build module_\(i) --verbose [success]",25,665-Double(i)*35,21,.systemGreen)} }
                else {box(0,0,280,708,.init(white:0.9,alpha:1));text("Inbox",30,650,32,.black);for i in 0..<7{text("Re: Project update and meeting notes",320,640-Double(i)*80,24,.black)} }
            default:
                box(0,230,1200,478,.systemCyan);box(0,0,1200,230,.systemGreen)
                for i in 0..<10 {let x=Double((i*157+frame*35)%1300)-80;NSColor.systemBrown.setFill();let p=NSBezierPath();p.move(to:NSPoint(x:x,y:180));p.line(to:NSPoint(x:x+110,y:460));p.line(to:NSPoint(x:x+240,y:180));p.close();p.fill()}
                box(20,645,240,30,.systemRed);text("HP 100 / 100",30,650,18,.white);box(480,20,250,70,.darkGray);text("Inventory   1   2   3",500,45,20,.white)
            }
            return true
        }
        return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
    }
}
