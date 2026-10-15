# WorkScribe, Concept A · Workspace

Mockups to react to, not a spec. Open `index.html` (or serve this folder with
`python3 -m http.server`). Every page has a theme toggle (auto / Paper / Chalkboard).

This round replaces the menu-bar-first design (popover + floating panel + one
window). The ask, in the user's words: move away from the menu bar except for
notifications; make it a standalone chat app with a dedicated main
window and Obsidian's workspace. Other concepts live in `design/concepts/`.

Sample content is unchanged: **"Offline sync — v2.4 scope"**, Tue 13 Oct, 32 min,
with **You**, **Priya Raman** (PM) and **Marcus Chen** (iOS lead), about
"Fieldbook" and the customer **Halvorsen Construction**.

## Information architecture

One window, an Obsidian-like workspace:

| Sidebar | What it is | Mocked |
| --- | --- | --- |
| Search (⌘K) | one search over meetings, vault notes, web clips, documents, audio, video, images; results are moments | 04 |
| **Ask** (home) | chat over everything, with a morning briefing as the first message; a rail with the next call, open items, recent, today's note | 01 |
| Today | the daily note (`Daily/2026-10-14.md`): jots, calls, answers you added | no |
| Meetings | list → meeting page: **live** while recording, **review** after Stop | 02, 03 |
| Notes | vault Markdown files with `[[links]]` | no |
| People | a page per named voice: meetings, what they asked, what they own | no |
| Sources | the two-switch table (during meetings / in Ask) plus the vault row | no (previous round) |
| Pinned, Recent | files and chats, Obsidian-style | 01 |
| Footer | the vault WorkScribe writes to, "on this Mac" | 01, 03 |

Outside the window: an optional **companion** (02), the **status item** and
**notifications** (05). Nothing else lives in the menu bar.

## Key decisions

1. **Chat is the front door.** Home is a conversation, not a dashboard.
   A daily briefing becomes the chat's first message, so it's cited and
   you can reply to it. Time-bound things (next call, open items, recent) sit in
   a right rail that drops below the chat on narrow windows.
2. **Trust-first recording state moved into the window.** The "System audio is
   off" banner sits on the Next-call card above Start (01), and as a notification
   (05). The meeting title bar carries the dot, timer, Mic/System levels, a
   "Mic + system audio" state chip, Companion and Stop (02).
3. **The meeting page is a live note editor.** Shorthand pane left (blush ground =
   the input register), enhanced pane right, **row-aligned** so each line sits
   beside what it became; Enhance notes toggle, "Notes are caught up", and a
   live "Enhancing as you type…" placeholder on the line in progress. Missed
   topics come after Stop, in the review. This settles last round's open question
   1 (in place vs side by side) in favour of side by side in the window.
4. **Kept: two anchors.** Selecting a line shows its excerpts on a time ruler:
   inside the ±2 min typing window and by meaning (filled tag), or meaning only
   (hollow). One live-answer slot pinned atop the sidecar; chat about the call
   below it. Named voices everywhere, with a one-line naming suggestion in the
   transcript header.
5. **The window gives the call room.** While recording, the sidebar folds to an
   icon rail (the search page uses the same rail to fit its three columns).
6. **In-call companion: yes, opt-in.** A 340 pt always-on-top window (⌥⌘N or the
   Companion button): timer, levels, last two notes with their enhanced lead, the
   jot line, the answer reduced to one row, Stop. *Why keep it:* leaving the menu
   bar removes the popover's jot line, and jotting shouldn't mean switching away
   from Zoom; it's also today's floating window, which people already use. *Why
   opt-in:* the window is the product now, and a second surface should be chosen.
   In the companion, enhancement is in place under each line (two panes don't fit).
7. **Menu bar = status + a plain menu.** Four states from the UX review (warming,
   ready, recording dot + timer, needs-attention ochre). Clicking opens a six-row
   NSMenu, not a popover. The old post-meeting digest became the "Recording saved"
   notification.
8. **Five notifications, one action each:** call detected → Start recording;
   permission problem → Open Settings; answer ready (only if window and companion
   are hidden, never while sharing); recording saved → Open; action item due
   (only yours) → Open / Done.
9. **Results are moments,** grouped by where they live (meetings, vault, files).
   ⌘K and Ask share a field ("Ask instead").

## Obsidian: storage and web clips (proposal, not decided)

Working assumption shown in the mockups: the user picks an Obsidian vault;
WorkScribe writes meeting write-ups (`Meetings/2026-10-13 Offline sync — v2.4 scope.md`),
chats saved as notes, and daily notes into it, with frontmatter (type, date,
people, customer, audio path) and `[[links]]` to people and customers. Action
items are Markdown tasks. The vault is also a **source**: notes, and **web clips**
from Obsidian's Web Clipper (title, site, clipped date, highlights) are searched
and cited like any file. Where it shows: sidebar footer (01, 03), the file chip
and "In your vault" section of the review (03), the "Saving to …" status line
(02), the vault group and a clip result in search (04), a clip cited by the live
answer (02).

Tradeoffs to settle with the user:

- **For:** portable plain text that outlives WorkScribe; Obsidian's backlinks,
  graph, Tasks and Dataview work for free; clipping is solved by an existing tool.
- **Two editors, one file.** Needs a rule: WorkScribe owns generated sections and
  never overwrites a section you edited; or it writes once and then only appends.
- **Anchors must survive edits.** Excerpt ids would need Obsidian block ids
  (`^e1`) or a sidecar file; hand edits can break them.
- **Transcripts and audio don't belong in a vault** (size, sync services). The
  mockup keeps them in a hidden `.workscribe/` folder linked from frontmatter;
  a library outside the vault may be better.
- **Not everyone has Obsidian.** A plain folder works the same; the alternative is
  WorkScribe's own library with export.
- **Clips during calls.** A clip can be cited by a live answer on a shared screen.
  Maybe the vault's "during meetings" switch defaults off.

## Indigo Wash

Unchanged from the previous round (`~/aviary/indigo-wash/languages/indigo-wash/SPEC.md`):
SPEC §5 tokens inline in `shared.css`, Chalkboard under `prefers-color-scheme: dark`
(guarded) and `[data-theme="dark"]`; cut sheets on surface with grain; one 1.25px
indigo line for structure; painted fills; Newsreader headings, Manrope UI text,
Kalam only once (the ⌥⌘N note on the index diagram); one indigo primary per view;
one vermilion per figure (01: the permission seal; 02: the recording dot, and the
companion's own dot; 03: your action item; 05: the recording dot, and the
permission banner's seal). Three registers: what you typed on blush, what the
model wrote with a serif lead, evidence washed indigo and tagged E1.

Files: `shared.css` (tokens, controls, transcript, citations), `app.css` (the
window chassis: sidebar, rail, page, composer, moments; replaces `notebook.css`),
`shared.js` (theme toggle, switches, and the icon sprite + SVG filters injected
once per page).

## Open questions

1. **Vault as the default store?** Vault, plain folder, or own library with export (above).
2. **Calendar.** "Next call" on home needs EventKit; opt-in with call detection as fallback?
3. **Companion default.** Opt-in now; appear automatically when screen sharing starts?
4. **Live answers on by default?** Still needs a ~4B model resident during calls.
5. **Media indexing cost** (~555 MB encoder for audio/video): only folders you add, only on power?
6. **Today vs Ask.** Is a separate daily-note page worth a sidebar slot, or should today's note just be the rail on home?
