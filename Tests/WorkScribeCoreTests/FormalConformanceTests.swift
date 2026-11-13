import XCTest
@testable import WorkScribeCore

/// Ties the Lean proofs in `formal/lean` to the real Swift types.
///
/// Each Lean theorem is about a Lean re-implementation. These tests drive the real types with
/// deterministic pseudo-random operation sequences and assert the same statements, so a drift
/// between the Swift and the Lean model shows up here. Every assertion names the Lean theorem it
/// mirrors (`Formal/Line.lean`, `Formal/AutoRecord.lean`, `Formal/Backlog.lean`, `Formal/Small.lean`).
///
/// Two defects the first round of proofs found have since been fixed in the Swift (an image result
/// hid an answered line; a changed image list cleared a line without raising its revision). The
/// tests that used to reproduce them now assert the fixed behaviour and are named for what they
/// guarantee.
///
/// Tests still named `testFinding…` state a limitation or a surprise that Lean proved about the
/// code as it is. They assert that outcome on purpose; if one fails, the behaviour changed and
/// both the test and the theorem it names need another look.
final class FormalConformanceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: - Deterministic generator (seeded LCG, no dependency)

    struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33 // the high bits of a 64-bit LCG are the well-mixed ones
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func bool() -> Bool { below(2) == 0 }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    // MARK: - 1. AI line lifecycle (Formal/Line.lean)

    /// The fourteen operations of the Lean `Op` type.
    enum LineOp: CustomStringConvertible {
        case reset, takeOwnership, resume, recheck, settle
        case retract(remaining: [String])
        case apply(LineOutcome)
        case setOwned(Bool?)
        case editText(String)
        case editEnhancement(String)
        case letAIRewrite
        case markFound
        case imagePublish(isImage: Bool, imageEvidenceEmpty: Bool)
        case docImagesChanged

        /// Lean `Op.isEngine`, plus the found marking.
        var isEngineOrMarkFound: Bool {
            switch self {
            case .reset, .resume, .recheck, .settle, .retract, .apply, .markFound: true
            default: false
            }
        }
        /// Lean `Op.isLineMethod`.
        var isLineMethod: Bool {
            switch self {
            case .reset, .takeOwnership, .resume, .recheck, .settle, .retract, .apply, .setOwned: true
            default: false
            }
        }
        var description: String {
            switch self {
            case .reset: "reset"
            case .takeOwnership: "takeOwnership"
            case .resume: "resume"
            case .recheck: "recheck"
            case .settle: "settle"
            case .retract(let remaining): "retract(\(remaining.count))"
            case .apply(let outcome): "apply(\(outcome))"
            case .setOwned(let value): "owned=\(String(describing: value))"
            case .editText(let text): "editText(\(text))"
            case .editEnhancement(let text): "editEnhancement(\(text))"
            case .letAIRewrite: "letAIRewrite"
            case .markFound: "markFound"
            case .imagePublish(let image, let empty): "imagePublish(isImage:\(image),empty:\(empty))"
            case .docImagesChanged: "docImagesChanged"
            }
        }
    }

    // MARK: App-target code, transcribed
    //
    // `markFound` and `imagePublish` below copy code from `Sources/WorkScribe`, which this test
    // target cannot import. `testTranscribedCodeStillMatchesTheSource` reads the source files and
    // fails when the copied statements are no longer there.

    /// MeetingNotes.swift, in `NoteEnhancementScheduler.run`: the engine marks a targeted jot that
    /// has no outcome yet (the id / queryRevision parts of the predicate only select the note).
    private func markFound(_ line: inout Line) {
        if line.state == .listening { line.state = .found }
    }
    private static let markFoundSource = [
        "if let i = meeting.notes?.firstIndex(where: { $0.id == target.note.id && $0.queryRevision == target.note.queryRevision && $0.line.state == .listening }) {",
        "meeting.notes![i].line.state = .found",
    ]

    /// NoteImageUnderstanding.swift, `publish` inside `readNoteImages`: one image result (OCR text,
    /// later the caption) is published into a note. `isImage` stands for `meeting.notes![i].isImage`
    /// and `imageEvidenceEmpty` for `meeting.notes![i].imageEvidence.isEmpty`.
    private func imagePublish(_ target: inout Line, isImage: Bool, imageEvidenceEmpty: Bool) {
        var line = target
        if line.owned == true { line.revision = (line.revision ?? 0) + 1 }
        else if isImage && imageEvidenceEmpty { line.reset() }
        else { line.revision = (line.revision ?? 0) + 1; line.recheck() }
        target = line
    }
    private static let imagePublishSource = [
        "var line = meeting.notes![i].line",
        "if line.owned == true { line.revision = (line.revision ?? 0) + 1 }",
        "else if meeting.notes![i].isImage && meeting.notes![i].imageEvidence.isEmpty { line.reset() }",
        "else { line.revision = (line.revision ?? 0) + 1; line.recheck() }",
        "meeting.notes![i].line = line",
    ]

    /// NoteDocument.swift:74, the one write to the line when a note's image list changed. This is
    /// core code, and the real method is driven in `testDocumentImageSyncStartsTheLineOverAndRaisesTheRevision`
    /// and `testDocumentImageSyncLeavesAnOwnedLineAlone`; it is copied here so the random sequences
    /// can run it without building a document.
    private func docImagesChanged(_ line: inout Line) {
        if line.owned == true { line.queryText = nil } else { line.reset() }
    }
    private static let docImagesChangedSource = [
        "if n.line.owned == true { n.line.queryText = nil } else { n.line.reset() }",
    ]

    /// The statements transcribed above are still in the source, in order and next to each other
    /// (comments between them are ignored). If this fails, re-transcribe them here and in
    /// `formal/lean/Formal/Line.lean` (`Line.imagePublish`, `Line.markFound`, `Line.docImagesChanged`),
    /// then re-check the proofs.
    func testTranscribedCodeStillMatchesTheSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func statements(_ relative: String) throws -> [String] {
            let url = root.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("\(relative) is not next to this test (built outside the repository)")
            }
            return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        }
        func assertContains(_ expected: [String], in relative: String) throws {
            let lines = try statements(relative)
            let found = lines.indices.contains { start in
                start + expected.count <= lines.count && Array(lines[start..<start + expected.count]) == expected
            }
            XCTAssertTrue(found, "\(relative) no longer contains the statements transcribed in this test: \(expected)")
        }
        try assertContains(Self.imagePublishSource, in: "Sources/WorkScribe/NoteImageUnderstanding.swift")
        try assertContains(Self.markFoundSource, in: "Sources/WorkScribe/MeetingNotes.swift")
        try assertContains(Self.docImagesChangedSource, in: "Sources/WorkScribeCore/NoteDocument.swift")
    }

    private let stamp = Date(timeIntervalSince1970: 0)
    private func bullet(_ text: String) -> Bullet { Bullet(topic: "", text: text, refs: []) } // markdown == text
    private let sentences = ["The trial lasts fourteen days.", "The trial lasts thirty days.",
                             "Pricing moves to twenty dollars.", "Launch slips to Friday."]
    private let jots = ["trial length", "trial length?", "completely different budget subject", "launch date",
                        "pricing tiers for teams"]

    /// Applies one operation to the real `Note`; returns `apply`'s result when the operation is `apply`.
    @discardableResult
    private func perform(_ op: LineOp, on note: inout Note) -> Bool? {
        switch op {
        case .reset: note.line.reset()
        case .takeOwnership: note.line.takeOwnership()
        case .resume: note.line.resume()
        case .recheck: note.line.recheck()
        case .settle: note.line.settle()
        case .retract(let remaining): note.line.retract(remaining: remaining, jot: note.text)
        case .apply(let outcome): return note.line.apply(outcome, basis: "basis", query: note.text, at: stamp)
        case .setOwned(let value): note.line.owned = value
        case .editText(let text): note.editText(text, at: 7)
        case .editEnhancement(let text): note.editEnhancement(NoteEnhancementText(topic: "", text: text))
        case .letAIRewrite: note.letAIRewrite()
        case .markFound: markFound(&note.line)
        case .imagePublish(let image, let empty): imagePublish(&note.line, isImage: image, imageEvidenceEmpty: empty)
        case .docImagesChanged: docImagesChanged(&note.line)
        }
        return nil
    }

    private func randomLineOp(_ rng: inout LCG, line: Line, ownedSetter: Bool, bareTakeOwnership: Bool) -> LineOp {
        while true {
            switch rng.below(21) {
            case 0: return .reset
            case 1: if bareTakeOwnership { return .takeOwnership }
            case 2: return .resume
            case 3, 4: return .settle
            case 5: return .retract(remaining: rng.pick([[], [line.text ?? ""], ["Unrelated words about the weather."]]))
            case 6, 7, 8, 9: return .apply(.line(bullet(rng.pick(sentences)), ["s\(rng.below(3))"]))
            case 10: return .apply(.unchanged)
            case 11: return .apply(.quiet(.unsupported))
            case 12: if ownedSetter { return .setOwned(rng.pick([true, false, nil])) }
            case 13: return .editText(rng.pick(jots))
            case 14: return .editEnhancement(rng.pick(["My own wording.", "Mine, edited again."]))
            case 15: return .letAIRewrite
            case 16: return .markFound
            case 17, 18: return .imagePublish(isImage: rng.bool(), imageEvidenceEmpty: rng.bool())
            case 19: return .docImagesChanged
            default: return .recheck
            }
        }
    }

    private func rev(_ line: Line) -> Int { line.revision ?? 0 }
    /// Lean `WF`.
    private func wellFormed(_ line: Line) -> Bool {
        line.state == .yours || ((line.text != nil) == (line.state == .answered || line.state == .settled))
    }
    /// Lean `WeakWF`.
    private func weaklyWellFormed(_ line: Line) -> Bool {
        if line.state == .yours { return true }
        if (line.state == .answered || line.state == .settled) && line.text == nil { return false }
        return !(line.state == .quiet && line.text != nil)
    }
    /// Lean `HistDistinct`.
    private func historyDistinct(_ line: Line) -> Bool { Set(line.history.map(\.text)).count == line.history.count }
    /// Lean `VersionsOrdered` (strictly increasing adjacent pairs is the same as pairwise).
    private func versionsOrdered(_ line: Line) -> Bool {
        line.history.allSatisfy { $0.version <= rev(line) }
            && zip(line.history, line.history.dropFirst()).allSatisfy { $0.version < $1.version }
    }
    /// Lean `TextInHistory`.
    private func textInHistory(_ line: Line) -> Bool {
        line.state == .yours || line.text == nil || line.history.contains { $0.text == line.text }
    }
    /// Lean `OwnedHasText`.
    private func ownedHasText(_ line: Line) -> Bool { line.state != .yours || line.text != nil }

    // MARK: The Lean definitions of Formal/Line.lean, transcribed into Swift
    //
    // These follow the Lean text, not the Swift source. `testLineInvariantsOverRandomSequences`
    // compares them with the real methods after every operation; a mismatch means the Lean model
    // no longer describes the code.

    private func modelReset(_ l: Line) -> Line { // Lean `Line.reset`
        if l.state == .yours { return l }
        var fresh = Line(); fresh.revision = rev(l) + 1; return fresh
    }
    private func modelTakeOwnership(_ l: Line) -> Line { // Lean `Line.takeOwnership`
        var n = l; n.state = .yours; n.revision = rev(l) + 1; return n
    }
    private func modelSetOwned(_ l: Line, _ value: Bool?) -> Line { // Lean `Line.setOwned`
        if value == true { return modelTakeOwnership(l) }
        if l.state == .yours { var n = l; n.state = l.text == nil ? .listening : .answered; return n }
        return l
    }
    private func modelResume(_ l: Line) -> Line { // Lean `Line.resume`
        guard l.state == .settled || l.state == .quiet else { return l }
        var n = l; n.state = l.text == nil ? .listening : .answered; return n
    }
    private func modelRecheck(_ l: Line) -> Line { // Lean `Line.recheck`
        if l.state == .yours { return l }
        var n = l; n.queryText = nil; n.basis = nil; n.state = l.text == nil ? .listening : l.state; return n
    }
    private func modelSettle(_ l: Line) -> Line { // Lean `Line.settle`
        if l.state == .yours { return l }
        var n = l; n.state = l.text == nil ? .quiet : .settled; return n
    }
    private func modelRetract(_ l: Line, remainingEmpty: Bool, grounded: Bool) -> Line { // Lean `Line.retract`
        if l.state == .yours || l.text == nil { return l }
        return remainingEmpty || !grounded ? modelReset(l) : l
    }
    private func modelApply(_ l: Line, _ outcome: LineOutcome, basis: String, query: String, at: Date) -> (Line, Bool) { // Lean `Line.apply`
        if l.state == .yours { return (l, false) }
        var n = l; n.basis = basis
        switch outcome {
        case .line(let bullet, let ids):
            let markdown = bullet.markdown
            if n.text == markdown || n.history.contains(where: { $0.text == markdown }) { return (n, false) }
            let revision = rev(n) + 1
            let reason = n.history.isEmpty ? "First matching discussion" : "New evidence"
            n.revision = revision; n.text = markdown; n.evidence = ids; n.queryText = query; n.state = .answered; n.updatedAt = at
            n.history = n.history + [LineRevision(version: revision, text: markdown, reason: reason, at: at, evidence: ids)]
            return (n, true)
        case .unchanged, .quiet:
            n.state = n.text == nil ? .listening : .answered
            return (n, false)
        }
    }
    private func modelImagePublish(_ l: Line, isImage: Bool, imageEvidenceEmpty: Bool) -> Line { // Lean `Line.imagePublish`
        if l.state == .yours { var n = l; n.revision = rev(l) + 1; return n }
        if isImage && imageEvidenceEmpty { return modelReset(l) }
        var n = l; n.revision = rev(l) + 1; return modelRecheck(n)
    }
    private func modelDocImagesChanged(_ l: Line) -> Line { // Lean `Line.docImagesChanged`
        if l.state == .yours { var n = l; n.queryText = nil; return n }
        return modelReset(l)
    }
    /// Lean `Note.isMajorEdit`, in whole numbers.
    private func modelIsMajorEdit(difference: Int, union: Int) -> Bool { difference > 1 && 10 * difference > 3 * max(1, union) }
    /// Lean `Note.step`. The two abstracted inputs are taken from the real code: `grounded` from
    /// `LineFaithfulness.grounded`, and the token-set sizes from `LexicalMatcher.tokens`.
    private func modelStep(_ note: Note, _ op: LineOp) -> (note: Note, applied: Bool?) {
        var n = note
        switch op {
        case .reset: n.line = modelReset(note.line)
        case .takeOwnership: n.line = modelTakeOwnership(note.line)
        case .resume: n.line = modelResume(note.line)
        case .recheck: n.line = modelRecheck(note.line)
        case .settle: n.line = modelSettle(note.line)
        case .retract(let remaining):
            let grounded = note.line.text.map {
                LineFaithfulness.grounded(NoteEnhancementText(markdown: $0).text, evidence: remaining, jot: note.text)
            } ?? true
            n.line = modelRetract(note.line, remainingEmpty: remaining.isEmpty, grounded: grounded)
        case .apply(let outcome):
            let result = modelApply(note.line, outcome, basis: "basis", query: note.text, at: stamp)
            n.line = result.0
            return (n, result.1)
        case .setOwned(let value): n.line = modelSetOwned(note.line, value)
        case .editText(let text): // Lean `Note.editText`
            let old = Set(LexicalMatcher.tokens(note.text)), new = Set(LexicalMatcher.tokens(text))
            let major = modelIsMajorEdit(difference: old.symmetricDifference(new).count, union: old.union(new).count)
            n.text = text; n.queryRevision += 1
            if major { n.line = modelReset(n.line); n.createdAt = 7 }
            n.line.basis = nil
        case .editEnhancement(let text): // Lean `Note.editEnhancement`
            var l = note.line; l.text = text; l.queryText = note.text
            n.line = modelTakeOwnership(l)
        case .letAIRewrite: // Lean `Note.letAIRewrite`
            var fresh = Line(); fresh.revision = rev(note.line) + 1
            n.line = fresh; n.queryRevision += 1
        case .markFound: // Lean `Line.markFound`
            if note.line.state == .listening { n.line.state = .found }
        case .imagePublish(let isImage, let empty):
            n.line = modelImagePublish(note.line, isImage: isImage, imageEvidenceEmpty: empty)
        case .docImagesChanged:
            n.line = modelDocImagesChanged(note.line)
        }
        return (n, nil)
    }

    func testLineInvariantsOverRandomSequences() {
        var reached = Set<Line.State>(), applied = 0
        var answersKeptThroughImage = 0, startedOverByImage = 0, unsettledByImage = 0, clearedByDocument = 0, rechecks = 0
        var retractReset = 0, retractKept = 0, majorEdits = 0, minorEdits = 0
        for seed in 0..<3000 {
            var rng = LCG(seed: UInt64(seed))
            // Two of the reachability theorems exclude an operation; give each a share of the seeds.
            let allowOwnedSetter = seed % 3 == 2, allowBareTakeOwnership = seed % 5 == 4
            var note = Note(text: "trial length", createdAt: 1)
            if seed % 7 == 0 { // MeetingNotes.swift:56-57, a note made from an answer
                note.fromAnswer = NoteAnswerOrigin(answerId: "a", question: "q", askedBy: nil)
                note.line.state = .quiet
            }
            XCTAssertTrue(wellFormed(note.line), "wf_new")
            var sawOwnedSetter = false, sawBareTakeOwnership = false
            // Every (text, revision) the line has had, for text_change_bumps_rev_run; and the highest
            // revision an image event has left behind, for the two `…_outdates_drafts` theorems.
            var seen = [(text: note.line.text, rev: rev(note.line))]
            var outdated: Int?
            for index in 0..<40 {
                let op = randomLineOp(&rng, line: note.line, ownedSetter: allowOwnedSetter, bareTakeOwnership: allowBareTakeOwnership)
                let before = note
                let model = modelStep(before, op)
                let result = perform(op, on: &note)
                let a = before.line, b = note.line
                let at = "seed \(seed) step \(index) \(op)"
                // The real type and the Lean definitions agree on the whole note and on apply's result.
                XCTAssertEqual(note, model.note, "Lean model \(at)")
                XCTAssertEqual(result, model.applied, "Lean model \(at)")
                reached.insert(b.state)
                if case .setOwned = op { sawOwnedSetter = true }
                if case .retract = op, a.state != .yours, a.text != nil { if b.text == nil { retractReset += 1 } else { retractKept += 1 } }
                if case .editText = op, a.state != .yours { if rev(b) > rev(a) { majorEdits += 1 } else { minorEdits += 1 } }
                if case .takeOwnership = op { sawBareTakeOwnership = true }

                // (a) The user's words are sacred.
                if a.state == .yours {
                    // yours_reset, yours_resume, yours_recheck, yours_settle, yours_retract, yours_apply,
                    // yours_markFound, engine_step_yours
                    if op.isEngineOrMarkFound { XCTAssertEqual(note, before, at) }
                    if case .apply = op { XCTAssertEqual(result, false, at) } // yours_apply
                    // leaves_yours_only_by_release
                    if b.state != .yours {
                        switch op {
                        case .letAIRewrite: break
                        case .setOwned(let value): XCTAssertNotEqual(value, true, at)
                        default: XCTFail("left yours by \(at)")
                        }
                    }
                    // yours_text_changes_only_by_user
                    if b.text != a.text {
                        switch op {
                        case .editEnhancement, .letAIRewrite: break
                        default: XCTFail("owned text changed by \(at)")
                        }
                    }
                    // yours_imagePublish, yours_docImagesChanged, yours_editText: exactly one field changes
                    var expected = a
                    switch op {
                    case .imagePublish: expected.revision = rev(a) + 1; XCTAssertEqual(b, expected, at)
                    case .docImagesChanged: expected.queryText = nil; XCTAssertEqual(b, expected, at)
                    case .editText: expected.basis = nil; XCTAssertEqual(b, expected, at)
                    default: break
                    }
                }

                // (b) Revision.
                XCTAssertGreaterThanOrEqual(rev(b), rev(a), "rev_mono \(at)")
                // text_change_bumps_rev: every operation, with no exception
                if b.text != a.text { XCTAssertGreaterThan(rev(b), rev(a), "text_change_bumps_rev \(at)") }
                // text_change_bumps_rev_run: against every earlier point of this sequence
                for earlier in seen where earlier.text != b.text {
                    XCTAssertGreaterThan(rev(b), earlier.rev, "text_change_bumps_rev_run \(at)")
                }
                seen.append((b.text, rev(b)))
                if case .imagePublish = op { // imagePublish_rev
                    XCTAssertEqual(rev(b), rev(a) + 1, "imagePublish_rev \(at)")
                    outdated = max(outdated ?? rev(a), rev(a))
                }
                if case .docImagesChanged = op { // docImagesChanged_bumps_rev
                    XCTAssertEqual(rev(b), a.state == .yours ? rev(a) : rev(a) + 1, "docImagesChanged_bumps_rev \(at)")
                    if a.state != .yours { outdated = max(outdated ?? rev(a), rev(a)) }
                }
                // imagePublish_outdates_drafts, docImagesChanged_outdates_drafts
                if let outdated { XCTAssertGreaterThan(rev(b), outdated, "outdates_drafts \(at)") }
                if case .takeOwnership = op { XCTAssertEqual(rev(b), rev(a) + 1, "takeOwnership_rev \(at)") }
                if op.isLineMethod { // rev_increase_iff
                    var cause = b.text != a.text
                    switch op {
                    case .takeOwnership, .setOwned(.some(true)): cause = true
                    case .reset: cause = cause || (a.state != .yours && a.text == nil)
                    default: break
                    }
                    XCTAssertEqual(rev(b) > rev(a), cause, "rev_increase_iff \(at)")
                }

                // (d) No flapping.
                if case .apply = op, let result {
                    applied += result ? 1 : 0
                    XCTAssertEqual(result, b.text != a.text, "apply_true_iff_text_changed \(at)")
                    XCTAssertEqual(rev(b), result ? rev(a) + 1 : rev(a), "apply_rev \(at)")
                    if b.text != a.text { XCTAssertFalse(a.history.contains { $0.text == b.text }, "apply_never_reuses_history \(at)") }
                }
                XCTAssertTrue(historyDistinct(b), "histDistinct_reachable \(at)")
                XCTAssertTrue(versionsOrdered(b), "versionsOrdered_reachable \(at)")
                if !sawOwnedSetter { XCTAssertTrue(textInHistory(b), "textInHistory_reachable \(at)") }
                if !sawOwnedSetter && !sawBareTakeOwnership { XCTAssertTrue(ownedHasText(b), "ownedHasText_reachable \(at)") }

                // (c) State and text agree, on every path: no operation is excluded any more.
                XCTAssertTrue(wellFormed(b), "wf_reachable \(at)")
                XCTAssertTrue(weaklyWellFormed(b), "weakWF_reachable \(at)")
                if b.text != nil { // text_never_hidden_reachable
                    XCTAssertFalse([.listening, .found, .quiet].contains(b.state), "text_never_hidden_reachable \(at)")
                }
                if case .editEnhancement = op { XCTAssertTrue(wellFormed(b) && ownedHasText(b), "wf_editEnhancement \(at)") }

                if case .recheck = op {
                    rechecks += 1
                    // recheck_keeps_answer
                    XCTAssertEqual(b.text, a.text, "recheck_keeps_answer \(at)")
                    if a.text != nil { XCTAssertEqual(b.state, a.state, "recheck_keeps_answer \(at)") }
                    if a.state != .yours { // recheck_not_owned
                        var expected = a; expected.queryText = nil; expected.basis = nil
                        if a.text == nil { expected.state = .listening }
                        XCTAssertEqual(b, expected, "recheck_not_owned \(at)")
                    }
                }
                if case .imagePublish(let isImage, let empty) = op {
                    if a.state != .yours { // imagePublish_not_owned
                        var expected = a
                        if isImage && empty { expected.reset(); startedOverByImage += a.text == nil ? 0 : 1 }
                        else {
                            expected.revision = rev(a) + 1; expected.queryText = nil; expected.basis = nil
                            if a.text == nil { expected.state = .listening }
                        }
                        XCTAssertEqual(b, expected, "imagePublish_not_owned \(at)")
                    }
                    if a.text != nil && !(isImage && empty) { // imagePublish_keeps_answer
                        XCTAssertEqual(b.text, a.text, "imagePublish_keeps_answer \(at)")
                        XCTAssertEqual(b.state, a.state, "imagePublish_keeps_answer \(at)")
                        if a.state != .yours { answersKeptThroughImage += 1 }
                    }
                    if a.state == .settled || a.state == .quiet { // imagePublish_stays_stopped_iff
                        let stillStopped = b.state == .settled || b.state == .quiet
                        XCTAssertEqual(stillStopped, a.text != nil && !(isImage && empty), "imagePublish_stays_stopped_iff \(at)")
                        if !stillStopped { unsettledByImage += 1 }
                    }
                }
                if case .docImagesChanged = op, a.state != .yours {
                    // docImagesChanged_not_owned
                    var expected = a; expected.reset()
                    XCTAssertEqual(b, expected, "docImagesChanged_not_owned \(at)")
                    if a.text != nil { clearedByDocument += 1 }
                    // docImagesChanged_allows_previous_text: the sentence it showed, and any other
                    for sentence in Set([a.text, sentences[3]].compactMap { $0 }) {
                        var again = b
                        XCTAssertTrue(again.apply(.line(bullet(sentence), []), basis: "b", query: "q", at: stamp),
                                      "docImagesChanged_allows_previous_text \(at)")
                        XCTAssertEqual(again.text, sentence, at); XCTAssertEqual(again.state, .answered, at)
                    }
                }
                // reset_allows_previous_text
                if a.state != .yours, let old = a.text {
                    var fresh = a; fresh.reset()
                    XCTAssertTrue(fresh.apply(.line(bullet(old), []), basis: "b", query: "q", at: stamp), "reset_allows_previous_text \(at)")
                }

                // (e) settle / resume / recheck, checked on copies of the reached line.
                var settled = b; settled.settle()
                XCTAssertTrue(wellFormed(settled), "wf_settle_any \(at)")
                var twice = settled; twice.settle()
                XCTAssertEqual(twice, settled, "settle_idem \(at)")
                var resumed = settled; resumed.resume()
                XCTAssertTrue(resumed.state != .settled && resumed.state != .quiet, "resume_not_settled \(at)")
                if b.state != .yours { // settle_resume
                    var expected = b; expected.state = b.text == nil ? .listening : .answered
                    XCTAssertEqual(resumed, expected, "settle_resume \(at)")
                }
                if wellFormed(b), [.listening, .answered, .yours].contains(b.state) {
                    XCTAssertEqual(resumed, b, "settle_resume_roundtrip \(at)")
                }
                var settledAgain = resumed; settledAgain.settle()
                XCTAssertEqual(settledAgain, settled, "settle_resume_settle \(at)")
                var once = b; once.resume()
                var both = once; both.resume()
                XCTAssertEqual(both, once, "resume_idem \(at)")
                var reset = b; reset.reset()
                XCTAssertTrue(wellFormed(reset), "wf_reset_any \(at)")
                for outcome in [LineOutcome.unchanged, .quiet(.abstained)] {
                    var repaired = b
                    repaired.apply(outcome, basis: "b", query: "q", at: stamp)
                    XCTAssertTrue(wellFormed(repaired), "wf_apply_noline_any \(at)")
                    if b.state == .settled || b.state == .quiet { // settled_not_absorbing
                        XCTAssertTrue(repaired.state == .listening || repaired.state == .answered, "settled_not_absorbing \(at)")
                    }
                }
                var rechecked = b; rechecked.recheck()
                var recheckedTwice = rechecked; recheckedTwice.recheck()
                XCTAssertEqual(recheckedTwice, rechecked, "recheck_idem \(at)")
                var recheckedThenResumed = rechecked; recheckedThenResumed.resume()
                var resumedThenRechecked = once; resumedThenRechecked.recheck()
                XCTAssertEqual(recheckedThenResumed, resumedThenRechecked, "recheck_resume_comm \(at)")
                if b.state != .yours {
                    var recheckedThenSettled = rechecked; recheckedThenSettled.settle()
                    var expected = settled; expected.queryText = nil; expected.basis = nil
                    XCTAssertEqual(recheckedThenSettled, expected, "recheck_then_settle \(at)")
                    var settledThenRechecked = settled; settledThenRechecked.recheck()
                    XCTAssertEqual(settledThenRechecked.state, b.text == nil ? .listening : .settled, "settle_then_recheck \(at)")
                }
            }
        }
        // The sequences are not vacuous: every state was reached and lines were written.
        XCTAssertEqual(reached, [.listening, .found, .answered, .settled, .quiet, .yours])
        XCTAssertGreaterThan(applied, 1000)
        // Both image paths met lines that had text: answers were kept through an image result,
        // image-only notes without evidence started over, stopped lines were un-settled, and a
        // changed image list cleared answers.
        XCTAssertGreaterThan(answersKeptThroughImage, 100); XCTAssertGreaterThan(startedOverByImage, 100)
        XCTAssertGreaterThan(unsettledByImage, 100); XCTAssertGreaterThan(clearedByDocument, 100)
        XCTAssertGreaterThan(rechecks, 1000)
        // Both outcomes of the grounding check and both kinds of jot edit were exercised.
        XCTAssertGreaterThan(retractReset, 100); XCTAssertGreaterThan(retractKept, 100)
        XCTAssertGreaterThan(majorEdits, 100); XCTAssertGreaterThan(minorEdits, 100)
    }

    /// Lean `wf_recheck_iff`, `wf_imagePublish_iff`, `recheck_keeps_answer`, `imagePublish_keeps_answer`
    /// and `imagePublish_rev`, on every combination of state and text, including the combinations no
    /// sequence of operations reaches any more (a line saved by an older build may hold one).
    func testRecheckAndImagePublishOnEveryStateWithAndWithoutText() {
        let states: [Line.State] = [.listening, .found, .answered, .settled, .quiet, .yours]
        for state in states {
            for text in [nil, sentences[0]] as [String?] {
                var line = Line(); line.state = state; line.text = text; line.queryText = "jot"; line.revision = 4
                let at = "\(state) \(text == nil ? "no text" : "text")"
                var rechecked = line; rechecked.recheck()
                XCTAssertEqual(rechecked.text, text, "recheck_keeps_answer \(at)")
                if text != nil { XCTAssertEqual(rechecked.state, state, "recheck_keeps_answer \(at)") }
                XCTAssertEqual(rechecked, modelRecheck(line), "Lean model \(at)")
                if state != .yours {
                    XCTAssertEqual(wellFormed(rechecked), text == nil || state == .answered || state == .settled, "wf_recheck_iff \(at)")
                }
                for isImage in [false, true] {
                    for empty in [false, true] {
                        var published = line; imagePublish(&published, isImage: isImage, imageEvidenceEmpty: empty)
                        XCTAssertEqual(published, modelImagePublish(line, isImage: isImage, imageEvidenceEmpty: empty), "Lean model \(at)")
                        XCTAssertEqual(rev(published), 5, "imagePublish_rev \(at)")
                        if text != nil && !(isImage && empty) { // imagePublish_keeps_answer
                            XCTAssertEqual(published.text, text, at); XCTAssertEqual(published.state, state, at)
                        }
                        if state != .yours { // wf_imagePublish_iff
                            XCTAssertEqual(wellFormed(published), (isImage && empty) || text == nil || state == .answered || state == .settled,
                                           "wf_imagePublish_iff \(at) \(isImage) \(empty)")
                        }
                    }
                }
            }
        }
    }

    /// The Lean model writes the `Double` test `difference / max(1, union) > 0.3` of Notes.swift:20
    /// as the whole-number test `10 * difference > 3 * max(1, union)`. They agree on every pair of
    /// token counts up to 400 (far beyond any jot).
    func testMajorEditRuleMatchesTheWholeNumberFormOfTheLeanModel() {
        for difference in 0...400 {
            for union in 0...400 {
                let swift = difference > 1 && Double(difference) / Double(max(1, union)) > 0.3
                XCTAssertEqual(swift, modelIsMajorEdit(difference: difference, union: union), "\(difference) \(union)")
            }
        }
        for difference in 0...1 { XCTAssertFalse(modelIsMajorEdit(difference: difference, union: 1), "isMajorEdit_single_token") }
    }

    /// Lean `isMajorEdit_single_token` / `isMajorEdit_iff`, on the real `editText`: an edit of at
    /// most one token keeps the line; replacing every token resets it.
    func testEditTextMinorKeepsTheLineAndMajorResetsIt() {
        var note = Note(text: "trial length", createdAt: 1)
        note.line.apply(.line(bullet(sentences[0]), ["s"]), basis: "b", query: note.text, at: stamp)
        let answered = note.line
        note.editText("trial length?", at: 9) // same tokens
        XCTAssertEqual(note.line.text, answered.text); XCTAssertEqual(note.line.revision, answered.revision)
        XCTAssertNil(note.line.basis); XCTAssertEqual(note.createdAt, 1)
        note.editText("completely different budget subject", at: 9) // every token replaced
        XCTAssertNil(note.line.text); XCTAssertEqual(note.line.state, .listening)
        XCTAssertEqual(note.line.revision, (answered.revision ?? 0) + 1); XCTAssertEqual(note.createdAt, 9)
    }

    /// Lean `captionTrace_keeps_answer`. An image-only jot gets its OCR result, the engine writes a
    /// line from it, then the caption for the same image is published. The answer stays on the line,
    /// `.answered`, with the revision raised so that a draft written before the caption is stale.
    /// (Before the fix the line ended `.listening` while still holding its text, and the Obsidian
    /// plugin, which never draws the text of a `.listening` line, stopped showing the answer.)
    func testImageResultKeepsAnAnsweredLineVisible() {
        var line = Line()
        imagePublish(&line, isImage: true, imageEvidenceEmpty: false) // OCR result with readable text
        XCTAssertEqual(line.state, .listening); XCTAssertEqual(line.revision, 1); XCTAssertTrue(wellFormed(line))
        XCTAssertTrue(line.apply(.line(bullet(sentences[0]), ["image"]), basis: "b", query: "", at: stamp))
        let answered = line
        imagePublish(&line, isImage: true, imageEvidenceEmpty: false) // caption for the same image
        XCTAssertEqual(line.state, .answered, "the answer is still shown")
        XCTAssertEqual(line.text, sentences[0])
        XCTAssertTrue(wellFormed(line), "wf_step")
        XCTAssertNil(line.queryText, "the line is marked for another look")
        XCTAssertEqual(line.revision, 3, "imagePublish_rev")
        // nothing else changed: imagePublish_not_owned
        var expected = answered; expected.revision = 3; expected.queryText = nil; expected.basis = nil
        XCTAssertEqual(line, expected)
        // the found marking only touches `.listening` lines, so it leaves the answer alone too
        var marked = line; markFound(&marked)
        XCTAssertEqual(marked, line)
        // the engine confirming the same sentence changes nothing visible
        var confirmed = line
        XCTAssertFalse(confirmed.apply(.line(bullet(sentences[0]), ["image"]), basis: "b2", query: "", at: stamp))
        XCTAssertEqual(confirmed.state, .answered); XCTAssertEqual(confirmed.text, sentences[0])
    }

    /// Lean `lateOcrTrace_keeps_answer`: the same for a jot with words and an image, when the OCR
    /// result lands after the engine answered from the transcript. On the real `Note` the line also
    /// goes back to "needs evidence", which is how the note is offered to the engine again.
    func testLateImageResultKeepsAnAnsweredLineVisible() {
        var note = Note(text: "pricing ![[slide.png]]", createdAt: 3)
        XCTAssertTrue(note.line.apply(.line(bullet(sentences[2]), ["s1"]), basis: "b", query: note.text, at: stamp))
        XCTAssertFalse(note.lineNeedsEvidence)
        let answered = note.line
        imagePublish(&note.line, isImage: false, imageEvidenceEmpty: false)
        XCTAssertEqual(note.line.state, .answered); XCTAssertEqual(note.line.text, sentences[2])
        XCTAssertTrue(wellFormed(note.line))
        XCTAssertEqual(note.line.revision, (answered.revision ?? 0) + 1)
        XCTAssertEqual(note.line.history, answered.history)
        // The basis is forgotten: that, not `queryText` alone, is what makes the engine take the jot up again.
        XCTAssertNil(note.line.basis); XCTAssertNotNil(answered.basis)
        XCTAssertTrue(note.lineNeedsEvidence)
    }

    /// Lean `imagePublish_not_owned`, first branch: an image-only note whose images carry no evidence
    /// has nothing to stand on, so a line that had an answer starts over (`reset()`): no text, no
    /// history, `.listening`, revision one higher. This is the one case where an image result
    /// removes an answer, and it does so consistently.
    func testImageOnlyNoteWithoutEvidenceStartsOver() {
        var line = Line()
        XCTAssertTrue(line.apply(.line(bullet(sentences[0]), ["image"]), basis: "b", query: "", at: stamp))
        imagePublish(&line, isImage: true, imageEvidenceEmpty: true)
        var expected = Line(); expected.revision = 2
        XCTAssertEqual(line, expected)
        XCTAssertTrue(wellFormed(line))
    }

    /// Lean `docImagesChanged_not_owned`, `docImagesChanged_bumps_rev`, `docImagesChanged_trace_bumps_rev`
    /// and `docImagesChanged_allows_previous_text`, on the real `NoteDocument.notes(previous:)`.
    /// The jot's text is unchanged; only the resolved path of its image changes. The answered line
    /// starts over: the text is cleared, the revision goes up by one, and the history is forgotten,
    /// so the engine can write the same sentence again. (Before the fix the revision stayed where it
    /// was and the cleared sentence was rejected for good as "already in the history".)
    func testDocumentImageSyncStartsTheLineOverAndRaisesTheRevision() {
        let source = "pricing tiers ![[slide.png]]"
        var note = Note(text: source, createdAt: 3); note.id = "a"
        note.images = [NoteImage(target: "slide.png")]
        let answer = Bullet(topic: "Pricing", text: "Team is twenty dollars a seat.", refs: [])
        XCTAssertTrue(note.line.apply(.line(answer, ["s1"]), basis: "b", query: note.text, at: stamp))
        let before = note.line
        let document = NoteDocument(path: "/tmp/formal.md", source: source, blocks: [
            .init(id: "a", from: 0, to: source.utf16.count, text: source, at: 3,
                  images: [NoteImage(target: "slide.png", path: "/tmp/slide.png")])])
        let synced = document.notes(previous: [note])
        XCTAssertEqual(synced.count, 1)
        var after = synced[0].line
        XCTAssertEqual(synced[0].queryRevision, note.queryRevision, "the jot itself was not edited")
        XCTAssertEqual(synced[0].images, [NoteImage(target: "slide.png", path: "/tmp/slide.png")])
        XCTAssertEqual(before.text, answer.markdown)
        XCTAssertNil(after.text); XCTAssertEqual(after.state, .listening)
        XCTAssertEqual(after.revision, (before.revision ?? 0) + 1, "text_change_bumps_rev: the text changed, so the revision rose")
        XCTAssertEqual(after.history, [], "the history is forgotten with the text")
        var reset = before; reset.reset()
        XCTAssertEqual(after, reset, "docImagesChanged_not_owned: exactly reset()")
        XCTAssertTrue(after.apply(.line(answer, ["s1"]), basis: "b2", query: source, at: stamp),
                      "docImagesChanged_allows_previous_text: the cleared sentence can be written again")
        XCTAssertEqual(after.text, answer.markdown); XCTAssertEqual(after.state, .answered)
        // A second sync with the same images changes nothing.
        XCTAssertEqual(document.notes(previous: synced), synced)
    }

    /// Lean `yours_docImagesChanged`, on the real `NoteDocument.notes(previous:)`: when the user owns
    /// the line, a changed image list only clears `queryText`. The text, the state and the revision
    /// stay.
    func testDocumentImageSyncLeavesAnOwnedLineAlone() {
        let source = "pricing tiers ![[slide.png]]"
        var note = Note(text: source, createdAt: 3); note.id = "a"
        note.images = [NoteImage(target: "slide.png")]
        note.editEnhancement(NoteEnhancementText(topic: "", text: "My own wording."))
        let before = note.line
        var block = NoteDocument.Block(id: "a", from: 0, to: source.utf16.count, text: source, at: 3,
                                       images: [NoteImage(target: "slide.png", path: "/tmp/slide.png")])
        block.owned = .init(from: 0, to: 0, text: "My own wording.")
        let synced = NoteDocument(path: "/tmp/formal.md", source: source, blocks: [block]).notes(previous: [note])
        var expected = before; expected.queryText = nil
        XCTAssertEqual(synced[0].line, expected)
        XCTAssertEqual(synced[0].line.state, .yours); XCTAssertEqual(synced[0].line.text, "My own wording.")
    }

    /// FINDING (limitation of the image fix), Lean `hidden_line_from_old_build_not_repaired`. The
    /// fix stops lines from being hidden; it does not un-hide one that already is. A `.listening`
    /// line that holds text, as the old publish path could save it, is decoded exactly as saved, and
    /// `recheck()`, another image result, the found marking and `resume()` all leave it hidden.
    /// `settle()` (Stop), `reset()` and an `apply` with `.unchanged` repair it.
    func testFindingALineHiddenByAnOlderBuildIsRepairedByStopButNotByRecheck() throws {
        var hidden = Line(); hidden.state = .listening; hidden.text = sentences[0]
        let loaded = try JSONDecoder().decode(Line.self, from: JSONEncoder().encode(hidden))
        XCTAssertEqual(loaded, hidden)
        XCTAssertFalse(wellFormed(loaded))
        var rechecked = loaded; rechecked.recheck()
        XCTAssertFalse(wellFormed(rechecked), "known limitation: recheck does not repair")
        var published = loaded; imagePublish(&published, isImage: false, imageEvidenceEmpty: false)
        XCTAssertFalse(wellFormed(published), "known limitation: an image result does not repair")
        var found = loaded; markFound(&found)
        XCTAssertEqual(found.state, .found); XCTAssertFalse(wellFormed(found))
        var resumed = loaded; resumed.resume()
        XCTAssertFalse(wellFormed(resumed))
        XCTAssertTrue(weaklyWellFormed(loaded), "weakWF covers such a line")
        var stopped = loaded; stopped.settle()
        XCTAssertEqual(stopped.state, .settled); XCTAssertTrue(wellFormed(stopped)) // wf_settle_any
        var next = loaded; next.apply(.unchanged, basis: "b", query: "", at: stamp)
        XCTAssertEqual(next.state, .answered); XCTAssertTrue(wellFormed(next))       // wf_apply_noline_any
        var reset = loaded; reset.reset()
        XCTAssertTrue(wellFormed(reset))                                             // wf_reset_any
    }

    /// FINDING (minor), Lean `image_result_after_stop`, `settle_then_recheck`,
    /// `imagePublish_stays_stopped_iff`: an image result that arrives after Stop puts a `.quiet` line
    /// back to `.listening`, and resets the `.settled` line of an image-only note that now has no
    /// evidence. A `.settled` line otherwise stays `.settled` with its text.
    func testFindingAnImageResultAfterStopUnsettlesALineWithoutText() {
        var quiet = Line(); quiet.settle()
        XCTAssertEqual(quiet.state, .quiet)
        imagePublish(&quiet, isImage: false, imageEvidenceEmpty: false)
        XCTAssertEqual(quiet.state, .listening, "known: a quiet line is listening again after Stop")
        var imageOnly = Line()
        XCTAssertTrue(imageOnly.apply(.line(bullet(sentences[0]), ["image"]), basis: "b", query: "", at: stamp))
        imageOnly.settle()
        imagePublish(&imageOnly, isImage: true, imageEvidenceEmpty: true)
        XCTAssertEqual(imageOnly.state, .listening); XCTAssertNil(imageOnly.text)
        var settled = Line()
        XCTAssertTrue(settled.apply(.line(bullet(sentences[0]), ["s1"]), basis: "b", query: "q", at: stamp))
        settled.settle()
        imagePublish(&settled, isImage: false, imageEvidenceEmpty: false)
        XCTAssertEqual(settled.state, .settled); XCTAssertEqual(settled.text, sentences[0])
    }

    /// FINDING (benign), Lean `reset_bumps_without_visible_change`: "revision increases exactly when
    /// the text changes or ownership is taken" is false, because `reset()` on an empty line also
    /// raises it.
    func testFindingResetRaisesRevisionWithoutAVisibleChange() {
        var line = Line(); line.reset()
        var expected = Line(); expected.revision = 1
        XCTAssertEqual(line, expected)
    }

    /// FINDING (minor), Lean `resume_erases_answer_marker`: the `.quiet` that MeetingNotes.swift:57
    /// gives a note made from an answer does not survive `resume()`.
    func testFindingResumeTurnsAnAnswerNotesMarkerIntoListening() {
        var fromAnswer = Line(); fromAnswer.state = .quiet
        XCTAssertTrue(wellFormed(fromAnswer), "wf_new")
        fromAnswer.resume()
        XCTAssertEqual(fromAnswer, Line())
    }

    // MARK: - 2. Auto-record policy (Formal/AutoRecord.lean)

    /// Drives the real policy with random traces. The four trace variables below are defined from
    /// the trace alone, the way the Lean theorems speak about it:
    /// `activeRunStart` / `absentRunStart` are the first sample of the current unbroken run
    /// (`ActiveSince` / `AbsentSince`), `latched` is "a `.start` was returned and nothing has
    /// released it" (`Releases`), `suppressed` is "suppressCurrentCall() and nothing has lifted it".
    /// `startDidNotBegin()` ends an active run and releases the latch unless the policy is
    /// suppressed, and leaves an absent run alone (`Event.KeepsAbsence`).
    func testAutoRecordOverRandomTraces() {
        var starts = 0, stops = 0, blockedWhileSuppressed = 0, blockedWhileLatched = 0
        var latchesReleasedByStartDidNotBegin = 0, startsAfterStartDidNotBegin = 0
        var ignoredWhileSuppressed = 0, stopsAcrossStartDidNotBegin = 0
        for seed in 0..<3000 {
            var rng = LCG(seed: UInt64(seed) &+ 10_000)
            var policy = AutoRecordPolicy()
            var now = 1_000.0, active = rng.bool()
            var activeRunStart: Double?, absentRunStart: Double?, latched = false, suppressed = false
            // Whether the open latch was opened by startDidNotBegin(), and whether one was called
            // during the current absent run.
            var reopened = false, absentRunSawStartDidNotBegin = false
            for index in 0..<80 {
                let at = "seed \(seed) step \(index)"
                let roll = rng.below(100)
                if roll < 5 {
                    policy.suppressCurrentCall()
                    suppressed = true; latched = false; activeRunStart = nil; absentRunStart = nil
                    reopened = false; absentRunSawStartDidNotBegin = false
                    continue
                }
                if roll < 7 {
                    policy.reset()
                    suppressed = false; latched = false; activeRunStart = nil; absentRunStart = nil
                    reopened = false; absentRunSawStartDidNotBegin = false
                    continue
                }
                if roll < 15 {
                    policy.startDidNotBegin()
                    if suppressed { ignoredWhileSuppressed += 1 } // startDidNotBegin_suppressed
                    else {
                        if latched { latchesReleasedByStartDidNotBegin += 1; reopened = true }
                        latched = false; activeRunStart = nil
                    }
                    if absentRunStart != nil { absentRunSawStartDidNotBegin = true }
                    continue
                }
                now += rng.pick([0, 0.25, 1, 2, 2, 2, 2.5, 3, 30, 59.5, 61, 119, 119.75, 120, 121]) // whole and fractional seconds
                if rng.below(4) == 0 { active.toggle() }
                let enabled = roll >= 17, busy = rng.below(4) == 0, automatic = rng.bool()
                let action = policy.update(callActive: active, enabled: enabled, busy: busy, automaticallyRecording: automatic,
                                           now: Date(timeIntervalSince1970: now))
                guard enabled else { // update_disabled: reset() and .none
                    XCTAssertEqual(action, .none, at)
                    suppressed = false; latched = false; activeRunStart = nil; absentRunStart = nil
                    reopened = false; absentRunSawStartDidNotBegin = false
                    continue
                }
                if active { absentRunStart = nil; absentRunSawStartDidNotBegin = false; activeRunStart = activeRunStart ?? now }
                else { activeRunStart = nil; absentRunStart = absentRunStart ?? now }
                // After a startDidNotBegin() the run starts again, so "settled" is "settled anew":
                // start_after_startDidNotBegin_settles_anew.
                let settled = active && now - activeRunStart! >= 3
                let graceElapsed = !active && now - absentRunStart! >= 120 // Lean `GraceElapsed`

                // (a) start_requires_settled_call
                if action == .start {
                    XCTAssertTrue(active && !busy && settled, at)
                    XCTAssertFalse(suppressed, at)
                }
                // (c) stop_requires_grace
                if action == .stop { XCTAssertTrue(!active && automatic && graceElapsed, at) }
                // (b) second_start_needs_release, (e)(i) stuck_latch
                if latched { XCTAssertNotEqual(action, .start, at); blockedWhileLatched += settled && !busy ? 1 : 0 }
                // (d) activity_never_lifts_suppression, (e)(ii) suppressed_until_long_absence
                if suppressed && !graceElapsed { XCTAssertEqual(action, .none, at); blockedWhileSuppressed += settled && !busy ? 1 : 0 }
                // start_iff / stop_iff: the action is exactly what the trace says it should be. With
                // `latched` false after a startDidNotBegin() this is also start_again_after_startDidNotBegin.
                let expected: AutoRecordPolicy.Action =
                    settled && !busy && !suppressed && !latched ? .start : (graceElapsed && automatic ? .stop : .none)
                XCTAssertEqual(action, expected, at)

                if action == .start {
                    latched = true; starts += 1
                    if reopened { startsAfterStartDidNotBegin += 1; reopened = false }
                }
                if action == .stop { stops += 1; if absentRunSawStartDidNotBegin { stopsAcrossStartDidNotBegin += 1 } }
                if graceElapsed { latched = false; suppressed = false; reopened = false }
            }
        }
        // Not vacuous: starts and stops happened, and both blocking rules actually blocked something.
        XCTAssertGreaterThan(starts, 500); XCTAssertGreaterThan(stops, 100)
        XCTAssertGreaterThan(blockedWhileSuppressed, 100); XCTAssertGreaterThan(blockedWhileLatched, 100)
        // startDidNotBegin() released closed latches, starts followed such a release, it was ignored
        // while suppressed, and absence runs that contained one still reached the grace period.
        XCTAssertGreaterThan(latchesReleasedByStartDidNotBegin, 100); XCTAssertGreaterThan(startsAfterStartDidNotBegin, 50)
        XCTAssertGreaterThan(ignoredWhileSuppressed, 100); XCTAssertGreaterThan(stopsAcrossStartDidNotBegin, 20)
    }

    /// One call into the policy, for the concrete traces (Lean `Event`, always with `enabled: true`).
    private enum Call {
        case sample(active: Bool, busy: Bool, automatic: Bool, at: Double)
        case suppress, startDidNotBegin
        static func active(_ at: Double, busy: Bool = false, automatic: Bool = false) -> Call { .sample(active: true, busy: busy, automatic: automatic, at: at) }
        static func absent(_ at: Double, busy: Bool = false, automatic: Bool = false) -> Call { .sample(active: false, busy: busy, automatic: automatic, at: at) }
    }
    private func actions(_ calls: [Call]) -> [AutoRecordPolicy.Action] {
        var policy = AutoRecordPolicy()
        return calls.map { call in
            switch call {
            case .suppress: policy.suppressCurrentCall(); return .none
            case .startDidNotBegin: policy.startDidNotBegin(); return .none
            case .sample(let active, let busy, let automatic, let at):
                return policy.update(callActive: active, enabled: true, busy: busy, automaticallyRecording: automatic,
                                     now: Date(timeIntervalSince1970: at))
            }
        }
    }

    /// The concrete traces proved in the `Checks` section of Formal/AutoRecord.lean, replayed on the
    /// real policy with the same expected actions.
    func testAutoRecordConcreteTracesMatchLean() {
        // 2-second polling of one call
        XCTAssertEqual(actions([.active(0), .active(2), .active(4), .active(6, automatic: true)]), [.none, .none, .start, .none])
        // a mute gap of 118 s does not stop an automatic recording; 120 s does
        XCTAssertEqual(actions([.absent(100, busy: true, automatic: true), .absent(218, busy: true, automatic: true),
                                .active(219, busy: true, automatic: true), .absent(220, busy: true, automatic: true),
                                .absent(340, busy: true, automatic: true)]), [.none, .none, .none, .none, .stop])
        // manual stop, then 130 s of absence: the next call is recorded
        XCTAssertEqual(actions([.active(0), .active(4), .suppress, .absent(1802), .absent(1932), .active(1934), .active(1938)]),
                       [.none, .start, .none, .none, .none, .none, .start])
        // startDidNotBegin() does not interrupt an absence run
        XCTAssertEqual(actions([.absent(100, busy: true, automatic: true), .startDidNotBegin, .absent(220, busy: true, automatic: true)]),
                       [.none, .none, .stop])
        // with startDidNotBegin() after every attempt, one call gets a start every time it has settled again
        XCTAssertEqual(actions([.active(0), .active(4), .startDidNotBegin, .active(6), .active(10), .startDidNotBegin,
                                .active(12), .active(16)]), [.none, .start, .none, .none, .start, .none, .none, .start])
    }

    /// Lean `stuck_latch` and `stuck_latch_released`. Under `update` alone the latch sticks: `.start`
    /// is returned at t = 4, no recording begins (not busy, not automatically recording), the call
    /// stays active for two hours, and the policy never asks again. `startDidNotBegin()` is the way
    /// out: after it the call has to settle anew (seen at 8, not yet settled at 10) and is then asked
    /// for again (at 12).
    func testStartLatchSticksUnderUpdateAloneAndStartDidNotBeginReleasesIt() {
        // stuck_latch: update alone
        XCTAssertEqual(actions([.active(0), .active(4), .active(6), .active(600), .active(7200)]),
                       [.none, .start, .none, .none, .none])
        // stuck_latch_released / start_again_after_startDidNotBegin
        XCTAssertEqual(actions([.active(0), .active(4), .active(6), .startDidNotBegin, .active(8), .active(10), .active(12)]),
                       [.none, .start, .none, .none, .none, .none, .start])
        // start_after_startDidNotBegin_settles_anew: the two hours before the release do not count
        XCTAssertEqual(actions([.active(0), .active(4), .active(7200), .startDidNotBegin, .active(7201), .active(7203.5),
                                .active(7204)]), [.none, .start, .none, .none, .none, .none, .start])
        // a busy sample at the settle point does not start; the next free one does
        XCTAssertEqual(actions([.active(0), .active(4), .startDidNotBegin, .active(8), .active(12, busy: true), .active(14)]),
                       [.none, .start, .none, .none, .none, .start])
        // startDidNotBegin() before any start, and twice in a row, changes nothing else
        XCTAssertEqual(actions([.startDidNotBegin, .active(0), .active(4), .startDidNotBegin, .startDidNotBegin, .active(6), .active(9)]),
                       [.none, .none, .start, .none, .none, .none, .start])
    }

    /// FINDING (e)(ii), Lean `suppressed_until_long_absence`: call A is stopped by hand at t = 1800;
    /// A ends, and 60 seconds later call B begins and runs for two hours. B is never recorded.
    /// `startDidNotBegin()` does not change this: it is ignored while the policy is suppressed.
    func testFindingACallStartingWithinTheGraceAfterAManualStopIsNeverRecorded() {
        XCTAssertEqual(actions([.active(0), .active(4), .suppress, .absent(1802), .absent(1860), .active(1862), .active(1866),
                                .active(5000), .active(9062)]),
                       [.none, .start, .none, .none, .none, .none, .none, .none, .none])
        XCTAssertEqual(actions([.active(0), .active(4), .suppress, .startDidNotBegin, .absent(1802), .absent(1860), .active(1862),
                                .startDidNotBegin, .active(1866), .active(5000), .active(9062)]),
                       [.none, .start, .none, .none, .none, .none, .none, .none, .none, .none, .none])
    }

    // MARK: - 3. Audio backlog (Formal/Backlog.lean)

    private struct CaptureFailed: Error {}

    /// Runs the real `AudioBacklog` next to the Lean model (`Formal/Backlog.lean`, transcribed
    /// below as five local variables) and checks after every call that they agree and that the
    /// model satisfies the proved invariant.
    func testAudioBacklogAccountingOverRandomSequences() async throws {
        // XCTest ends the whole process when an async test stops at its first failure
        // (`continueAfterFailure = false`), so this test records failures through `expect` and
        // leaves by hand after the first failing step.
        continueAfterFailure = true
        var failed = false
        func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
            if !condition { failed = true; XCTFail(message(), line: line) }
        }
        // Position-dependent bytes, so a reordered or duplicated slice cannot go unnoticed.
        var filler = LCG(seed: 99)
        let pattern = Data((0..<262_144).map { _ in UInt8(truncatingIfNeeded: filler.next()) })
        var offset = 0
        var splits = 0, overflows = 0, clamped = 0
        for seed in 0..<2000 {
            var rng = LCG(seed: UInt64(seed) &+ 20_000)
            let seconds = rng.pick([-3, 0, 1, 2, 2, 3, 3, 4])
            let backlog = AudioBacklog(seconds: seconds)
            let capacity = max(1, seconds) * 32_000                                  // AudioBacklog.init
            var chunks: [Data] = [], pending = 0, inFlight = 0, closed = false, failure = false
            var accepted = Data(), delivered = Data(), discarded = false
            for index in 0..<30 {
                let at = "seed \(seed) step \(index)"
                switch rng.below(12) {
                case 0...4: // append
                    let size = rng.pick([0, 1, 640, 640, 6_400, 31_999, 32_000, 32_001, 40_000, 70_000])
                    if offset + size > pattern.count { offset = 0 }
                    let data = pattern.subdata(in: offset..<offset + size); offset += size
                    var outcome = "ok"
                    do { try backlog.append(data) } catch is AudioBacklog.Overflow { outcome = "overflow" } catch { outcome = "closed" }
                    let before = pending
                    if closed { expect(outcome == "closed", "append_closed \(at): \(outcome)") }
                    else if !(size <= capacity - pending) { expect(outcome == "overflow", "append \(at): \(outcome)"); overflows += 1 }
                    else { expect(outcome == "ok", "append \(at): \(outcome)"); chunks.append(data); pending += size; accepted.append(data) }
                    // append_rejects_or_keeps_bound
                    expect(outcome == "ok" ? pending == before + size && pending <= capacity : pending == before,
                           "append_rejects_or_keeps_bound \(at)")
                case 5...7: // next, only where the real method returns instead of sleeping
                    guard !chunks.isEmpty || failure || closed else { continue }
                    if !chunks.isEmpty { // next_drains_first
                        guard let data = try await backlog.next() else { return XCTFail("next returned nil with audio queued \(at)") }
                        var expected = chunks.removeFirst()
                        if expected.count > 32_000 { // next_splits
                            chunks.insert(Data(expected.dropFirst(32_000)), at: 0); expected = Data(expected.prefix(32_000)); splits += 1
                        }
                        inFlight += expected.count
                        expect(data == expected && data.count <= 32_000, "next_preserves_bytes \(at)")
                        delivered.append(data)
                    } else if failure {
                        do { _ = try await backlog.next(); expect(false, "the failure must surface \(at)") }
                        catch { expect(error is CaptureFailed, "wrong error \(at): \(error)") }
                    } else {
                        let end = try await backlog.next()
                        expect(end == nil, "closed and empty must end \(at)")
                    }
                case 8, 9: // acknowledge with any argument
                    let count = rng.pick([Int.min, -5, 0, 1, 640, inFlight, inFlight + 7, 32_000, Int.max])
                    backlog.acknowledge(count)
                    let acknowledged = min(max(0, count), inFlight)
                    if acknowledged != count { clamped += 1 }
                    expect(0 <= acknowledged && acknowledged <= inFlight, "acknowledge_clamped \(at)")
                    inFlight -= acknowledged; pending -= acknowledged
                case 10: // finish, with or without an error
                    failure = rng.bool()
                    if failure { backlog.finish(throwing: CaptureFailed()) } else { backlog.finish() }
                    closed = true
                default: // discard (rare), then a late acknowledge: acknowledge_after_discard
                    guard rng.below(3) == 0 else { continue }
                    backlog.discard()
                    chunks = []; pending = 0; inFlight = 0; closed = true; discarded = true
                    backlog.acknowledge(rng.pick([-1, 640, 32_000]))
                }
                // Lean `accounting`: pending = queued + inFlight, 0 ≤ inFlight ≤ pending ≤ capacity
                expect(pending == chunks.reduce(0) { $0 + $1.count } + inFlight, "accounting (sum) \(at)")
                expect(0 <= inFlight && inFlight <= pending && pending <= capacity, "accounting (bounds) \(at)")
                // the real counter agrees with the model
                expect(backlog.pendingSeconds == Double(pending) / 32_000,
                       "real pending \(backlog.pendingSeconds * 32_000) vs model \(pending) \(at)")
                if failed { return }
            }
            // Lean `delivered_then_queued`: without discard, handed out ++ still queued == accepted.
            if !discarded {
                expect(delivered + chunks.reduce(Data(), +) == accepted, "delivered_then_queued seed \(seed)")
                backlog.finish() // clears any failure, so the drain ends with nil
                while let data = try await backlog.next() { delivered.append(data); expect(data.count <= 32_000, "chunk size seed \(seed)") }
                expect(delivered == accepted, "delivered_then_queued, drained, seed \(seed)")
            }
            if failed { return }
        }
        // Not vacuous: splits, overflows and clamped acknowledgements all happened.
        expect(splits > 200 && overflows > 200 && clamped > 200, "coverage: \(splits) splits, \(overflows) overflows, \(clamped) clamped")
    }

    // MARK: - 4. Small machines (Formal/Small.lean)

    /// Lean `RecordingPressure.ofLag_mono`, on real `Double`s (finite, infinite, negative, fractional).
    func testRecordingPressureIsMonotoneInLag() {
        var rng = LCG(seed: 30_000)
        let fixed: [Double] = [-.infinity, -1, 0, 1.999, 2, 2.001, 5.999, 6, 6.001, 11.999, 12, 12.001, 30, .infinity]
        var lags = fixed
        for _ in 0..<3000 { lags.append(Double(rng.below(16_000)) / 1000 - 1) }
        lags.sort()
        for (a, b) in zip(lags, lags.dropFirst()) {
            XCTAssertLessThanOrEqual(RecordingPressure(lag: a), RecordingPressure(lag: b), "ofLag_mono \(a) \(b)")
        }
        XCTAssertEqual(fixed.map { RecordingPressure(lag: $0) },
                       [.normal, .normal, .normal, .normal, .screenPaused, .screenPaused, .screenPaused, .aiPaused, .aiPaused,
                        .aiPaused, .transcriptDelayed, .transcriptDelayed, .transcriptDelayed, .transcriptDelayed])
        XCTAssertEqual(RecordingPressure(lag: .nan), .normal) // every comparison with NaN is false
    }

    func testResumeOverRandomMeetings() {
        var resumed = 0, refused = 0
        for seed in 0..<3000 {
            var rng = LCG(seed: UInt64(seed) &+ 40_000)
            var meeting = Meeting(title: "Formal")
            meeting.startedAt = Date(timeIntervalSince1970: 1_000)
            let ended: Double? = rng.below(8) == 0 ? nil : 1_000 + Double(rng.pick([0, 60, 3_600]))
            meeting.endedAt = ended.map { Date(timeIntervalSince1970: $0) }
            meeting.status = rng.pick(["complete", "complete", "interrupted", "recording", "finalizing", "failed"])
            meeting.retention = rng.pick([nil, nil, "live", "finalized", "purged", "purging"])
            if rng.below(4) == 0 { meeting.document = NoteDocument(path: "/tmp/formal.md", source: "", finalized: rng.below(3) == 0) }
            meeting.purgeAt = Date(timeIntervalSince1970: 90_000); meeting.failure = rng.bool() ? "earlier failure" : nil
            if rng.bool() {
                meeting.recordingSessions = [RecordingSession(id: "initial", start: 0, end: 30)]
                if rng.bool() { meeting.recordingSessions?.append(RecordingSession(start: 40, end: 60)) }
            }
            meeting.notes = (0..<rng.below(4)).map { _ in
                var note = Note(text: "trial length", createdAt: 1)
                for _ in 0..<rng.below(6) {
                    perform(randomLineOp(&rng, line: note.line, ownedSetter: false, bareTakeOwnership: false), on: &note)
                }
                return note
            }
            let now = (ended ?? 2_000) + Double(rng.pick([-1, 0, 1, 300, 599, 600, 601, 5_000]))
            let at = "seed \(seed)"
            // canResume_iff
            let allowed = ended != nil && now >= ended! && now - ended! < 600 && meeting.retention != "purged"
                && meeting.retention != "purging" && meeting.document?.finalized != true
                && (meeting.status == "complete" || meeting.status == "interrupted")
            XCTAssertEqual(meeting.canResume(at: Date(timeIntervalSince1970: now)), allowed, "canResume_iff \(at)")
            var next = meeting
            // resume_isSome_iff
            guard (try? next.resume(at: Date(timeIntervalSince1970: now))) != nil else {
                XCTAssertFalse(allowed, "resume_isSome_iff \(at)"); refused += 1
                XCTAssertEqual(next.status, meeting.status); XCTAssertEqual(next.endedAt, meeting.endedAt)
                XCTAssertEqual(next.recordingSessions, meeting.recordingSessions); XCTAssertEqual(next.notes, meeting.notes)
                continue
            }
            XCTAssertTrue(allowed, "resume_isSome_iff \(at)"); resumed += 1
            // resume_then_cannot_resume
            for later in [now, now + 1, ended! + 1, 1e9] { XCTAssertFalse(next.canResume(at: Date(timeIntervalSince1970: later)), at) }
            XCTAssertThrowsError(try next.resume(at: Date(timeIntervalSince1970: now + 1)), at)
            // resume_status
            XCTAssertEqual(next.status, "recording", at); XCTAssertEqual(next.retention, "live", at)
            XCTAssertNil(next.endedAt, at); XCTAssertNil(next.purgeAt, at); XCTAssertNil(next.failure, at)
            // resume_sessions
            let sessions = next.recordingSessions ?? []
            XCTAssertEqual(sessions.count, (meeting.recordingSessions?.count ?? 1) + 1, "resume_sessions \(at)")
            if let earlier = meeting.recordingSessions { XCTAssertEqual(Array(sessions.dropLast()), earlier, at) }
            else {
                XCTAssertEqual(sessions.first?.id, "initial", at); XCTAssertEqual(sessions.first?.start, 0, at)
                XCTAssertEqual(sessions.first?.end, ended! - 1_000, at)
            }
            XCTAssertEqual(sessions.last?.start, now - 1_000, at); XCTAssertNil(sessions.last?.end, at)
            XCTAssertNotEqual(sessions.last?.id, "initial", at)
            // resume_lines
            XCTAssertEqual(next.notes?.count, meeting.notes?.count, at)
            for (old, new) in zip(meeting.notes ?? [], next.notes ?? []) {
                var expected = old; expected.line.resume()
                XCTAssertEqual(new, expected, "resume_lines \(at)")
                XCTAssertTrue(new.line.state != .settled && new.line.state != .quiet, "resume_lines \(at)")
            }
        }
        XCTAssertGreaterThan(resumed, 200); XCTAssertGreaterThan(refused, 1000)
    }

    func testTitlePolicyNeverReplacesAManualOrFinalTitle() {
        var allowed = 0
        var rng = LCG(seed: 50_000)
        for index in 0..<3000 {
            var meeting = Meeting(title: "Recording", titleOrigin: "pending")
            meeting.titleOrigin = rng.pick(["pending", "pending", "automatic", "automatic", "manual", "imported", nil])
            meeting.titleFinal = rng.pick([nil, nil, false, true])
            let words = rng.pick([0, 5, 6, 7, 44, 45, 46, 200]), final = rng.bool()
            meeting.segments = words == 0 ? [] : [Segment(source: "system", speaker: "1", start: 0, end: 5,
                                                          text: Array(repeating: "word", count: words).joined(separator: " "))]
            let result = TitlePolicy.canGenerate(meeting, final: final)
            let origin = meeting.titleOrigin
            // the Lean definition `TitlePolicy.canGenerate`, line for line
            let model: Bool
            if !(origin == "pending" || origin == "automatic") { model = false }
            else if meeting.titleFinal == true { model = false }
            else if !final && origin == "automatic" { model = false }
            else { model = words >= (final ? 6 : 45) }
            XCTAssertEqual(result, model, "canGenerate \(index)")
            if result { // canGenerate_requires
                XCTAssertTrue(origin == "pending" || origin == "automatic", "\(index)"); XCTAssertNotEqual(meeting.titleFinal, true, "\(index)")
                allowed += 1
            }
            if origin == "manual" || origin == nil { XCTAssertFalse(result, "canGenerate_manual / canGenerate_legacy \(index)") }
            if meeting.titleFinal == true { XCTAssertFalse(result, "canGenerate_final_title \(index)") }
            if origin == "automatic" && !final { XCTAssertFalse(result, "canGenerate_live_keeps_automatic \(index)") }
        }
        XCTAssertGreaterThan(allowed, 200)
    }
}
