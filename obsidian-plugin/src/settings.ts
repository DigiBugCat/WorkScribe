import { App, PluginSettingTab, Setting } from "obsidian";
import { defaultApiJsonPath } from "./lib/discovery";
import type WorkScribePlugin from "./main";

export type Scope = "everything" | "meeting";
export type LivePanelTab = "ask" | "qa" | "transcript";

export interface WorkScribeSettings {
  /** Empty = ~/Library/Application Support/WorkScribe/api.json. */
  apiJsonPath: string;
  yourName: string;
  autoOpenLiveView: boolean;
  defaultScope: Scope;
  conversationsFolder: string;
  /** Companion panel tab. */
  livePanelTab: LivePanelTab;
  /** Show suggestions in the past-meeting view. */
  showSuggestions: boolean;
}

export const DEFAULT_SETTINGS: WorkScribeSettings = {
  apiJsonPath: "",
  yourName: "",
  autoOpenLiveView: true,
  defaultScope: "everything",
  conversationsFolder: "WorkScribe/Conversations",
  livePanelTab: "transcript",
  showSuggestions: true,
};

export class WorkScribeSettingTab extends PluginSettingTab {
  constructor(
    app: App,
    private readonly plugin: WorkScribePlugin,
  ) {
    super(app, plugin);
  }

  override display(): void {
    const { containerEl } = this;
    containerEl.empty();
    const s = this.plugin.settings;

    const conn = containerEl.createDiv({ cls: "ws-settings-conn" });
    const renderConn = () => {
      conn.empty();
      const st = this.plugin.connState;
      conn.createSpan({ cls: `ws-conn-dot is-${st.kind}` });
      conn.createSpan({
        text:
          st.kind === "online"
            ? "Connected to WorkScribe"
            : st.kind === "connecting"
              ? "Connecting to WorkScribe…"
              : st.reason,
      });
    };
    renderConn();

    new Setting(containerEl)
      .setName("api.json path")
      .setDesc(`Where WorkScribe publishes its port and token. Leave empty for ${defaultApiJsonPath()}. Point it at dev/api.json to use the mock server.`)
      .addText((t) =>
        t
          .setPlaceholder(defaultApiJsonPath())
          .setValue(s.apiJsonPath)
          .onChange(async (v) => {
            s.apiJsonPath = v.trim();
            await this.plugin.saveSettings();
          }),
      )
      .addButton((b) =>
        b.setButtonText("Reconnect").onClick(() => {
          this.plugin.reconnect();
          window.setTimeout(renderConn, 800);
        }),
      );

    new Setting(containerEl)
      .setName("Open the meeting note and companion when recording starts")
      .addToggle((t) =>
        t.setValue(s.autoOpenLiveView).onChange(async (v) => {
          s.autoOpenLiveView = v;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName("Your name in meeting questions")
      .setDesc("Put questions addressed to you first. Include a short name or comma-separated alternatives.")
      .addText(t=>t.setValue(s.yourName).onChange(async value=>{s.yourName=value.trim();await this.plugin.saveSettings();}));

    new Setting(containerEl)
      .setName("Default scope for questions")
      .setDesc("During a call, “This meeting” asks about the live meeting first.")
      .addDropdown((d) =>
        d
          .addOption("everything", "Everything")
          .addOption("meeting", "This meeting (when recording)")
          .setValue(s.defaultScope)
          .onChange(async (v) => {
            s.defaultScope = v as Scope;
            await this.plugin.saveSettings();
          }),
      );

    new Setting(containerEl)
      .setName("Save conversations to")
      .setDesc("Vault folder for conversations saved from the Ask view.")
      .addText((t) =>
        t.setValue(s.conversationsFolder).onChange(async (v) => {
          s.conversationsFolder = v.trim().replace(/^\/+|\/+$/g, "") || DEFAULT_SETTINGS.conversationsFolder;
          await this.plugin.saveSettings();
        }),
      );

    containerEl.createEl("p", {
      cls: "setting-item-description",
      text: "Quick ask defaults to Mod+Shift+K. Change it under Settings → Hotkeys → “WorkScribe: Quick ask”.",
    });
  }
}
