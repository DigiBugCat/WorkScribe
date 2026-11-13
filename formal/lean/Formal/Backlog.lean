/-
  Audio backlog accounting.

  Swift source transcribed here (worktree `WorkScribe-codex`, branch `codex-backend`):
    Sources/WorkScribeCore/AudioBacklog.swift   lines 6-59

  Each method body runs inside `lock.withLock`, so each is modelled as one atomic step. What the
  lock is assumed to give (no two bodies interleave) is not proved here.
  A `Data` value is a `List α` of bytes; `data.count` is its length. `Int` counters are unbounded.
-/

namespace WorkScribe

/-- AudioBacklog.swift:8-13  the stored properties. `failed` is `failure != nil`.
    `capacity` has no default: it is set by `init`. -/
structure AudioBacklog (α : Type) where
  chunks : List (List α) := []
  pending : Int := 0
  inFlight : Int := 0
  closed : Bool := false
  failed : Bool := false
  capacity : Int

/-- What `append` did: returned normally, threw because the backlog is closed
    (`failure ?? CocoaError(.userCancelled)`), or threw `Overflow()`. -/
inductive AppendResult where
  | ok | closedError | overflow
  deriving DecidableEq, Repr

/-- What one pass through the locked section of `next()` produced: a chunk, a thrown failure,
    `nil` because the backlog is closed and empty, or nothing yet (the caller sleeps 20 ms and
    runs the section again). -/
inductive NextResult (α : Type) where
  | data (bytes : List α)
  | failure
  | finished
  | wait

namespace AudioBacklog

variable {α : Type}

/-- AudioBacklog.swift:14  `init(seconds: Int = 30) { capacity = max(1, seconds) * 32_000 }` -/
def init (seconds : Int := 30) : AudioBacklog α := { capacity := max 1 seconds * 32000 }

/-- AudioBacklog.swift:19-25  `append(_:)`.
    ```
    guard !closed else { throw failure ?? CocoaError(.userCancelled) }
    guard data.count <= capacity - pending else { throw Overflow() }
    chunks.append(data); pending += data.count
    ``` -/
def append (b : AudioBacklog α) (data : List α) : AudioBacklog α × AppendResult :=
  if b.closed = true then (b, .closedError)
  else if ¬ ((data.length : Int) ≤ b.capacity - b.pending) then (b, .overflow)
  else ({ b with chunks := b.chunks ++ [data], pending := b.pending + data.length }, .ok)

/-- AudioBacklog.swift:26-28  `finish(throwing:)`: `closed = true; failure = error`.
    `error` is `error != nil`. -/
def finish (b : AudioBacklog α) (error : Bool) : AudioBacklog α :=
  { b with closed := true, failed := error }

/-- AudioBacklog.swift:29-31  `discard()`:
    `chunks.removeAll(); pending = 0; inFlight = 0; closed = true` -/
def discard (b : AudioBacklog α) : AudioBacklog α :=
  { b with chunks := [], pending := 0, inFlight := 0, closed := true }

/-- AudioBacklog.swift:32-37  `acknowledge(_:)`:
    ```
    let acknowledged = min(max(0, count), inFlight)
    inFlight -= acknowledged; pending -= acknowledged
    ``` -/
def acknowledge (b : AudioBacklog α) (count : Int) : AudioBacklog α :=
  let acknowledged := min (max 0 count) b.inFlight
  { b with inFlight := b.inFlight - acknowledged, pending := b.pending - acknowledged }

/-- AudioBacklog.swift:41-53  one pass through the locked section of `next()`.
    ```
    if !chunks.isEmpty {
        var data = chunks.removeFirst()
        if data.count > 32_000 {
            let remainder = Data(data.dropFirst(32_000))
            data = Data(data.prefix(32_000)); chunks.insert(remainder, at: 0)
        }
        inFlight += data.count
        return (data, false)
    }
    if let failure { throw failure }
    return (nil, closed)
    ``` -/
def next (b : AudioBacklog α) : AudioBacklog α × NextResult α :=
  match b.chunks with
  | data :: rest =>
    if data.length > 32000 then
      let remainder := data.drop 32000
      let data := data.take 32000
      ({ b with chunks := remainder :: rest, inFlight := b.inFlight + data.length }, .data data)
    else
      ({ b with chunks := rest, inFlight := b.inFlight + data.length }, .data data)
  | [] =>
    if b.failed = true then (b, .failure)
    else (b, if b.closed = true then .finished else .wait)

end AudioBacklog

/-- One call into the backlog. -/
inductive BacklogOp (α : Type) where
  | append (data : List α)
  | finish (error : Bool)
  | discard
  | acknowledge (count : Int)
  | next

