import {createServer} from 'node:http';
import {readFileSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {build} from 'esbuild';
import {chromium} from 'playwright';
import {startMockServer} from './mock-server.mjs';
import assert from 'node:assert/strict';
const out=resolve(process.argv[2]??'/private/tmp/claude-501/handoffs/e4b/ui-8');mkdirSync(out,{recursive:true});
const scratch=resolve('.surface-qa');mkdirSync(scratch,{recursive:true});
await build({entryPoints:['dev/surface-page.ts'],bundle:true,format:'iife',outfile:join(scratch,'page.js'),logLevel:'silent'});
const html=`<!doctype html><title>WorkScribe surface QA</title><meta charset="utf-8"><link rel="stylesheet" href="/styles.css"><style>
:root{--font-text-size:15px;--font-small:12px;--font-smallest:11px;--radius-m:6px;--text-normal:#252525;--text-muted:#666;--text-faint:#777;--text-warning:#986500;--interactive-accent:#705dcf;--text-highlight-bg:#eddb8e;--background-primary:#fff;--background-primary-alt:#f8f8f8;--background-modifier-border:#ddd}
.theme-dark{--text-normal:#dedede;--text-muted:#aaa;--text-faint:#999;--text-warning:#dcb566;--interactive-accent:#ab9df2;--text-highlight-bg:#6d591b;--background-primary:#202020;--background-primary-alt:#272727;--background-modifier-border:#444;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--background-primary);color:var(--text-normal);font-family:-apple-system,system-ui}header{height:48px;padding:14px 24px;border-bottom:1px solid var(--background-modifier-border)}header span{float:right;color:var(--text-muted);font-size:12px}main{display:grid;grid-template-columns:minmax(0,760px) 330px;height:calc(100vh - 48px);justify-content:center}#editor{min-width:0;overflow:auto}aside{border-left:1px solid var(--background-modifier-border);padding:18px;overflow:auto;background:var(--background-primary-alt);font-size:12px}aside h3{font-size:13px}#transcript{max-height:400px;overflow:auto}.transcript-row{padding:10px 6px;white-space:pre-line;line-height:1.5;border-radius:5px}.is-evidence{background:var(--text-highlight-bg)}button{cursor:pointer;color:var(--text-normal);background:var(--background-primary);border:1px solid var(--background-modifier-border);border-radius:5px;padding:4px 8px}#sources:empty{display:none}.ws-surface-line{margin-left:12px;font-size:14px}
</style><body class="theme-light"><header>Offline sync — v2.4 <span id="status"></span></header><main><div id="editor"></div><aside><h3>Sources</h3><div id="sources"></div><h3>Transcript</h3><div id="transcript"></div></aside></main><script src="/page.js"></script>`;
const mock=await startMockServer({vault:join(scratch,'vault'),discovery:false,quiet:true});
const server=createServer(async(req,res)=>{try{
 if(req.url.startsWith('/v1/')){const chunks=[];for await(const chunk of req)chunks.push(chunk);const response=await fetch(`http://127.0.0.1:${mock.port}${req.url}`,{method:req.method,headers:{authorization:`Bearer ${mock.token}`,'content-type':'application/json'},...(req.method==='POST'?{body:Buffer.concat(chunks)}:{})});res.writeHead(response.status,Object.fromEntries(response.headers));if(req.url==='/v1/events'){const reader=response.body.getReader();res.on('close',()=>void reader.cancel());while(true){const {value,done}=await reader.read();if(done)break;res.write(value);}res.end();}else res.end(Buffer.from(await response.arrayBuffer()));return;}
 res.setHeader('Content-Type',req.url==='/styles.css'?'text/css':req.url==='/page.js'?'text/javascript':'text/html');res.end(req.url==='/styles.css'?readFileSync('styles.css'):req.url==='/page.js'?readFileSync(join(scratch,'page.js')):html);
 }catch(error){if(!res.headersSent)res.writeHead(500);res.end(String(error));}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});const metrics={screenshots:[],checks:[],errors:[]};
try {
 const ref=await browser.newPage();await ref.goto('file:///private/tmp/claude-501/handoffs/e4b/ui-reference-mock.html');for(const id of ['m-meet','m-struct','m-prose','m-note']){await ref.locator('#'+id).click();assert.equal(await ref.locator('#'+id).getAttribute('aria-pressed'),'true');}await ref.close();metrics.checks.push('All four reference tabs opened');
 for(const theme of ['light','dark']){
  const context=await browser.newContext({viewport:{width:1180,height:980},recordVideo:{dir:out,size:{width:1180,height:980}}});const page=await context.newPage();page.on('pageerror',e=>metrics.errors.push(e.message));await page.goto(url);await page.waitForFunction(()=>window.qa);
  await page.evaluate(dark=>{window.qa.theme(dark);window.qa.all();},theme==='dark');
  const shot=async(name,locator)=>{if(process.env.WORKSCRIBE_QA_VIDEO_ONLY==='1')return;const path=join(out,`${theme}-${name}.png`);if(locator)await locator.screenshot({path});else await page.screenshot({path});metrics.screenshots.push(path);};
  await shot('line',page.locator('#editor'));await shot('status',page.locator('header'));
  assert.equal(await page.evaluate(()=>window.qa.view.state.doc.toString()),await page.evaluate(()=>window.qa.source));
  await page.locator('.ws-surface-pin').first().click();await page.waitForSelector('.is-evidence');await shot('sources');
  for(const [index,name] of ['sketch-pin','table-pin','task-pin'].entries()){await page.locator('.ws-surface-pin').nth(index).scrollIntoViewIfNeeded();await shot(name,page.locator('main'));}
  await page.locator('.ws-check-differs').click();await shot('check',page.locator('main'));
  await page.evaluate(()=>window.qa.revision());await page.waitForSelector('.ws-surface-change');await page.waitForTimeout(350);await shot('revision-mid-fade',page.locator('.ws-surface-line[data-ws-block="ship"]'));
  const duration=await page.locator('.ws-surface-change').first().evaluate(el=>getComputedStyle(el).animationDuration);assert.equal(duration,'1.2s');
  await page.getByRole('button',{name:'Make diagram',exact:true}).click();await page.waitForSelector('.ws-preview-diagram svg');await shot('make-preview',page.locator('.ws-make-preview'));
  const before=await page.evaluate(()=>window.qa.view.state.doc.toString());assert.equal(before,await page.evaluate(()=>window.qa.source));
  await page.getByRole('button',{name:'Insert below sketch',exact:true}).click();assert.ok((await page.evaluate(()=>window.qa.view.state.doc.toString())).includes('```mermaid'));
  await page.evaluate(()=>window.qa.undo());assert.equal(await page.evaluate(()=>window.qa.view.state.doc.toString()),before);metrics.checks.push(`${theme}: pin/check/preview preserve Markdown; insert undo restores exact document`);
  await page.emulateMedia({reducedMotion:'reduce'});await page.evaluate(()=>window.qa.revision());await page.waitForTimeout(60);assert.ok(await page.locator('.ws-surface-change').evaluateAll(els=>els.every(el=>getComputedStyle(el).animationName==='none')));metrics.checks.push(`${theme}: reduced motion suppresses revision animation`);
  await shot('reduced-motion',page.locator('.ws-surface-line[data-ws-block="ship"]'));
  const line=page.locator('.ws-surface-line[data-ws-block="ship"] .ws-editor-ai-button');
  await line.dispatchEvent('compositionstart');await line.evaluate(el=>{el.textContent='My edited ship date';});
  await page.evaluate(()=>{const current=window.qa.store.lines.get('surface-demo/ship');window.qa.apply({...current,state:'quiet',revision:current.revision+1});});
  assert.equal(await line.textContent(),'My edited ship date');await line.dispatchEvent('compositionend');assert.ok((await page.evaluate(()=>window.qa.view.state.doc.toString())).includes('> My edited ship date'));
  await page.evaluate(()=>window.qa.undo());assert.equal(await page.evaluate(()=>window.qa.view.state.doc.toString()),before);metrics.checks.push(`${theme}: IME text survives arriving state change; first input is one undoable ownership edit`);
  const video=page.video();await context.close();if(video)await video.saveAs(join(out,theme+"-interaction.webm"));
 }
 assert.deepEqual(metrics.errors,[]);
}finally{await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));await mock.close();rmSync(scratch,{recursive:true,force:true});writeFileSync(join(out,'metrics.json'),JSON.stringify(metrics,null,2));}
console.log(JSON.stringify(metrics,null,2));
