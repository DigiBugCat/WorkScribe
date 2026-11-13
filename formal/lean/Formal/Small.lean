/-
  Three small pure functions.

  Swift sources transcribed here (worktree `WorkScribe-codex`, branch `codex-backend`):
    Sources/WorkScribeCore/AudioBacklog.swift       lines 85-92   `RecordingPressure(lag:)`
    Sources/WorkScribeCore/RecordingSession.swift   lines 20-38   `Meeting.canResume` / `resume()`
    Sources/WorkScribeCore/TitlePolicy.swift        lines 4-10    `TitlePolicy.canGenerate`
-/
import Formal.Line

set_option linter.unusedSectionVars false

namespace WorkScribe

/-! # RecordingPressure -/

/-- AudioBacklog.swift:85-86  `enum RecordingPressure: Int, Comparable { case normal, screenPaused, aiPaused, transcriptDelayed }` -/
inductive RecordingPressure where
  | normal | screenPaused | aiPaused | transcriptDelayed
  deriving DecidableEq, Repr

namespace RecordingPressure

/-- AudioBacklog.swift:85  the `Int` raw value, in declaration order. -/
def rawValue : RecordingPressure → Nat
  | normal => 0
  | screenPaused => 1
  | aiPaused => 2
  | transcriptDelayed => 3

/-- AudioBacklog.swift:87  `static func < (lhs, rhs) { lhs.rawValue < rhs.rawValue }` -/
instance : LT RecordingPressure := ⟨fun a b => a.rawValue < b.rawValue⟩
instance : LE RecordingPressure := ⟨fun a b => a.rawValue ≤ b.rawValue⟩
instance (a b : RecordingPressure) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.rawValue ≤ b.rawValue))

section
variable {α : Type} [LE α] [DecidableRel (fun a b : α => a ≤ b)] [OfNat α 2] [OfNat α 6] [OfNat α 12]

/-- AudioBacklog.swift:88-90
    `self = lag >= 12 ? .transcriptDelayed : lag >= 6 ? .aiPaused : lag >= 2 ? .screenPaused : .normal`.
    `lag` is a `Double` in Swift; here it is any type with a decidable `≤` and the three constants
    (`lag >= 12` is written `12 ≤ lag`). -/
def ofLag (lag : α) : RecordingPressure :=
  if (12 : α) ≤ lag then .transcriptDelayed
  else if (6 : α) ≤ lag then .aiPaused
  else if (2 : α) ≤ lag then .screenPaused
  else .normal

/-- Pressure never goes down when lag goes up: for any number type whose `≤` is transitive (true
    of `Double`, NaN included, though that fact about IEEE 754 is assumed, not proved here). -/