namespace AudioBacklog

variable {α : Type}

/-- One call applied to the backlog (results are dropped; see `accepted` and `delivered`). -/
def step (b : AudioBacklog α) : BacklogOp α → AudioBacklog α
  | .append data => (b.append data).1
  | .finish error => b.finish error
  | .discard => b.discard
  | .acknowledge count => b.acknowledge count
  | .next => b.next.1

/-- A sequence of calls, applied left to right. -/
def run (b : AudioBacklog α) (ops : List (BacklogOp α)) : AudioBacklog α := ops.foldl step b

/-- Total number of bytes in a list of chunks. -/
def queued : List (List α) → Nat
  | [] => 0
  | c :: cs => c.length + queued cs

/-- All bytes that the `append` calls in `ops` accepted, in order. -/
def accepted (b : AudioBacklog α) : List (BacklogOp α) → List α
  | [] => []
  | .append data :: ops =>
    (if (b.append data).2 = .ok then data else []) ++ accepted (b.step (.append data)) ops
  | op :: ops => accepted (b.step op) ops

/-- All bytes that the `next` calls in `ops` handed out, in order. -/
def delivered (b : AudioBacklog α) : List (BacklogOp α) → List α
  | [] => []
  | .next :: ops =>
    (match b.next.2 with
      | .data bytes => bytes
      | _ => []) ++ delivered (b.step .next) ops
  | op :: ops => delivered (b.step op) ops

/-! # Theorems -/

@[simp] theorem run_nil (b : AudioBacklog α) : b.run [] = b := rfl
@[simp] theorem run_cons (b : AudioBacklog α) (op : BacklogOp α) (ops : List (BacklogOp α)) :
    b.run (op :: ops) = (b.step op).run ops := rfl

@[simp] theorem queued_nil : queued ([] : List (List α)) = 0 := rfl
@[simp] theorem queued_cons (c : List α) (cs : List (List α)) : queued (c :: cs) = c.length + queued cs := rfl
@[simp] theorem queued_append (a b : List (List α)) : queued (a ++ b) = queued a + queued b := by
  induction a with
  | nil => simp
  | cons c cs ih => simp [ih]; omega

/-- The byte count of the queue is the length of its concatenation. -/
theorem queued_eq_length_flatten (cs : List (List α)) : queued cs = cs.flatten.length := by
  induction cs with
  | nil => simp
  | cons c cs ih => simp [ih]

/-- The accounting invariant:
    `pending` is the queued bytes plus the in-flight bytes; `inFlight` is not negative; `pending`
    does not exceed `capacity`. -/
structure Inv (b : AudioBacklog α) : Prop where
  sum : b.pending = (queued b.chunks : Int) + b.inFlight
  inFlight_nonneg : 0 ≤ b.inFlight
  bound : b.pending ≤ b.capacity

/-- A new backlog satisfies the invariant, for any `seconds` (including zero and negative). -/
theorem inv_init (seconds : Int) : Inv (init seconds : AudioBacklog α) := by
  refine ⟨by simp [init], by simp [init], ?_⟩
  simp only [init]
  have : (1 : Int) ≤ max 1 seconds := Int.le_max_left 1 seconds
  omega

/-- `append` keeps the invariant, whether it accepts or rejects. (AudioBacklog.swift:19-25) -/
theorem inv_append {b : AudioBacklog α} (h : Inv b) (data : List α) : Inv (b.append data).1 := by
  obtain ⟨h1, h2, h3⟩ := h
  unfold append
  split
  · exact ⟨h1, h2, h3⟩
  · split
    · exact ⟨h1, h2, h3⟩
    · rename_i hc
      refine ⟨?_, h2, ?_⟩
      · simp; omega
      · simp at hc ⊢; omega

/-- `finish` keeps the invariant. (AudioBacklog.swift:26-28) -/
theorem inv_finish {b : AudioBacklog α} (h : Inv b) (error : Bool) : Inv (b.finish error) :=
  ⟨h.sum, h.inFlight_nonneg, h.bound⟩

/-- `discard` keeps the invariant: everything is zero afterwards, and `0 ≤ capacity` follows from
    the invariant before. (AudioBacklog.swift:29-31) -/
theorem inv_discard {b : AudioBacklog α} (h : Inv b) : Inv b.discard := by
  obtain ⟨h1, h2, h3⟩ := h
  refine ⟨by simp [discard], by simp [discard], ?_⟩
  simp only [discard]
  have : (0 : Int) ≤ (queued b.chunks : Int) := Int.natCast_nonneg _
  omega

