import Foundation
import WorkScribeCore

enum ImageVerification {
    static func note() async throws {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--verify-image-note"), args.count > i+2 else { throw CaptureError.message("--verify-image-note MODEL IMAGE") }
        let url = URL(fileURLWithPath:args[i+2]).standardizedFileURL
        let started = Date()
        let ocr = await NoteImageUnderstanding.shared.read(.init(target:url.lastPathComponent,path:url.path),note:url,vault:url.deletingLastPathComponent())
        let ocrAt = Date().timeIntervalSince(started)
        let image = await NoteImageUnderstanding.shared.caption(ocr,note:url,vault:url.deletingLastPathComponent())
        let captionAt = Date().timeIntervalSince(started)
        var note = Note(text:"![[" + url.lastPathComponent + "]]",createdAt:760); note.images=[image]
        var meeting=Meeting(title:"Mobile launch review"); meeting.notes=[note]
        meeting.segments=[Segment(source:"system",speaker:"Marcus",start:750,end:770,text:"Marcus walked through the chart. The high spike is the 12 mini stall during image decoding. We need to move image decode off the main thread.")]
        guard let result = try await Enrich(textModel: TextModels.generator(.gemma4, path: args[i+1])).enhance(meeting,incremental:true) else { throw CaptureError.message("No note plan") }
        CurrentNoteEngine.apply(result, to: &meeting, final: false)
        let notes=meeting.notes ?? []
        let report: [String:Any] = ["ocr_ready_seconds":ocrAt,"caption_ready_seconds":captionAt,"useful_line_seconds_without_scheduler":Date().timeIntervalSince(started),"ocr":ocr.text ?? "","caption":image.caption ?? "","ai_line":notes.first?.line.text ?? ""]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--verify-images"), args.count > i+3,
              let embedder = CoreMLEmbedder(directory: URL(fileURLWithPath: args[i+1])) else { throw CaptureError.message("--verify-images MODEL_DIRECTORY IMAGE1 IMAGE2") }
        var report: [[String: Any]] = [], vectors: [[Float]] = []
        for path in args.dropFirst(i+2) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let start = Date()
            let read = await NoteImageUnderstanding.shared.read(NoteImage(target: url.lastPathComponent, path: url.path), note: url, vault: url.deletingLastPathComponent())
            let ocr = Date().timeIntervalSince(start)
            let begin = Date(); let vector = try await embedder.image(url)
            vectors.append(vector)
            let first = Date().timeIntervalSince(begin)
            let warmStart = Date(); _ = try await embedder.image(url)
            report.append(["image":url.lastPathComponent,"ocr_seconds":ocr,"ocr":read.text ?? "","image_first_seconds":first,"image_warm_seconds":Date().timeIntervalSince(warmStart),"dimension":vector.count])
        }
        let queries = ["A phone launch performance chart showing a main thread stall", "A marketing budget with advertising overspend"]
        let q = try await embedder.texts(queries, role: .query)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("image-bench-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let index = try SearchIndex(url:temporary.appendingPathComponent("search.sqlite"))
        _ = try index.adopt(modelID:embedder.modelID)
        let indexer = FolderIndexer(index:index,embedder:embedder,extractor:FileExtractors())
        for path in args.dropFirst(i+2) { _ = try await indexer.index(URL(fileURLWithPath:path).standardizedFileURL,kind:.image,root:temporary.path) }
        var hybrid: [[String:Any]] = []
        for (j,query) in queries.enumerated() {
            let hits = try index.search(SearchRequest(query),queryVector:q[j],queryModelID:embedder.modelID).hits
            hybrid.append(["query":query,"top_file":hits.first.map { URL(fileURLWithPath:$0.ref).lastPathComponent } ?? "none","top_kind":hits.first?.kind.rawValue ?? "none"])
        }
        let result: [String:Any] = ["hybrid":hybrid,"images": report, "queries":queries,"cosines":q.map { row in vectors.map { VectorMath.dot(row,$0) } }, "model":embedder.modelID]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys]))
        await embedder.release()
    }
}
