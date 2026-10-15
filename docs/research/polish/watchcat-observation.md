# Native motion review

Expected sequence: stable typed text during AI revision; Why disclosure; first-keystroke ownership; direct Let AI rewrite and Undo; explicit Ask; Stop; Finalize; one Undo restores pencil; explicit light/dark snapshots.

Observed by watchcat (5 fps, synthetic vault only):

Here is a chronological log of visible events and interface behavior:

- **0:00** — The editor briefly displays a fully populated note for a split second before snapping back to an early state where typing begins at the top.
- **0:00 – 0:02** — The user rapidly types three bullet points into the note: `ship date nov 4 not oct 28`, `beta 40 accts, halvorsen first`, and `pricing for the beta?`.
- **0:06** — While the cursor rests on the final bullet, AI-suggested annotations automatically populate beneath each of the three bullet points, accompanied by inline `Why?` links.
- **0:07** — A dark pill tooltip labeled `"AI line. Type to make it yours"` pops up over the second AI annotation block.
- **0:13 – 0:14** — The first AI annotation is edited/modified, and then undone/cleared back to just `v2.4`.
- **0:15 – 0:18** — Re-typing and undo/redo operations occur on the AI suggestion line; inline contextual action labels (`Why?` and `Let AI rewrite`) appear above the modified text.
- **0:19** — Focus switches to the right-hand panel (*Ask while you listen*). The user submits a query: `"What does the Halvorsen contract say about offline?"`.
- **0:19 – 0:20** — The panel streams an answer referencing contract details (`Dec 31`, `24 hours of reconnecting`).
- **0:21** — The user stops recording (audio timer stops at `00:20`). A banner appears at the top right: `"Recording stopped. Review your notes, then finalize when you're ready."`, and a modal card appears at the bottom of the editor with a purple `"Finalize ⌘↵"` button.
- **0:23** — An AI summary line (`The team reviewed scope, timing and next steps.`) automatically inserts above the main heading in italicized gray text.
- **0:24 – 0:25** — The user clicks `"Finalize ⌘↵"`, then undoes and finalizes again.
- **0:25** — The top banner updates to `"Transcript fades in 24 hours"` with a `"Done now"` option.
- **0:27** — The entire application theme switches instantly from light mode to dark mode.

### Moments worth a closer rewatch:
- **0:00.000 – 0:00.200**: Note content flashes the finished state before snapping back to the initial typing state.
- **0:13.400 – 0:15.000**: Rapid text clear/undo on the first AI annotation line to confirm cursor placement and caret stability.
tokens=11268 cost_usd=0.0089 prompt=v2


Interpretation: the initial flash is switching from the prior synthetic meeting to a fresh fixture. The clear/reappearance around 13–18 seconds follows the deliberately exercised ownership/hand-back/Undo steps; it is not an unsolicited rewrite. The reviewer misread the countdown as 24 hours: the native screenshot and formatter tests show 23 h. Exact source/selection/undo assertions are in native-metrics.json. This does not establish physical audio capture, arbitrary IME compatibility, or community-theme coverage.