/-- `acknowledge` keeps the invariant for every argument: negative, zero, more than is in flight.
    (AudioBacklog.swift:32-37) -/
theorem inv_acknowledge {b : AudioBacklog α} (h : Inv b) (count : Int) : Inv (b.acknowledge count) := by
  obtain ⟨h1, h2, h3⟩ := h
  simp only [acknowledge]
  refine ⟨?_, ?_, ?_⟩ <;> simp only [] <;> omega

/-- One pass of `next` keeps the invariant, with or without a split. (AudioBacklog.swift:41-53) -/
theorem inv_next {b : AudioBacklog α} (h : Inv b) : Inv b.next.1 := by
  obtain ⟨h1, h2, h3⟩ := h
  unfold next
  split
  · rename_i data rest hch
    rw [hch] at h1
    simp only [queued_cons] at h1
    split
    · rename_i hlen
      refine ⟨?_, ?_, h3⟩
      · simp only [queued_cons, List.length_drop, List.length_take]; omega
      · simp only [List.length_take]; omega
    · refine ⟨?_, ?_, h3⟩
      · simp only []; omega
      · simp only []; omega
  · split
    · exact ⟨h1, h2, h3⟩
    · exact ⟨h1, h2, h3⟩

/-- Every call keeps the invariant. -/
theorem inv_step {b : AudioBacklog α} (h : Inv b) (op : BacklogOp α) : Inv (b.step op) := by
  cases op with
  | append data => exact inv_append h data
  | finish error => exact inv_finish h error
  | discard => exact inv_discard h
  | acknowledge count => exact inv_acknowledge h count
  | next => exact inv_next h

/-- Every sequence of calls keeps the invariant. -/
theorem inv_run {b : AudioBacklog α} (h : Inv b) (ops : List (BacklogOp α)) : Inv (b.run ops) := by
  induction ops generalizing b with
  | nil => simpa using h
  | cons op ops ih => exact ih (inv_step h op)

/-- After any sequence of calls on a new backlog: `pending` equals queued bytes plus in-flight
    bytes, and `0 ≤ inFlight ≤ pending ≤ capacity`. No counter can go negative. -/
theorem accounting (seconds : Int) (ops : List (BacklogOp α)) :
    let b := (init seconds : AudioBacklog α).run ops
    b.pending = (queued b.chunks : Int) + b.inFlight ∧
      0 ≤ b.inFlight ∧ b.inFlight ≤ b.pending ∧ b.pending ≤ b.capacity := by
  have h := inv_run (inv_init (α := α) seconds) ops
  refine ⟨h.sum, h.inFlight_nonneg, ?_, h.bound⟩
  have h1 := h.sum
  have : (0 : Int) ≤ (queued ((init seconds : AudioBacklog α).run ops).chunks : Int) := Int.natCast_nonneg _
  omega

/-- `append` either rejects and leaves the backlog exactly as it was, or accepts, adds exactly
    `data.count` to `pending`, and `pending` is still within `capacity`. (AudioBacklog.swift:19-25) -/
theorem append_rejects_or_keeps_bound (b : AudioBacklog α) (data : List α) :
    ((b.append data).2 ≠ .ok ∧ (b.append data).1 = b) ∨
    ((b.append data).2 = .ok ∧ (b.append data).1.pending = b.pending + data.length ∧
      (b.append data).1.pending ≤ b.capacity ∧ (b.append data).1.chunks = b.chunks ++ [data]) := by
  unfold append
  split
  · simp
  · split
    · simp
    · rename_i hc
      refine Or.inr ⟨rfl, rfl, ?_, rfl⟩
      simp at hc ⊢; omega

/-- A closed backlog accepts nothing. (AudioBacklog.swift:21) -/
theorem append_closed (b : AudioBacklog α) (h : b.closed = true) (data : List α) :
    b.append data = (b, .closedError) := by
  simp [append, h]

/-- `acknowledge` removes the same amount from `inFlight` and `pending`, and that amount is
    between zero and what was in flight. (AudioBacklog.swift:32-37) -/
theorem acknowledge_clamped (b : AudioBacklog α) (h : 0 ≤ b.inFlight) (count : Int) :
    0 ≤ (b.acknowledge count).inFlight ∧ (b.acknowledge count).inFlight ≤ b.inFlight ∧
      b.pending - (b.acknowledge count).pending = b.inFlight - (b.acknowledge count).inFlight := by
  simp only [acknowledge]
  refine ⟨?_, ?_, ?_⟩ <;> omega

/-- `acknowledge` after `discard` changes nothing, whatever the argument (the pump's late
    acknowledgement after a failed start or a stop). (AudioBacklog.swift:29-37) -/
