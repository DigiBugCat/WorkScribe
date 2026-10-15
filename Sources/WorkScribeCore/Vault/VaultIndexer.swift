import Foundation

/// What a web clip note says about where it came from.
public struct ClipInfo: Equatable, Sendable {
    public var url: String?
    public var site: String?
    public var clipped: String?
    public var title: String?
    public var author: String?
    public var highlights: [String]
    public var meetingID: String?
}

extension VaultDocument {
    /// A Web Clipper note (or one from WorkScribe's extension): `source`/`url` frontmatter with an http(s) URL, a note
    /// under `Clippings/`, or `type: clip`. Meeting and person notes never count, whatever fields they have.
    public func clipInfo(path: String) -> ClipInfo? {
        let type = frontmatter["type"]?.first?.lowercased()
        if let type, ["meeting", "person", "workscribe-conflict"].contains(type) { return nil }
        let url = [frontmatter["source"], frontmatter["url"], frontmatter["link"]].compactMap { $0?.first }
            .first { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
        let inClippings = path.lowercased().hasPrefix("clippings/")
        let tagged = allTags.contains { $0.lowercased() == "clippings" || $0.lowercased() == "clipping" }
        guard type == "clip" || inClippings || (url != nil && (type == nil || tagged || frontmatter["clipped"] != nil || frontmatter["created"] != nil)) else {
            return nil
        }
        var site = frontmatter["site"]?.first
        if site == nil, let url, let host = URL(string: url)?.host { site = VaultLinks.siteName(host) }
        let listed = frontmatter["highlights"]?.strings ?? []
        var seen = Set<String>()
        return ClipInfo(url: url, site: site,
                        clipped: (frontmatter["clipped"] ?? frontmatter["created"] ?? frontmatter["date"])?.first,
                        title: frontmatter["title"]?.first ?? title,
                        author: frontmatter["author"]?.strings.map { Markdown.plain($0) }.joined(separator: ", ").nilIfEmpty,
                        highlights: (listed.map(Markdown.plain) + highlights).filter { !$0.isEmpty && seen.insert($0).inserted },
                        meetingID: frontmatter["meeting_id"]?.first)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What in a vault gets indexed: Markdown notes, not Obsidian's configuration, the trash, hidden folders or
/// WorkScribe's conflict copies.
public enum VaultRules {
    public static func isNote(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        guard let name = parts.last, name.lowercased().hasSuffix(".md"), !name.hasSuffix(".conflict.md") else { return false }
        return !parts.contains { $0.hasPrefix(".") } && !parts.dropLast().contains { $0 == "node_modules" }
    }

    public static func isImage(_ relative: String) -> Bool {
        !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) && NoteImageContent.extensions.contains((relative as NSString).pathExtension.lowercased())
    }
    public static func images(_ root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { isImage(relative($0, to: root)) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { FileIdentity.url($0) }
    }

    public static func walk(_ root: URL) -> [URL] {
        let base = FileIdentity.url(root)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if FolderRules.skipReason(forFolder: url) != nil { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if isNote(relative(url, to: base)) { out.append(FileIdentity.url(url)) }
        }
        return out.sorted { $0.path < $1.path }
    }

    public static func relative(_ url: URL, to root: URL) -> String {
        let full = FileIdentity.url(url).path, base = FileIdentity.url(root).path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }
}

/// Indexes a vault's Markdown as `vault` sources: each note's heading sections become chunks (kind `clip` for web
/// clips, `document` otherwise), embedded notes are folded in one level deep (never recursively), and the source
/// records the note's vault path, clip URL, site, clipped date and highlights for results and deep links.
public struct VaultIndexer: Sendable {
    public let index: SearchIndex
    public let embedder: (any Embedder)?
    public let extractor: any FileExtracting
    public let gate: @Sendable () async -> Void
    /// Text taken from each embedded note.
    public var embedLimit = 4000

    public init(index: SearchIndex, embedder: (any Embedder)?, extractor: any FileExtracting = PlainTextExtractor(), gate: @escaping @Sendable () async -> Void = {}) {
        self.index = index; self.embedder = embedder; self.extractor = extractor; self.gate = gate
    }

    /// Full pass: every note under `vault`; notes that disappeared leave the index.
    public func sync(vault: URL) async throws -> IndexReport {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        let root = FileIdentity.url(vault)
        let files = VaultRules.walk(root)
        let resolver = EmbedResolver(root: root, files: files + VaultRules.images(root))
        var report = IndexReport()
        var seen = Set<String>()
        for url in files + VaultRules.images(root) {
            try Task.checkCancellation()
            seen.insert(url.path)
            await tally(&report) { try await index(url, vault: root, resolver: resolver) }
        }
        for source in try index.sources(kind: .vault) where source.root.map(FileIdentity.path) == root.path && (!seen.contains(source.ref) || source.root != root.path) {
            try index.remove(ref: source.ref); report.removed += 1
        }
        return report
    }

    /// Incremental pass for paths FSEvents reported: changed notes are re-read, deleted ones removed.
    public func update(paths: [String], vault: URL) async throws -> IndexReport {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        let root = FileIdentity.url(vault)
        var report = IndexReport()
        var resolver: EmbedResolver?
        var affected = Set(paths)
        let imageChanges = Set(paths.filter { VaultRules.isImage(VaultRules.relative(URL(fileURLWithPath:$0),to:root)) }.map { FileIdentity.url(URL(fileURLWithPath:$0)).path })
        if !imageChanges.isEmpty {
            for source in try index.sources(kind:.vault) where source.root == root.path {
                if let raw = try index.meta(ref:source.ref)["images"], let data = raw.data(using:.utf8),
                   let refs = try? JSONDecoder().decode([String].self,from:data), !imageChanges.isDisjoint(with:refs) { affected.insert(source.ref) }
            }
        }
        for path in affected.sorted() {
            try Task.checkCancellation()
            let url = FileIdentity.url(URL(fileURLWithPath:path))
            guard url.path.hasPrefix(root.path + "/"), (VaultRules.isNote(VaultRules.relative(url, to: root)) || VaultRules.isImage(VaultRules.relative(url, to: root))) else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                if resolver == nil { resolver = EmbedResolver(root: root, files: VaultRules.walk(root) + VaultRules.images(root)) }
                await tally(&report) { try await index(url, vault: root, resolver: resolver!) }
            } else if try index.source(ref: url.path) != nil {
                try index.remove(ref: url.path); report.removed += 1
            }
        }
        return report
    }

    private func tally(_ report: inout IndexReport, _ body: () async throws -> FolderIndexer.Outcome) async {
        do {
            switch try await body() {
            case .indexed: report.indexed += 1
            case .refreshed: report.refreshed += 1
            case .unchanged: report.unchanged += 1
            case .skipped: report.skipped += 1
            }
        } catch { report.failed += 1 }
    }

    private func indexImage(_ url: URL, vault: URL) async throws -> FolderIndexer.Outcome {
        guard NoteImageContent.resolve(NoteImage(target: url.lastPathComponent, path: url.path), note: url, vault: vault) != nil else { return .skipped }
        let fingerprint = try FolderIndexer.fingerprint(url)
        if let existing = try index.source(ref: url.path), existing.fingerprint == fingerprint,
           embedder == nil || existing.modelID == embedder?.modelID { return .unchanged }
        var chunks = try await FolderIndexer(index: index, embedder: embedder, extractor: extractor, gate: gate).read(url, kind: .image)
        if chunks.isEmpty { chunks = [Chunk(kind: .image, modality: .text, text: url.deletingPathExtension().lastPathComponent, thumbnail: url.path)] }
        try index.replace(kind: .vault, ref: url.path, root: vault.path, title: url.lastPathComponent, fingerprint: fingerprint,
                          modelID: embedder?.modelID, meta: ["path": VaultRules.relative(url, to: vault), "vault": vault.lastPathComponent], chunks: chunks)
        return .indexed
    }

    @discardableResult
    public func index(_ url: URL, vault: URL, resolver: EmbedResolver) async throws -> FolderIndexer.Outcome {
        if VaultRules.isImage(VaultRules.relative(url, to: vault)) { return try await indexImage(url, vault: vault) }
        let ref = url.path
        let data = try Data(contentsOf: url)
        let raw = String(decoding: data, as: UTF8.self)
        let relative = VaultRules.relative(url, to: vault)
        let imageURLs = Array(Set(NoteImageContent.parse(raw, source:raw).targets.compactMap { resolver.resolveImage($0,from:relative) })).sorted { $0.path < $1.path }.prefix(64)
        let imageStamp = imageURLs.map { $0.path + ":" + ((try? FolderIndexer.fingerprint($0)) ?? "missing") }.joined(separator:"|")
        let fingerprint = try FolderIndexer.fingerprint(url) + imageStamp
        let existing = try index.source(ref: ref)
        let modelCurrent = embedder == nil || existing?.modelID == embedder?.modelID
        if let existing, existing.fingerprint == fingerprint, modelCurrent { return .unchanged }
        let hash = VaultWriter.sha256(data) + imageStamp
        if let existing, existing.contentHash == hash, modelCurrent {
            try index.touch(ref: ref, fingerprint: fingerprint)
            return .refreshed
        }
        let document = VaultDocument.parse(raw)
        let clip = document.clipInfo(path: relative)
        let title = clip?.title ?? document.frontmatter["title"]?.first ?? document.title ?? url.deletingPathExtension().lastPathComponent

        var meta: [String: String] = ["path": relative]
        if !imageURLs.isEmpty { meta["images"] = String(decoding:try JSONEncoder().encode(imageURLs.map(\.path)),as:UTF8.self) }
        if FileManager.default.fileExists(atPath: vault.appendingPathComponent(".obsidian").path) { meta["vault"] = vault.lastPathComponent }
        if let type = document.frontmatter["type"]?.first { meta["type"] = type }
        if let id = document.frontmatter["workscribe_id"]?.first { meta["workscribe_id"] = id }
        let tags = document.allTags
        if !tags.isEmpty { meta["tags"] = tags.joined(separator: ", ") }
        if let clip {
            meta["type"] = "clip"
            meta["url"] = clip.url; meta["site"] = clip.site; meta["clipped"] = clip.clipped; meta["author"] = clip.author
            meta["meeting_id"] = clip.meetingID
            if !clip.highlights.isEmpty { meta["highlights"] = clip.highlights.joined(separator: "\n") }
        } else if let meeting = document.frontmatter["meeting_id"]?.first {
            meta["meeting_id"] = meeting
        }

        let kind: ChunkKind = clip == nil ? .document : .clip
        var texts: [String] = []
        if let clip, !clip.highlights.isEmpty { texts.append("Highlights: " + clip.highlights.joined(separator: " · ")) }
        for section in document.sections {
            let body = [section.heading, section.text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
            texts.append(contentsOf: TextChunker.chunks(body))
        }
        // Embedded notes, one level: their own embeds are not followed.
        var embedded = Set<String>()
        for embed in document.embeds {
            guard let target = resolver.resolve(embed.target, from: relative), target.path != url.path,
                  embedded.insert(target.path).inserted,
                  let text = try? String(contentsOf: target, encoding: .utf8) else { continue }
            let plain = VaultDocument.parse(text).plainText
            guard !plain.isEmpty else { continue }
            texts.append(contentsOf: TextChunker.chunks("Embedded \(embed.display):\n" + String(plain.prefix(embedLimit))))
        }
        var chunks = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Chunk(kind: kind, modality: .text, text: $0) }
        if chunks.isEmpty { chunks = [Chunk(kind: kind, modality: .text, text: title)] }
        if let embedder {
            let rows = chunks.indices.filter { chunks[$0].text.map(SearchText.hasWords) ?? false }
            for batch in stride(from: 0, to: rows.count, by: 32) {
                await gate()
                try Task.checkCancellation()
                let part = Array(rows[batch..<min(batch + 32, rows.count)])
                let vectors = try await embedder.texts(part.map { chunks[$0].text ?? "" }, role: .document(title: title))
                for (row, vector) in zip(part, vectors) { chunks[row].vector = VectorMath.normalized(vector) }
            }
        }
        for image in imageURLs {
            guard NoteImageContent.resolve(.init(target:image.lastPathComponent,path:image.path),note:url,vault:vault) != nil else { continue }
            await gate(); try Task.checkCancellation()
            let evidence = (try? await extractor.passages(of:image,kind:.image).passages.map(\.text).joined(separator:"\n")) ?? ""
            let vector = embedder?.supportsImages == true ? try? await embedder?.image(image) : nil
            chunks.append(Chunk(kind:.image,modality:vector == nil ? .text : .image,
                                text:"Image in \(title): \(image.lastPathComponent)\n" + evidence, vector:vector ?? nil,thumbnail:image.path))
        }
        try index.replace(kind: .vault, ref: ref, root: vault.path, title: title, fingerprint: fingerprint, contentHash: hash,
                          modelID: embedder?.modelID, meta: meta, chunks: chunks)
        return .indexed
    }
}

/// Resolves `![[target]]` the way Obsidian does for the common cases: a vault-relative path, a path relative to
/// the embedding note, or a unique note name anywhere in the vault (shortest path wins on ties).
public struct EmbedResolver: Sendable {
    let root: URL
    let byName: [String: [URL]]
    let byPath: [String: URL]
    public init(root: URL, files: [URL]) {
        self.root = FileIdentity.url(root)
        var names: [String: [URL]] = [:], paths: [String: URL] = [:]
        for file in files {
            let relative = VaultRules.relative(file, to: root).lowercased()
            paths[relative] = file
            if file.pathExtension.lowercased() == "md" { names[file.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(file) }
        }
        byName = names.mapValues { $0.sorted { $0.path.count < $1.path.count } }
        byPath = paths
    }

    public func resolveImage(_ target: String, from relative: String) -> URL? {
        guard !target.contains(":"), NoteImageContent.extensions.contains((target as NSString).pathExtension.lowercased()) else { return nil }
        let folder = (relative as NSString).deletingLastPathComponent
        return byPath[target.lowercased()] ?? byPath[((folder as NSString).appendingPathComponent(target)).lowercased()]
            ?? byPath.values.filter { $0.lastPathComponent.lowercased() == target.lowercased() }.sorted { $0.path.count < $1.path.count }.first
    }

    public func resolve(_ target: String, from relative: String) -> URL? {
        let clean = target.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let withExtension = clean.lowercased().hasSuffix(".md") ? clean : clean + ".md"
        guard withExtension.lowercased().hasSuffix(".md") else { return nil }
        if let exact = byPath[withExtension.lowercased()] { return exact }
        let folder = (relative as NSString).deletingLastPathComponent
        if !folder.isEmpty, let sibling = byPath[((folder as NSString).appendingPathComponent(withExtension)).lowercased()] { return sibling }
        if !clean.contains("/") { return byName[(withExtension as NSString).deletingPathExtension.lowercased()]?.first }
        return nil
    }
}