theorem ofLag_mono (trans : ∀ a b c : α, a ≤ b → b ≤ c → a ≤ c) (lag lag' : α) (h : lag ≤ lag') :
    ofLag lag ≤ ofLag lag' := by
  show (ofLag lag).rawValue ≤ (ofLag lag').rawValue
  unfold ofLag
  by_cases h12 : (12 : α) ≤ lag
  · have := trans _ _ _ h12 h
    simp [h12, this, rawValue]
  · by_cases h6 : (6 : α) ≤ lag
    · have h6' := trans _ _ _ h6 h
      by_cases h12' : (12 : α) ≤ lag' <;> simp [h12, h6, h6', h12', rawValue]
    · by_cases h2 : (2 : α) ≤ lag
      · have h2' := trans _ _ _ h2 h
        by_cases h12' : (12 : α) ≤ lag' <;> by_cases h6' : (6 : α) ≤ lag' <;>
          simp [h12, h6, h2, h2', h12', h6', rawValue]
      · simp [h12, h6, h2, rawValue]

end

/-- The thresholds on whole seconds: the function is not constant, and each level is reached. -/
example : ofLag (0 : Nat) = .normal ∧ ofLag (1 : Nat) = .normal ∧ ofLag (2 : Nat) = .screenPaused ∧
    ofLag (5 : Nat) = .screenPaused ∧ ofLag (6 : Nat) = .aiPaused ∧ ofLag (11 : Nat) = .aiPaused ∧
    ofLag (12 : Nat) = .transcriptDelayed ∧ ofLag (30 : Nat) = .transcriptDelayed := by decide

/-- The transitivity hypothesis of `ofLag_mono` is satisfiable: it holds for `Nat` and `Int`. -/
example (lag lag' : Nat) (h : lag ≤ lag') : ofLag lag ≤ ofLag lag' :=
  ofLag_mono (fun _ _ _ => Nat.le_trans) lag lag' h
example (lag lag' : Int) (h : lag ≤ lag') : ofLag lag ≤ ofLag lag' :=
  ofLag_mono (fun _ _ _ => Int.le_trans) lag lag' h

/-- WRONG ON PURPOSE: the middle comparison reversed (`lag <= 6` for `lag >= 6`). -/
def Broken.ofLag (lag : Nat) : RecordingPressure :=
  if 12 ≤ lag then .transcriptDelayed
  else if lag ≤ 6 then .aiPaused
  else if 2 ≤ lag then .screenPaused
  else .normal

/-- Seen to fail: the reversed variant is not monotone: lag 3 gives more pressure than lag 8. -/
example : ¬ (Broken.ofLag 3 ≤ Broken.ofLag 8) := by decide

end RecordingPressure

/-! # Meeting.canResume / resume() -/

/-- RecordingSession.swift:4-9  the properties the modelled code sets: `isInitial` is
    `id == "initial"` (every other id is a fresh UUID), `start`, and `end` (here `stop`).
    `sourceOffsets` and `screen` are dropped. -/
structure RecordingSession where
  isInitial : Bool
  start : Int
  stop : Option Int
  deriving DecidableEq, Repr

/-- Meeting.swift:16-75  the properties that `canResume` and `resume()` read or write.
    Times are `Int` seconds. `finalized` is `document?.finalized`. The cleared dictionaries
    `partials`, `partialSpeakers`, `partialIDs` are dropped. -/
structure Meeting (Text : Type) where
  startedAt : Int
  endedAt : Option Int
  status : String
  retention : Option String
  finalized : Option Bool
  purgeAt : Option Int
  failure : Option String
  recordingSessions : Option (List RecordingSession)
  notes : Option (List (Note Text))

namespace Meeting

variable {Text : Type} [DecidableEq Text]

/-- RecordingSession.swift:21-25
    ```
    guard let endedAt, now >= endedAt, now.timeIntervalSince(endedAt) < 600,
          retention != "purged", retention != "purging", document?.finalized != true else { return false }
    return status == "complete" || status == "interrupted"
    ``` -/
def canResume (m : Meeting Text) (now : Int) : Bool :=
  match m.endedAt with
  | none => false
  | some endedAt =>
    if endedAt ≤ now ∧ now - endedAt < 600 ∧ m.retention ≠ some "purged" ∧ m.retention ≠ some "purging"
        ∧ m.finalized ≠ some true then
      (m.status == "complete" || m.status == "interrupted")
    else false

/-- RecordingSession.swift:27-37  `resume(at:)`. `none` is `throw ResumeError.unavailable`.
    ```
    guard canResume(at: now) else { throw ResumeError.unavailable }
    if recordingSessions == nil {
        recordingSessions = [RecordingSession(id: "initial", start: 0, end: endedAt!.timeIntervalSince(startedAt), …)]
    }
    recordingSessions!.append(RecordingSession(start: now.timeIntervalSince(startedAt)))
    endedAt = nil; purgeAt = nil; retention = "live"; status = "recording"; failure = nil
    …
    for i in (notes ?? []).indices { notes![i].line.resume() }
    ``` -/
def resume (m : Meeting Text) (now : Int) : Option (Meeting Text) :=
  if m.canResume now = false then none
  else
    let sessions := match m.recordingSessions with
      | none => [{ isInitial := true, start := 0, stop := m.endedAt.map (· - m.startedAt) }]
      | some sessions => sessions
    some { m with
      recordingSessions := some (sessions ++ [{ isInitial := false, start := now - m.startedAt, stop := none }]),
      endedAt := none, purgeAt := none, retention := some "live", status := "recording", failure := none,
      notes := m.notes.map (fun notes => notes.map (fun n => { n with line := n.line.resume })) }

/-- The number of recording sessions; a meeting that has never been resumed (`nil`) counts as the
    one implicit initial session that `resume()` writes out for it. -/
def sessionCount (m : Meeting Text) : Nat :=
  match m.recordingSessions with
  | none => 1
  | some sessions => sessions.length

/-- `canResume` is true exactly for a meeting that has ended, at a time not before the end and less
    than 600 seconds after it, that is not purged, purging or finalized, and whose status is
    "complete" or "interrupted". (RecordingSession.swift:21-25) -/
theorem canResume_iff (m : Meeting Text) (now : Int) :
    m.canResume now = true ↔
      ∃ endedAt, m.endedAt = some endedAt ∧ endedAt ≤ now ∧ now < endedAt + 600 ∧
        m.retention ≠ some "purged" ∧ m.retention ≠ some "purging" ∧ m.finalized ≠ some true ∧
        (m.status = "complete" ∨ m.status = "interrupted") := by
  unfold canResume
  cases h : m.endedAt with
  | none => simp
  | some endedAt =>
    simp only [Option.some.injEq, exists_eq_left']
    constructor
    · intro hc
      split at hc
      · rename_i hg
        obtain ⟨h1, h2, h3, h4, h5⟩ := hg
        refine ⟨h1, by omega, h3, h4, h5, ?_⟩
        simpa using hc
      · simp at hc
    · rintro ⟨h1, h2, h3, h4, h5, h6⟩
      have hg : endedAt ≤ now ∧ now - endedAt < 600 ∧ m.retention ≠ some "purged" ∧
          m.retention ≠ some "purging" ∧ m.finalized ≠ some true := ⟨h1, by omega, h3, h4, h5⟩
      split
      · simpa using h6
      · rename_i hn; exact absurd hg hn

/-- `resume()` succeeds exactly when `canResume` is true. (RecordingSession.swift:28) -/
theorem resume_isSome_iff (m : Meeting Text) (now : Int) :
    (m.resume now).isSome = true ↔ m.canResume now = true := by
  unfold resume
  cases h : m.canResume now <;> simp

/-- After a successful resume the meeting cannot be resumed again, at any time, until it ends
    again: `canResume` is false. (RecordingSession.swift:21-22, 34) -/
theorem resume_then_cannot_resume (m m' : Meeting Text) (now : Int) (h : m.resume now = some m')
    (later : Int) : m'.canResume later = false := by
  unfold resume at h
  split at h
  · simp at h
  · simp only [Option.some.injEq] at h
    subst h
    simp [canResume]

/-- After a successful resume the status is "recording", retention is "live", and the end time,
    purge time and failure are cleared. (RecordingSession.swift:34) -/
theorem resume_status (m m' : Meeting Text) (now : Int) (h : m.resume now = some m') :
    m'.status = "recording" ∧ m'.retention = some "live" ∧ m'.endedAt = none ∧ m'.purgeAt = none ∧
      m'.failure = none := by
  unfold resume at h
  split at h
  · simp at h
  · simp only [Option.some.injEq] at h
    subst h
    simp

/-- After a successful resume the session count has grown by exactly one, every earlier session
    is still there in order, and the new last session starts at `now - startedAt` with no end.
    (RecordingSession.swift:29-33) -/
theorem resume_sessions (m m' : Meeting Text) (now : Int) (h : m.resume now = some m') :
    m'.sessionCount = m.sessionCount + 1 ∧
      ∃ earlier, m'.recordingSessions = some (earlier ++ [{ isInitial := false, start := now - m.startedAt, stop := none }]) ∧
        (m.recordingSessions = some earlier ∨
          (m.recordingSessions = none ∧
            earlier = [{ isInitial := true, start := 0, stop := m.endedAt.map (· - m.startedAt) }])) := by
  unfold resume at h
  split at h
  · simp at h
  · simp only [Option.some.injEq] at h
    subst h
    cases hs : m.recordingSessions with
    | none => simp [sessionCount, hs]
    | some sessions => simp [sessionCount, hs]

/-- After a successful resume every note's line is the old line with `Line.resume()` applied, so
    no line is left `.settled` or `.quiet`, and a line the user owns is untouched.
    (RecordingSession.swift:36, Line.swift:23) -/
theorem resume_lines (m m' : Meeting Text) (now : Int) (h : m.resume now = some m') :
    m'.notes = m.notes.map (fun notes => notes.map (fun n => { n with line := n.line.resume })) ∧
      ∀ notes', m'.notes = some notes' → ∀ n' ∈ notes',
        n'.line.state ≠ .settled ∧ n'.line.state ≠ .quiet := by
  unfold resume at h
  split at h
  · simp at h
  · simp only [Option.some.injEq] at h
    subst h
    refine ⟨rfl, ?_⟩
    intro notes' hn n' hn'
    cases hnotes : m.notes with
    | none => simp [hnotes] at hn
    | some notes =>
      simp only [hnotes, Option.map_some, Option.some.injEq] at hn
      subst hn
      obtain ⟨n, _, rfl⟩ := List.mem_map.mp hn'
      exact resume_not_settled n.line

/-- A meeting that satisfies `canResume`: ended 60 seconds ago with status "complete". -/
def sample : Meeting Nat :=
  { startedAt := 1000, endedAt := some 1060, status := "complete", retention := none, finalized := none,
    purgeAt := some 87460, failure := none, recordingSessions := none,
    notes := some [(Note.new 0 (some 5) false).run [.apply (.line 7 []) 1 0 0, .settle]] }

/-- The hypothesis `m.resume now = some m'` is satisfiable, the ten-minute boundary is where the
    existing test puts it (1599 yes, 1600 no on an end at 1000), and resuming twice fails. -/
example : (sample.resume 1090).isSome = true ∧
    ((sample.resume 1090).bind (·.resume 1091)).isSome = false ∧
    sample.canResume 1659 = true ∧ sample.canResume 1660 = false ∧ sample.canResume 1059 = false := by
  simp [sample, resume, canResume]

/-- WRONG ON PURPOSE: a `resume` that forgets `endedAt = nil`. -/
def Broken.resume (m : Meeting Nat) (now : Int) : Meeting Nat :=
  { m with status := "complete", recordingSessions := some [] , purgeAt := now }

/-- Seen to fail: without clearing `endedAt`, the meeting can be resumed again. -/
example : (Broken.resume sample 1090).canResume 1091 = true := by
  simp [sample, Broken.resume, canResume]

end Meeting

/-! # TitlePolicy.canGenerate -/

namespace TitlePolicy

/-- TitlePolicy.swift:4-10  `canGenerate(_:final:)`. `titleOrigin` and `titleFinal` are the two
    `Meeting` properties it reads; `words` is the word count computed on line 8.
    ```
    guard meeting.titleOrigin == "pending" || meeting.titleOrigin == "automatic" else { return false }
    if meeting.titleFinal == true { return false }
    if !final && meeting.titleOrigin == "automatic" { return false }
    return words >= (final ? 6 : 45)
    ``` -/
def canGenerate (titleOrigin : Option String) (titleFinal : Option Bool) (words : Nat) (final : Bool) : Bool :=
  if ¬ (titleOrigin = some "pending" ∨ titleOrigin = some "automatic") then false
  else if titleFinal = some true then false
  else if final = false ∧ titleOrigin = some "automatic" then false
  else decide (words ≥ (if final = true then 6 else 45))

/-- A title can be generated only when its origin is "pending" or "automatic" and it is not
    final: no other origin (including a missing one on a legacy recording) is ever replaced. -/
theorem canGenerate_requires (titleOrigin : Option String) (titleFinal : Option Bool) (words : Nat)
    (final : Bool) (h : canGenerate titleOrigin titleFinal words final = true) :
    (titleOrigin = some "pending" ∨ titleOrigin = some "automatic") ∧ titleFinal ≠ some true := by
  unfold canGenerate at h
  split at h
  · simp at h
  · rename_i ho
    split at h
    · simp at h
    · rename_i hf
      exact ⟨Classical.not_not.mp ho, hf⟩

/-- A manual title is never replaced. -/
theorem canGenerate_manual (titleFinal : Option Bool) (words : Nat) (final : Bool) :
    canGenerate (some "manual") titleFinal words final = false := by
  simp [canGenerate]

/-- A legacy recording with no recorded origin is treated as manual: never replaced. -/
theorem canGenerate_legacy (titleFinal : Option Bool) (words : Nat) (final : Bool) :
    canGenerate none titleFinal words final = false := by
  simp [canGenerate]

/-- A final title is never replaced, whatever its origin. -/
theorem canGenerate_final_title (titleOrigin : Option String) (words : Nat) (final : Bool) :
    canGenerate titleOrigin (some true) words final = false := by
  unfold canGenerate
  split <;> simp

/-- The live (non-final) pass never replaces an automatic title; only the final pass can. -/
theorem canGenerate_live_keeps_automatic (titleFinal : Option Bool) (words : Nat) :
    canGenerate (some "automatic") titleFinal words false = false := by
  unfold canGenerate
  split
  · rfl
  · split <;> simp

/-- The function is not constantly false: a pending title with enough words can be generated,
    live at 45 words and on the final pass at 6, and not with fewer. -/
example : canGenerate (some "pending") none 45 false = true ∧ canGenerate (some "pending") none 44 false = false ∧
    canGenerate (some "pending") none 6 true = true ∧ canGenerate (some "pending") none 5 true = false ∧
    canGenerate (some "automatic") (some false) 6 true = true := by
  simp [canGenerate]

/-- WRONG ON PURPOSE: `canGenerate` without the origin guard. -/
def Broken.canGenerate (titleFinal : Option Bool) (words : Nat) : Bool :=
  if titleFinal = some true then false else decide (words ≥ 6)

/-- Seen to fail: without the origin guard a manual title with enough words would be replaced. -/
example : Broken.canGenerate none 10 = true := by decide

end TitlePolicy

end WorkScribe