theorem acknowledge_after_discard (b : AudioBacklog α) (count : Int) :
    b.discard.acknowledge count = b.discard := by
  simp only [acknowledge, discard]
  have h : min (max 0 count) (0 : Int) = 0 := by omega
  simp [h]

/-- One pass of `next` never changes `pending`: reading does not release capacity; only
    `acknowledge` and `discard` do. (AudioBacklog.swift:41-53) -/
theorem next_pending (b : AudioBacklog α) : b.next.1.pending = b.pending := by
  unfold next
  split
  · split <;> rfl
  · split <;> rfl

/-- Splitting preserves the audio: the chunk handed out followed by everything still queued is
    exactly what was queued before, byte for byte and in order; and no chunk handed out is longer
    than 32,000 bytes. (AudioBacklog.swift:43-49) -/
theorem next_preserves_bytes (b : AudioBacklog α) (bytes : List α) (h : b.next.2 = .data bytes) :
    bytes ++ b.next.1.chunks.flatten = b.chunks.flatten ∧ bytes.length ≤ 32000 := by
  unfold next at h ⊢
  split at h
  · rename_i data rest hch
    split at h
    · rename_i hlen
      simp only [NextResult.data.injEq] at h
      subst h
      simp only [hch, hlen, ↓reduceIte, List.flatten_cons, List.length_take]
      constructor
      · rw [← List.append_assoc, List.take_append_drop]
      · omega
    · rename_i hlen
      simp only [NextResult.data.injEq] at h
      subst h
      simp only [hch, hlen, ↓reduceIte, List.flatten_cons]
      exact ⟨trivial, by omega⟩
  · split at h <;> (try split at h) <;> simp at h

/-- A chunk longer than 32,000 bytes is split: its first 32,000 bytes are handed out and counted
    as in flight, and the rest goes back to the head of the queue. (AudioBacklog.swift:44-48) -/
theorem next_splits (b : AudioBacklog α) (data : List α) (rest : List (List α))
    (hch : b.chunks = data :: rest) (hlen : data.length > 32000) :
    b.next = ({ b with chunks := data.drop 32000 :: rest, inFlight := b.inFlight + 32000 },
              .data (data.take 32000)) := by
  have h32 : ((32000 : Nat) : Int) = 32000 := rfl
  simp only [next, hch, hlen, ↓reduceIte, List.length_take]
  have : min 32000 data.length = 32000 := by omega
  rw [this, h32]

/-- Accepted audio is always handed out before a failure or the end is reported: `next` throws
    or returns `nil` only when the queue is empty. (AudioBacklog.swift:42, 51-52) -/
theorem next_drains_first (b : AudioBacklog α) (h : b.chunks ≠ []) : ∃ bytes, b.next.2 = .data bytes := by
  unfold next
  split
  · split
    · exact ⟨_, rfl⟩
    · exact ⟨_, rfl⟩
  · rename_i hch; exact absurd hch h

/-- No loss, no duplication, no reordering: over any sequence of calls that does not call
    `discard`, the bytes handed out by `next`, followed by the bytes still queued, are exactly
    the bytes that were queued at the start followed by the bytes `append` accepted. -/
