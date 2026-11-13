/-
  Auto-record policy.

  Swift sources transcribed here (worktree `WorkScribe-codex`, branch `codex-backend`, working
  tree of 2026-11-11, which is commit edcaeba plus uncommitted changes):
    Sources/WorkScribeCore/AutoRecordPolicy.swift   lines 5-43
  Callers read to decide what a trace is (not transcribed; AppModel.swift was being edited by
  someone else while this was written, so these line numbers are those seen on 2026-11-11):
    Sources/WorkScribe/AppModel.swift:165-191  `checkCall`, every 2 s, calls `update` (line 176)
    Sources/WorkScribe/AppModel.swift:16       `autoRecordCalls` off calls `reset()`
    Sources/WorkScribe/AppModel.swift:349      a failed automatic start calls `suppressCurrentCall()`
    Sources/WorkScribe/AppModel.swift:365      a refused captions start calls `suppressCurrentCall()`
    Sources/WorkScribe/AppModel.swift:443      a manual stop calls `suppressCurrentCall()`
    Sources/WorkScribe/AppModel.swift:181-186  when the automatic `start` returns and this call's
                                               recording is not running, `startDidNotBegin()`
  `startDidNotBegin()` is modelled as one more event that may arrive at any point of a trace,
  which is more than this one caller does.

  Time is `Nat` seconds. The policy only ever sees the samples it is given, so "continuously
  active" below always means "active at every sample taken in that span".

  History. The first version of this file proved that once `.start` was returned nothing but a
  suppress, a reset, a disabling update or 120 s of absence would ever make the policy ask again,
  so a start that did not begin a recording cost the whole call (`stuck_latch`). The policy has
  since gained `startDidNotBegin()` (AutoRecordPolicy.swift:23-26) as the way out. `stuck_latch`
  is still true of `update` alone and is kept; `start_again_after_startDidNotBegin` and
  `stuck_latch_released` prove the way out.
-/

namespace WorkScribe

/-- AutoRecordPolicy.swift:6  `enum Action { case none, start, stop }` -/
inductive Action where
  | none | start | stop
  deriving DecidableEq, Repr

/-- AutoRecordPolicy.swift:7-12  the stored properties, with the Swift defaults.
    `TimeInterval`/`Date` are `Nat` seconds. -/
structure AutoRecordPolicy where
  settleSeconds : Nat := 3
  endGraceSeconds : Nat := 120
  candidateSince : Option Nat := none
  absentSince : Option Nat := none
  suppressed : Bool := false
  requestedStart : Bool := false
  deriving DecidableEq, Repr

namespace AutoRecordPolicy

/-- AutoRecordPolicy.swift:14-16
    `suppressed = true; candidateSince = nil; absentSince = nil; requestedStart = false` -/
def suppressCurrentCall (p : AutoRecordPolicy) : AutoRecordPolicy :=
  { p with suppressed := true, candidateSince := none, absentSince := none, requestedStart := false }

/-- AutoRecordPolicy.swift:17-19
    `candidateSince = nil; absentSince = nil; requestedStart = false; suppressed = false` -/
def reset (p : AutoRecordPolicy) : AutoRecordPolicy :=
  { p with candidateSince := none, absentSince := none, requestedStart := false, suppressed := false }

/-- AutoRecordPolicy.swift:23-26
    ```
    mutating func startDidNotBegin() {
        guard !suppressed else { return }
        requestedStart = false; candidateSince = nil
    }
    ```
    `absentSince` is not touched. -/
def startDidNotBegin (p : AutoRecordPolicy) : AutoRecordPolicy :=
  -- guard !suppressed else { return }
  if p.suppressed = true then p
  -- requestedStart = false; candidateSince = nil
  else { p with requestedStart := false, candidateSince := none }

/-- AutoRecordPolicy.swift:27-42  `update(callActive:enabled:busy:automaticallyRecording:now:)`.
    Returns the new policy and the action.

    Two spellings differ from the Swift and mean the same:
    * `if candidateSince == nil { candidateSince = now }` is `candidateSince := some (candidateSince.getD now)`
      (same for `absentSince`);
    * `now.timeIntervalSince(since!) >= settleSeconds` is `since + settleSeconds ≤ now`, which is the
      same comparison without a subtraction, so it is also right when `now` is before `since`. -/
def update (p : AutoRecordPolicy) (callActive enabled busy automaticallyRecording : Bool) (now : Nat) :
    AutoRecordPolicy × Action :=
  -- guard enabled else { reset(); return .none }
  if enabled = false then (p.reset, .none)
  else if callActive = true then
    -- absentSince = nil
    let p := { p with absentSince := none }
    -- guard !suppressed else { return .none }
    if p.suppressed = true then (p, .none)
    else
      -- if candidateSince == nil { candidateSince = now }
      let since := p.candidateSince.getD now
      let p := { p with candidateSince := some since }
      -- guard !busy, !requestedStart, now.timeIntervalSince(candidateSince!) >= settleSeconds else { return .none }
      if busy = false ∧ p.requestedStart = false ∧ since + p.settleSeconds ≤ now then
        -- requestedStart = true; return .start
        ({ p with requestedStart := true }, .start)
      else (p, .none)
  else
    -- candidateSince = nil
    let p := { p with candidateSince := none }
    -- if absentSince == nil { absentSince = now }
    let since := p.absentSince.getD now
    let p := { p with absentSince := some since }
    -- guard now.timeIntervalSince(absentSince!) >= endGraceSeconds else { return .none }
    if since + p.endGraceSeconds ≤ now then
      -- suppressed = false; requestedStart = false
      -- return automaticallyRecording ? .stop : .none
      ({ p with suppressed := false, requestedStart := false },
        if automaticallyRecording = true then .stop else .none)
    else (p, .none)

end AutoRecordPolicy

/-- One call into the policy. -/
inductive Event where
  /-- `update(callActive:enabled:busy:automaticallyRecording:now:)` -/
  | update (callActive enabled busy automaticallyRecording : Bool) (now : Nat)
  /-- `suppressCurrentCall()` -/
  | suppress
  /-- `reset()` -/
  | reset
  /-- `startDidNotBegin()` -/
  | startDidNotBegin
  deriving DecidableEq, Repr

namespace Event

/-- An `update` with the feature enabled and a call detected. -/
def IsActiveSample : Event → Prop
  | .update true true _ _ _ => True
  | _ => False

/-- An `update` with the feature enabled and no call detected. -/
def IsAbsentSample : Event → Prop
  | .update false true _ _ _ => True
  | _ => False

/-- An `update` with the feature enabled (call detected or not). -/
def IsSample : Event → Prop
  | .update _ true _ _ _ => True
  | _ => False

/-- An event that leaves a run of call-absent samples unbroken: a call-absent sample, or
    `startDidNotBegin()`, which is not a sample and does not touch `absentSince`. -/
def KeepsAbsence : Event → Prop
  | .update false true _ _ _ => True
  | .startDidNotBegin => True
  | _ => False

instance (e : Event) : Decidable e.IsActiveSample := by
  cases e with
  | update ca en b ar now => cases ca <;> cases en <;> simp only [IsActiveSample] <;> infer_instance
  | suppress => simp only [IsActiveSample]; infer_instance
  | reset => simp only [IsActiveSample]; infer_instance
  | startDidNotBegin => simp only [IsActiveSample]; infer_instance

instance (e : Event) : Decidable e.IsAbsentSample := by
  cases e with
  | update ca en b ar now => cases ca <;> cases en <;> simp only [IsAbsentSample] <;> infer_instance
  | suppress => simp only [IsAbsentSample]; infer_instance
  | reset => simp only [IsAbsentSample]; infer_instance
  | startDidNotBegin => simp only [IsAbsentSample]; infer_instance

instance (e : Event) : Decidable e.KeepsAbsence := by
  cases e with
  | update ca en b ar now => cases ca <;> cases en <;> simp only [KeepsAbsence] <;> infer_instance
  | suppress => simp only [KeepsAbsence]; infer_instance
  | reset => simp only [KeepsAbsence]; infer_instance
  | startDidNotBegin => simp only [KeepsAbsence]; infer_instance

