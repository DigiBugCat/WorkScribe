/-
  AI line lifecycle.

  Swift sources transcribed here (worktree `WorkScribe-codex`, branch `codex-backend`, working
  tree of 2026-11-11, which is commit edcaeba plus uncommitted changes):
    Sources/WorkScribeCore/Engine/Line.swift            lines 4-50, 52-61, 81-83
    Sources/WorkScribeCore/Notes.swift                  lines 5-32
    Sources/WorkScribe/MeetingNotes.swift               lines 55-57 and 267-270
    Sources/WorkScribe/NoteImageUnderstanding.swift     the `publish` function in `readNoteImages`,
                                                        lines 108-126; the line is written on 116-122
    Sources/WorkScribeCore/NoteDocument.swift           lines 69-75
  The two files under `Sources/WorkScribe` were being edited by others while this was written;
  their line numbers are the ones seen then. `FormalConformanceTests.swift` holds the same
  statements as text and fails (`testTranscribedCodeStillMatchesTheSource`) when they change.

  Everything below is a re-implementation in Lean. A theorem here is a statement about these
  definitions; it says something about the app only as far as each definition matches the Swift
  it names. `README.md` lists every abstraction.

  History. The first version of this file proved that two of these places broke invariants the
  rest of the code relies on. Both were then changed in the Swift, and the definitions and
  theorems below describe the changed code:
    * the image publish wrote `state = .listening` over a line that still had text, so an answer
      on screen disappeared. It now calls the new `Line.recheck()` (Line.swift:27-31);
    * the NoteDocument image path cleared the text without raising the revision and kept the
      history, so the cleared sentence could never be written again. It now calls `reset()`.
  The old behaviour of both is kept at the end of the file as `Broken.imagePublish` and
  `Broken.docImagesChanged`, with examples showing which theorem each one violates.
-/

set_option linter.unusedSectionVars false

namespace WorkScribe

/-- Line.swift:5  `enum State { case listening, found, answered, settled, quiet, yours }` -/
inductive LineState where
  | listening | found | answered | settled | quiet | yours
  deriving DecidableEq, Repr

/-- Line.swift:45  the two string literals passed as `reason:`
    ("First matching discussion" / "New evidence"). -/
inductive Reason where
  | firstMatch | newEvidence
  deriving DecidableEq, Repr

/-- Line.swift:52-61  `struct LineRevision`. `at: Date` is the field `time` (a `Nat`; never compared). -/
structure LineRevision (Text : Type) where
  version : Int
  text : Text
  reason : Reason
  time : Nat
  evidence : List Text
  deriving DecidableEq, Repr

/-- Line.swift:4-16  `struct Line`, every stored property, with the Swift defaults.
    `String` is the abstract type `Text`; `Date` is `Nat`; `Int`/`Int64` are unbounded `Int`. -/
structure Line (Text : Type) where
  state : LineState := .listening
  text : Option Text := none
  queryText : Option Text := none
  revision : Option Int := some 0
  evidence : Option (List Text) := none
  basis : Option Text := none
  seenThrough : Int := 0
  attemptedEvidence : Option (List Text) := none
  updatedAt : Option Nat := none
  history : List (LineRevision Text) := []
  deriving DecidableEq, Repr

/-- Line.swift:81-83  `enum LineOutcome { case line(Bullet, [String]), unchanged, quiet(LineRejection) }`.
    `apply` reads only `bullet.markdown` from the bullet and never reads the rejection, so the
    bullet is its markdown and `.quiet` carries no payload. -/
inductive LineOutcome (Text : Type) where
  | line (markdown : Text) (ids : List Text)
  | unchanged
  | quiet
  deriving DecidableEq, Repr

namespace Line

variable {Text : Type} [DecidableEq Text]

/-- The expression `revision ?? 0`, which Line.swift writes inline at lines 21, 22 and 43. -/
def rev (l : Line Text) : Int := l.revision.getD 0

/-- Line.swift:18  `get { state == .yours }` (declared `Bool?`, never nil). -/
def owned (l : Line Text) : Bool := l.state == .yours

/-- Line.swift:22
    `mutating func takeOwnership() { state = .yours; revision = (revision ?? 0) + 1 }` -/
def takeOwnership (l : Line Text) : Line Text :=
  { l with state := .yours, revision := some (l.rev + 1) }

/-- Line.swift:21
    `mutating func reset() { guard state != .yours else { return }; let next = (revision ?? 0) + 1; self = Line(); revision = next }` -/
def reset (l : Line Text) : Line Text :=
  if l.state = .yours then l
  else
    let next := l.rev + 1
    { ({} : Line Text) with revision := some next }

/-- Line.swift:19  the `owned` setter:
    `set { if newValue == true { takeOwnership() } else if state == .yours { state = text == nil ? .listening : .answered } }` -/
def setOwned (l : Line Text) (newValue : Option Bool) : Line Text :=
  if newValue = some true then l.takeOwnership
  else if l.state = .yours then { l with state := if l.text = none then .listening else .answered }
  else l

/-- Line.swift:23
    `mutating func resume() { if state == .settled || state == .quiet { state = text == nil ? .listening : .answered } }` -/
def resume (l : Line Text) : Line Text :=
  if l.state = .settled ∨ l.state = .quiet then
    { l with state := if l.text = none then .listening else .answered }
  else l

/-- Line.swift:27-31
    ```
    mutating func recheck() {
        guard state != .yours else { return }
        queryText = nil; basis = nil
        if text == nil { state = .listening }
    }
    ```
    The statements after the guard are one record update: `queryText` and `basis` are cleared (the
    engine takes a jot up again only when its basis is gone), and the state becomes `.listening`
    when there is no text and is left alone when there is. -/
def recheck (l : Line Text) : Line Text :=
  if l.state = .yours then l
  else { l with queryText := none, basis := none, state := if l.text = none then .listening else l.state }

/-- Line.swift:32
    `mutating func settle() { guard state != .yours else { return }; state = text == nil ? .quiet : .settled }` -/
def settle (l : Line Text) : Line Text :=
  if l.state = .yours then l
  else { l with state := if l.text = none then .quiet else .settled }

/-- Line.swift:33-36  `retract(remaining:jot:)`.
    `remainingEmpty` is `remaining.isEmpty`; `grounded` is the result of
    `LineFaithfulness.grounded(NoteEnhancementText(markdown: text).text, evidence: remaining, jot: jot)`. -/
def retract (l : Line Text) (remainingEmpty grounded : Bool) : Line Text :=
  if l.state = .yours ∨ l.text = none then l
  else if remainingEmpty || !grounded then l.reset
  else l

/-- Line.swift:37-49  `apply(_:basis:query:at:)`. Returns the new line and the `Bool` result. -/
def apply (l : Line Text) (outcome : LineOutcome Text) (basis query : Text) (time : Nat) :
    Line Text × Bool :=
  -- guard state != .yours else { return false }
  if l.state = .yours then (l, false)
  else
    -- self.basis = basis
    let l := { l with basis := some basis }
    match outcome with
    | .line markdown ids =>
      -- guard text != bullet.markdown, !history.contains(where: { $0.text == bullet.markdown }) else { return false }
      if l.text = some markdown ∨ l.history.any (fun r => r.text == markdown) = true then (l, false)
      else
        -- revision = (revision ?? 0) + 1; text = bullet.markdown; evidence = ids; queryText = query
        -- state = .answered; updatedAt = at
        -- history.append(LineRevision(version: revision ?? 1, text: bullet.markdown,
        --     reason: history.isEmpty ? "First matching discussion" : "New evidence", at: at, evidence: ids))
        let revision := l.rev + 1
        ({ l with
            revision := some revision, text := some markdown, evidence := some ids,
            queryText := some query, state := .answered, updatedAt := some time,
            history := l.history ++
              [{ version := revision, text := markdown,
                 reason := if l.history.isEmpty then .firstMatch else .newEvidence,
                 time := time, evidence := ids }] }, true)
    -- case .quiet, .unchanged: state = text == nil ? .listening : .answered; return false
    | .unchanged | .quiet =>
      ({ l with state := if l.text = none then .listening else .answered }, false)