theorem delivered_then_queued (b : AudioBacklog α) (ops : List (BacklogOp α))
    (hnd : ∀ op ∈ ops, op ≠ BacklogOp.discard) :
    delivered b ops ++ (b.run ops).chunks.flatten = b.chunks.flatten ++ accepted b ops := by
  induction ops generalizing b with
  | nil => simp [delivered, accepted]
  | cons op ops ih =>
    have ih' := ih (b.step op) (fun o ho => hnd o (by simp [ho]))
    cases op with
    | discard => exact absurd rfl (hnd _ (by simp))
    | finish error =>
      simp only [delivered, accepted, run_cons]
      simpa [step, finish] using ih'
    | acknowledge count =>
      simp only [delivered, accepted, run_cons]
      simpa [step, acknowledge] using ih'
    | append data =>
      simp only [delivered, accepted, run_cons]
      rw [ih']
      rcases append_rejects_or_keeps_bound b data with ⟨hno, hsame⟩ | ⟨hok, _, _, hch⟩
      · simp [step, hsame, hno]
      · simp [step, hch, hok]
    | next =>
      simp only [delivered, accepted, run_cons]
      cases hres : b.next.2 with
      | data bytes =>
        have hb := (next_preserves_bytes b bytes hres).1
        simp only [List.append_assoc]
        rw [ih', ← List.append_assoc]
        simp only [step] at hb ⊢
        rw [hb]
      | failure =>
        have hsame : b.next.1.chunks = b.chunks := by
          unfold next at hres ⊢; split <;> (try split) <;> simp_all
        simpa [step, hsame] using ih'
      | finished =>
        have hsame : b.next.1.chunks = b.chunks := by
          unfold next at hres ⊢; split <;> (try split) <;> simp_all
        simpa [step, hsame] using ih'
      | wait =>
        have hsame : b.next.1.chunks = b.chunks := by
          unfold next at hres ⊢; split <;> (try split) <;> simp_all
        simpa [step, hsame] using ih'

/-! ## Checks against vacuity -/

section Checks

/-- A reachable state with audio both queued and in flight: two chunks appended, one read. -/
example :
    let b := (init 2 : AudioBacklog Nat).run [.append [1, 2, 3], .append [4, 5], .next]
    b.pending = 5 ∧ b.inFlight = 3 ∧ b.chunks = [[4, 5]] := by decide

/-- The split branch of `next` is reachable: chunks longer than 32,000 bytes exist (the
    hypothesis of `next_splits`). -/
example : (List.replicate 40000 (0 : Nat)).length > 32000 := by
  rw [List.length_replicate]; omega

/-- Acknowledging more than is in flight, a negative amount, or anything after `discard`:
    the counters stay at zero or above. -/
example :
    let b := (init 2 : AudioBacklog Nat).run [.append [1, 2, 3], .next, .acknowledge 99,
      .acknowledge (-7), .discard, .acknowledge 3]
    b.pending = 0 ∧ b.inFlight = 0 := by decide

/-- A full backlog rejects: with capacity 32,000 and 32,000 bytes pending, one more byte overflows. -/
example :
    let b : AudioBacklog Nat := { capacity := 32000, pending := 32000, inFlight := 32000 }
    (b.append [1]).2 = .overflow := by decide

namespace Broken

/-- WRONG ON PURPOSE: `acknowledge` without the `min(max(0, count), inFlight)` clamp. -/
def acknowledge (b : AudioBacklog Nat) (count : Int) : AudioBacklog Nat :=
  { b with inFlight := b.inFlight - count, pending := b.pending - count }

/-- WRONG ON PURPOSE: `acknowledge` that forgets `pending -= acknowledged`. -/
def acknowledgeInFlightOnly (b : AudioBacklog Nat) (count : Int) : AudioBacklog Nat :=
  { b with inFlight := b.inFlight - min (max 0 count) b.inFlight }

/-- WRONG ON PURPOSE: `append` without the capacity guard. -/
def append (b : AudioBacklog Nat) (data : List Nat) : AudioBacklog Nat :=
  { b with chunks := b.chunks ++ [data], pending := b.pending + data.length }

/-- WRONG ON PURPOSE: a split that forgets `chunks.insert(remainder, at: 0)`, with the limit
    lowered to 2 so the example is small. -/
def nextDropsRemainder (b : AudioBacklog Nat) : AudioBacklog Nat × List Nat :=
  match b.chunks with
  | data :: rest => ({ b with chunks := rest, inFlight := b.inFlight + (data.take 2).length }, data.take 2)
  | [] => (b, [])

end Broken

/-- Seen to fail: without the clamp, acknowledging 5 with nothing in flight makes both counters
    negative. -/
example : (Broken.acknowledge (init 1) 5).inFlight < 0 ∧ (Broken.acknowledge (init 1) 5).pending < 0 := by
  decide

/-- Seen to fail: if `pending` is not reduced, `pending` no longer equals queued plus in flight. -/
example :
    let b := Broken.acknowledgeInFlightOnly ((init 1 : AudioBacklog Nat).run [.append [1, 2, 3], .next]) 3
    b.pending ≠ (queued b.chunks : Int) + b.inFlight := by decide

/-- Seen to fail: without the capacity guard `pending` exceeds `capacity`. -/
example :
    let b : AudioBacklog Nat := { capacity := 2 }
    ¬ ((Broken.append b [1, 2, 3]).pending ≤ (Broken.append b [1, 2, 3]).capacity) := by decide

/-- Seen to fail: a split that drops the remainder loses bytes, and breaks the sum. -/
example :
    let b : AudioBacklog Nat := { capacity := 10, chunks := [[1, 2, 3]], pending := 3 }
    let r := Broken.nextDropsRemainder b
    r.2 ++ r.1.chunks.flatten ≠ b.chunks.flatten ∧ r.1.pending ≠ (queued r.1.chunks : Int) + r.1.inFlight := by
  decide

end Checks

end AudioBacklog

end WorkScribe
