# WorkScribe Clip (Chrome, Arc, Brave, Edge)

A small Manifest V3 extension with two actions, both available from the toolbar
button and the page's context menu:

- **Clip to current meeting**: saves the page (your selection if there is one,
  otherwise its readable text, plus the YouTube time if you're watching a video)
  as a note in `Clippings/`, linked from the meeting WorkScribe is recording at
  the moment you clipped. With no meeting recording, the clip goes to `Inbox.md`.
- **Ask WorkScribe about this page**: saves the page the same way and hands it,
  with your question, to WorkScribe's quick ask.

The popup always shows the destination ("Meeting: Weekly sync" or "No meeting
recording — saved to Inbox") before anything is sent.

For ordinary web clipping, use Obsidian's official Web Clipper with
`extras/obsidian-clipper/workscribe-template.json`. Clips it saves are indexed by
WorkScribe too. This extension exists only for what the Clipper can't know: the
meeting being recorded.

## What it can and can't do

Permissions: `activeTab`, `scripting`, `contextMenus`, `nativeMessaging`. No
host permissions and no content scripts: it reads a page only in the tab where
you clicked the button or menu item, only at that moment, and never changes the
page. It has no network access of its own and stores nothing.

Page content is treated as untrusted data throughout. The native host checks
size and schema, WorkScribe checks again, writes the text into the clip note
with Markdown syntax escaped (no links, embeds, remote images, code blocks or
comments can come from a page), and never acts on instructions in it.

## Install

1. Build the host (or install WorkScribe.app, which bundles it in
   `Contents/Helpers`):

   ```sh
   swift build -c release --product WorkScribeNativeHost
   ```

2. Register it with your browsers:

   ```sh
   extras/chrome-extension/install-native-host.sh            # finds the host
   extras/chrome-extension/install-native-host.sh /path/to/WorkScribeNativeHost
   ```

   This writes `com.workscribe.clipper.json` into each installed browser's
   `NativeMessagingHosts` folder (Chrome, Chrome Beta, Chromium, Arc, Brave,
   Edge) and the host's allowlist to
   `~/Library/Application Support/WorkScribe/NativeHost/allowed-origins.txt`.
   `--uninstall` removes them.

3. Open `chrome://extensions` (or `arc://extensions`, `brave://extensions`),
   turn on Developer mode, **Load unpacked**, and pick this folder. The
   manifest's `key` pins the extension ID to `lcbgpofefjibjkigocjhkmjokpojgldd`,
   which the host allows by default. A copy loaded without the key gets another
   ID: pass it to the install script as an extra argument.

WorkScribe must be running. If it isn't, the popup says so.

## How a clip travels

```
popup / context menu ──sendNativeMessage──▶ WorkScribeNativeHost ──Unix socket──▶ WorkScribe.app
        ◀──────────── ack {id, destination} ◀──────────────── ack ◀─────────────
```

- **Extension → host**: Chrome's native messaging (stdio, 4-byte length + JSON).
  Chrome starts the host with the caller's origin; the host refuses any origin
  not on its allowlist.
- **Host → app**: `~/Library/Application Support/WorkScribe/clip.sock`, a Unix
  domain socket (folder 0700, socket 0600; the app also checks the peer's user
  ID). Chosen over a distributed notification (visible to every process, no
  reply) and a file drop (needs polling for the ack) because the popup needs a
  request/response: first `status` for the destination, then `clip`/`ask` with
  an acknowledgement. No network port is opened.

Message (version 1):

```json
{ "v": 1, "id": "<uuid>", "type": "status | clip | ask",
  "page": { "url": "https://…", "title": "…", "site": "…", "selection": "…", "text": "…",
            "description": "…", "author": "…", "videoTime": 754 },
  "question": "…", "meetingId": "<uuid shown in the popup>" }
```

Limits: 3 MB per message, URL 4 KB (http/https only; credentials stripped),
title 1,000 characters, selection 200,000, text 1,000,000, question 4,000.
Unknown fields are rejected. Reply: `{ "v": 1, "id", "ok", "code"?, "error"?,
"destination": { "kind": "meeting" | "inbox", "title", "meetingId"?, "offset"?, "path"? }, "vault"? }`.

## Not yet verified

Loading the extension in a real browser and the full browser → host → app path
have not been run; the host's validation and the socket are covered by
`swift test` (`ClipProtocolTests`). `chrome.action.openPopup()` from the context
menu needs a recent Chrome; older ones clip directly and report on the badge.