/-- MeetingNotes.swift:267-270  the engine marks a targeted jot that has no outcome yet:
    `if let i = …firstIndex(where: { … && $0.line.state == .listening }) { meeting.notes![i].line.state = .found }`.
    The id and `queryRevision` parts of the predicate select which note; when they do not match
    nothing is written, which is the identity and needs no operation of its own. -/
def markFound (l : Line Text) : Line Text :=
  if l.state = .listening then { l with state := .found } else l

/-- NoteImageUnderstanding.swift:116-122, inside `publish`  one image result (OCR text, or later
    the caption) is published into a note. `isImage` is `meeting.notes![i].isImage` and
    `imageEvidenceEmpty` is `meeting.notes![i].imageEvidence.isEmpty`, both read after the new
    result was stored on line 114. The line is changed on a copy and written back on line 122.
    ```
    var line = meeting.notes![i].line
    if line.owned == true { line.revision = (line.revision ?? 0) + 1 }
    else if meeting.notes![i].isImage && meeting.notes![i].imageEvidence.isEmpty { line.reset() }
    else { line.revision = (line.revision ?? 0) + 1; line.recheck() }
    meeting.notes![i].line = line
    ``` -/
def imagePublish (l : Line Text) (isImage imageEvidenceEmpty : Bool) : Line Text :=
  -- if line.owned == true { line.revision = (line.revision ?? 0) + 1 }
  if l.owned = true then { l with revision := some (l.rev + 1) }
  -- else if isImage && imageEvidence.isEmpty { line.reset() }
  else if (isImage && imageEvidenceEmpty) = true then l.reset
  -- else { line.revision = (line.revision ?? 0) + 1; line.recheck() }
  else ({ l with revision := some (l.rev + 1) } : Line Text).recheck

/-- NoteDocument.swift:69-75, the body of `if (n.images ?? []) != images`  a document sync found
    that the note's image list changed (line 74 is the only write to the line).
    ```
    if n.line.owned == true { n.line.queryText = nil } else { n.line.reset() }
    ``` -/
def docImagesChanged (l : Line Text) : Line Text :=
  if l.owned = true then { l with queryText := none } else l.reset

end Line

/-- Notes.swift:5-15  the stored properties of `struct Note` that the modelled methods read or
    write. `fromAnswer` is `fromAnswer != nil`. `createdAt: Double?` is `Option Nat`. -/
structure Note (Text : Type) where
  text : Text
  createdAt : Option Nat
  line : Line Text := {}
  queryRevision : Int := 0
  fromAnswer : Bool := false
  deriving DecidableEq, Repr

namespace Note

variable {Text : Type} [DecidableEq Text]

/-- Notes.swift:18-20  the minor/major rule of `editText`:
    `let major = difference > 1 && Double(difference) / Double(max(1, old.union(new).count)) > 0.3`.
    `difference` is the size of the symmetric difference of the old and new token sets, `union`
    the size of their union. The `Double` comparison `d / u > 0.3` is written as the exact
    rational comparison `10 * d > 3 * u` (see README, "Line" abstractions). -/
def isMajorEdit (difference union : Nat) : Bool :=
  decide (difference > 1) && decide (10 * difference > 3 * max 1 union)

/-- Notes.swift:17-24  `editText(_:at:)`. `major` is the value computed on lines 18-20.
    ```
    self.text = text; queryRevision += 1
    if major { line.reset(); createdAt = at }
    line.basis = nil
    ``` -/
def editText (n : Note Text) (text : Text) (major : Bool) (time : Option Nat) : Note Text :=
  let n := { n with text := text, queryRevision := n.queryRevision + 1 }
  let n := if major = true then { n with line := n.line.reset, createdAt := time } else n
  { n with line := { n.line with basis := none } }

/-- Notes.swift:25-27  `editEnhancement(_:)`; `markdown` is `value.markdown`.
    `line.text = value.markdown; line.queryText = text; line.takeOwnership()` -/
def editEnhancement (n : Note Text) (markdown : Text) : Note Text :=
  { n with line := ({ n.line with text := some markdown, queryText := some n.text }).takeOwnership }

/-- Notes.swift:31
    `mutating func letAIRewrite() { let next = (line.revision ?? 0) + 1; line = Line(); line.revision = next; queryRevision += 1 }` -/
def letAIRewrite (n : Note Text) : Note Text :=
  let next := n.line.rev + 1
  { n with line := { ({} : Line Text) with revision := some next }, queryRevision := n.queryRevision + 1 }

/-- Notes.swift:28-30 `init(text:createdAt:)` followed by MeetingNotes.swift:56-57:
    ```
    var note = Note(text: text, createdAt: when)
    note.fromAnswer = fromAnswer
    note.line.state = fromAnswer == nil ? .listening : .quiet
    ```
    With `fromAnswer = false` this is exactly `Note(text:createdAt:)`. -/
def new (text : Text) (createdAt : Option Nat) (fromAnswer : Bool) : Note Text :=
  { text := text, createdAt := createdAt, fromAnswer := fromAnswer,
    line := { ({} : Line Text) with state := if fromAnswer = true then .quiet else .listening } }

end Note

/-- Every modelled way a note's line is written after the note exists (fourteen operations). -/
inductive Op (Text : Type) where
  -- `Line` methods, Line.swift:19-49
  | reset
  | takeOwnership
  | resume
  | recheck
  | settle
  | retract (remainingEmpty grounded : Bool)
  | apply (outcome : LineOutcome Text) (basis query : Text) (time : Nat)
  | setOwned (newValue : Option Bool)
  -- `Note` methods, Notes.swift:17-31
  | editText (text : Text) (major : Bool) (time : Option Nat)
  | editEnhancement (markdown : Text)
  | letAIRewrite
  -- direct writes from outside `Line`
  | markFound
  | imagePublish (isImage imageEvidenceEmpty : Bool)
  | docImagesChanged
  deriving DecidableEq, Repr

namespace Op

variable {Text : Type}

/-- The `Line` methods that are not the user's own act, named in property (a): reset, resume,
    recheck, settle, retract, apply. The app calls them from the engine and from the image path. -/
def isEngine : Op Text → Bool
  | .reset | .resume | .recheck | .settle | .retract _ _ | .apply _ _ _ _ => true
  | _ => false

/-- The `owned` setter. Nothing in `Sources/` calls it (the getter is read in many places). -/
def isSetOwned : Op Text → Bool
  | .setOwned _ => true
  | _ => false

/-- The eight `Line` methods (Line.swift:19-49), as opposed to `Note` methods and outside writes. -/
def isLineMethod : Op Text → Bool
  | .reset | .takeOwnership | .resume | .recheck | .settle | .retract _ _ | .apply _ _ _ _
  | .setOwned _ => true
  | _ => false

end Op

namespace Note

variable {Text : Type} [DecidableEq Text]

/-- One operation applied to a note. -/
def step (n : Note Text) : Op Text → Note Text
  | .reset => { n with line := n.line.reset }
  | .takeOwnership => { n with line := n.line.takeOwnership }
  | .resume => { n with line := n.line.resume }
  | .recheck => { n with line := n.line.recheck }
  | .settle => { n with line := n.line.settle }
  | .retract e g => { n with line := n.line.retract e g }
  | .apply o b q t => { n with line := (n.line.apply o b q t).1 }
  | .setOwned v => { n with line := n.line.setOwned v }
  | .editText text major time => n.editText text major time
  | .editEnhancement markdown => n.editEnhancement markdown
  | .letAIRewrite => n.letAIRewrite
  | .markFound => { n with line := n.line.markFound }
  | .imagePublish i e => { n with line := n.line.imagePublish i e }
  | .docImagesChanged => { n with line := n.line.docImagesChanged }

/-- A sequence of operations, applied left to right. -/
def run (n : Note Text) (ops : List (Op Text)) : Note Text := ops.foldl step n

@[simp] theorem run_nil (n : Note Text) : n.run [] = n := rfl
@[simp] theorem run_cons (n : Note Text) (op : Op Text) (ops : List (Op Text)) :
    n.run (op :: ops) = (n.step op).run ops := rfl
theorem run_append (n : Note Text) (a b : List (Op Text)) : n.run (a ++ b) = (n.run a).run b := by
  simp [run, List.foldl_append]

