# WorkScribe for Obsidian

WorkScribe runs as a macOS menu-bar app: it records, labels speakers by voice, enhances your notes on the device, searches your files, and captures the screen. This plugin makes Obsidian the place where you work with all of that. It talks to the app's local HTTP API on `127.0.0.1` and is desktop only.

## What it does

Starting a meeting creates one real vault note and opens it in Obsidian's normal Markdown editor.
Live Preview, Source mode, lists, headings, links, embeds, vim mode and other editor extensions remain
Obsidian's responsibility. Top-level paragraphs and list items get one live AI line underneath; nested
children stay with their parent and headings provide context. The Ask / Live Q&A / Transcript companion
and recording pill stay in the right sidebar.

AI lines are CodeMirror decorations, not Markdown. Click one for **Make it mine**, **Why?**, or
**Let AI rewrite**. Taking ownership inserts an ordinary blockquote that you can edit freely; handing it
back removes that quote in a normal undoable transaction. AI rewrites never enter the undo history.
Long lines wrap without a nested scrollbar, and updates wait for a typing pause or composition to finish.
The active editor line keeps its screen position as the AI text changes height.

After Stop's final pass, the same note gains real AI blockquotes, a summary, attendees, Tasks-format
items and topics you missed. There is no copy step, transcript URL or hidden block ID. Reading view
shows only real file content. **Done now** or the 24-hour deadline removes raw meeting material.
The note stays a normal editable Markdown file even when WorkScribe or the plugin is unavailable.
If finalization finds unsynced edits, it leaves them untouched: sync and retry **Finalize**. Deadline
recovery preserves the current file and skips any ambiguous AI anchors.

**Settings:** API discovery override, automatic opening, default question scope, conversation folder.
WorkScribe must be configured to use this vault. Existing placement settings are retired: the note is
always a normal tab, and the companion is a normal movable Obsidian sidebar leaf.

**Implementation and evidence:** [Native note research](../docs/research/real-note-editor.md).

## Install

```sh
cd obsidian-plugin
npm install
npm run build                      # tsc --noEmit (strict) + esbuild → main.js
scripts/install.sh /path/to/vault  # copies main.js, manifest.json, styles.css
                                   # into <vault>/.obsidian/plugins/workscribe/
                                   # add --enable to list it in community-plugins.json
```

Then reload Obsidian and enable **WorkScribe** under Settings → Community plugins.

## Develop against the mock

```sh
npm run mock -- --vault "$TMPDIR/workscribe-test-vault" --live --speed 2
```

`dev/mock-server.mjs` implements the API contract below. Its data is the sample meeting from the mockups: "Offline sync — v2.4 scope", with You, Priya Raman and Marcus Chen. With `--live` it plays a call: provisional and then final transcript segments, enhancement of whatever you jot (lines from the mockup get canned enhancements with E-tags), a live answer streamed word by word, a second answer, and a screen moment. It writes `dev/api.json`, never the real one. Point the plugin's *api.json path* setting at that file. Use a throwaway vault and point its discovery setting at the mock file.

```sh
npm test       # node:test: SSE parser, decoders, link formatting, native anchoring, editor undo/ownership and latency,
               # live-state reducer, AI line ownership, hotkey matching, client ↔ mock end to end
npm run smoke  # loads the built main.js with a stubbed `obsidian`, runs onload against
               # the mock, starts a recording, jots, waits for the enhancement
```

## Shared API contract (v1)

[docs/api/local-api.md](../docs/api/local-api.md) is the authoritative contract for the app, plugin and mock.
The plugin handles the app's wrapped meeting details, batched `notes` snapshots, `transcript`, streaming
`answer`, `screen`, `clip`, `ask_request` and `continue` events. Page requests fill the composer and require
an explicit send. The citations event replaces streamed text with the final renumbered answer.

Run the same client against the actual Swift listener and handlers, with isolated fixture stores and providers:

```sh
# From the repository root, first build/test Swift:
swift test
cd obsidian-plugin
WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test
```

This adds a real-server contract test to the normal mock tests. Without that environment variable it is
explicitly skipped. The fixture mode does not start recording or load the user's meetings, vault or models.

## Layout

`src/lib/` holds the pure, tested modules: types, SSE parser, decoders, client, connection, live-state reducer, formatting and links, block mapping, AI line ownership (`suggestions.ts`) and hotkey matching. `src/lib/anchors.ts` parses/reconciles native blocks, `editor-extension.ts` owns the CM6 decorations,
and `src/ui/note-editor.ts` owns file/API synchronization. `src/ui/` also holds the views, modals and renderers: `lines.ts` (the legacy past-meeting renderer), `chat.ts` + `composer.ts` (the Claudian-style chat used by the Ask view and the live side panel), and `render.ts` (moments, citation chips, sources). `src/main.ts` is the plugin entry point and `styles.css` the styles. `dev/` contains the mock server and the smoke loader, and `scripts/install.sh` the installer.

### Images and screenshots

Paste or drag images into the real meeting note as usual. An image-only paragraph/list item gets
its own contextual AI line when local image evidence is available; words alongside an image remain
your shorthand. Your image and original text are never rewritten. “Why?” includes the local OCR
and image description while the meeting's evidence is retained.

**WorkScribe: Grab this moment** inserts the current permitted screen-awareness frame at your cursor,
using your Obsidian attachment-folder and link settings. Assign a hotkey in Obsidian if desired;
it is unbound by default. Screen awareness must already be recording. Paused/private screens are
refused. Once saved into your vault, the image is yours and survives meeting/screen-recording cleanup.
Undo removes the embed, leaving the attachment file like an ordinary Obsidian paste.
