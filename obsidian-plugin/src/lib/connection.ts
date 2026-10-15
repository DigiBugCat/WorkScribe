// Keeps one /v1/events subscription alive with backoff, and tracks whether
// the app is reachable. Pure apart from timers (injected for tests).

import { ApiError, type WorkScribeClient } from "./client";
import type { LiveEvent } from "./types";

export type ConnState = { kind: "connecting" } | { kind: "online" } | { kind: "offline"; reason: string };

export interface Timers {
  set(fn: () => void, ms: number): unknown;
  clear(h: unknown): void;
}

const realTimers: Timers = {
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

export const BACKOFF_MS = [1000, 2000, 4000, 8000, 15000];

export class EventsConnection {
  state: ConnState = { kind: "connecting" };
  private abort: AbortController | null = null;
  private timer: unknown = null;
  private attempt = 0;
  private stopped = true;

  constructor(
    private readonly client: WorkScribeClient,
    private readonly onEvent: (ev: LiveEvent) => void,
    private readonly onState: (s: ConnState) => void,
    private readonly timers: Timers = realTimers,
  ) {}

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    this.abort?.abort();
    this.abort = null;
    if (this.timer !== null) this.timers.clear(this.timer);
    this.timer = null;
  }

  /** Reconnect now (e.g. after the api.json path setting changed). */
  restart(): void {
    this.stop();
    this.attempt = 0;
    this.start();
  }

  private set(s: ConnState): void {
    const same = s.kind === this.state.kind && (s.kind !== "offline" || (this.state as { reason: string }).reason === s.reason);
    this.state = s;
    if (!same) this.onState(s);
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    const ac = new AbortController();
    this.abort = ac;
    try {
      const { done } = await this.client.events(this.onEvent, ac.signal);
      this.attempt = 0;
      this.set({ kind: "online" });
      // Ask for a fresh status in case the app doesn't push one on connect.
      this.client.status().then((status) => this.onEvent({ type: "status", status }), () => undefined);
      await done;
      if (ac.signal.aborted) return;
      this.set({ kind: "offline", reason: "WorkScribe closed the connection" });
    } catch (e) {
      if (ac.signal.aborted) return;
      this.set({ kind: "offline", reason: e instanceof ApiError ? e.message : String(e) });
    }
    this.schedule();
  }

  private schedule(): void {
    if (this.stopped) return;
    const ms = BACKOFF_MS[Math.min(this.attempt, BACKOFF_MS.length - 1)]!;
    this.attempt++;
    this.timer = this.timers.set(() => {
      this.timer = null;
      void this.connect();
    }, ms);
  }
}