/-- A call-absent sample keeps an absent run unbroken. -/
theorem IsAbsentSample.keepsAbsence {e : Event} (h : e.IsAbsentSample) : e.KeepsAbsence := by
  cases e with
  | update ca en b ar now => cases ca <;> cases en <;> simp_all [IsAbsentSample, KeepsAbsence]
  | suppress => simp [IsAbsentSample] at h
  | reset => simp [IsAbsentSample] at h
  | startDidNotBegin => trivial

end Event

namespace AutoRecordPolicy

/-- One event applied to the policy: the new policy and the action handed back to the caller. -/
def step (p : AutoRecordPolicy) : Event → AutoRecordPolicy × Action
  | .update ca en b ar now => p.update ca en b ar now
  | .suppress => (p.suppressCurrentCall, .none)
  | .reset => (p.reset, .none)
  | .startDidNotBegin => (p.startDidNotBegin, .none)

/-- The policy after a sequence of events. -/
def run (p : AutoRecordPolicy) (es : List Event) : AutoRecordPolicy :=
  es.foldl (fun p e => (p.step e).1) p

/-- The actions returned by a sequence of events, in order. -/
def actions (p : AutoRecordPolicy) : List Event → List Action
  | [] => []
  | e :: es => (p.step e).2 :: actions (p.step e).1 es

/-- A policy as `AutoRecordPolicy()` leaves it, for any two thresholds. -/
def Fresh (p : AutoRecordPolicy) : Prop :=
  p.candidateSince = none ∧ p.absentSince = none ∧ p.suppressed = false ∧ p.requestedStart = false

end AutoRecordPolicy

/-- The trace `es` ends with an unbroken run of enabled call-active samples, and one sample of
    that run was taken at time `t`. (When the policy's `candidateSince` is `t`, that sample is
    the first of the run.) Nothing but call-active samples may follow the sample at `t`: a
    `startDidNotBegin()` ends the run, like a suppress or a reset. -/
def ActiveSince (es : List Event) (t : Nat) : Prop :=
  ∃ pre b a rest, es = pre ++ .update true true b a t :: rest ∧ ∀ e ∈ rest, e.IsActiveSample

/-- The trace `es` ends with an unbroken run of enabled call-absent samples, and one sample of
    that run was taken at time `t`. "Unbroken" means no other sample, no suppress and no reset
    since the sample at `t`; calls of `startDidNotBegin()` may lie in between, because that
    method leaves `absentSince` alone (`Event.KeepsAbsence`). -/
def AbsentSince (es : List Event) (t : Nat) : Prop :=
  ∃ pre b a rest, es = pre ++ .update false true b a t :: rest ∧ ∀ e ∈ rest, e.KeepsAbsence

/-- Event `e`, arriving after history `hist`, is a call-absent sample at a time `now` that closes
    an unbroken run of call-absent samples reaching back at least `grace` seconds. -/
def GraceElapsed (grace : Nat) (hist : List Event) (e : Event) : Prop :=
  ∃ b a now t, e = .update false true b a now ∧ AbsentSince (hist ++ [e]) t ∧ t + grace ≤ now

/-- Event `e`, arriving after history `hist`, is one of the five things that can release the
    start latch: `suppressCurrentCall()`, `reset()`, an `update` with `enabled: false`, a
    call-absent sample that completes `grace` seconds of continuous absence, or
    `startDidNotBegin()`. -/
def Releases (grace : Nat) (hist : List Event) (e : Event) : Prop :=
  e = .suppress ∨ e = .reset ∨ (∃ ca b a now, e = .update ca false b a now) ∨ GraceElapsed grace hist e
    ∨ e = .startDidNotBegin

namespace AutoRecordPolicy

/-! # Theorems -/

@[simp] theorem run_nil (p : AutoRecordPolicy) : p.run [] = p := rfl
@[simp] theorem run_cons (p : AutoRecordPolicy) (e : Event) (es : List Event) :
    p.run (e :: es) = (p.step e).1.run es := rfl
theorem run_append (p : AutoRecordPolicy) (a b : List Event) : p.run (a ++ b) = (p.run a).run b := by
  simp [run, List.foldl_append]

/-- `AutoRecordPolicy()` is fresh. -/
theorem fresh_init : Fresh {} := by simp [Fresh]

/-! ## What one `update` does, case by case (a readable restatement of lines 27-42) -/

/-- With `enabled: false`, `update` is `reset()` and returns `.none`. -/
theorem update_disabled (p : AutoRecordPolicy) (ca b ar : Bool) (now : Nat) :
    p.update ca false b ar now = (p.reset, .none) := by
  simp [update]

/-- A call-active sample while suppressed only clears `absentSince` and returns `.none`. -/
theorem update_active_suppressed (p : AutoRecordPolicy) (hs : p.suppressed = true) (b ar : Bool)
    (now : Nat) : p.update true true b ar now = ({ p with absentSince := none }, .none) := by
  simp [update, hs]

/-- A call-active sample while not suppressed. -/
theorem update_active (p : AutoRecordPolicy) (hs : p.suppressed = false) (b ar : Bool) (now : Nat) :
    p.update true true b ar now =
      if b = false ∧ p.requestedStart = false ∧ p.candidateSince.getD now + p.settleSeconds ≤ now then
        ({ p with absentSince := none, candidateSince := some (p.candidateSince.getD now),
                  requestedStart := true }, .start)
      else
        ({ p with absentSince := none, candidateSince := some (p.candidateSince.getD now) }, .none) := by
  simp [update, hs]

/-- A call-absent sample. -/
theorem update_absent (p : AutoRecordPolicy) (b ar : Bool) (now : Nat) :
    p.update false true b ar now =
      if p.absentSince.getD now + p.endGraceSeconds ≤ now then
        ({ p with candidateSince := none, absentSince := some (p.absentSince.getD now),
                  suppressed := false, requestedStart := false },
          if ar = true then .stop else .none)
      else
        ({ p with candidateSince := none, absentSince := some (p.absentSince.getD now) }, .none) := by
  simp [update]

/-- `startDidNotBegin()` on a suppressed policy changes nothing. (AutoRecordPolicy.swift:24) -/
theorem startDidNotBegin_suppressed (p : AutoRecordPolicy) (hs : p.suppressed = true) :
    p.startDidNotBegin = p := by
  simp [startDidNotBegin, hs]

/-- `startDidNotBegin()` on a policy that is not suppressed opens the latch and forgets the
    candidate; it leaves `absentSince`, `suppressed` and the thresholds alone.
    (AutoRecordPolicy.swift:25) -/
theorem startDidNotBegin_open (p : AutoRecordPolicy) (hs : p.suppressed = false) :
    p.startDidNotBegin = { p with requestedStart := false, candidateSince := none } := by
  simp [startDidNotBegin, hs]

