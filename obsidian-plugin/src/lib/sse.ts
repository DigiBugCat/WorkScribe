// Incremental Server-Sent Events parser (WHATWG event-stream rules).
// Feed it arbitrary text chunks; it emits complete events.

export interface SseMessage {
  event: string;
  data: string;
  id?: string;
  retry?: number;
}

export class SseParser {
  private buf = "";
  private data: string[] = [];
  private event = "";
  private id: string | undefined;
  private retry: number | undefined;
  private sawBom = false;

  constructor(private readonly onMessage: (msg: SseMessage) => void) {}

  push(chunk: string): void {
    if (!this.sawBom) {
      if (chunk.length === 0) return;
      if (chunk.charCodeAt(0) === 0xfeff) chunk = chunk.slice(1);
      this.sawBom = true;
    }
    this.buf += chunk;
    // Split on CRLF, LF or CR; keep the trailing partial line in the buffer.
    let start = 0;
    for (let i = 0; i < this.buf.length; i++) {
      const c = this.buf[i];
      if (c === "\n" || c === "\r") {
        // A CR at the very end might be the first half of CRLF: wait for more.
        if (c === "\r" && i === this.buf.length - 1) break;
        this.line(this.buf.slice(start, i));
        if (c === "\r" && this.buf[i + 1] === "\n") i++;
        start = i + 1;
      }
    }
    this.buf = this.buf.slice(start);
  }

  /** Flush at end of stream (a final event without a blank line is discarded per spec). */
  end(): void {
    // A trailing CR held back as a possible CRLF half is a complete line ending.
    if (this.buf.endsWith("\r")) this.line(this.buf.slice(0, -1));
    this.buf = "";
    this.data = [];
    this.event = "";
  }

  private line(line: string): void {
    if (line === "") {
      this.dispatch();
      return;
    }
    if (line.startsWith(":")) return; // comment / keep-alive
    const colon = line.indexOf(":");
    let field = line;
    let value = "";
    if (colon >= 0) {
      field = line.slice(0, colon);
      value = line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
    }
    switch (field) {
      case "event":
        this.event = value;
        break;
      case "data":
        this.data.push(value);
        break;
      case "id":
        if (!value.includes("\0")) this.id = value;
        break;
      case "retry":
        if (/^\d+$/.test(value)) this.retry = Number(value);
        break;
      default:
        break;
    }
  }

  private dispatch(): void {
    if (this.data.length === 0) {
      this.event = "";
      return;
    }
    const msg: SseMessage = { event: this.event || "message", data: this.data.join("\n") };
    if (this.id !== undefined) msg.id = this.id;
    if (this.retry !== undefined) msg.retry = this.retry;
    this.data = [];
    this.event = "";
    this.onMessage(msg);
  }
}
