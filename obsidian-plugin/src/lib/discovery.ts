// Find the running app: ~/Library/Application Support/WorkScribe/api.json.

import { promises as fs } from "fs";
import * as os from "os";
import * as path from "path";
import { ApiError, NOT_RUNNING } from "./client";
import { parseDiscovery } from "./parse";
import type { Discovery } from "./types";

export function defaultApiJsonPath(): string {
  return path.join(os.homedir(), "Library", "Application Support", "WorkScribe", "api.json");
}

export function expandHome(p: string): string {
  return p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : p;
}

export async function readDiscovery(file: string): Promise<Discovery> {
  let text: string;
  try {
    text = await fs.readFile(expandHome(file), "utf8");
  } catch {
    throw new ApiError("offline", `${NOT_RUNNING}: no ${file}`);
  }
  try {
    return parseDiscovery(text);
  } catch (e) {
    throw new ApiError("offline", `${NOT_RUNNING}: ${(e as Error).message}`);
  }
}