/-- No event changes the two thresholds. -/
theorem step_thresholds (p : AutoRecordPolicy) (e : Event) :
    (p.step e).1.settleSeconds = p.settleSeconds ∧ (p.step e).1.endGraceSeconds = p.endGraceSeconds := by
  cases e with
  | suppress => simp [step, suppressCurrentCall]
  | reset => simp [step, reset]
  | startDidNotBegin => simp only [step, startDidNotBegin]; split <;> simp
  | update ca en b ar now =>
    cases en <;> cases ca <;> simp only [step, update] <;> (repeat' split) <;> simp_all [reset]

/-- No sequence of events changes the two thresholds. -/
theorem run_thresholds (p : AutoRecordPolicy) (es : List Event) :
    (p.run es).settleSeconds = p.settleSeconds ∧ (p.run es).endGraceSeconds = p.endGraceSeconds := by
  induction es generalizing p with
  | nil => simp
  | cons e es ih =>
    have h1 := step_thresholds p e
    have h2 := ih (p.step e).1
    simp only [run_cons]
    exact ⟨h2.1.trans h1.1, h2.2.trans h1.2⟩

/-! ## The link between the policy's two timestamps and the trace -/

theorem ActiveSince.snoc {es : List Event} {t : Nat} {e : Event} (h : ActiveSince es t)
    (he : e.IsActiveSample) : ActiveSince (es ++ [e]) t := by
  obtain ⟨pre, b, a, rest, rfl, hr⟩ := h
  refine ⟨pre, b, a, rest ++ [e], by simp, ?_⟩
  intro x hx
  rcases List.mem_append.mp hx with hx | hx
  · exact hr x hx
  · simp at hx; subst hx; exact he

theorem AbsentSince.snoc {es : List Event} {t : Nat} {e : Event} (h : AbsentSince es t)
    (he : e.KeepsAbsence) : AbsentSince (es ++ [e]) t := by
  obtain ⟨pre, b, a, rest, rfl, hr⟩ := h
  refine ⟨pre, b, a, rest ++ [e], by simp, ?_⟩
  intro x hx
  rcases List.mem_append.mp hx with hx | hx
  · exact hr x hx
  · simp at hx; subst hx; exact he

theorem ActiveSince.here (es : List Event) (b a : Bool) (t : Nat) :
    ActiveSince (es ++ [.update true true b a t]) t :=
  ⟨es, b, a, [], rfl, by simp⟩

theorem AbsentSince.here (es : List Event) (b a : Bool) (t : Nat) :
    AbsentSince (es ++ [.update false true b a t]) t :=
  ⟨es, b, a, [], rfl, by simp⟩

/-- The invariant tying the policy `p` to the history `hist` that produced it:
    `candidateSince` is a sample of the current unbroken active run, `absentSince` is a sample of
    the current unbroken absent run, and a suppressed policy has no candidate and no latch. -/
structure Inv (hist : List Event) (p : AutoRecordPolicy) : Prop where
  cand : ∀ t, p.candidateSince = some t → ActiveSince hist t
  absent : ∀ t, p.absentSince = some t → AbsentSince hist t
  supp : p.suppressed = true → p.candidateSince = none ∧ p.requestedStart = false

/-- A fresh policy with an empty history satisfies the invariant. -/
theorem inv_fresh {p : AutoRecordPolicy} (h : p.Fresh) : Inv [] p := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  exact ⟨by simp [h1], by simp [h2], by simp [h3]⟩

/-- One event preserves the invariant. -/
theorem inv_step {hist : List Event} {p : AutoRecordPolicy} (h : Inv hist p) (e : Event) :
    Inv (hist ++ [e]) (p.step e).1 := by
  cases e with
  | suppress => exact ⟨by simp [step, suppressCurrentCall], by simp [step, suppressCurrentCall],
      by simp [step, suppressCurrentCall]⟩
  | reset => exact ⟨by simp [step, reset], by simp [step, reset], by simp [step, reset]⟩
  | startDidNotBegin =>
    cases hs : p.suppressed with
    | true =>
      simp only [step, startDidNotBegin_suppressed p hs]
      refine ⟨?_, fun t ht => AbsentSince.snoc (h.absent t ht) trivial, h.supp⟩
      intro t ht
      have := (h.supp hs).1
      simp_all
    | false =>
      simp only [step, startDidNotBegin_open p hs]
      exact ⟨by simp, fun t ht => AbsentSince.snoc (h.absent t ht) trivial, by simp [hs]⟩
  | update ca en b ar now =>
    cases en with
    | false =>
      simp only [step, update_disabled]
      exact ⟨by simp [reset], by simp [reset], by simp [reset]⟩
    | true =>
      cases ca with
      | true =>
        cases hs : p.suppressed with
        | true =>
          simp only [step, update_active_suppressed p hs]
          refine ⟨?_, by simp, ?_⟩
          · intro t ht
            have := (h.supp hs).1
            simp_all
          · intro _; exact h.supp hs
        | false =>
          simp only [step, update_active p hs]
          have hc : ActiveSince (hist ++ [Event.update true true b ar now]) (p.candidateSince.getD now) := by
            cases hcs : p.candidateSince with
            | none => simpa using ActiveSince.here hist b ar now
            | some t => simpa using ActiveSince.snoc (h.cand t hcs) (e := Event.update true true b ar now) trivial
          split
          · exact ⟨by intro t ht; simp at ht; subst ht; exact hc, by simp, by simp [hs]⟩
          · exact ⟨by intro t ht; simp at ht; subst ht; exact hc, by simp, by simp [hs]⟩
      | false =>
        simp only [step, update_absent]
        have ha : AbsentSince (hist ++ [Event.update false true b ar now]) (p.absentSince.getD now) := by
          cases has : p.absentSince with
          | none => simpa using AbsentSince.here hist b ar now
          | some t => simpa using AbsentSince.snoc (h.absent t has) (e := Event.update false true b ar now) trivial
        split
        · exact ⟨by simp, by intro t ht; simp at ht; subst ht; exact ha, by simp⟩
        · refine ⟨by simp, by intro t ht; simp at ht; subst ht; exact ha, ?_⟩
          intro hsup
          exact ⟨rfl, (h.supp hsup).2⟩

/-- Any sequence of events preserves the invariant. -/
theorem inv_run {hist : List Event} {p : AutoRecordPolicy} (h : Inv hist p) (es : List Event) :
    Inv (hist ++ es) (p.run es) := by
  induction es generalizing hist p with
  | nil => simpa using h
  | cons e es ih =>
    have := ih (inv_step h e)
    simpa using this

/-- The invariant holds for every policy reached from a fresh one. -/
theorem inv_of_fresh {p0 : AutoRecordPolicy} (h0 : p0.Fresh) (es : List Event) : Inv es (p0.run es) := by
  simpa using inv_run (inv_fresh h0) es

/-! ## (a) `.start` -/

/-- (a), one call: `update` returns `.start` only if the call is active, the feature enabled, the
    app not busy, the policy not suppressed and not already latched, and the candidate timestamp
    is at least `settleSeconds` old. (AutoRecordPolicy.swift:27-36) -/
theorem start_local (p : AutoRecordPolicy) (ca en b ar : Bool) (now : Nat)
    (h : (p.update ca en b ar now).2 = .start) :
    ca = true ∧ en = true ∧ b = false ∧ p.suppressed = false ∧ p.requestedStart = false ∧
      p.candidateSince.getD now + p.settleSeconds ≤ now := by
  cases en with
  | false => simp [update_disabled] at h
  | true =>
    cases ca with
    | false =>
      rw [update_absent] at h
      split at h <;> (try split at h) <;> simp_all
    | true =>
      cases hs : p.suppressed with
      | true => simp [update_active_suppressed p hs] at h
      | false =>
        rw [update_active p hs] at h
        split at h
        · simp_all
        · simp at h

/-- (a), one call, both directions: `update` returns `.start` exactly when the call is active, the
    feature enabled, the app not busy, the policy neither suppressed nor latched, and the
    candidate timestamp at least `settleSeconds` old. (AutoRecordPolicy.swift:27-36) -/
theorem start_iff (p : AutoRecordPolicy) (ca en b ar : Bool) (now : Nat) :
    (p.update ca en b ar now).2 = .start ↔
      (ca = true ∧ en = true ∧ b = false ∧ p.suppressed = false ∧ p.requestedStart = false ∧
        p.candidateSince.getD now + p.settleSeconds ≤ now) := by
  constructor
  · exact start_local p ca en b ar now
  · rintro ⟨rfl, rfl, rfl, hs, hr, ht⟩
    simp [update_active p hs, hr, ht]

/-- (a), over any trace from a fresh policy: `.start` is returned only when the call is active,
    the app is not busy, the policy is not suppressed, and the trace ends with an unbroken run of
    call-active samples that began at least `settleSeconds` before now. -/
theorem start_requires_settled_call (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (es : List Event)
    (ca en b ar : Bool) (now : Nat) (h : ((p0.run es).update ca en b ar now).2 = .start) :
    ca = true ∧ en = true ∧ b = false ∧ (p0.run es).suppressed = false ∧
      ∃ t, ActiveSince (es ++ [.update ca en b ar now]) t ∧ t + p0.settleSeconds ≤ now := by
  obtain ⟨hca, hen, hb, hs, _, ht⟩ := start_local _ ca en b ar now h
  subst hca hen
  refine ⟨rfl, rfl, hb, hs, (p0.run es).candidateSince.getD now, ?_, ?_⟩
  · cases hcs : (p0.run es).candidateSince with
    | none => simpa using ActiveSince.here es b ar now
    | some t =>
      simpa using ActiveSince.snoc ((inv_of_fresh h0 es).cand t hcs) (e := Event.update true true b ar now) trivial
  · rw [(run_thresholds p0 es).1] at ht; exact ht

/-- The policy does start: from a fresh policy, one call-active sample at `t0` followed by a
    call-active, not-busy sample at any `t1 ≥ t0 + settleSeconds` returns `.start`. -/
theorem start_fires_after_settle (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (hpos : 0 < p0.settleSeconds)
    (b ar ar' : Bool) (t0 t1 : Nat) (ht : t0 + p0.settleSeconds ≤ t1) :
    (p0.update true true b ar t0).2 = .none ∧
      ((p0.update true true b ar t0).1.update true true false ar' t1).2 = .start := by
  obtain ⟨h1, h2, h3, h4⟩ := h0
  have hno : ¬ (t0 + p0.settleSeconds ≤ t0) := by omega
  simp [update, h1, h3, h4, hno, ht]

/-! ## (c) `.stop` -/

/-- (c), one call: `update` returns `.stop` only if no call is detected, the feature is enabled,
    the recording was started automatically, and the absence timestamp is at least
    `endGraceSeconds` old. (AutoRecordPolicy.swift:37-41) -/
theorem stop_local (p : AutoRecordPolicy) (ca en b ar : Bool) (now : Nat)
    (h : (p.update ca en b ar now).2 = .stop) :
    ca = false ∧ en = true ∧ ar = true ∧ p.absentSince.getD now + p.endGraceSeconds ≤ now := by
  cases en with
  | false => simp [update_disabled] at h
  | true =>
    cases ca with
    | false =>
      rw [update_absent] at h
      split at h
      · cases ar <;> simp_all
      · simp at h
    | true =>
      cases hs : p.suppressed with
      | true => simp [update_active_suppressed p hs] at h
      | false =>
        rw [update_active p hs] at h
        split at h <;> simp at h

/-- (c), one call, both directions: `update` returns `.stop` exactly when no call is detected,
    the feature is enabled, the recording was started automatically, and the absence timestamp is
    at least `endGraceSeconds` old. (AutoRecordPolicy.swift:37-41) -/
theorem stop_iff (p : AutoRecordPolicy) (ca en b ar : Bool) (now : Nat) :
    (p.update ca en b ar now).2 = .stop ↔
      (ca = false ∧ en = true ∧ ar = true ∧ p.absentSince.getD now + p.endGraceSeconds ≤ now) := by
  constructor
  · exact stop_local p ca en b ar now
  · rintro ⟨rfl, rfl, rfl, ht⟩
    simp [update_absent, ht]

/-- (c), over any trace from a fresh policy: `.stop` is returned only when the recording was
    started automatically and the trace ends with an unbroken run of call-absent samples that
    began at least `endGraceSeconds` before now. A mute gap shorter than that never stops. -/
theorem stop_requires_grace (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (es : List Event)
    (ca en b ar : Bool) (now : Nat) (h : ((p0.run es).update ca en b ar now).2 = .stop) :
    ca = false ∧ en = true ∧ ar = true ∧
      ∃ t, AbsentSince (es ++ [.update ca en b ar now]) t ∧ t + p0.endGraceSeconds ≤ now := by
  obtain ⟨hca, hen, har, ht⟩ := stop_local _ ca en b ar now h
  subst hca hen
  refine ⟨rfl, rfl, har, (p0.run es).absentSince.getD now, ?_, ?_⟩
  · cases has : (p0.run es).absentSince with
    | none => simpa using AbsentSince.here es b ar now
    | some t =>
      simpa using AbsentSince.snoc ((inv_of_fresh h0 es).absent t has) (e := Event.update false true b ar now) trivial
  · rw [(run_thresholds p0 es).2] at ht; exact ht

/-- The policy does stop: from a fresh policy, a call-absent sample at `t0` followed by a
    call-absent sample at any `t1 ≥ t0 + endGraceSeconds`, during an automatic recording, returns
    `.stop`. -/
theorem stop_fires_after_grace (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (hpos : 0 < p0.endGraceSeconds)
    (b ar b' : Bool) (t0 t1 : Nat) (ht : t0 + p0.endGraceSeconds ≤ t1) :
    (p0.update false true b ar t0).2 = .none ∧
      ((p0.update false true b ar t0).1.update false true b' true t1).2 = .stop := by
  obtain ⟨h1, h2, h3, h4⟩ := h0
  have hno : ¬ (t0 + p0.endGraceSeconds ≤ t0) := by omega
  simp [update, h2, hno, ht]

/-- After a `.stop`, every later call-absent sample during an automatic recording returns `.stop`
    again (the caller, `AppModel.stop`, has to be idempotent, and is). -/
theorem stop_repeats (p : AutoRecordPolicy) (b b' : Bool) (now now' : Nat)
    (h : (p.update false true b true now).2 = .stop) (hle : now ≤ now') :
    ((p.update false true b true now).1.update false true b' true now').2 = .stop := by
  have hg : p.absentSince.getD now + p.endGraceSeconds ≤ now := (stop_local p false true b true now h).2.2.2
  have hg' : p.absentSince.getD now + p.endGraceSeconds ≤ now' := by omega
  simp [update_absent, hg, hg']

/-! ## (b) and (e)(i): the start latch -/

/-- An event that returns `.start` found the latch open and leaves it closed. -/
theorem start_latches (p : AutoRecordPolicy) (e : Event) (h : (p.step e).2 = .start) :
    p.requestedStart = false ∧ (p.step e).1.requestedStart = true := by
  cases e with
  | suppress => simp [step] at h
  | reset => simp [step] at h
  | startDidNotBegin => simp [step] at h
  | update ca en b ar now =>
    obtain ⟨hca, hen, hb, hs, hr, ht⟩ := start_local p ca en b ar now h
    subst hca hen hb
    refine ⟨hr, ?_⟩
    simp only [step, update_active p hs]
    simp [hr, ht]

/-- While the latch is closed, a call-active sample returns `.none` and leaves it closed, whatever
    `busy` and `automaticallyRecording` are. -/
theorem latched_active_sample (p : AutoRecordPolicy) (hl : p.requestedStart = true) (e : Event)
    (he : e.IsActiveSample) : (p.step e).2 = .none ∧ (p.step e).1.requestedStart = true := by
  cases e with
  | suppress => exact absurd he (by simp [Event.IsActiveSample])
  | reset => exact absurd he (by simp [Event.IsActiveSample])
  | startDidNotBegin => exact absurd he (by simp [Event.IsActiveSample])
  | update ca en b ar now =>
    cases ca <;> cases en <;> simp only [Event.IsActiveSample] at he
    cases hs : p.suppressed with
    | true => simp [step, update_active_suppressed p hs, hl]
    | false => simp [step, update_active p hs, hl]

/-- A closed latch stays closed through any event that is not one of the five releases. -/
theorem latch_persists {hist : List Event} {p : AutoRecordPolicy} (hinv : Inv hist p)
    (hl : p.requestedStart = true) (e : Event) (hr : ¬ Releases p.endGraceSeconds hist e) :
    (p.step e).1.requestedStart = true := by
  cases e with
  | suppress => exact absurd (Or.inl rfl) hr
  | reset => exact absurd (Or.inr (Or.inl rfl)) hr
  | startDidNotBegin => exact absurd (Or.inr (Or.inr (Or.inr (Or.inr rfl)))) hr
  | update ca en b ar now =>
    cases en with
    | false => exact absurd (Or.inr (Or.inr (Or.inl ⟨ca, b, ar, now, rfl⟩))) hr
    | true =>
      cases ca with
      | true => exact (latched_active_sample p hl (Event.update true true b ar now) trivial).2
      | false =>
        have hinv' := inv_step hinv (Event.update false true b ar now)
        simp only [step, update_absent] at hinv' ⊢
        split
        · rename_i hg
          exfalso
          apply hr
          refine Or.inr (Or.inr (Or.inr (Or.inl ⟨b, ar, now, p.absentSince.getD now, rfl, ?_, hg⟩)))
          simp only [hg, ↓reduceIte] at hinv'
          exact hinv'.absent _ rfl
        · exact hl

/-- With the latch closed, a later `.start` needs a release somewhere in between. -/
theorem latched_start_needs_release {hist : List Event} {p : AutoRecordPolicy} (hinv : Inv hist p)
    (hl : p.requestedStart = true) (mid : List Event) (e2 : Event)
    (h2 : ((p.run mid).step e2).2 = .start) :
    ∃ a r b, mid = a ++ r :: b ∧ Releases p.endGraceSeconds (hist ++ a) r := by
  induction mid generalizing hist p with
  | nil =>
    have := (start_latches p e2 (by simpa using h2)).1
    simp [hl] at this
  | cons e mid ih =>
    by_cases hr : Releases p.endGraceSeconds hist e
    · exact ⟨[], e, mid, rfl, by simpa using hr⟩
    · have hl' := latch_persists hinv hl e hr
      obtain ⟨a, r, b, hmid, hrel⟩ := ih (inv_step hinv e) hl' (by simpa using h2)
      refine ⟨e :: a, r, b, by simp [hmid], ?_⟩
      rw [(step_thresholds p e).2] at hrel
      simpa using hrel

/-- (b): after one `.start`, no second `.start` is returned until something releases the latch in
    between: `suppressCurrentCall()`, `reset()`, an `update` with `enabled: false`, a call-absent
    sample completing `endGraceSeconds` of continuous absence, or `startDidNotBegin()`. -/
theorem second_start_needs_release (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (pre mid : List Event)
    (e1 e2 : Event) (h1 : ((p0.run pre).step e1).2 = .start)
    (h2 : ((p0.run (pre ++ e1 :: mid)).step e2).2 = .start) :
    ∃ a r b, mid = a ++ r :: b ∧ Releases p0.endGraceSeconds (pre ++ e1 :: a) r := by
  have hinv : Inv (pre ++ [e1]) ((p0.run pre).step e1).1 := inv_step (inv_of_fresh h0 pre) e1
  have hl := (start_latches _ e1 h1).2
  have h2' : ((((p0.run pre).step e1).1.run mid).step e2).2 = .start := by
    simpa [run_append] using h2
  obtain ⟨a, r, b, hmid, hrel⟩ := latched_start_needs_release hinv hl mid e2 h2'
  refine ⟨a, r, b, hmid, ?_⟩
  rw [(step_thresholds _ e1).2, (run_thresholds p0 pre).2] at hrel
  simpa using hrel

/-- (e)(i), the stuck latch, still TRUE of `update` alone: once `.start` has been returned, every
    later call-active sample returns `.none` for as long as the call stays active, whether or not
    a recording ever began (`busy` and `automaticallyRecording` may be anything, including both
    false). `update` by itself never asks again for this call. The way out is for the caller to
    report that the start did not begin a recording: `startDidNotBegin()`, proved in
    `stuck_latch_released` below. -/
theorem stuck_latch (p : AutoRecordPolicy) (e1 : Event) (h1 : (p.step e1).2 = .start)
    (later : List Event) (hl : ∀ e ∈ later, e.IsActiveSample) :
    ∀ a r b, later = a ++ r :: b → (((p.step e1).1.run a).step r).2 = .none := by
  have key : ∀ (q : AutoRecordPolicy) (es : List Event), q.requestedStart = true →
      (∀ e ∈ es, e.IsActiveSample) →
      ∀ a r b, es = a ++ r :: b → ((q.run a).step r).2 = .none := by
    intro q es
    induction es generalizing q with
    | nil => intro _ _ a r b h; simp at h
    | cons e es ih =>
      intro hq hes a r b h
      cases a with
      | nil =>
        simp only [List.nil_append, List.cons.injEq] at h
        obtain ⟨rfl, _⟩ := h
        exact (latched_active_sample q hq e (hes e (by simp))).1
      | cons a0 a =>
        simp only [List.cons_append, List.cons.injEq] at h
        obtain ⟨rfl, h⟩ := h
        simpa using ih (q.step e).1 (latched_active_sample q hq e (hes e (by simp))).2
          (fun x hx => hes x (by simp [hx])) a r b h
  exact key _ later (start_latches p e1 h1).2 hl

/-! ## The way out of the stuck latch: `startDidNotBegin()` -/

/-- An event that returns `.start` is a call-active sample, and the policy was not suppressed. -/
theorem start_is_active_sample (p : AutoRecordPolicy) (e : Event) (h : (p.step e).2 = .start) :
    e.IsActiveSample ∧ p.suppressed = false := by
  cases e with
  | suppress => simp [step] at h
  | reset => simp [step] at h
  | startDidNotBegin => simp [step] at h
  | update ca en b ar now =>
    obtain ⟨hca, hen, _, hs, _, _⟩ := start_local p ca en b ar now h
    subst hca hen
    exact ⟨trivial, hs⟩

/-- A call-active sample never changes whether the policy is suppressed. -/
theorem active_sample_suppressed (p : AutoRecordPolicy) (e : Event) (he : e.IsActiveSample) :
    (p.step e).1.suppressed = p.suppressed := by
  cases e with
  | suppress => exact absurd he (by simp [Event.IsActiveSample])
  | reset => exact absurd he (by simp [Event.IsActiveSample])
  | startDidNotBegin => exact absurd he (by simp [Event.IsActiveSample])
  | update ca en b ar now =>
    cases ca <;> cases en <;> simp only [Event.IsActiveSample] at he
    cases hs : p.suppressed with
    | true => simp [step, update_active_suppressed p hs, hs]
    | false => simp only [step, update_active p hs]; split <;> simp [hs]

/-- No run of call-active samples changes whether the policy is suppressed. -/
theorem active_run_suppressed (p : AutoRecordPolicy) (es : List Event)
    (hes : ∀ e ∈ es, e.IsActiveSample) : (p.run es).suppressed = p.suppressed := by
  induction es generalizing p with
  | nil => rfl
  | cons e es ih =>
    simp only [run_cons]
    rw [ih _ (fun x hx => hes x (by simp [hx])), active_sample_suppressed p e (hes e (by simp))]

/-- NOTE. On every policy a trace can reach, the `guard !suppressed` in `startDidNotBegin()`
    makes no difference: a suppressed policy already has an open latch and no candidate, so
    clearing both changes nothing. The guard is harmless; suppression is protected by `update`
    (`suppressed_active_sample`), not by this guard. -/
theorem startDidNotBegin_guard_redundant {hist : List Event} {p : AutoRecordPolicy} (hinv : Inv hist p) :
    p.startDidNotBegin = { p with requestedStart := false, candidateSince := none } := by
  by_cases hs : p.suppressed = true
  · rw [startDidNotBegin_suppressed p hs]
    obtain ⟨h1, h2⟩ := hinv.supp hs
    cases p
    simp_all
  · exact startDidNotBegin_open p (by simpa using hs)

/-- The way out in its smallest form. On any policy that is not suppressed, `startDidNotBegin()`
    followed by a call-active sample at `t0` and a call-active, not-busy sample at any
    `t1 ≥ t0 + settleSeconds` returns `.none` and then `.start`. The policy is still not
    suppressed afterwards, so the same statement applies to the next attempt: nothing in the
    policy limits how many times this can repeat during one call. -/
theorem start_fires_after_startDidNotBegin (p : AutoRecordPolicy) (hs : p.suppressed = false)
    (hpos : 0 < p.settleSeconds) (b ar ar' : Bool) (t0 t1 : Nat) (ht : t0 + p.settleSeconds ≤ t1) :
    (p.startDidNotBegin.update true true b ar t0).2 = .none ∧
      ((p.startDidNotBegin.update true true b ar t0).1.update true true false ar' t1).2 = .start ∧
      ((p.startDidNotBegin.update true true b ar t0).1.update true true false ar' t1).1.suppressed = false := by
  have hno : ¬ (t0 + p.settleSeconds ≤ t0) := by omega
  simp [startDidNotBegin, update, hs, hno, ht]

/-- A policy that is not suppressed, has an open latch and a candidate from `t0` returns `.start`
    during any run of call-active samples that ends with a not-busy sample at some
    `t1 ≥ t0 + settleSeconds`: at that sample at the latest. -/
theorem start_in_settled_run (q : AutoRecordPolicy) (hs : q.suppressed = false)
    (hr : q.requestedStart = false) (t0 : Nat) (hc : q.candidateSince = some t0) (mid : List Event)
    (hmid : ∀ e ∈ mid, e.IsActiveSample) (ar' : Bool) (t1 : Nat) (ht : t0 + q.settleSeconds ≤ t1) :
    Action.start ∈ q.actions (mid ++ [.update true true false ar' t1]) := by
  induction mid generalizing q with
  | nil => simp [actions, step, update_active q hs, hr, hc, ht]
  | cons e mid ih =>
    have he := hmid e (by simp)
    cases e with
    | suppress => exact absurd he (by simp [Event.IsActiveSample])
    | reset => exact absurd he (by simp [Event.IsActiveSample])
    | startDidNotBegin => exact absurd he (by simp [Event.IsActiveSample])
    | update ca en b a now =>
      cases ca <;> cases en <;> simp only [Event.IsActiveSample] at he
      simp only [List.cons_append, actions, step, update_active q hs]
      split
      · simp
      · exact List.mem_cons_of_mem _
          (ih _ (by simp [hs]) (by simp [hr]) (by simp [hc]) (fun x hx => hmid x (by simp [hx]))
            (by simpa using ht))

/-- The way out in general. On any policy that is not suppressed, after `startDidNotBegin()`: if
    the call is then seen active at `t0`, is active at every later sample, and is seen active and
    not busy at some `t1 ≥ t0 + settleSeconds`, then `.start` is returned, at `t1` at the latest
    (it is among the actions returned for those samples). -/
theorem start_again_after_startDidNotBegin (p : AutoRecordPolicy) (hs : p.suppressed = false)
    (b ar : Bool) (t0 : Nat) (mid : List Event) (hmid : ∀ e ∈ mid, e.IsActiveSample)
    (ar' : Bool) (t1 : Nat) (ht : t0 + p.settleSeconds ≤ t1) :
    Action.start ∈ p.startDidNotBegin.actions
      (.update true true b ar t0 :: (mid ++ [.update true true false ar' t1])) := by
  have hs' : p.startDidNotBegin.suppressed = false := by simp [startDidNotBegin, hs]
  have hr' : p.startDidNotBegin.requestedStart = false := by simp [startDidNotBegin, hs]
  have hc' : p.startDidNotBegin.candidateSince = none := by simp [startDidNotBegin, hs]
  have hth : p.startDidNotBegin.settleSeconds = p.settleSeconds := by simp [startDidNotBegin, hs]
  simp only [actions, step, update_active _ hs']
  split
  · simp
  · exact List.mem_cons_of_mem _
      (start_in_settled_run _ (by simp [hs']) (by simp [hr']) t0 (by simp [hc']) mid hmid ar' t1
        (by simpa [hth] using ht))

/-- (e)(i) is escapable. After a `.start` that did not lead to a recording, and any number of
    further call-active samples (all of which return `.none`, by `stuck_latch`): once the caller
    reports `startDidNotBegin()`, a call that is then seen active at `t0`, is active at every
    later sample, and is seen active and not busy at some `t1 ≥ t0 + settleSeconds` gets `.start`
    again. -/
theorem stuck_latch_released (p : AutoRecordPolicy) (e1 : Event) (h1 : (p.step e1).2 = .start)
    (later : List Event) (hl : ∀ e ∈ later, e.IsActiveSample)
    (b ar : Bool) (t0 : Nat) (mid : List Event) (hmid : ∀ e ∈ mid, e.IsActiveSample)
    (ar' : Bool) (t1 : Nat) (ht : t0 + p.settleSeconds ≤ t1) :
    Action.start ∈ (((p.step e1).1.run later).startDidNotBegin).actions
      (.update true true b ar t0 :: (mid ++ [.update true true false ar' t1])) := by
  obtain ⟨he1, hs0⟩ := start_is_active_sample p e1 h1
  have hs : ((p.step e1).1.run later).suppressed = false := by
    rw [active_run_suppressed _ later hl, active_sample_suppressed p e1 he1]; exact hs0
  have hth : ((p.step e1).1.run later).settleSeconds = p.settleSeconds := by
    rw [(run_thresholds _ later).1, (step_thresholds p e1).1]
  exact start_again_after_startDidNotBegin _ hs b ar t0 mid hmid ar' t1 (by rw [hth]; exact ht)

/-- If a trace ends with an unbroken run of call-active samples through `t`, and the trace
    contains an event that is not a call-active sample, the run lies entirely after that event. -/
theorem ActiveSince.after {pre post : List Event} {e : Event} {t : Nat}
    (h : ActiveSince (pre ++ e :: post) t) (he : ¬ e.IsActiveSample) : ActiveSince post t := by
  obtain ⟨pre', b, a, rest, heq, hr⟩ := h
  rcases List.append_eq_append_iff.mp heq with ⟨as, _, h2⟩ | ⟨cs, _, h2⟩
  · cases as with
    | nil =>
      simp only [List.nil_append, List.cons.injEq] at h2
      exact absurd (h2.1 ▸ trivial : e.IsActiveSample) he
    | cons x as =>
      simp only [List.cons_append, List.cons.injEq] at h2
      exact ⟨as, b, a, rest, h2.2, hr⟩
  · cases cs with
    | nil =>
      simp only [List.nil_append, List.cons.injEq] at h2
      exact absurd (h2.1 ▸ trivial : e.IsActiveSample) he
    | cons x cs =>
      simp only [List.cons_append, List.cons.injEq] at h2
      exact absurd (hr e (by rw [h2.2]; simp)) he

/-- "The call must settle anew" (the doc comment at AutoRecordPolicy.swift:22). Over any trace
    from a fresh policy: if `.start` is returned after a `startDidNotBegin()`, the unbroken run of
    call-active samples that justifies it lies entirely after that `startDidNotBegin()`, and it
    began at least `settleSeconds` before now. Time the call was active before does not count. -/
theorem start_after_startDidNotBegin_settles_anew (p0 : AutoRecordPolicy) (h0 : p0.Fresh)
    (pre post : List Event) (ca en b ar : Bool) (now : Nat)
    (h : ((p0.run (pre ++ .startDidNotBegin :: post)).update ca en b ar now).2 = .start) :
    ∃ t, ActiveSince (post ++ [.update ca en b ar now]) t ∧ t + p0.settleSeconds ≤ now := by
  obtain ⟨_, _, _, _, t, hact, ht⟩ := start_requires_settled_call p0 h0 _ ca en b ar now h
  refine ⟨t, ?_, ht⟩
  have hsplit : (pre ++ Event.startDidNotBegin :: post) ++ [Event.update ca en b ar now]
      = pre ++ Event.startDidNotBegin :: (post ++ [Event.update ca en b ar now]) := by simp
  rw [hsplit] at hact
  exact ActiveSince.after hact (by simp [Event.IsActiveSample])

/-! ## (d) and (e)(ii): suppression -/

/-- (d), first half: a call-active sample never lifts suppression and returns `.none`. -/
theorem suppressed_active_sample (p : AutoRecordPolicy) (hs : p.suppressed = true) (e : Event)
    (he : e.IsActiveSample) : (p.step e).2 = .none ∧ (p.step e).1.suppressed = true := by
  cases e with
  | suppress => exact absurd he (by simp [Event.IsActiveSample])
  | reset => exact absurd he (by simp [Event.IsActiveSample])
  | startDidNotBegin => exact absurd he (by simp [Event.IsActiveSample])
  | update ca en b ar now =>
    cases ca <;> cases en <;> simp only [Event.IsActiveSample] at he
    simp [step, update_active_suppressed p hs, hs]

/-- (d), first half over time: no amount of call activity lifts suppression. -/
theorem activity_never_lifts_suppression (p : AutoRecordPolicy) (hs : p.suppressed = true)
    (es : List Event) (hes : ∀ e ∈ es, e.IsActiveSample) : (p.run es).suppressed = true := by
  induction es generalizing p with
  | nil => simpa using hs
  | cons e es ih =>
    simp only [run_cons]
    exact ih _ (suppressed_active_sample p hs e (hes e (by simp))).2 (fun x hx => hes x (by simp [hx]))

/-- One step of a suppressed policy that is neither `reset()`, nor a disabling `update`, nor a
    sample completing the grace period (so: a sample, a repeated suppress, or
    `startDidNotBegin()`): suppression stays and the action is `.none`. -/
theorem suppressed_step {hist : List Event} {p : AutoRecordPolicy} (hinv : Inv hist p)
    (hs : p.suppressed = true) (e : Event) (he : e.IsSample ∨ e = .suppress ∨ e = .startDidNotBegin)
    (hg : ¬ GraceElapsed p.endGraceSeconds hist e) :
    (p.step e).2 = .none ∧ (p.step e).1.suppressed = true := by
  cases e with
  | suppress => simp [step, suppressCurrentCall]
  | startDidNotBegin => simp [step, startDidNotBegin, hs]
  | reset => rcases he with he | he | he <;> simp [Event.IsSample] at he
  | update ca en b ar now =>
    cases en with
    | false => rcases he with he | he | he <;> simp [Event.IsSample] at he
    | true =>
      cases ca with
      | true => exact suppressed_active_sample p hs (Event.update true true b ar now) trivial
      | false =>
        have hinv' := inv_step hinv (Event.update false true b ar now)
        simp only [step, update_absent] at hinv' ⊢
        split
        · rename_i hgr
          exfalso
          apply hg
          refine ⟨b, ar, now, p.absentSince.getD now, rfl, ?_, hgr⟩
          simp only [hgr, ↓reduceIte] at hinv'
          exact hinv'.absent _ rfl
        · exact ⟨rfl, hs⟩

/-- (d), second half: if an event lifts suppression, it is `reset()`, an `update` with
    `enabled: false`, or a call-absent sample completing `endGraceSeconds` of continuous absence.
    In particular `startDidNotBegin()` never lifts it. -/
theorem suppression_lifted_only_by (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (hist : List Event)
    (e : Event) (hs : (p0.run hist).suppressed = true)
    (hl : ((p0.run hist).step e).1.suppressed = false) :
    e = .reset ∨ (∃ ca b a now, e = .update ca false b a now) ∨
      GraceElapsed p0.endGraceSeconds hist e := by
  cases e with
  | suppress => simp [step, suppressCurrentCall] at hl
  | reset => exact Or.inl rfl
  | startDidNotBegin => simp [step, startDidNotBegin, hs] at hl
  | update ca en b ar now =>
    cases en with
    | false => exact Or.inr (Or.inl ⟨ca, b, ar, now, rfl⟩)
    | true =>
      refine Or.inr (Or.inr ?_)
      apply Classical.byContradiction
      intro hg
      have := (suppressed_step (inv_of_fresh h0 hist) hs (Event.update ca true b ar now)
        (Or.inl (by cases ca <;> trivial)) (by rw [(run_thresholds p0 hist).2]; exact hg)).2
      simp [this] at hl

/-- (e)(ii), TRUE and unchanged by `startDidNotBegin()`: after `suppressCurrentCall()` (a manual
    stop, or a failed automatic start), for as long as the trace contains only samples, further
    suppresses and `startDidNotBegin()` calls, and no absence run reaches `endGraceSeconds`, the
    policy stays suppressed and every action is `.none`. The policy has no notion of which call
    is active, so a different call that begins within the grace period is never recorded
    automatically, however long it lasts. -/
theorem suppressed_until_long_absence (p0 : AutoRecordPolicy) (h0 : p0.Fresh) (hist : List Event)
    (hs : (p0.run hist).suppressed = true) (es : List Event)
    (hes : ∀ e ∈ es, e.IsSample ∨ e = .suppress ∨ e = .startDidNotBegin)
    (hgap : ∀ a r b, es = a ++ r :: b → ¬ GraceElapsed p0.endGraceSeconds (hist ++ a) r) :
    (p0.run (hist ++ es)).suppressed = true ∧
      ∀ a r b, es = a ++ r :: b → ((p0.run (hist ++ a)).step r).2 = .none := by
  have key : ∀ (es : List Event) (hist : List Event) (p : AutoRecordPolicy), Inv hist p →
      p.suppressed = true → (∀ e ∈ es, e.IsSample ∨ e = .suppress ∨ e = .startDidNotBegin) →
      (∀ a r b, es = a ++ r :: b → ¬ GraceElapsed p.endGraceSeconds (hist ++ a) r) →
      (p.run es).suppressed = true ∧ ∀ a r b, es = a ++ r :: b → ((p.run a).step r).2 = .none := by
    intro es
    induction es with
    | nil => intro hist p _ hs _ _; exact ⟨by simpa using hs, by intro a r b h; simp at h⟩
    | cons e es ih =>
      intro hist p hinv hs hes hgap
      have hstep := suppressed_step hinv hs e (hes e (by simp))
        (by simpa using hgap [] e es rfl)
      have hrec := ih (hist ++ [e]) (p.step e).1 (inv_step hinv e) hstep.2
        (fun x hx => hes x (by simp [hx]))
        (by
          intro a r b h
          rw [(step_thresholds p e).2]
          simpa using hgap (e :: a) r b (by simp [h]))
      refine ⟨by simpa using hrec.1, ?_⟩
      intro a r b h
      cases a with
      | nil =>
        simp only [List.nil_append, List.cons.injEq] at h
        obtain ⟨rfl, _⟩ := h
        simpa using hstep.1
      | cons a0 a =>
        simp only [List.cons_append, List.cons.injEq] at h
        obtain ⟨rfl, h⟩ := h
        simpa using hrec.2 a r b h
  have := key es hist (p0.run hist) (inv_of_fresh h0 hist) hs hes
    (by intro a r b h; rw [(run_thresholds p0 hist).2]; exact hgap a r b h)
  exact ⟨by simpa [run_append] using this.1, by
    intro a r b h; simpa [run_append] using this.2 a r b h⟩

/-! ## Concrete traces and checks against vacuity -/

section Checks

/-- The app's 2-second polling of one call: `.start` once the call has been active for three
    seconds, then nothing while the recording runs. -/
example : actions {} [.update true true false false 0, .update true true false false 2,
    .update true true false false 4, .update true true false true 6]
    = [.none, .none, .start, .none] := by decide

/-- (e)(i) on a concrete trace, `update` alone: `.start` at t = 4, the recording never begins
    (not busy, not automatically recording), the call stays active for two hours, and the policy
    never asks again. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .update true true false false 6, .update true true false false 600,
    .update true true false false 7200]
    = [.none, .start, .none, .none, .none] := by decide

/-- The way out on a concrete trace: the same call, but at t = 7 the caller reports that the
    start did not begin a recording. The call is seen again at t = 8, has not yet settled anew at
    t = 10, and is asked for again at t = 12. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .update true true false false 6, .startDidNotBegin,
    .update true true false false 8, .update true true false false 10,
    .update true true false false 12]
    = [.none, .start, .none, .none, .none, .none, .start] := by decide

/-- NOTE on a concrete trace: with `startDidNotBegin()` after every attempt, one call that stays
    active gets a new `.start` every time it has settled again: three in sixteen seconds here.
    The policy no longer limits attempts per call; how often it asks is now up to the caller. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .startDidNotBegin, .update true true false false 6, .update true true false false 10,
    .startDidNotBegin, .update true true false false 12, .update true true false false 16]
    = [.none, .start, .none, .none, .start, .none, .none, .start] := by decide

/-- `startDidNotBegin()` does not interrupt an absence run: an automatic recording still stops
    120 seconds after the call was last seen, with a `startDidNotBegin()` in between. -/
example : actions {} [.update false true true true 100, .startDidNotBegin,
    .update false true true true 220] = [.none, .none, .stop] := by decide

/-- (e)(ii) on a concrete trace: call A is recorded from t = 4; the user stops it by hand at
    t = 1800 (`suppress`); A ends, and 60 seconds later call B begins and runs for two hours.
    B is never recorded: every action after the manual stop is `.none`. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .suppress,
    .update false true false false 1802, .update false true false false 1860,
    .update true true false false 1862, .update true true false false 1866,
    .update true true false false 5000, .update true true false false 9062]
    = [.none, .start, .none, .none, .none, .none, .none, .none, .none] := by decide

/-- (e)(ii) is not helped by `startDidNotBegin()`: the same trace with that call after the manual
    stop and again once call B is active. B is still never recorded. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .suppress, .startDidNotBegin,
    .update false true false false 1802, .update false true false false 1860,
    .update true true false false 1862, .startDidNotBegin, .update true true false false 1866,
    .update true true false false 5000, .update true true false false 9062]
    = [.none, .start, .none, .none, .none, .none, .none, .none, .none, .none, .none] := by decide

/-- The same two calls with a gap of 130 seconds: B is recorded. The hypothesis "no absence run
    reaches the grace period" in `suppressed_until_long_absence` is what makes the difference. -/
example : actions {} [.update true true false false 0, .update true true false false 4,
    .suppress,
    .update false true false false 1802, .update false true false false 1932,
    .update true true false false 1934, .update true true false false 1938]
    = [.none, .start, .none, .none, .none, .none, .start] := by decide

/-- A mute gap of 118 seconds does not stop an automatic recording; 120 seconds does. -/
example : actions {} [.update false true true true 100, .update false true true true 218,
    .update true true true true 219, .update false true true true 220,
    .update false true true true 340]
    = [.none, .none, .none, .none, .stop] := by decide

namespace Broken

/-- WRONG ON PURPOSE: `update` without `!requestedStart` in the guard. -/
def updateNoLatch (p : AutoRecordPolicy) (callActive busy : Bool) (now : Nat) : AutoRecordPolicy × Action :=
  if callActive = true then
    if p.suppressed = true then ({ p with absentSince := none }, .none)
    else
      let since := p.candidateSince.getD now
      if busy = false ∧ since + p.settleSeconds ≤ now then
        ({ p with absentSince := none, candidateSince := some since, requestedStart := true }, .start)
      else ({ p with absentSince := none, candidateSince := some since }, .none)
  else ({ p with candidateSince := none }, .none)

/-- WRONG ON PURPOSE: `update` without `guard !suppressed`. -/
def updateIgnoresSuppression (p : AutoRecordPolicy) (now : Nat) : AutoRecordPolicy × Action :=
  let since := p.candidateSince.getD now
  if p.requestedStart = false ∧ since + p.settleSeconds ≤ now then
    ({ p with absentSince := none, candidateSince := some since, requestedStart := true }, .start)
  else ({ p with absentSince := none, candidateSince := some since }, .none)

/-- WRONG ON PURPOSE: the call-active branch forgets `absentSince = nil`, so separate mute gaps
    add up. -/
def updateKeepsAbsence (p : AutoRecordPolicy) (callActive ar : Bool) (now : Nat) : AutoRecordPolicy × Action :=
  if callActive = true then (p, .none)
  else
    let since := p.absentSince.getD now
    if since + p.endGraceSeconds ≤ now then
      ({ p with absentSince := some since }, if ar = true then .stop else .none)
    else ({ p with absentSince := some since }, .none)

/-- WRONG ON PURPOSE: `startDidNotBegin` that opens the latch but keeps `candidateSince`. -/
def startDidNotBeginKeepsCandidate (p : AutoRecordPolicy) : AutoRecordPolicy :=
  if p.suppressed = true then p else { p with requestedStart := false }

end Broken

/-- Seen to fail: if `startDidNotBegin` kept the candidate, the very next sample would return
    `.start` two seconds after the failed attempt, on the strength of time the call was active
    before it. `start_after_startDidNotBegin_settles_anew` forbids that for the real method,
    which returns `.none` here. -/
example :
    let latched := ((({} : AutoRecordPolicy).update true true false false 0).1.update true true false false 4).1
    ((Broken.startDidNotBeginKeepsCandidate latched).update true true false false 6).2 = .start ∧
      (latched.startDidNotBegin.update true true false false 6).2 = .none := by decide

/-- Seen to fail: without the latch, a second `.start` follows the first with no release in
    between, which `second_start_needs_release` forbids for the real `update`. -/
example :
    let p1 := (Broken.updateNoLatch {} true false 0).1
    let r2 := Broken.updateNoLatch p1 true false 4
    let r3 := Broken.updateNoLatch r2.1 true false 6
    r2.2 = .start ∧ r3.2 = .start := by decide

/-- Seen to fail: ignoring suppression starts a recording right after a manual stop. -/
example :
    let p := (AutoRecordPolicy.suppressCurrentCall {})
    let r1 := Broken.updateIgnoresSuppression p 10
    let r2 := Broken.updateIgnoresSuppression r1.1 14
    p.suppressed = true ∧ r2.2 = .start := by decide

/-- Seen to fail: if activity does not clear `absentSince`, two short mute gaps stop the
    recording although the call was never absent for 120 seconds in a row. -/
example :
    let r1 := Broken.updateKeepsAbsence {} false true 0
    let r2 := Broken.updateKeepsAbsence r1.1 true true 60
    let r3 := Broken.updateKeepsAbsence r2.1 false true 121
    r3.2 = .stop := by decide

/-- The hypotheses of `second_start_needs_release` are satisfiable: here are two starts, with a
    disabling `update` between them as the release. -/
example :
    let pre : List Event := [.update true true false false 0]
    let e1 : Event := .update true true false false 4
    let mid : List Event := [.update true false false false 6, .update true true false false 8]
    let e2 : Event := .update true true false false 12
    (((({} : AutoRecordPolicy).run pre).step e1).2 = .start) ∧
      (((({} : AutoRecordPolicy).run (pre ++ e1 :: mid)).step e2).2 = .start) := by decide

/-- The same with `startDidNotBegin()` as the release between the two starts. -/
example :
    let pre : List Event := [.update true true false false 0]
    let e1 : Event := .update true true false false 4
    let mid : List Event := [.startDidNotBegin, .update true true false false 6]
    let e2 : Event := .update true true false false 10
    (((({} : AutoRecordPolicy).run pre).step e1).2 = .start) ∧
      (((({} : AutoRecordPolicy).run (pre ++ e1 :: mid)).step e2).2 = .start) := by decide

/-- The hypotheses of `stuck_latch_released` are satisfiable: a `.start`, two more call-active
    samples, and after the release a first sample at 8 and a not-busy one at 12 ≥ 8 + 3. -/
example :
    let p := (({} : AutoRecordPolicy).run [.update true true false false 0])
    let e1 : Event := .update true true false false 4
    let later : List Event := [.update true true false false 6, .update true true true false 7]
    (p.step e1).2 = .start ∧ (∀ e ∈ later, e.IsActiveSample) ∧ 8 + p.settleSeconds ≤ 12 := by decide

/-- The hypothesis of `start_after_startDidNotBegin_settles_anew` is satisfiable. -/
example :
    let pre : List Event := [.update true true false false 0, .update true true false false 4]
    let post : List Event := [.update true true false false 6]
    (((({} : AutoRecordPolicy).run (pre ++ .startDidNotBegin :: post)).update true true false false 10).2
      = .start) := by decide

/-- The hypothesis of `startDidNotBegin_guard_redundant` holds on every policy reached from a
    fresh one (`inv_of_fresh`); here it is used on a suppressed one. -/
example : (({} : AutoRecordPolicy).run [.update true true false false 0, .suppress]).suppressed = true := by
  decide

/-- The hypothesis of `stop_requires_grace` is satisfiable. -/
example : (((({} : AutoRecordPolicy).run [.update false true true true 0]).update false true true true 120).2
    = .stop) := by decide

end Checks

end AutoRecordPolicy

end WorkScribe
