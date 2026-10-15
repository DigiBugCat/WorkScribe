// Ask view: a native Obsidian view (right sidebar by default) holding one
// Claudian-style chat over everything WorkScribe knows.

import { ItemView, type TFile, type WorkspaceLeaf } from "obsidian";
import type { Clip } from "../lib/types";
import type WorkScribePlugin from "../main";
import { ChatPanel, type Conversation } from "./chat";

export type { ChatMessage, Conversation } from "./chat";

export const ASK_VIEW = "workscribe-ask";

export class AskView extends ItemView {
  chat!: ChatPanel;
  private unsub: (() => void) | null = null;

  constructor(
    leaf: WorkspaceLeaf,
    private readonly plugin: WorkScribePlugin,
  ) {
    super(leaf);
  }

  getViewType(): string {
    return ASK_VIEW;
  }
  getDisplayText(): string {
    return "Ask WorkScribe";
  }
  override getIcon(): string {
    return "message-circle-question";
  }

  get conv(): Conversation {
    return this.chat.conv;
  }

  override async onOpen(): Promise<void> {
    const root = this.contentEl;
    root.empty();
    root.addClass("ws-ask");
    this.chat = this.addChild(new ChatPanel(root, this.app, this.plugin, { scope: this.plugin.settings.defaultScope }));
    this.unsub = this.plugin.subscribe((c) => {
      if (c.has("status") || c.has("meeting") || c.has("conn") || c.has("context")) this.chat.refresh();
    });
  }

  override async onClose(): Promise<void> {
    this.unsub?.();
  }

  focusInput(): void {
    this.chat.focus();
  }

  seed(conv: Conversation): void {
    this.chat.seed(conv);
  }

  reset(): void {
    this.chat.reset();
  }

  attachVaultFile(f: TFile): void {
    this.chat.attachVaultFile(f);
  }

  offerClip(clip: Clip, question?: string): void {
    this.chat.offerClip(clip, question);
  }

  async send(question?: string): Promise<void> {
    await this.chat.send(question ?? this.chat.composer.value);
  }

  saveAsNote(): Promise<void> {
    return this.chat.saveAsNote();
  }
}
