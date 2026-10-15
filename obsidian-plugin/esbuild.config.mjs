import esbuild from "esbuild";
import { readdirSync, rmSync } from "node:fs";
import { builtinModules } from "node:module";

const mode = process.argv[2] ?? "production";

if (mode === "tests") {
  // Bundle each test file (pure logic only, no `obsidian` import) for node:test.
  rmSync(".test-build", { recursive: true, force: true });
  const entries = readdirSync("test").filter((f) => f.endsWith(".test.ts")).map((f) => `test/${f}`);
  await esbuild.build({
    entryPoints: entries,
    outdir: ".test-build",
    outExtension: { ".js": ".mjs" },
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node20",
    // Keep the mock server as a real module: bundled, its CLI guard would see itself as the entry point.
    // (.test-build/ sits beside dev/, so the relative import still resolves.)
    external: ["../dev/*", ...builtinModules, ...builtinModules.map((m) => `node:${m}`)],
    logLevel: "warning",
  });
} else {
  const ctx = await esbuild.context({
    entryPoints: ["src/main.ts"],
    outfile: "main.js",
    bundle: true,
    format: "cjs",
    platform: "browser",
    target: "es2021",
    external: [
      "obsidian",
      "electron",
      "@codemirror/*",
      // The standalone block parser is bundled; Obsidian does not expose @lezer/markdown.
      ...builtinModules,
      ...builtinModules.map((m) => `node:${m}`),
    ],
    sourcemap: mode === "production" ? false : "inline",
    minify: false,
    treeShaking: true,
    logLevel: "info",
    banner: { js: "/* WorkScribe for Obsidian. Bundled by esbuild; source in src/. */" },
  });
  if (mode === "watch") {
    await ctx.watch();
  } else {
    await ctx.rebuild();
    await ctx.dispose();
  }
}
