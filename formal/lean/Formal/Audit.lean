/-
  Build-time audit: every theorem in the `WorkScribe` namespace may depend only on Lean's three
  standard axioms. A `sorry` (axiom `sorryAx`), a `native_decide` (axiom `Lean.ofReduceBool`) or
  any declared `axiom` anywhere underneath a theorem makes `lake build` fail here.
-/
import Lean
import Formal.Line
import Formal.AutoRecord
import Formal.Backlog
import Formal.Small

open Lean Elab Command in
/-- Fail unless every theorem under `WorkScribe` uses only `propext`, `Classical.choice`, `Quot.sound`. -/
elab "#assert_standard_axioms" : command => do
  let env ← getEnv
  let allowed : List Name := [``propext, ``Classical.choice, ``Quot.sound]
  let mut checked : Nat := 0
  let mut bad : Array (Name × Name) := #[]
  for (name, info) in env.constants.toList do
    if (`WorkScribe).isPrefixOf name then
      if let .thmInfo _ := info then
        checked := checked + 1
        for ax in (← collectAxioms name) do
          unless allowed.contains ax do bad := bad.push (name, ax)
  unless bad.isEmpty do
    throwError "non-standard axioms: {bad}"
  if checked < 100 then
    throwError "axiom audit looked at only {checked} theorems; expected the whole WorkScribe namespace"
  logInfo m!"axiom audit: {checked} theorems under WorkScribe, all within [propext, Classical.choice, Quot.sound]"

#assert_standard_axioms