end Note


/-! # Theorems

Proof method: almost every statement is a finite case analysis (operation × state × text
present or absent). `line_cases` / `note_cases` split a line or note into those cases, unfold
every operation and let `simp`, `omega` and `grind` close each case. -/

section Tactics

/-- Unfold every modelled operation. -/
macro "line_unfold" : tactic => `(tactic|
  simp only [Note.step, Note.editText, Note.editEnhancement, Note.letAIRewrite, Note.new, Line.reset,
    Line.takeOwnership, Line.resume, Line.recheck, Line.settle, Line.retract, Line.apply, Line.setOwned,
    Line.markFound, Line.imagePublish, Line.docImagesChanged, Line.rev, Line.owned,
    Op.isEngine, Op.isSetOwned, Op.isLineMethod] at *)

/-- Simplify, pushing field projections through `if`. -/
macro "line_simp" : tactic => `(tactic|
  simp_all [apply_ite Line.state, apply_ite Line.text, apply_ite Line.revision, apply_ite Line.history,
    apply_ite Note.line, apply_ite Prod.fst, apply_ite Prod.snd])

macro "line_auto" : tactic => `(tactic|
  (line_unfold <;> (try line_simp) <;> (repeat' split) <;> (try line_simp) <;> (try omega) <;> (try grind)))

/-- Case split a line on state × text present/absent, then `line_auto`. -/
macro "line_cases" l:ident : tactic => `(tactic|
  (obtain ⟨state, txt, qt, revision, ev, basis, st, ae, ua, hist⟩ := $l
   cases state <;> cases txt <;> line_auto))

