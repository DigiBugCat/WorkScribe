// Disposable native Obsidian profile; synthetic status and transcript only. No audio capture.
import { chromium } from 'playwright';
import { mkdirSync, writeFileSync, copyFileSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
import { startMockServer } from './mock-server.mjs';

const root = resolve('../.artifacts/realrun-native'), vault = join(root, 'vault'), profile = join(root, 'profile');
const output = resolve('../docs/research/realrun');
mkdirSync(join(vault, '.obsidian/plugins/workscribe'), { recursive: true });
mkdirSync(profile, { recursive: true }); mkdirSync(output, { recursive: true });
const server = await startMockServer({ vault, discovery: join(root, 'api.json'), live: true, quiet: true, speed: 1000 });
for (const name of ['main.js', 'manifest.json', 'styles.css']) copyFileSync(resolve(name), join(vault, '.obsidian/plugins/workscribe', name));
writeFileSync(join(vault, '.obsidian/plugins/workscribe/data.json'), JSON.stringify({ apiJsonPath: server.discoveryPath, autoOpenLiveView: true }));
writeFileSync(join(vault, '.obsidian/community-plugins.json'), JSON.stringify(['workscribe']));
writeFileSync(join(profile, 'obsidian.json'), JSON.stringify({ vaults: { aabbccddeeaa1926: { path: vault, ts: Date.now(), open: true } } }));
const child = spawn('/Applications/Obsidian.app/Contents/MacOS/Obsidian', [`--user-data-dir=${profile}`, '--remote-debugging-port=19269', '--no-sandbox'], { stdio: 'ignore' });
let browser;
try {
  for (let i = 0; i < 80; i++) {
    try { browser = await chromium.connectOverCDP('http://127.0.0.1:19269'); break; } catch { await new Promise(r => setTimeout(r, 250)); }
  }
  assert.ok(browser, 'isolated Obsidian started');
  const page = browser.contexts()[0].pages().find(p => p.url().startsWith('app://obsidian'));
  assert.ok(page); page.setDefaultTimeout(12000);
  await page.waitForFunction(() => window.app?.vault);
  assert.equal(await page.evaluate(() => app.vault.adapter.getBasePath()), vault);
  for (let i = 0; i < 40; i++) {
    if (await page.evaluate(() => !!app.plugins.plugins.workscribe)) break;
    const trust = page.getByRole('button', { name: 'Trust author and enable plugins', exact: true });
    if (await trust.count()) await trust.click();
    await page.waitForTimeout(250);
  }
  await page.evaluate(async () => { if (!app.plugins.plugins.workscribe) await app.plugins.enablePlugin('workscribe'); });
  await page.waitForFunction(() => app.plugins.plugins.workscribe?.recording);
  const fixture = JSON.parse(readFileSync(resolve('../Tests/WorkScribeCoreTests/Golden/realrun-fragments.json'), 'utf8'));
  await page.evaluate(async raw => {
    const p = app.plugins.plugins.workscribe;
    await p.noteEditor.open(p.live.meetingId);
    p.live.segments = raw.map(s => ({ ...s, speakerId: s.speaker, final: true }));
    p.settings.livePanelTab = 'transcript'; await p.activateLiveView();
  }, fixture);
  await page.waitForSelector('.ws-turn');
  assert.equal(await page.locator('.ws-turn').count(), 5);
  const original = await page.evaluate(() => app.workspace.getLeavesOfType('markdown')[0].view.editor.getValue());
  const notice = 'Your Mac is busy · still recording, the transcript will catch up';
  const frames = [];
  for (let frame = 0; frame < 30; frame++) {
    if (frame === 5 || frame === 20) {
      await page.evaluate(message => {
        const p = app.plugins.plugins.workscribe;
        p.handleEvent({ type: 'status', status: { ...p.live.status, recording: true, message } });
        p.noteEditor.refresh(true);
      }, frame === 5 ? notice : 'Recording on this Mac · transcript caught up');
    }
    if (frame === 10) {
      assert.equal(await page.locator('.ws-paused-header').innerText(), notice);
      await page.screenshot({ path: join(output, 'busy-transcript.png') });
    }
    const file = join(root, `frame-${String(frame).padStart(3, '0')}.png`);
    await page.screenshot({ path: file }); frames.push(file); await page.waitForTimeout(200);
  }
  assert.equal(await page.locator('.ws-paused-header').count(), 0);
  assert.equal(await page.evaluate(() => app.workspace.getLeavesOfType('markdown')[0].view.editor.getValue()), original);
  await page.screenshot({ path: join(output, 'caught-up-transcript.png') });
  writeFileSync(join(root, 'frames.txt'), frames.map(f => `file '${f}'\nduration 0.2`).join('\n'));
  writeFileSync(join(output, 'ui-check.json'), JSON.stringify({ synthetic: true, turns: 5, notice, noticeCleared: true, userTextPreserved: true }, null, 2));
  console.log('Native Obsidian: five readable turns; busy notice appeared and cleared; user text preserved.');
} finally { await browser?.close(); child.kill('SIGTERM'); await server.close(); }
