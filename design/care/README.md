# WorkScribe: ink and pencil

A design exploration of how WorkScribe should feel, moment by moment, now that the live meeting is a real Obsidian note. Open `index.html` (or serve this folder with `python3 -m http.server`). Every page has a theme switch (auto, light, dark). Screenshots of each page and state are in `shots/`.

| Page | What it shows |
| --- | --- |
| `index.html` | The argument, the three shapes, the arc of a meeting, the care list, decisions |
| `live.html` | The live note at real scale in Obsidian's default theme: a playable scene with typing, drafting, a rewrite, two questions, Why? |
| `line.html` | The AI line: anatomy, seven states, a slowed-down rewrite with its timing, rewrite rules, final Markdown form |
| `finalize.html` | Stop, the final pass, Finalize, the fade countdown, Done now, the note a week later, and its Markdown source |
| `menubar.html` | The tally's five states, the menu, quit-while-recording, notifications, Quick ask over a call, the Chrome clipper |

Shared files: `care.css` (tokens for the studio pages, Obsidian's default theme and macOS surfaces), `care.js` (theme, stage scaling, Lucide icon sprite, a pausable timeline, and the AI line animator: word diff, drafting, drying). Every mockup page supports deep links for screenshots, for example `live.html#question`, `finalize.html#step3&md`, `line.html#still`, plus `#light`, `#dark` and `#bare` (the frame without page chrome).

Sample content is the usual meeting: "Offline sync — v2.4 scope", Wed 14 Oct, You, Priya Raman and Marcus Chen, about Fieldbook and Halvorsen Construction.

## The argument

Only the note survives a WorkScribe meeting. Transcript, audio, screen and evidence are deleted within a day. So the note is the product, and every other surface should be as quiet as it can bear.

The metaphor that organises everything below is **ink and pencil**. Your words are ink. WorkScribe writes in pencil directly under each of your lines, in the same typeface but a little smaller and lighter, and keeps correcting itself as the conversation arrives. At Finalize the pencil is inked into Markdown. Then the tape is thrown away.

## Three shapes

**A. Pencil in the note (chosen).** WorkScribe lives inside the note you're already writing. The menu bar is a tally light: status, Stop, Quick ask, and what's about to fade. Obsidian is everything you read and write, live and after. Ask lives in Obsidian's right sidebar, scoped to the open note; Quick ask (⌥⌘K) is the same conversation, summoned anywhere. Best at trust in the moment and the note you keep. Worst at people who don't type in meetings, and at anything that isn't a meeting.

**B. The desk.** A place where the day collects: meetings, clips, questions heard, answers given, ambient captures. You clear it by filing things into notes. The menu bar becomes an inbox count; Obsidian becomes the archive in another room; Ask lives at the desk. Best at loose things with no note to live in, and ambient capture. Worst at the fade: a desk of things that delete themselves in 24 hours is a desk of countdowns, and an inbox that needs emptying is a chore.

**C. The familiar.** Mostly invisible. It listens, answers when asked, nudges at the right moment and leaves a finished note behind. The menu bar holds everything (status, nudges, a small feed); Obsidian is the output folder; Ask is Quick ask only. Best at zero attention. Worst at trust: it hides the live line, so you'd judge WorkScribe only by its output, at the end, when it's too late to steer.

### Why A

- **Care belongs where things last.** The note is the only thing you'll see again. It gets the craft budget.
- **The live line is the idea.** Reading across two columns takes extra effort. A pencil line directly under your own words turns the meeting into a quiet conversation with your notes, and lets you steer while it's happening.
- **Obsidian is already open.** A second window competes for the same screen next to Zoom. Inside Obsidian, WorkScribe wears Obsidian's clothes: its font, colours and sidebar.
- **What A borrows.** From C, the tally: you know it's listening without looking. From B, nothing structural. Loose things (a clip outside a meeting, an answer you keep) go to today's daily note, which is already a desk.
- **People who don't type** still get the familiar's whole output: a meeting with an empty note ends with a brief, "Also discussed" and action items.
- **Ambient capture** (screenpipe-style, gated by a decision model) gets no surface in this shape. It is a source Ask can cite, under the same 24-hour fade. No feed, no timeline.
- **The risk is engineering.** CodeMirror decorations that rewrite live must handle IME, scroll anchoring and Obsidian Sync without a flicker. The mockups assume that bar is met.

### Where Indigo Wash goes

Inside Obsidian, WorkScribe uses only the theme's tokens, so community themes work. The menu, notifications and Quick ask are drawn as native macOS surfaces. Indigo Wash remains the brand for the app icon, onboarding and the website. This is a decision for you (below).

## The arc of a meeting

Each moment has one act of care and a failure path.

1. **Before (09:58).** Four minutes out, the tally grows a small dot and one notification offers the note, which already exists with the calendar title and attendees as links. Prep lines you write get AI lines too: "Don't agree to Oct 28 until Marcus has sized the migration" is answered by the meeting. Opening the note never starts recording. *Fails:* without calendar access there's no nudge; the call starting still starts recording, with a soft tick so you know it heard.
2. **The first ten seconds (10:02).** The tally's red dot swells once and holds still. The note gains a pill, "● 0:03 · Mic + system · Stop", and the cursor waits on the first empty bullet. At ten seconds WorkScribe checks both channels and, if only your mic is coming through, says so by name: "Priya and Marcus won't be in the transcript." *Fails:* a denied mic permission turns the tally amber (never red) and the pill offers Open Settings, straight to Privacy & Security › Microphone.
3. **Typing.** Pencil lines appear under lines you've left, never under the one you're typing. When a pencil line above the cursor grows, the editor scrolls by the same amount so your line doesn't move. *Fails:* if Obsidian quits mid-meeting, recording continues; reopening says "Caught up on 6 minutes".
4. **A question (10:21).** Priya asks what the Halvorsen contract commits them to. The panel doesn't switch tabs; Live Q&A gets a count; the answer waits with sources and the model that made it. Questions asked of you by name are marked "Asked of you" and sorted first. *Fails:* with the cloud down it answers on this Mac and says so; if nothing answers, "Nothing in your notes or files answers this", never a guess.
5. **A line rewrites (10:27).** Only changed words move; new words arrive darker and dry to pencil grey. A rewrite that only rephrases is dropped. *Fails:* with no model available, lines freeze under one header note, "AI lines paused · your notes are saving".
6. **Stop (10:34).** Instant, from the pill, the menu bar or ⌥⌘R. The final pass reads the whole call and sweeps down the note in reading order while you keep typing; "android?" finally gets an answer and "pricing for the beta?" is marked Not discussed. *Fails:* stopped by mistake, "Resume" stays in the pill for ten minutes.
7. **Finalize (10:35).** A bar says exactly what will be written and that your edits stay. Press it and pencil becomes ink in reading order, 45 ms per line, as one editor transaction: one ⌘Z puts it all back. *Fails:* if the file changed underneath (Sync, another device), Finalize writes beside it as "… (WorkScribe).md" and says where.
8. **The fade (to Thu 10:34).** The pill reads "Transcript fades in 23 h · Done now" with an arc that empties; the menu lists what's fading. Done now confirms inline and names what goes. If you never pressed Finalize, it finalizes an hour before the fade and tells you once. *Fails:* "Couldn't delete 1 file yet. Trying again in a minute."
9. **A week later.** No plugin chrome. Your lines in roman, WorkScribe's in italic, a one-paragraph brief at the top, real tasks at the bottom. Ask answers from the note and says so; the Transcript tab says when the transcript faded. *Fails:* even with WorkScribe uninstalled, the note reads perfectly.

## The AI line

**What it is.** A CodeMirror block decoration after your line, not document text, so undo, search and Sync only ever contain what you typed until Finalize.

**Typography.** Aligned to your text, not the bullet. The theme's `--font-text` at `0.9375em` (15 px under 16 px), line height 1.5, colour `--text-muted`. The topic lead is omitted; your own line names the topic. 1 px above, 7 px to your next line, so each pair reads as one unit. No WorkScribe font, colour or icon enters the editor.

**The nib.** A 4 px mark in the bullet column, shown only while something is happening. Settled lines carry no mark at all; an always-present mark read as a second bullet in testing the mockups.

**States.**

| State | Mark | Copy and behaviour |
| --- | --- | --- |
| Listening (no evidence yet) | hollow nib | No row on Return. After 8 s with nothing relevant: "Listening for this", once |
| Drafting | breathing nib | Words arrive about 60 ms apart, in pencil. No spinner, no "Thinking…" |
| Rewriting | none | Changed words only; new words arrive dark and dry over 2.4 s. Hover: "v3 · 2 min ago" |
| Settled | none | Muted colour and smaller size are the only signal |
| Yours | none | First keystroke makes it yours: text colour, same size and place, never rewritten. Hover: "Yours · Let AI rewrite" |
| Paused (offline) | dash | Lines freeze and dim to 72%. One header note: "AI lines paused · your notes are saving". Nothing red |
| Not discussed | none | After the final pass: "Not discussed". Nothing is written at Finalize |

**A rewrite, in time.** Removed words fade out in place over 140 ms. Layout settles and the line's height eases over 180 ms while the editor compensates scroll. New words fade in over 220 ms, 24 ms apart, starting dark ("wet"), then dry to the line's colour over 2.4 s. With Reduce Motion, the words change in one step and keep the darker colour for 2.4 s. The implementation is a word-level LCS diff (`Care.rewrite` in `care.js`).

**When a rewrite may happen.** Only when facts change (the model gets its previous line and must return it unchanged otherwise; a pure rephrase is dropped). Never under the line being typed. Within three lines of the cursor, only after a 2 s typing pause. A 4 s debounce and at most one pass per 15 s per meeting. Your numbers, names and acronyms survive as typed. No flapping: a line can't lose more than half its words without new evidence or return to an earlier wording. Lines out of view update silently. Editing your own line makes its AI line dim and reread, then rewrite once.

**Final Markdown form.** Three candidates are shown in `line.html`:

- Callout (`> [!workscribe]`): unmistakable but turns seven lines into seven boxes and means nothing outside Obsidian.
- Blockquote (`> …`): portable, but says "someone said this", which is wrong in a note full of real quotes.
- **Indented italic (chosen):** the lightest mark that survives every renderer. Italic has long meant another voice (stage directions, marginalia). It stays inside your bullet, so outlines fold correctly. Caveat: strict CommonMark joins the two lines with a space; Obsidian's default (strict line breaks off) shows the break.

```markdown
- ship date nov 4 not oct 28
  *v2.4 moves from Oct 28 to Nov 4 so QA gets a full week on the SQLite migration. Priya tells Halvorsen on Friday.*
- beta 40 accts, halvorsen first
  40 accounts. Halvorsen first because of the year-end contract clause.
- pricing for the beta?
```

Rules: the topic lead is dropped (your line names the topic); lines you took over are written in roman; never-discussed lines get nothing; asterisks and underscores in AI text are escaped; no block IDs, transcript links or anchors survive. The brief is one italic paragraph under the properties. "Missed topics" are written as "Also discussed". Action items are tasks with `[[owner]]` and a 📅 date.

This differs from today's `VaultWriter.regions` in three ways: italics on AI continuation lines, no `## Brief`/`## Notes` headings, and "Also discussed" instead of "Missed topics".

## Unnecessary care

Sixty-four details. ★ marks the ten to build first: together they decide whether the live line feels trustworthy and whether the fade feels safe.

**Menu bar and sound**
1. The recording timer uses tabular numerals in a slot sized for 00:00, so nothing in the menu bar shifts as it counts; it widens once, at the hour.
2. The red dot swells once when recording starts and then holds still; a dot that pulses for an hour becomes noise.
3. Red only ever means recording; anything that needs you is amber, and the tally changes shape too, so it reads in grayscale.
4. The menu opens with Stop highlighted, so stopping from the menu bar is two clicks without aiming.
5. "Fading soon" in the menu lists transcripts about to be deleted, with hours left.
6. Quitting while recording asks "Stop and save ‘Offline sync — v2.4 scope’, then quit?", and updates wait until nothing is recording.
7. The start tick plays only when recording started by itself; manual starts and stops are silent.

**Before the meeting**

8. Four minutes before a meeting with a call link, the tally gets a small dot; a banner only when it's worth one.
9. The note exists before the call, titled from the calendar with attendees as links, so prep lines can be answered by the meeting.
10. Opening the note never starts recording; the call starting does, or you do.
11. Ad-hoc meetings are named from the first 45 words, and a title you typed is never replaced.

**The first ten seconds**

12. ★ Within ten seconds WorkScribe checks both channels, and if only your mic comes through it says so by name: "Priya and Marcus won't be in the transcript."
13. The cursor waits on the first empty bullet, so your first keystroke lands in the note.
14. The pill names its live sources in words ("Mic + system"), not icons to decode.
15. The menu bar, the pill and the status bar read one clock, so they never disagree by a second.

**Typing**

16. ★ An AI line never appears under the line you're still typing; it waits for Return or a 4-second pause.
17. ★ When an AI line above your cursor grows, the editor scrolls by the same amount, so the line you're typing never moves.
18. Rewrites within three lines of the cursor wait until you've stopped typing for 2 seconds.
19. AI lines are decorations, not text, so undo, search and Sync see only your keystrokes until Finalize.
20. Copying across AI lines copies them as they'll be written (indented italics), so a mid-meeting paste into Slack looks right.
21. A line that hasn't come up says "Listening for this" once, in the faintest grey, and nothing more.

**The AI line**

22. ★ A rewrite changes only the words that changed; surviving words don't move or flicker.
23. ★ New words arrive darker and dry to pencil grey over 2.4 s, so you can see what changed without a highlight.
24. The line's height eases over 180 ms; nothing jumps.
25. A rewrite that only rephrases is dropped before it reaches the screen.
26. Numbers, names and acronyms you typed survive exactly as you typed them.
27. Lines scrolled out of view update silently; animation is spent only on what you can see.
28. Your first keystroke in an AI line makes it yours for good; "Let AI rewrite" waits on hover if you change your mind.
29. The AI line uses your theme's font and muted colour; no WorkScribe font, colour or icon enters your editor.
30. With Reduce Motion on, words change in one step but keep the darker colour for 2.4 s, so the change is still visible.

**Questions and Ask**

31. ★ A detected question never takes focus or switches the panel's tab; Live Q&A gets a count, and that's all.
32. Questions asked of you by name are marked "Asked of you" and sorted first.
33. Every answer says where it was made: "GPT-5 mini" or "On this Mac".
34. When nothing answers a question, the card says "Nothing in your notes or files answers this" instead of guessing.
35. "Add to note" inserts the answer under your cursor as your line, with the asker's name and the source.
36. Ask cites notes for past meetings, never transcripts that have faded.

**Stop and Finalize**

37. Stop is instant: audio closes on the press, and the final pass runs while you keep reading or typing.
38. "Resume" stays in the pill for ten minutes after Stop and continues the same note.
39. The final pass sweeps down the note in reading order, so you can watch it reach the line you care about.
40. The Finalize bar says exactly what it will write and promises your edits stay as you wrote them.
41. ★ Finalize is one editor transaction: a single ⌘Z puts every line back in pencil.
42. ★ Lines you took over are written without italics, so a week later you can tell your words from WorkScribe's with no metadata.
43. AI lines drop their topic label in the note, because your line above already names the topic.
44. A line that was never discussed gets nothing written under it; your question stays a question.
45. Missed topics are called "Also discussed"; the note shouldn't scold you.
46. Action items are real tasks with the owner as a [[link]] and a due date, so Tasks and Dataview see them.

**The fade**

47. ★ The countdown reads "Transcript fades in 23 h", rounded down, and counts minutes only in the last hour.
48. ★ If you never press Finalize, WorkScribe finalizes an hour before the fade and tells you once.
49. "Done now" confirms inline and names what goes: "Delete the transcript, audio and 3 screen moments now? The note stays."
50. After the fade the Transcript tab says when it faded and that the note is what remains, never "not found".
51. At the fade, WorkScribe removes its own section markers from the note, because it will never write to it again.

**A week later**

52. The note opens with no plugin chrome: no banner, no badge, no "AI generated" label.
53. The brief is the first thing under the properties, one italic paragraph you can read in ten seconds.
54. If you uninstall WorkScribe, every note still reads correctly.

**Quick ask and the clipper**

55. Quick ask opens already scoped to the meeting in progress, shown as a chip you can remove.
56. Esc closes Quick ask and keeps your half-typed question for ten minutes.
57. Quick ask never opens by itself, so nothing appears on a shared screen uninvited.
58. The clipper names the meeting it will clip into before you press anything.
59. A clip lands as a link at the end of the note, stamped with the meeting minute, never at your cursor.

**When things fail**

60. If Obsidian quits mid-meeting, recording continues, and reopening the note says "Caught up on 6 minutes".
61. When the cloud model is unreachable, answers fall back to this Mac and say so; AI lines carry on, slower, without a banner.
62. If no model is available, AI lines freeze under one header note, "AI lines paused · your notes are saving"; nothing turns red.
63. If the note changed under WorkScribe, Finalize writes beside it rather than merging blind, and says where.
64. If a deletion fails, the pill says "Couldn't delete 1 file yet. Trying again in a minute." and it retries until done.

## Decisions for you

1. **Finalize: a press, or automatic?** Recommended: explicit, with the safety net (it finalizes on its own an hour before the fade). Automatic is simpler but removes the moment where you strike what you don't want.
2. **Indented italic** as the final form, with edited lines left roman and topic labels dropped. Recommended: accept the strict-CommonMark caveat.
3. **Indigo Wash's role.** Recommended: retire it from in-product surfaces (Obsidian tokens inside the plugin, native menu, notifications and Quick ask); keep it for icon, onboarding and website.
4. **Strip section markers at the fade.** The `<!-- workscribe:begin -->` markers protect your edits while WorkScribe might still write. After the fade it never will. Recommended: strip them; the cost is that the note can never be regenerated.
5. **Notes before the call** need calendar access through EventKit. Recommended: ask at the first meeting, not during onboarding.
6. **The start tick** for auto-start. Recommended: on by default; it's the only way to know auto-start heard the call.

## What's verified and what isn't

The mockups render in headless Chrome at desktop and phone widths in both themes; screenshots are in `shots/`. Timings in the live scene are compressed about three times. Nothing here has been tried inside a real Obsidian editor: in particular scroll anchoring, IME composition and word-level rewrites in CodeMirror decorations are design requirements for the plugin, not demonstrated behaviour. Model names in answer labels are placeholders for whichever small GPT model ships.
