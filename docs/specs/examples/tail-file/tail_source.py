#!/usr/bin/env python3
"""A WorkScribe transcript source that tails a text file (wsp/1).

Each new line of the file is one thing someone said:

    Priya Raman: Ship it on the 4th so QA gets a full week.

A line still being written (no newline yet) is sent as a partial; when the newline
arrives the same id is sent as final. Times are on the wall clock (Unix seconds).

This is the template for a captions reader: replace read_new_lines() with whatever
reads your platform and keep the rest. Standard library only. Run with python3 -I.
"""
import json
import os
import sys
import threading
import time

PROTOCOL = 1
SOURCE = {"id": "tail-file", "name": "Text file", "version": "0.1.0"}
CAPABILITIES = {
    "timing": "live", "partials": True, "speakers": "names", "words": False, "corrections": False,
    "audio": {"microphone": False, "system": False, "files": False}, "screen": False,
    "permissions": ["files"], "egress": "none", "clock": "wall", "latency": 0.5, "keepsAudio": False,
}
POLL = 0.25          # seconds between reads of the file
HEARTBEAT = 15.0     # the host wants to hear from a live source at least every 30 s

_out = threading.Lock()


def send(message):
    """One JSON object per line on stdout. Nothing else may be written to stdout."""
    line = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
    with _out:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(text):
    """stderr is a human log. Never put transcript text here."""
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def speaker_and_text(line):
    """'Priya Raman: hello' -> ('Priya Raman', 'hello'). A prefix of 1-4 words counts as a name."""
    name, colon, text = line.partition(": ")
    if colon and 0 < len(name.split()) <= 4:
        return name.strip(), text.strip()
    return None, line.strip()


class Tail:
    """Reads lines appended to a file after the session starts."""

    def __init__(self, path):
        self.path = os.path.expanduser(path)
        self.handle = None
        self.buffer = ""

    def read_new_lines(self):
        """Returns (complete lines, the unfinished tail). Waits quietly if the file doesn't exist yet."""
        if self.handle is None:
            if not os.path.exists(self.path):
                return [], ""
            self.handle = open(self.path, "r", encoding="utf-8", errors="replace")
            self.handle.seek(0, os.SEEK_END)   # only what is said from now on
        self.buffer += self.handle.read()
        *complete, self.buffer = self.buffer.split("\n")
        return [line for line in complete if line.strip()], self.buffer


def session(config, stopping):
    tail = Tail(config.get("path", "~/captions.txt"))
    number = 0                 # line counter; ids are "l<number>"
    partial_since = None       # when the current unfinished line was first seen
    last_partial = ""
    last_sent = time.time()
    waiting_said = False
    send({"type": "status", "state": "listening", "message": "Reading new lines in " + os.path.basename(tail.path)})
    while not stopping.is_set():
        lines, unfinished = tail.read_new_lines()
        now = time.time()
        if tail.handle is None and not waiting_said:
            send({"type": "status", "state": "waiting", "message": "Waiting for " + tail.path})
            waiting_said, last_sent = True, now
        for line in lines:
            number += 1
            speaker, text = speaker_and_text(line)
            # Stamp when the words were said, as best we know: when the line first appeared, minus our latency.
            start = (partial_since or now) - CAPABILITIES["latency"]
            final = {"type": "final", "id": "l%d" % number, "start": round(start, 3), "end": round(now, 3), "text": text}
            if speaker:
                final["speaker"] = speaker
            send(final)
            partial_since, last_partial, last_sent = None, "", now
        if unfinished.strip() and unfinished != last_partial:
            partial_since = partial_since or now
            speaker, text = speaker_and_text(unfinished)
            partial = {"type": "partial", "id": "l%d" % (number + 1), "text": text, "start": round(partial_since, 3)}
            if speaker:
                partial["speaker"] = speaker
            send(partial)
            last_partial, last_sent = unfinished, now
        if now - last_sent >= HEARTBEAT:
            send({"type": "status", "state": "listening"})
            last_sent = now
        stopping.wait(POLL)
    send({"type": "end", "reason": "stopped", "complete": True})


def main():
    hello = None
    stopping = threading.Event()
    worker = None
    for raw in sys.stdin:                       # the loop ends when stdin closes: then we must exit
        try:
            message = json.loads(raw)
        except ValueError:
            log("Ignored a line that isn't JSON")
            continue
        kind = message.get("type")
        if kind == "hello":
            if PROTOCOL not in message.get("protocols", []):
                send({"type": "error", "code": "protocol", "message": "This source speaks wsp/1 only."})
                return 1
            hello = message
            send({"type": "hello", "protocol": PROTOCOL, "source": SOURCE, "capabilities": CAPABILITIES})
            if message.get("mode") == "probe":
                folder = os.path.dirname(os.path.expanduser(message.get("config", {}).get("path", "~/captions.txt")))
                if os.path.isdir(folder):
                    send({"type": "availability", "available": True})
                else:
                    send({"type": "availability", "available": False, "reason": "The folder for the captions file doesn't exist."})
                return 0
        elif kind == "start" and hello is not None and worker is None:
            worker = threading.Thread(target=session, args=(hello.get("config", {}), stopping), daemon=True)
            worker.start()
        elif kind == "stop":
            break
        elif kind == "purge":
            # This source keeps nothing outside its scratch folder, which WorkScribe deletes itself.
            send({"type": "purged", "meetingId": message.get("meetingId")})
            return 0
        # Unknown message types are ignored: that is how the protocol grows.
    stopping.set()
    if worker is not None:
        worker.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