/-- Case split a note's line on state × text present/absent, then `line_auto`. -/
macro "note_cases" n:ident : tactic => `(tactic|
  (obtain ⟨text, createdAt, ⟨state, txt, qt, revision, ev, basis, st, ae, ua, hist⟩, qr, fa⟩ := $n
   cases state <;> cases txt <;> line_auto))

end Tactics

variable {Text : Type} [DecidableEq Text]

/-! ## (a) The user's words are sacred -/

/-- `reset()` returns a line the user owns completely unchanged. (Line.swift:21) -/
theorem yours_reset {l : Line Text} (h : l.state = .yours) : l.reset = l := by
  simp [Line.reset, h]

/-- `resume()` returns a line the user owns completely unchanged. (Line.swift:23) -/
theorem yours_resume {l : Line Text} (h : l.state = .yours) : l.resume = l := by
  simp [Line.resume, h]

/-- `recheck()` returns a line the user owns completely unchanged. (Line.swift:28) -/
theorem yours_recheck {l : Line Text} (h : l.state = .yours) : l.recheck = l := by
  simp [Line.recheck, h]

/-- `settle()` returns a line the user owns completely unchanged. (Line.swift:32) -/
theorem yours_settle {l : Line Text} (h : l.state = .yours) : l.settle = l := by
  simp [Line.settle, h]

/-- `retract` returns a line the user owns completely unchanged, whatever the grounding check
    says. (Line.swift:33-36) -/
theorem yours_retract {l : Line Text} (h : l.state = .yours) (remainingEmpty grounded : Bool) :
    l.retract remainingEmpty grounded = l := by
  simp [Line.retract, h]

/-- `apply` with any outcome returns a line the user owns completely unchanged, and returns
    `false`. (Line.swift:37-38) -/
theorem yours_apply {l : Line Text} (h : l.state = .yours) (o : LineOutcome Text) (b q : Text)
    (t : Nat) : l.apply o b q t = (l, false) := by
  simp [Line.apply, h]

/-- The engine's listening → found marking returns a line the user owns completely unchanged.
    (MeetingNotes.swift:268-270) -/
theorem yours_markFound {l : Line Text} (h : l.state = .yours) : l.markFound = l := by
  simp [Line.markFound, h]

/-- One engine-driven operation (reset, resume, recheck, settle, retract, apply, or the found
    marking) leaves a note whose line the user owns completely unchanged. -/
theorem engine_step_yours (n : Note Text) (op : Op Text) (hy : n.line.state = .yours)
    (hop : op.isEngine = true ∨ op = .markFound) : n.step op = n := by
  cases op <;> note_cases n

/-- Any sequence of engine-driven operations, of any length and in any order, leaves a note
    whose line the user owns completely unchanged. -/
theorem engine_run_yours (n : Note Text) (ops : List (Op Text)) (hy : n.line.state = .yours)
    (hops : ∀ op ∈ ops, op.isEngine = true ∨ op = .markFound) : n.run ops = n := by
  induction ops with
  | nil => rfl
  | cons op ops ih =>
    have h1 : n.step op = n := engine_step_yours n op hy (hops op (by simp))
    simp only [Note.run_cons, h1]
    exact ih (fun o ho => hops o (by simp [ho]))

/-- Of all fourteen modelled operations, only `letAIRewrite` and the setter `owned = false`
    (or `owned = nil`) can take a line out of the `yours` state. -/
theorem leaves_yours_only_by_release (n : Note Text) (op : Op Text) (hy : n.line.state = .yours)
    (hl : (n.step op).line.state ≠ .yours) :
    op = .letAIRewrite ∨ ∃ v, op = .setOwned v ∧ v ≠ some true := by
  cases op <;> note_cases n

/-- Of all fourteen modelled operations, only the user's own `editEnhancement` and
    `letAIRewrite` can change the text of a line the user owns; this includes both image paths. -/
theorem yours_text_changes_only_by_user (n : Note Text) (op : Op Text)
    (hy : n.line.state = .yours) (ht : (n.step op).line.text ≠ n.line.text) :
    (∃ markdown, op = .editEnhancement markdown) ∨ op = .letAIRewrite := by
  cases op <;> note_cases n

/-- Publishing an image result into a note whose line the user owns changes exactly one field of
    the line: `revision` goes up by one. (NoteImageUnderstanding.swift:117) -/
theorem yours_imagePublish {l : Line Text} (h : l.state = .yours) (isImage imageEvidenceEmpty : Bool) :
    l.imagePublish isImage imageEvidenceEmpty = { l with revision := some (l.rev + 1) } := by
  line_cases l

/-- A changed image list changes exactly one field of a line the user owns: `queryText` is
    cleared. (NoteDocument.swift:74) -/
theorem yours_docImagesChanged {l : Line Text} (h : l.state = .yours) :
    l.docImagesChanged = { l with queryText := none } := by
  line_cases l

/-- Editing the jot changes exactly one field of a line the user owns: `basis` is cleared; a
    major edit does not reset it. (Notes.swift:17-24) -/
theorem yours_editText (n : Note Text) (h : n.line.state = .yours) (text : Text) (major : Bool)
    (time : Option Nat) : (n.editText text major time).line = { n.line with basis := none } := by
  note_cases n

/-! ## (b) Revision -/

/-- No modelled operation ever lowers `revision ?? 0`. -/
theorem rev_mono (n : Note Text) (op : Op Text) : n.line.rev ≤ (n.step op).line.rev := by
  cases op <;> note_cases n

/-- Over any sequence of operations `revision ?? 0` never decreases. -/
theorem rev_mono_run (n : Note Text) (ops : List (Op Text)) : n.line.rev ≤ (n.run ops).line.rev := by
  induction ops generalizing n with
  | nil => simp
  | cons op ops ih => exact Int.le_trans (rev_mono n op) (ih (n.step op))

/-- Whenever any of the fourteen operations changes the visible text, the revision strictly
    increases (so a draft made against the old text fails the engine's `line.revision ==`
    staleness guard, CurrentNoteEngine.swift:29). Before the NoteDocument fix this was false for
    the image-list path and the theorem had to exclude it. -/
theorem text_change_bumps_rev (n : Note Text) (op : Op Text)
    (ht : (n.step op).line.text ≠ n.line.text) : n.line.rev < (n.step op).line.rev := by
  cases op <;> note_cases n

/-- Over any sequence of operations: if the visible text at the end differs from the text at the
    start, the revision at the end is strictly higher than at the start. -/
theorem text_change_bumps_rev_run (n : Note Text) (ops : List (Op Text))
    (ht : (n.run ops).line.text ≠ n.line.text) : n.line.rev < (n.run ops).line.rev := by
  induction ops generalizing n with
  | nil => simp at ht
  | cons op ops ih =>
    simp only [Note.run_cons] at ht ⊢
    by_cases h : (n.step op).line.text = n.line.text
    · exact Int.lt_of_le_of_lt (rev_mono n op) (ih (n.step op) (by rw [h]; exact ht))
    · exact Int.lt_of_lt_of_le (text_change_bumps_rev n op h) (rev_mono_run (n.step op) ops)

/-- Taking ownership always raises the revision by exactly one. (Line.swift:22) -/
theorem takeOwnership_rev (l : Line Text) : l.takeOwnership.rev = l.rev + 1 := by
  simp [Line.takeOwnership, Line.rev]

/-- `apply` raises the revision by exactly one when it returns `true` and leaves it alone when it
    returns `false`. (Line.swift:37-49) -/
theorem apply_rev (l : Line Text) (o : LineOutcome Text) (b q : Text) (t : Nat) :
    (l.apply o b q t).1.rev = if (l.apply o b q t).2 = true then l.rev + 1 else l.rev := by
  cases o <;> line_cases l

/-- For the eight `Line` methods, the revision strictly increases exactly when the visible text
    changed, or ownership was taken, or `reset` ran on a line that had no text. The last case is
    why "exactly when the text changes or ownership is taken" is false as stated. -/
theorem rev_increase_iff (n : Note Text) (op : Op Text) (hm : op.isLineMethod = true) :
    n.line.rev < (n.step op).line.rev ↔
      ((n.step op).line.text ≠ n.line.text ∨ op = .takeOwnership ∨ op = .setOwned (some true)
        ∨ (op = .reset ∧ n.line.state ≠ .yours ∧ n.line.text = none)) := by
  cases op <;> note_cases n

/-- FINDING (benign). `reset()` on a fresh line raises the revision although neither the text
    nor the state changes and no ownership is taken: revision counts resets, not only text. -/
theorem reset_bumps_without_visible_change :
    ∃ l : Line Nat, l.state ≠ .yours ∧ l.reset.text = l.text ∧ l.reset.state = l.state ∧
      l.rev < l.reset.rev :=
  ⟨{}, by decide⟩

/-- Publishing an image result raises the revision by exactly one on every line: owned or not,
    with text or without, whichever of the three branches runs.
    (NoteImageUnderstanding.swift:117, 119, 121) -/
theorem imagePublish_rev (l : Line Text) (isImage imageEvidenceEmpty : Bool) :
    (l.imagePublish isImage imageEvidenceEmpty).rev = l.rev + 1 := by
  cases isImage <;> cases imageEvidenceEmpty <;> line_cases l

/-- The NoteDocument image-list path raises the revision by exactly one on a line the user does
    not own, and leaves it where it was on a line the user owns (whose text it does not touch).
    (NoteDocument.swift:74) -/
theorem docImagesChanged_bumps_rev (l : Line Text) :
    l.docImagesChanged.rev = if l.state = .yours then l.rev else l.rev + 1 := by
  line_cases l

/-- After an image result is published, the revision stays above its old value through every
    later sequence of operations. A draft that recorded the old revision can therefore never
    again match the line's revision, which is what the engine's staleness guard compares
    (CurrentNoteEngine.swift:29; the guard is app code and is not modelled). -/
theorem imagePublish_outdates_drafts (n : Note Text) (isImage imageEvidenceEmpty : Bool)
    (ops : List (Op Text)) :
    n.line.rev < ((n.step (.imagePublish isImage imageEvidenceEmpty)).run ops).line.rev := by
  have h1 : (n.step (.imagePublish isImage imageEvidenceEmpty)).line.rev = n.line.rev + 1 :=
    imagePublish_rev n.line isImage imageEvidenceEmpty
  have h2 := rev_mono_run (n.step (.imagePublish isImage imageEvidenceEmpty)) ops
  omega

/-- The same after a changed image list, for a line the user does not own: the revision stays
    above its old value through every later sequence of operations, so a draft written for the
    old pictures never matches again. -/
theorem docImagesChanged_outdates_drafts (n : Note Text) (hy : n.line.state ≠ .yours)
    (ops : List (Op Text)) : n.line.rev < ((n.step .docImagesChanged).run ops).line.rev := by
  have h1 : (n.step .docImagesChanged).line.rev = n.line.rev + 1 := by
    have := docImagesChanged_bumps_rev n.line
    simpa [Note.step, hy] using this
  have h2 := rev_mono_run (n.step .docImagesChanged) ops
  omega

/-- The trace on which the old code lost the text with no revision increase: a jot is answered,
    then a document sync finds its image list changed. Now the text is cleared, the history is
    cleared with it, the line is `.listening`, and the revision is one higher.
    (NoteDocument.swift:74) -/
theorem docImagesChanged_trace_bumps_rev :
    let n := (Note.new (0 : Nat) none false).run [.apply (.line 7 [1]) 5 0 12]
    n.line.state = .answered ∧ n.line.text = some 7 ∧
      (n.step .docImagesChanged).line.text = none ∧
      (n.step .docImagesChanged).line.state = .listening ∧
      (n.step .docImagesChanged).line.history = [] ∧
      (n.step .docImagesChanged).line.rev = n.line.rev + 1 := by
  decide

/-! ## (c) State and text agree -/

/-- The well-formedness invariant: unless the user owns the line, it has text exactly when its
    state is `answered` or `settled`. -/
def WF (l : Line Text) : Prop :=
  l.state ≠ .yours → (l.text ≠ none ↔ (l.state = .answered ∨ l.state = .settled))

instance (l : Line Text) : Decidable (WF l) := by unfold WF; infer_instance

/-- A new note's line is well formed, both for an ordinary jot (`.listening`) and for a note
    made from an answer (`.quiet`). (Notes.swift:28-30, MeetingNotes.swift:55-57) -/
theorem wf_new (text : Text) (createdAt : Option Nat) (fromAnswer : Bool) :
    WF (Note.new text createdAt fromAnswer).line := by
  cases fromAnswer <;> simp [WF, Note.new]

/-- Every one of the fourteen operations preserves the invariant: the eight `Line` methods,
    `editText`, `editEnhancement`, `letAIRewrite`, the listening → found marking, the image
    publish and the NoteDocument image-list path. Before the image-publish fix this was false for
    the publish and the theorem had to exclude it. -/
theorem wf_step (n : Note Text) (op : Op Text) (h : WF n.line) : WF (n.step op).line := by
  unfold WF at *
  cases op <;> note_cases n

/-- The invariant survives any sequence of operations. -/
theorem wf_run (n : Note Text) (ops : List (Op Text)) (h : WF n.line) : WF (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih => exact ih (n.step op) (wf_step n op h)

/-- Starting from a new note, the invariant holds after any sequence of operations. -/
theorem wf_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool) (ops : List (Op Text)) :
    WF ((Note.new text createdAt fromAnswer).run ops).line :=
  wf_run _ ops (wf_new text createdAt fromAnswer)

/-- The same, said the way a reader of the screen would: starting from a new note, after any
    sequence of operations, a line that holds text is never `.listening`, `.found` or `.quiet`,
    the three states the Obsidian plugin draws without the text
    (obsidian-plugin/src/ui/surfaces/line.ts:12-18, read, not modelled). -/
theorem text_never_hidden_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) :
    ((Note.new text createdAt fromAnswer).run ops).line.text ≠ none →
      ((Note.new text createdAt fromAnswer).run ops).line.state ≠ .listening ∧
      ((Note.new text createdAt fromAnswer).run ops).line.state ≠ .found ∧
      ((Note.new text createdAt fromAnswer).run ops).line.state ≠ .quiet := by
  intro ht
  have h := wf_reachable text createdAt fromAnswer ops
  unfold WF at h
  by_cases hy : ((Note.new text createdAt fromAnswer).run ops).line.state = .yours
  · simp [hy]
  · rcases (h hy).mp ht with h1 | h1 <;> simp [h1]

/-- Honesty check for `editEnhancement`: it preserves the invariant from any line (the result is
    always `yours`, about which the invariant says nothing; see `ownedHasText_reachable`).
    (Notes.swift:25-27) -/
theorem wf_editEnhancement (n : Note Text) (markdown : Text) : WF (n.editEnhancement markdown).line := by
  simp [WF, Note.editEnhancement, Line.takeOwnership]

/-- On a line the user does not own, `recheck()` clears `queryText`, sends a line that has no
    text back to `.listening`, and changes nothing else: not the text, the revision, the history
    or the `basis`. (Line.swift:27-31) -/
theorem recheck_not_owned {l : Line Text} (hy : l.state ≠ .yours) :
    l.recheck = { l with queryText := none, basis := none, state := if l.text = none then .listening else l.state } := by
  simp [Line.recheck, hy]

/-- `recheck()` never changes the text of any line, and never changes the state of a line that
    has text: it cannot write "listening" over an answer. (Line.swift:27-31) -/
theorem recheck_keeps_answer (l : Line Text) :
    l.recheck.text = l.text ∧ (l.text ≠ none → l.recheck.state = l.state) := by
  line_cases l

/-- On a line the user does not own, the image publish does exactly one of two things. For an
    image-only note whose images carry no evidence it is `reset()`. Otherwise it raises the
    revision by one, clears `queryText` and `basis` (so the engine takes the jot up again), sends
    a line that has no text back to `.listening`, and changes nothing else. (NoteImageUnderstanding.swift:116-122) -/
theorem imagePublish_not_owned {l : Line Text} (hy : l.state ≠ .yours) (isImage imageEvidenceEmpty : Bool) :
    l.imagePublish isImage imageEvidenceEmpty =
      if isImage = true ∧ imageEvidenceEmpty = true then l.reset
      else { l with revision := some (l.rev + 1), queryText := none, basis := none,
                    state := if l.text = none then .listening else l.state } := by
  cases isImage <;> cases imageEvidenceEmpty <;> line_cases l

/-- A late OCR result or caption does not hide an answer: unless the note is an image-only note
    whose images carry no evidence, the image publish leaves the text and the state of a line
    that has text exactly as they were. (NoteImageUnderstanding.swift:116-122) -/
theorem imagePublish_keeps_answer (l : Line Text) (isImage imageEvidenceEmpty : Bool)
    (ht : l.text ≠ none) (hne : ¬ (isImage = true ∧ imageEvidenceEmpty = true)) :
    (l.imagePublish isImage imageEvidenceEmpty).text = l.text ∧
      (l.imagePublish isImage imageEvidenceEmpty).state = l.state := by
  cases isImage <;> cases imageEvidenceEmpty <;> line_cases l

/-- An image-only jot: its OCR result is published, the engine writes a line from it, then the
    caption for the same image is published. -/
def captionTrace : List (Op Nat) :=
  [.imagePublish true false, .apply (.line 7 [1]) 5 0 12, .imagePublish true false]

/-- A jot with words and an image: the engine answers from the transcript, then the image's OCR
    result is published. -/
def lateOcrTrace : List (Op Nat) :=
  [.apply (.line 7 [1]) 5 0 12, .imagePublish false false]

/-- On the trace where the old code hid the answer (OCR result, engine answer, then caption), the
    line now ends `.answered` and well formed, still holding its text; `queryText` is cleared so
    the note counts as needing another look, and the revision is above the answer's. -/
theorem captionTrace_keeps_answer :
    let n := (Note.new (0 : Nat) (some 10) false).run captionTrace
    n.line.state = .answered ∧ n.line.text = some 7 ∧ n.line.queryText = none ∧ n.line.rev = 3 ∧
      WF n.line := by
  decide

/-- The same for a jot with words and an image, when the OCR result lands after the engine
    answered from the transcript: the answer stays. -/
theorem lateOcrTrace_keeps_answer :
    let n := (Note.new (0 : Nat) (some 10) false).run lateOcrTrace
    n.line.state = .answered ∧ n.line.text = some 7 ∧ n.line.queryText = none ∧ n.line.rev = 2 ∧
      WF n.line := by
  decide

/-- `recheck()` keeps the invariant but does not restore it. On a line the user does not own it
    gives a well-formed line exactly when the line had no text or was already `.answered` or
    `.settled`; a line that is `.listening`, `.found` or `.quiet` while holding text stays so. -/
theorem wf_recheck_iff (l : Line Text) (hy : l.state ≠ .yours) :
    WF l.recheck ↔ (l.text = none ∨ l.state = .answered ∨ l.state = .settled) := by
  unfold WF; line_cases l

/-- The same for the image publish as a whole: on a line the user does not own it gives a
    well-formed line exactly when it resets the line (image-only note without evidence), or the
    line had no text, or was already `.answered` or `.settled`. -/
theorem wf_imagePublish_iff (l : Line Text) (hy : l.state ≠ .yours) (isImage imageEvidenceEmpty : Bool) :
    WF (l.imagePublish isImage imageEvidenceEmpty) ↔
      ((isImage = true ∧ imageEvidenceEmpty = true) ∨ l.text = none ∨ l.state = .answered
        ∨ l.state = .settled) := by
  unfold WF
  cases isImage <;> cases imageEvidenceEmpty <;> line_cases l

/-- LIMITATION OF THE FIX. It stops lines from being hidden; it does not un-hide one that already
    is. A `.listening` line that holds text (which the old publish path wrote, and which `Codable`
    loads from disk exactly as saved) is still not well formed after `recheck()`, after another
    image result, after the found marking, or after `resume()`. `settle()` (Stop), `reset()` and
    an `apply` with `.unchanged`/`.quiet` do repair it, as before. -/
theorem hidden_line_from_old_build_not_repaired :
    let l : Line Nat := { state := .listening, text := some 7 }
    ¬ WF l ∧ ¬ WF l.recheck ∧ ¬ WF (l.imagePublish false false) ∧ ¬ WF l.markFound ∧ ¬ WF l.resume ∧
      WF l.settle ∧ WF l.reset ∧ WF (l.apply .unchanged 0 0 0).1 := by
  decide

/-- `settle()` produces a well-formed line from any line at all, so Stop repairs a line the old
    build left hidden. (Line.swift:32) -/
theorem wf_settle_any (l : Line Text) : WF l.settle := by
  unfold WF; line_cases l

/-- `reset()` produces a well-formed line from any line at all. (Line.swift:21) -/
theorem wf_reset_any (l : Line Text) : WF l.reset := by
  unfold WF; line_cases l

/-- `apply` with an `.unchanged` or `.quiet` outcome produces a well-formed line from any line at
    all, so the next engine pass that reaches the note repairs a line the old build left hidden.
    (Line.swift:47) -/
theorem wf_apply_noline_any (l : Line Text) (o : LineOutcome Text) (ho : o = .unchanged ∨ o = .quiet)
    (b q : Text) (t : Nat) : WF (l.apply o b q t).1 := by
  unfold WF; cases o <;> line_cases l

/-- Half of the invariant: `answered` and `settled` lines have text, and `quiet` lines have none.
    It says nothing about `.listening` and `.found`, so a line the old build left hidden
    (`.listening` with text) satisfies it. -/
def WeakWF (l : Line Text) : Prop :=
  l.state ≠ .yours →
    ((l.state = .answered ∨ l.state = .settled) → l.text ≠ none) ∧ (l.state = .quiet → l.text = none)

/-- Every modelled operation preserves the weak invariant, starting from any line that has it. -/
theorem weakWF_step (n : Note Text) (op : Op Text) (h : WeakWF n.line) : WeakWF (n.step op).line := by
  unfold WeakWF at *
  cases op <;> note_cases n

instance (l : Line Text) : Decidable (WeakWF l) := by unfold WeakWF; infer_instance

/-- The weak invariant survives any sequence of operations. -/
theorem weakWF_run (n : Note Text) (ops : List (Op Text)) (h : WeakWF n.line) :
    WeakWF (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih => exact ih (n.step op) (weakWF_step n op h)

/-- Starting from a new note, the weak invariant holds after any sequence of operations. (Now
    that `wf_reachable` has no exception this follows from it; it is kept because `weakWF_run`
    also covers lines that start out hidden.) -/
theorem weakWF_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) : WeakWF ((Note.new text createdAt fromAnswer).run ops).line :=
  weakWF_run _ ops (by cases fromAnswer <;> simp [WeakWF, Note.new])

/-- The full invariant implies the weak one. -/
theorem weakWF_of_wf {l : Line Text} (h : WF l) : WeakWF l := by
  unfold WF at h; unfold WeakWF; line_cases l

/-- A line the user owns has text. -/
def OwnedHasText (l : Line Text) : Prop := l.state = .yours → l.text ≠ none

/-- Every operation except a bare `takeOwnership()` / `owned = …` keeps "owned lines have text". -/
theorem ownedHasText_step (n : Note Text) (op : Op Text)
    (hop : op ≠ .takeOwnership ∧ op.isSetOwned = false) (h : OwnedHasText n.line) :
    OwnedHasText (n.step op).line := by
  unfold OwnedHasText at *
  cases op <;> note_cases n

/-- "Owned lines have text" survives any sequence without a bare `takeOwnership()` / `owned = …`. -/
theorem ownedHasText_run (n : Note Text) (ops : List (Op Text))
    (hops : ∀ op ∈ ops, op ≠ .takeOwnership ∧ op.isSetOwned = false) (h : OwnedHasText n.line) :
    OwnedHasText (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih =>
    exact ih (n.step op) (fun o ho => hops o (by simp [ho])) (ownedHasText_step n op (hops op (by simp)) h)

/-- Starting from a new note, a line the user owns always has text, as long as ownership is only
    ever taken through `editEnhancement` (the only caller of `takeOwnership` in `Sources/`). -/
theorem ownedHasText_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) (hops : ∀ op ∈ ops, op ≠ .takeOwnership ∧ op.isSetOwned = false) :
    OwnedHasText ((Note.new text createdAt fromAnswer).run ops).line :=
  ownedHasText_run _ ops hops (by cases fromAnswer <;> simp [OwnedHasText, Note.new])

/-! ## (d) No flapping -/

/-- `apply` returns `true` exactly when the visible text changed. (Line.swift:37-49) -/
theorem apply_true_iff_text_changed (l : Line Text) (o : LineOutcome Text) (b q : Text) (t : Nat) :
    (l.apply o b q t).2 = true ↔ (l.apply o b q t).1.text ≠ l.text := by
  cases o <;> line_cases l

/-- When `apply` changes the text, the new text is not the text of any earlier revision in the
    history. (Line.swift:42) -/
theorem apply_never_reuses_history (l : Line Text) (o : LineOutcome Text) (b q : Text) (t : Nat)
    (hc : (l.apply o b q t).1.text ≠ l.text) :
    ∀ r ∈ l.history, (l.apply o b q t).1.text ≠ some r.text := by
  cases o <;> line_cases l

/-- The texts recorded in the history are pairwise distinct. -/
def HistDistinct (l : Line Text) : Prop := (l.history.map (·.text)).Nodup

/-- Every modelled operation keeps the history texts pairwise distinct. -/
theorem histDistinct_step (n : Note Text) (op : Op Text) (h : HistDistinct n.line) :
    HistDistinct (n.step op).line := by
  unfold HistDistinct at *
  cases op <;> note_cases n

/-- Distinct history texts survive any sequence of operations. -/
theorem histDistinct_run (n : Note Text) (ops : List (Op Text)) (h : HistDistinct n.line) :
    HistDistinct (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih => exact ih (n.step op) (histDistinct_step n op h)

/-- Starting from a new note, the history texts are pairwise distinct after any sequence of
    operations: the engine never shows the same sentence twice within one history. -/
theorem histDistinct_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) : HistDistinct ((Note.new text createdAt fromAnswer).run ops).line :=
  histDistinct_run _ ops (by simp [HistDistinct, Note.new])

/-- The text of a line the user does not own is one of the texts in its history. -/
def TextInHistory (l : Line Text) : Prop :=
  l.state ≠ .yours → ∀ t, l.text = some t → ∃ r ∈ l.history, r.text = t

/-- Every operation except the `owned` setter keeps "the shown text is in the history". -/
theorem textInHistory_step (n : Note Text) (op : Op Text) (hop : op.isSetOwned = false)
    (h : TextInHistory n.line) : TextInHistory (n.step op).line := by
  unfold TextInHistory at *
  cases op <;> note_cases n

/-- "The shown text is in the history" survives any sequence that does not call the `owned` setter. -/
theorem textInHistory_run (n : Note Text) (ops : List (Op Text))
    (hops : ∀ op ∈ ops, op.isSetOwned = false) (h : TextInHistory n.line) :
    TextInHistory (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih =>
    exact ih (n.step op) (fun o ho => hops o (by simp [ho])) (textInHistory_step n op (hops op (by simp)) h)

/-- Starting from a new note, the text of a line the user does not own is always in its history,
    as long as the (unused) `owned` setter is not called. -/
theorem textInHistory_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) (hops : ∀ op ∈ ops, op.isSetOwned = false) :
    TextInHistory ((Note.new text createdAt fromAnswer).run ops).line :=
  textInHistory_run _ ops hops (by simp [TextInHistory, Note.new])

/-- On a line the user does not own, the NoteDocument image-list path is exactly `reset()`: the
    text, the history, the evidence and the basis are forgotten, the state is `.listening`, and
    the revision is one higher. (NoteDocument.swift:74) -/
theorem docImagesChanged_not_owned {l : Line Text} (hy : l.state ≠ .yours) :
    l.docImagesChanged = l.reset := by
  line_cases l

/-- After the NoteDocument image-list path has cleared a line, any sentence can be written to it,
    including the one it showed before: `apply` accepts it and the line shows it, `.answered`.
    Before the fix the old sentence was rejected for good, because the history was kept.
    (NoteDocument.swift:74 with Line.swift:42) -/
theorem docImagesChanged_allows_previous_text (l : Line Text) (hy : l.state ≠ .yours) (t : Text)
    (ids : List Text) (b q : Text) (tm : Nat) :
    (l.docImagesChanged.apply (.line t ids) b q tm).2 = true ∧
      (l.docImagesChanged.apply (.line t ids) b q tm).1.text = some t ∧
      (l.docImagesChanged.apply (.line t ids) b q tm).1.state = .answered := by
  line_cases l

/-- After `reset()` any sentence is accepted, including one the line showed before.
    (Line.swift:21, 42) -/
theorem reset_allows_previous_text (l : Line Text) (hy : l.state ≠ .yours) (t : Text)
    (ids : List Text) (b q : Text) (tm : Nat) : (l.reset.apply (.line t ids) b q tm).2 = true := by
  line_cases l

/-! ## (e) Other properties the code relies on -/

/-- `settle()` then `resume()` on a line the user does not own recomputes the state from the
    text alone (`.listening` without text, `.answered` with) and changes nothing else. -/
theorem settle_resume (l : Line Text) (hy : l.state ≠ .yours) :
    l.settle.resume = { l with state := if l.text = none then .listening else .answered } := by
  line_cases l

/-- `settle()` then `resume()` is the identity on a well-formed line that was `.listening`,
    `.answered` or `.yours`; a `.found` line comes back as `.listening`. -/
theorem settle_resume_roundtrip (l : Line Text) (h : WF l)
    (hs : l.state = .listening ∨ l.state = .answered ∨ l.state = .yours) : l.settle.resume = l := by
  unfold WF at h; line_cases l

/-- Settling twice is the same as settling once. -/
theorem settle_idem (l : Line Text) : l.settle.settle = l.settle := by line_cases l

/-- Resuming twice is the same as resuming once. -/
theorem resume_idem (l : Line Text) : l.resume.resume = l.resume := by line_cases l

/-- Stop, resume, stop lands in exactly the state the first stop produced. -/
theorem settle_resume_settle (l : Line Text) : l.settle.resume.settle = l.settle := by line_cases l

/-- After `resume()` no line is `.settled` or `.quiet`. (Line.swift:23, RecordingSession.swift:36) -/
theorem resume_not_settled (l : Line Text) : l.resume.state ≠ .settled ∧ l.resume.state ≠ .quiet := by
  line_cases l

/-- FINDING (minor). `resume()` turns the `.quiet` marker that MeetingNotes.swift:57 gives a note
    made from an answer into `.listening`: after a resume its line is indistinguishable from a
    fresh jot's line. -/
theorem resume_erases_answer_marker (text : Text) (createdAt : Option Nat) :
    (Note.new text createdAt true).line.resume = (Note.new text createdAt false).line := by
  simp [Note.new, Line.resume]

/-- `.settled` and `.quiet` are not terminal: a later `apply` with `.unchanged` or `.quiet` puts
    the line back to `.answered` or `.listening`. (Line.swift:47) -/
theorem settled_not_absorbing (l : Line Text) (hs : l.state = .settled ∨ l.state = .quiet)
    (o : LineOutcome Text) (ho : o = .unchanged ∨ o = .quiet) (b q : Text) (t : Nat) :
    (l.apply o b q t).1.state = .listening ∨ (l.apply o b q t).1.state = .answered := by
  cases o <;> line_cases l

/-- Rechecking twice is the same as rechecking once. (Line.swift:27-31) -/
theorem recheck_idem (l : Line Text) : l.recheck.recheck = l.recheck := by line_cases l

/-- `recheck()` and `resume()` give the same line in either order, on every line. -/
theorem recheck_resume_comm (l : Line Text) : l.recheck.resume = l.resume.recheck := by line_cases l

/-- `recheck()` then `settle()` is `settle()` with `queryText` and `basis` cleared: a recheck
    before Stop does not change the state Stop decides. -/
theorem recheck_then_settle (l : Line Text) (hy : l.state ≠ .yours) :
    l.recheck.settle = { l.settle with queryText := none, basis := none } := by
  line_cases l

/-- NOTE (minor). `settle()` then `recheck()`: a line that Stop settled with text stays
    `.settled`, but a line that Stop marked `.quiet` goes back to `.listening`. Like `apply`
    (`settled_not_absorbing`), `recheck()` does not treat a stopped line as final. -/
theorem settle_then_recheck (l : Line Text) (hy : l.state ≠ .yours) :
    l.settle.recheck.state = if l.text = none then .listening else .settled := by
  line_cases l

/-- Exactly when an image result leaves a stopped line stopped: for a line that is `.settled` or
    `.quiet`, the state is still `.settled` or `.quiet` after the image publish exactly when the
    line has text and the note is not an image-only note without evidence. -/
theorem imagePublish_stays_stopped_iff (l : Line Text) (hs : l.state = .settled ∨ l.state = .quiet)
    (isImage imageEvidenceEmpty : Bool) :
    ((l.imagePublish isImage imageEvidenceEmpty).state = .settled ∨
        (l.imagePublish isImage imageEvidenceEmpty).state = .quiet) ↔
      (l.text ≠ none ∧ ¬ (isImage = true ∧ imageEvidenceEmpty = true)) := by
  cases isImage <;> cases imageEvidenceEmpty <;> line_cases l

/-- NOTE (minor), on reachable lines. An image result that arrives after Stop un-settles a line
    in two cases: a `.quiet` line goes back to `.listening` (first trace), and the `.settled`
    line of an image-only note whose images now carry no evidence is reset to `.listening` with
    no text (second trace). Otherwise a `.settled` line stays `.settled` and keeps its text
    (third trace). Whether the app settles such a line again is up to the scheduler
    (MeetingNotes.swift:288, 309), which is not modelled. -/
theorem image_result_after_stop :
    ((Note.new (0 : Nat) none false).run [.settle, .imagePublish false false]).line.state = .listening ∧
    (let l := ((Note.new (0 : Nat) none false).run
        [.imagePublish true false, .apply (.line 7 [1]) 5 0 12, .settle, .imagePublish true true]).line;
      l.state = .listening ∧ l.text = none) ∧
    (let l := ((Note.new (0 : Nat) none false).run
        [.apply (.line 7 [1]) 5 0 12, .settle, .imagePublish false false]).line;
      l.state = .settled ∧ l.text = some 7) := by
  decide

/-- The version numbers stored in the history are strictly increasing and never exceed the
    current revision. -/
def VersionsOrdered (l : Line Text) : Prop :=
  (∀ r ∈ l.history, r.version ≤ l.rev) ∧ l.history.Pairwise (fun a b => a.version < b.version)

/-- Every modelled operation keeps the history versions strictly increasing and at most the
    current revision. -/
theorem versionsOrdered_step (n : Note Text) (op : Op Text) (h : VersionsOrdered n.line) :
    VersionsOrdered (n.step op).line := by
  unfold VersionsOrdered at *
  cases op <;> note_cases n

/-- Ordered history versions survive any sequence of operations. -/
theorem versionsOrdered_run (n : Note Text) (ops : List (Op Text)) (h : VersionsOrdered n.line) :
    VersionsOrdered (n.run ops).line := by
  induction ops generalizing n with
  | nil => simpa using h
  | cons op ops ih => exact ih (n.step op) (versionsOrdered_step n op h)

/-- Starting from a new note, history versions are strictly increasing and at most the current
    revision after any sequence of operations. -/
theorem versionsOrdered_reachable (text : Text) (createdAt : Option Nat) (fromAnswer : Bool)
    (ops : List (Op Text)) : VersionsOrdered ((Note.new text createdAt fromAnswer).run ops).line :=
  versionsOrdered_run _ ops (by simp [VersionsOrdered, Note.new])

/-- An edit that changes at most one token is never major. (Notes.swift:20) -/
theorem isMajorEdit_single_token (difference union : Nat) (h : difference ≤ 1) :
    Note.isMajorEdit difference union = false := by
  simp [Note.isMajorEdit]; omega

/-- An edit is major exactly when more than one token changed and the changed tokens are more
    than three tenths of all tokens. (Notes.swift:20) -/
theorem isMajorEdit_iff (difference union : Nat) :
    Note.isMajorEdit difference union = true ↔ 1 < difference ∧ 3 * max 1 union < 10 * difference := by
  simp [Note.isMajorEdit]

/-! ## Checks against vacuity

The hypotheses used above are satisfiable (first group), and each invariant is violated by a
deliberately wrong variant of an operation (second group). The second group includes the two
operations as they were before they were fixed. -/

section Checks

/-- An owned line exists and is reachable through `editEnhancement`. -/
example : ((Note.new (0 : Nat) none false).run [.editEnhancement 9]).line.state = .yours := by decide

/-- A non-trivial engine sequence satisfies the hypothesis of `engine_run_yours`. -/
example : ∀ op ∈ ([.reset, .settle, .apply (.line 7 []) 1 0 0, .retract true false, .resume, .recheck,
    .markFound] : List (Op Nat)), op.isEngine = true ∨ op = .markFound := by decide

/-- Both hypotheses of `leaves_yours_only_by_release` hold together for `letAIRewrite`. -/
example : let n := (Note.new (0 : Nat) none false).run [.editEnhancement 9]
    n.line.state = .yours ∧ (n.step .letAIRewrite).line.state ≠ .yours := by decide

/-- Both hypotheses of `yours_text_changes_only_by_user` hold together for a second edit. -/
example : let n := (Note.new (0 : Nat) none false).run [.editEnhancement 9]
    n.line.state = .yours ∧ (n.step (.editEnhancement 8)).line.text ≠ n.line.text := by decide

/-- The hypothesis of `text_change_bumps_rev` holds for an `apply` that writes a line, and for
    the NoteDocument image-list path the theorem used to exclude. -/
example : let n := Note.new (0 : Nat) none false
    let a := n.step (.apply (.line 7 []) 1 0 0)
    a.line.text ≠ n.line.text ∧ (a.step .docImagesChanged).line.text ≠ a.line.text := by decide

/-- The hypothesis of `text_change_bumps_rev_run` holds for a sequence whose last step is not the
    one that changed the text. -/
example : let n := Note.new (0 : Nat) none false
    (n.run [.apply (.line 7 []) 1 0 0, .imagePublish false false, .settle]).line.text ≠ n.line.text := by
  decide

/-- A sequence that uses both image paths and `recheck` reaches every state on the way, and
    `wf_reachable` (which has no hypothesis left to satisfy) applies to all of it. -/
example :
    let ops : List (Op Nat) := [.markFound, .imagePublish false false, .apply (.line 7 []) 1 0 0,
      .imagePublish true false, .settle, .recheck, .docImagesChanged, .settle, .resume, .editEnhancement 9]
    let at_ (k : Nat) := ((Note.new (0 : Nat) none false).run (ops.take k)).line.state
    at_ 1 = .found ∧ at_ 2 = .listening ∧ at_ 3 = .answered ∧ at_ 4 = .answered ∧ at_ 5 = .settled ∧
      at_ 6 = .settled ∧ at_ 7 = .listening ∧ at_ 8 = .quiet ∧ at_ 9 = .listening ∧ at_ 10 = .yours := by
  decide

/-- The hypotheses of `imagePublish_keeps_answer` hold on a reachable answered line. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    l.text ≠ none ∧ ¬ ((false : Bool) = true ∧ (false : Bool) = true) := by decide

/-- The hypotheses of `docImagesChanged_allows_previous_text` and `docImagesChanged_outdates_drafts`
    hold on a reachable line that shows a sentence recorded in its history. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    l.state ≠ .yours ∧ l.text = some 7 ∧ ∃ r ∈ l.history, r.text = 7 := by decide

/-- Both sides of `wf_recheck_iff` occur: true on a reachable answered line, false on a
    `.listening` line that holds text. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    let hidden : Line Nat := { state := .listening, text := some 7 }
    l.state ≠ .yours ∧ WF l.recheck ∧ hidden.state ≠ .yours ∧ ¬ WF hidden.recheck := by decide

/-- The hypothesis of `imagePublish_stays_stopped_iff` holds on reachable lines of both kinds. -/
example :
    ((Note.new (0 : Nat) none false).run [.settle]).line.state = .quiet ∧
    ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0, .settle]).line.state = .settled := by
  decide

/-- The hypotheses of `settle_resume_roundtrip` hold on a reachable answered line. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    WF l ∧ l.state = .answered := by decide

namespace Broken

/-- WRONG ON PURPOSE: `settle` that always says `.settled`. -/
def settle (l : Line Nat) : Line Nat := if l.state = .yours then l else { l with state := .settled }

/-- WRONG ON PURPOSE: `settle` without the `guard state != .yours`. -/
def settleUnguarded (l : Line Nat) : Line Nat :=
  { l with state := if l.text = none then .quiet else .settled }

/-- WRONG ON PURPOSE: `reset` that forgets to carry the revision forward. -/
def reset (l : Line Nat) : Line Nat := if l.state = .yours then l else {}

/-- WRONG ON PURPOSE: `apply` for a `.line` outcome without the history half of the guard and
    with `version: 1` instead of the new revision. -/
def applyLine (l : Line Nat) (markdown : Nat) : Line Nat :=
  if l.state = .yours ∨ l.text = some markdown then l
  else { l with revision := some (l.rev + 1), text := some markdown, state := .answered,
                history := l.history ++ [{ version := 1, text := markdown, reason := .newEvidence,
                                            time := 0, evidence := [] }] }

/-- WRONG ON PURPOSE: `recheck` that always goes back to `.listening`. -/
def recheck (l : Line Nat) : Line Nat :=
  if l.state = .yours then l else { l with queryText := none, state := .listening }

/-- WRONG ON PURPOSE: the image publish as it was before the fix
    (NoteImageUnderstanding.swift:109-114 at commit edcaeba). `.listening` is written over a line
    that still has text.
    ```
    line.revision = (line.revision ?? 0) + 1
    if isImage && imageEvidence.isEmpty && line.owned != true { line.text = nil }
    if line.owned != true { line.queryText = nil; line.state = .listening }
    ``` -/
def imagePublish (l : Line Nat) (isImage imageEvidenceEmpty : Bool) : Line Nat :=
  let l := { l with revision := some (l.rev + 1) }
  let l := if (isImage && imageEvidenceEmpty && l.owned != true) = true then { l with text := none } else l
  if (l.owned != true) = true then { l with queryText := none, state := .listening } else l

/-- WRONG ON PURPOSE: the NoteDocument image-list path as it was before the fix
    (NoteDocument.swift:69-72 at commit edcaeba). The text is cleared; the revision and the
    history are kept.
    ```
    n.line.queryText = nil; n.line.state = n.line.owned == true ? .yours : .listening
    if n.line.owned != true { n.line.text = nil }
    ``` -/
def docImagesChanged (l : Line Nat) : Line Nat :=
  let l := { l with queryText := none, state := if l.owned = true then .yours else .listening }
  if (l.owned != true) = true then { l with text := none } else l

end Broken

/-- Seen to fail: the broken `settle` violates `WF` and `WeakWF` on a fresh line. -/
example : ¬ WF (Broken.settle {}) ∧ ¬ WeakWF (Broken.settle {}) := by decide

/-- Seen to fail: an unguarded `settle` changes a line the user owns. -/
example : let l := ((Note.new (0 : Nat) none false).run [.editEnhancement 9]).line
    Broken.settleUnguarded l ≠ l := by decide

/-- Seen to fail: the broken `reset` lowers the revision. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    ¬ (l.rev ≤ (Broken.reset l).rev) := by decide

/-- Seen to fail: without the history guard a sentence comes back, so history texts repeat, and
    with a constant version the versions are not increasing. -/
example : let l := Broken.applyLine (Broken.applyLine (Broken.applyLine {} 7) 8) 7
    ¬ HistDistinct l ∧ ¬ VersionsOrdered l := by
  simp [HistDistinct, VersionsOrdered, Broken.applyLine, Line.rev]

/-- Seen to fail: a `recheck` that always says `.listening` breaks `WF` on an answered line. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 []) 1 0 0]).line
    WF l ∧ ¬ WF (Broken.recheck l) := by decide

/-- Seen to fail: the old image publish takes a well-formed answered line to `.listening` while
    it still holds its text, on both traces. `wf_step` and `imagePublish_keeps_answer` forbid
    that for the current publish (`captionTrace_keeps_answer`, `lateOcrTrace_keeps_answer`). -/
example :
    let afterAnswer := ((Note.new (0 : Nat) (some 10) false).run [.apply (.line 7 [1]) 5 0 12]).line
    let afterOcrAndAnswer := ((Broken.imagePublish {} true false).apply (.line 7 [1]) 5 0 12).1
    WF afterAnswer ∧ (Broken.imagePublish afterAnswer false false).state = .listening ∧
      (Broken.imagePublish afterAnswer false false).text = some 7 ∧
      ¬ WF (Broken.imagePublish afterAnswer false false) ∧
    WF afterOcrAndAnswer ∧ (Broken.imagePublish afterOcrAndAnswer true false).state = .listening ∧
      (Broken.imagePublish afterOcrAndAnswer true false).text = some 7 ∧
      ¬ WF (Broken.imagePublish afterOcrAndAnswer true false) := by
  decide

/-- Seen to fail: the old NoteDocument path changes the text with no revision increase, which
    `text_change_bumps_rev` forbids, and then rejects the very sentence it cleared, which
    `docImagesChanged_allows_previous_text` forbids. -/
example : let l := ((Note.new (0 : Nat) none false).run [.apply (.line 7 [1]) 5 0 12]).line
    (Broken.docImagesChanged l).text ≠ l.text ∧ ¬ (l.rev < (Broken.docImagesChanged l).rev) ∧
      ((Broken.docImagesChanged l).apply (.line 7 [1]) 5 0 12).2 = false ∧
      ((Broken.docImagesChanged l).apply (.line 7 [1]) 5 0 12).1.text = none := by
  decide

/-- Seen to fail: a bare `takeOwnership()` on an empty line gives an owned line with no text
    (the operation `ownedHasText_reachable` excludes). -/
example : ¬ OwnedHasText (({} : Line Nat).takeOwnership) := by
  simp [OwnedHasText, Line.takeOwnership]

/-- Seen to fail: releasing an owned line with the `owned` setter shows text that is not in the
    history (the operation `textInHistory_reachable` excludes). -/
example : ¬ TextInHistory ((Note.new (0 : Nat) none false).run [.editEnhancement 9, .setOwned (some false)]).line := by
  simp [TextInHistory, Note.new, Note.run, Note.step, Note.editEnhancement, Line.takeOwnership,
    Line.setOwned]

end Checks

end WorkScribe
