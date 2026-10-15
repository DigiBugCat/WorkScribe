import { chromium } from 'playwright';
import { mkdirSync, writeFileSync, readdirSync, unlinkSync } from 'node:fs';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { startMockServer } from './mock-server.mjs';
const output=resolve(process.argv[2] ?? '../docs/research/polish');mkdirSync(output,{recursive:true});for(const name of readdirSync(output))if(/^frame-.*\.jpg$/.test(name))unlinkSync(resolve(output,name));
const browser=await chromium.connectOverCDP(process.env.OBSIDIAN_CDP ?? 'http://localhost:9249');
const page=browser.contexts()[0].pages().find(p=>p.url().startsWith('app://obsidian.md/'));
assert.ok(page,'Obsidian main window');page.on('console',m=>{if(m.type()==='error')console.log('CONSOLE',m.text());});page.on('pageerror',e=>console.log('EARLY ERROR',e.stack));page.setDefaultTimeout(10000);
await page.evaluate(expected=>{
  if(app.vault.adapter.getBasePath()!==expected) throw new Error('Native checks require the isolated polish test vault');
},process.env.OBSIDIAN_TEST_VAULT ?? (() => { throw new Error('Set OBSIDIAN_TEST_VAULT to a disposable test vault'); })());
const trust=page.getByText('Trust author and enable plugins',{exact:true});for(let i=0;i<40;i++){if(await page.evaluate(()=>!!app.plugins.plugins.workscribe)||await trust.count())break;await page.waitForTimeout(250);}if(await trust.count())await trust.click();
await page.evaluate(async()=>{if(!app.plugins.plugins.workscribe)await app.plugins.enablePlugin('workscribe');});
await page.waitForFunction(()=>!!app.plugins.plugins.workscribe);
for(const extra of browser.contexts()[0].pages()) if(extra!==page && (await extra.title()).startsWith('Settings - ')) await extra.close();
await page.bringToFront();
const errors=[];page.on('pageerror',e=>{errors.push(e.message);console.log('PAGE ERROR',e.message);});
const oldMeeting=await page.evaluate(()=>app.plugins.plugins.workscribe.live.meetingId);
const vault=await page.evaluate(()=>app.vault.adapter.getBasePath());
const mock=await startMockServer({vault,discovery:resolve(output,'native-api.json'),live:true,speed:0.5,quiet:true});
await page.evaluate(async path=>{const p=app.plugins.plugins.workscribe;p.settings.apiJsonPath=path;await p.saveSettings();p.reconnect();},mock.discoveryPath);
const metrics={};
await page.evaluate(()=>{window.glyphs=(el,text)=>{let offset=el.textContent.indexOf(text),end=offset+text.length-1;const nodes=[];const w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);while(w.nextNode())nodes.push(w.currentNode);const point=index=>{for(const n of nodes){if(index<n.length){const r=document.createRange();r.setStart(n,index);r.setEnd(n,index+1);const b=r.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height};}index-=n.length;}return null;};return {first:point(offset),last:point(end)};};});const frames=[];let capture=true;
const loop=(async()=>{while(capture){const name=`frame-${String(frames.length).padStart(5,'0')}.jpg`;const stamp=Date.now();await page.screenshot({path:resolve(output,name),type:'jpeg',quality:75});frames.push({name,stamp});await new Promise(r=>setTimeout(r,180));}})();
try {
 await page.waitForFunction(old=>app.plugins.plugins.workscribe.recording && app.plugins.plugins.workscribe.live.meetingId!==old,oldMeeting);
 await page.evaluate(async()=>{
  const p=app.plugins.plugins.workscribe;await p.activateLiveView();
  document.body.classList.remove('theme-dark');document.body.classList.add('theme-light');
  window.wsTestView=()=>app.workspace.getLeavesOfType('markdown').find(l=>p.meetingIdOf(l.view.file)===p.live.meetingId).view;
  document.querySelectorAll('[data-ws-native-test]').forEach(e=>e.removeAttribute('data-ws-native-test'));
  const v=wsTestView();v.containerEl.setAttribute('data-ws-native-test','true');
  v.editor.setValue(v.editor.getValue().split('\n- ship date')[0].replace(/- $/,'')+'');
  v.editor.setCursor(v.editor.offsetToPos(v.editor.getValue().length));v.editor.focus();
  for(const leaf of app.workspace.getLeavesOfType('markdown')) if(leaf.view!==v) leaf.detach();
 });
 await page.keyboard.type('- ship date nov 4 not oct 28',{delay:25});await page.keyboard.press('Enter');
 await page.keyboard.type('beta 40 accts, halvorsen first',{delay:25});await page.keyboard.press('Enter');
 await page.keyboard.type('pricing for the beta?',{delay:25});
 await page.waitForFunction(()=>[...app.plugins.plugins.workscribe.live.notes.values()].filter(n=>n.enhanced).length>=2,null,{timeout:15000});
 metrics.activeLine=await page.evaluate(()=>({widgets:wsTestView().containerEl.querySelectorAll('.ws-editor-ai').length,source:wsTestView().editor.getValue()}));
 assert.ok(!metrics.activeLine.source.includes('QA gets'));
 await page.screenshot({path:resolve(output,'recording-header.png')});
 // Fresh responsive header evidence at actual viewport widths, with the companion open.
 metrics.headers=[];
 for(const [name,width] of [['pill-1024',1024],['pill-sidebar',740]]) {
   if(name==='pill-sidebar')await page.evaluate(()=>app.workspace.leftSplit.collapse());
   await page.setViewportSize({width,height:900});await page.waitForTimeout(350);
   const measurement=await page.evaluate(()=>{
     const v=wsTestView(),header=v.containerEl.querySelector('.view-header'),pill=header.querySelector('.ws-rec-pill');
     const stop=pill.querySelector('.ws-rec-stop'),clock=pill.querySelector('.ws-rec-clock'),source=pill.querySelector('.ws-rec-source');
     const title=header.querySelector('.view-header-title-container');
     return {header:header.getBoundingClientRect().toJSON(),pill:pill.getBoundingClientRect().toJSON(),stop:stop.getBoundingClientRect().toJSON(),clock:clock.getBoundingClientRect().toJSON(),source:source.getBoundingClientRect().toJSON(),sourceVisible:getComputedStyle(source).display!=='none',title:title?.getBoundingClientRect().toJSON(),text:header.innerText};
   });
   assert.ok(measurement.pill.left>=measurement.header.left-1,JSON.stringify(measurement));
   assert.ok(measurement.stop.right<=measurement.pill.right+1,JSON.stringify(measurement));
   assert.ok(measurement.stop.right<=measurement.header.right+1,JSON.stringify(measurement));
   assert.ok(measurement.clock.right<=measurement.stop.left,JSON.stringify(measurement));
   if(measurement.sourceVisible)assert.ok(measurement.source.right<=measurement.stop.left,JSON.stringify(measurement));
   metrics.headers.push({name,width,...measurement});
   await page.screenshot({path:resolve(output,name+'.png')});
 }
 await page.evaluate(()=>app.workspace.leftSplit.expand());
 await page.setViewportSize({width:1480,height:1100});await page.waitForTimeout(350);
 metrics.liveSpacing=await page.evaluate(()=>{
   const v=wsTestView(),props=v.containerEl.querySelector('.metadata-container'),first=v.containerEl.querySelector('.HyperMD-list-line');
   return {properties:props?.getBoundingClientRect().toJSON(),first:first?.getBoundingClientRect().toJSON(),margin:props?getComputedStyle(props).marginBottom:null};
 });
 assert.ok(Math.abs(metrics.liveSpacing.first.top-metrics.liveSpacing.properties.bottom-22)<2,JSON.stringify(metrics.liveSpacing));
 await page.screenshot({path:resolve(output,'live-spacing.png')});

 await page.waitForTimeout(5000);
 metrics.rewrite=await page.evaluate(async()=>{
  const p=app.plugins.plugins.workscribe,cm=wsTestView().editor.cm;
  const before={selection:cm.state.selection.toJSON(),source:cm.state.doc.toString(),caret:cm.lineBlockAt(cm.state.selection.main.head).top-cm.scrollDOM.scrollTop};
  const [id,n]=[...p.live.notes.entries()][0];
  p.live.notes.set(id,{...n,enhanced:{topic:'Ship date.',text:'v2.4 moves from Oct 28 to Nov 4 so QA gets a full week on the SQLite migration. Priya tells Halvorsen on Friday. The rollout follows the migration review.'}});p.notify(new Set(['notes']));
  await new Promise(r=>setTimeout(r,2250));
  return {before,after:{selection:cm.state.selection.toJSON(),source:cm.state.doc.toString(),caret:cm.lineBlockAt(cm.state.selection.main.head).top-cm.scrollDOM.scrollTop},wet:document.querySelectorAll('.ws-ai-change').length,focused:cm.hasFocus};
 });
 assert.deepEqual(metrics.rewrite.before.selection,metrics.rewrite.after.selection);assert.equal(metrics.rewrite.before.source,metrics.rewrite.after.source);
 assert.ok(Math.abs(metrics.rewrite.before.caret-metrics.rewrite.after.caret)<2);assert.ok(metrics.rewrite.wet>0);
 metrics.alignment=await page.evaluate(()=>{
  const cm=wsTestView().editor.cm;
  return [...wsTestView().containerEl.querySelectorAll('.ws-editor-ai')].map(el=>{
   const pos=cm.posAtDOM(el),line=cm.state.doc.lineAt(pos),prefix=line.text.match(/^\s*(?:[-+*]|\d+[.)])\s+(?:\[.\]\s+)?/)?.[0].length??0;
   const expected=cm.coordsAtPos(line.from+prefix)?.left,actual=el.querySelector('.ws-editor-ai-button').getBoundingClientRect().left;
   const next=el.nextElementSibling;const gap=next?.classList.contains('cm-line')?next.getBoundingClientRect().top-el.querySelector('.ws-editor-ai-button').getBoundingClientRect().bottom:null;return {text:el.innerText,expected,actual,delta:actual-expected,gap};
  });
 });
 assert.ok(metrics.alignment.filter(m=>m.gap!==null).every(m=>Math.abs(m.gap-7)<=1),JSON.stringify(metrics.alignment));
 assert.ok(metrics.alignment.every(m=>Math.abs(m.delta)<=.5),JSON.stringify(metrics.alignment));
 assert.equal(new Set(metrics.alignment.map(m=>m.text)).size,metrics.alignment.length,'AI text belongs to only one bullet');
 await page.screenshot({path:resolve(output,'live-mid-rewrite.png')});
 await page.evaluate(()=>{const cm=wsTestView().editor.cm;cm.dispatch({changes:{from:4,insert:'# anchor-shift regression\n'},userEvent:'input'});});
 await page.waitForTimeout(250);
 await page.locator('[data-ws-native-test] .ws-editor-ai').first().hover({timeout:5000});
 await page.locator('.ws-ai-margin .ws-ai-why').first().click({timeout:5000});
 await page.waitForSelector('.ws-evidence-header .ws-trace');
 assert.ok((await page.locator('.ws-evidence-header').innerText()).includes('What it heard'));
 await page.screenshot({path:resolve(output,'line-why-trace.png')});await page.keyboard.press('Escape');
 // First keystroke, without a menu, takes over the actual AI line.
 metrics.beforeOwned=await page.locator('[data-ws-native-test] .ws-editor-ai-button').first().evaluate(el=>{const r=document.createRange();r.selectNodeContents(el);return [...r.getClientRects()].map(r=>({x:r.x,y:r.y,width:r.width,height:r.height}));});
 const first=page.locator('[data-ws-native-test] .ws-editor-ai-button').first();await first.click();await first.evaluate(el=>{const range=document.createRange();range.selectNodeContents(el);range.collapse(false);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);});metrics.glyphsBefore=await first.evaluate(el=>window.glyphs(el,el.textContent));metrics.ownedBeforeStyle=await first.evaluate(el=>({text:el.textContent,rect:el.getBoundingClientRect().toJSON(),font:getComputedStyle(el).font,spacing:getComputedStyle(el).letterSpacing,whiteSpace:getComputedStyle(el).whiteSpace}));await page.keyboard.type('!');
 await page.waitForTimeout(1200);
 metrics.owned=await page.evaluate(()=>({source:wsTestView().editor.getValue(),owned:[...app.plugins.plugins.workscribe.live.notes.values()].filter(n=>n.userEdited).length}));
 metrics.glyphsAfter=await page.locator('[data-ws-native-test] .ws-owned-line').first().evaluate(el=>window.glyphs(el,el.textContent.trim().replace(/!$/,'')));
 for(const point of ['first','last'])for(const axis of ['x','y'])assert.ok(Math.abs(metrics.glyphsBefore[point][axis]-metrics.glyphsAfter[point][axis])<=.5,`owned ${point} ${axis}`);
 metrics.afterOwned=await page.locator('[data-ws-native-test] .ws-owned-line').first().evaluate(el=>({text:el.textContent,html:el.innerHTML,rect:el.getBoundingClientRect().toJSON(),font:getComputedStyle(el).font,spacing:getComputedStyle(el).letterSpacing,whiteSpace:getComputedStyle(el).whiteSpace}));
 await page.screenshot({path:resolve(output,'owned-line.png')});
 assert.ok(metrics.owned.source.includes('- ship date nov 4 not oct 28\n  v2.4'),'ownership follows the same bullet after earlier text shifts');
 assert.equal(metrics.owned.owned,1);assert.ok(!metrics.owned.source.includes('> **'));
 await page.evaluate(()=>wsTestView().editor.focus());await page.keyboard.press('Meta+z');await page.waitForTimeout(1200);
 assert.ok(!(await page.evaluate(()=>wsTestView().editor.getValue())).includes('migration review.!'));
 await page.keyboard.press('Meta+Shift+z');await page.waitForTimeout(1200);
 assert.equal(await page.evaluate(()=>[...app.plugins.plugins.workscribe.live.notes.values()].filter(n=>n.userEdited).length),1);
 await page.locator('[data-ws-native-test] .ws-owned-line').hover();
 await page.locator('.ws-ai-margin .ws-ai-handback').filter({hasText:'Let AI rewrite'}).first().click();
 await page.waitForTimeout(1200);
 assert.equal(await page.evaluate(()=>[...app.plugins.plugins.workscribe.live.notes.values()].filter(n=>n.userEdited).length),0);
 await page.evaluate(()=>wsTestView().editor.focus());await page.keyboard.press('Meta+z');await page.waitForTimeout(1200);
 assert.equal(await page.evaluate(()=>[...app.plugins.plugins.workscribe.live.notes.values()].filter(n=>n.userEdited).length),1);

 // Ask is the same ChatPanel as Quick ask; its trace stays collapsed until requested.
 await page.evaluate(async()=>{
  const p=app.plugins.plugins.workscribe;const l=app.workspace.getLeavesOfType('workscribe-live')[0];p.settings.livePanelTab='ask';l.view.render();await l.view.chat.send('What does the Halvorsen contract say about offline?');
 });
 await page.waitForSelector('.ws-msg .ws-trace');
 const askTrace=page.locator('.ws-msg .ws-trace').last();await askTrace.locator('summary').first().click();
 await page.screenshot({path:resolve(output,'ask-answer-trace.png')});
 // A detected question never changes the active tab or steals the editor's focus.
 metrics.question=await page.evaluate(()=>{
  const p=app.plugins.plugins.workscribe;wsTestView().editor.focus();
  p.live.answer={id:'q-check',at:10,question:'What did we decide?',answer:'Nov 4.',citations:[],done:true};p.notify(new Set(['answer']));
  return {tab:p.settings.livePanelTab,focused:wsTestView().editor.cm.hasFocus};
 });assert.equal(metrics.question.tab,'ask');assert.ok(metrics.question.focused);
 // Stop leaves pencil editable; explicit Finalize is one editor transaction.
 await page.evaluate(async()=>{await app.plugins.plugins.workscribe.stopRecording();});await page.waitForTimeout(1500);
 assert.equal(await page.evaluate(()=>app.plugins.plugins.workscribe.noteEditor.isFinalized()),false);
 await page.waitForSelector('.ws-rec-resume');
 const beforeResume=await page.evaluate(()=>({id:app.plugins.plugins.workscribe.live.meetingId,source:wsTestView().editor.getValue(),segments:app.plugins.plugins.workscribe.live.segments.length}));
 await page.screenshot({path:resolve(output,'resume-ready.png')});
 // Drive the real Resume button and observe the same bound note return to recording.
 await page.locator('.ws-rec-resume').click();
 await page.waitForFunction(()=>app.plugins.plugins.workscribe.recording);
 metrics.resume=await page.evaluate(()=>({id:app.plugins.plugins.workscribe.live.meetingId,source:wsTestView().editor.getValue(),segments:app.plugins.plugins.workscribe.live.segments.length}));
 assert.equal(metrics.resume.id,beforeResume.id);assert.equal(metrics.resume.source,beforeResume.source);assert.equal(metrics.resume.segments,beforeResume.segments);
 await page.screenshot({path:resolve(output,'resumed.png')});
 await page.evaluate(async()=>{await app.plugins.plugins.workscribe.stopRecording();});await page.waitForTimeout(500);
 // The fixture exposes real note completion state; observe partial and full rings without a timer pretending to know progress.
 const savedNotes=await page.evaluate(()=>{const p=app.plugins.plugins.workscribe,n=[...p.live.notes.entries()];p.live.status={...p.live.status,phase:'finalizing',finalizationProgress:0.35};p.live.notes=new Map(n.map(([id,n],i)=>[id,{...n,state:i===0?'enhancing':'done'}]));p.notify(new Set(['notes']));return n;});
 await page.waitForTimeout(250);await page.screenshot({path:resolve(output,'finishing-ring.png')});
 metrics.finishingRing=await page.locator('.ws-progress-ring').first().getAttribute('aria-valuenow');
 assert.ok(Number(metrics.finishingRing)<100);
 await page.evaluate(notes=>{const p=app.plugins.plugins.workscribe;p.live.status={...p.live.status,phase:'ready',finalizationProgress:1};p.live.notes=new Map(notes);p.notify(new Set(['notes']));},savedNotes);
 await page.waitForTimeout(250);
 assert.equal(await page.locator('.ws-progress-ring').first().getAttribute('aria-valuenow'),'100');
 const nonMeeting=await page.evaluate(async()=>{const f=await app.vault.create('Unrelated.md','[[A link]]');const l=app.workspace.getLeaf('tab');await l.openFile(f);l.view.editor.focus();return f.path;});
 await page.keyboard.press('Meta+Enter');await page.waitForTimeout(300);
 assert.equal(await page.evaluate(()=>app.plugins.plugins.workscribe.noteEditor.isFinalized()),false);
 metrics.unrelatedShortcut=true;
 await page.evaluate(async()=>{await app.plugins.plugins.workscribe.noteEditor.open(app.plugins.plugins.workscribe.live.meetingId);});
 await page.screenshot({path:resolve(output,'finalize-bar.png')});
 await page.waitForTimeout(250);
 metrics.finalizeScrollBefore=await page.evaluate(()=>wsTestView().editor.cm.scrollDOM.scrollTop);
 const before=await page.evaluate(()=>wsTestView().editor.getValue());
 await page.evaluate(async()=>{await app.plugins.plugins.workscribe.noteEditor.finalize();});await page.waitForTimeout(1200);
 metrics.final=await page.evaluate(()=>({source:wsTestView().editor.getValue(),finalized:app.plugins.plugins.workscribe.noteEditor.isFinalized(),widgets:wsTestView().containerEl.querySelectorAll('.ws-editor-ai').length}));
 metrics.finalizeScrollAfter=await page.evaluate(()=>wsTestView().editor.cm.scrollDOM.scrollTop);
 assert.ok(Math.abs(metrics.finalizeScrollBefore-metrics.finalizeScrollAfter)<=1,'Finalize preserves scroll');
 assert.ok(!/^# /m.test(metrics.final.source.replace(/^---\n[\s\S]*?\n---\n/,'')));assert.ok(/---\n\n\*[^\n]+\*\n\n- /.test(metrics.final.source));
 assert.ok(metrics.final.finalized);assert.equal(metrics.final.widgets,0);assert.ok(!metrics.final.source.includes('> **'));
 await page.evaluate(()=>wsTestView().editor.focus());await page.keyboard.press('Meta+z');await page.waitForTimeout(1500);
 metrics.undo=await page.evaluate(()=>({source:wsTestView().editor.getValue(),finalized:app.plugins.plugins.workscribe.noteEditor.isFinalized()}));
 assert.equal(metrics.undo.source,before);assert.equal(metrics.undo.finalized,false);
 await page.evaluate(async()=>{await app.plugins.plugins.workscribe.noteEditor.flush();await app.plugins.plugins.workscribe.noteEditor.finalize();});await page.waitForTimeout(800);
 await page.setViewportSize({width:1480,height:1100});
 for(const theme of ['light','dark']) {
  await page.evaluate(async theme=>{document.body.classList.toggle('theme-dark',theme==='dark');document.body.classList.toggle('theme-light',theme==='light');const v=wsTestView();const l=app.workspace.getLeavesOfType('markdown').find(l=>l.view===v);await l.setViewState({type:'markdown',state:{file:v.file.path,mode:'preview'}});},theme);
  await page.waitForTimeout(400);await page.screenshot({path:resolve(output,`finalized-${theme}.png`)});
 }

 await page.evaluate(async()=>{const v=wsTestView();const leaf=app.workspace.getLeavesOfType('markdown').find(l=>l.view===v);await leaf.setViewState({type:'markdown',state:{file:v.file.path,mode:'source'}});});
 await page.evaluate(()=>{
  const p=app.plugins.plugins.workscribe,v=wsTestView(),cm=v.editor.cm,s=p.noteEditor.session(cm.state);s.document.finalized=false;
  const head=cm.state.doc.toString().match(/^---\n[\s\S]*?\n---\n/)?.[0]??'';
  v.editor.setValue(head+'\n- outer\n  - inner\n    - deepest\n1. number\n   1. child\n      1. grandchild\n- [ ] task\n  - [ ] nested task\n    - [ ] deepest task');v.editor.setCursor({line:0,ch:0});
  const blocks=cm.state.field(p.noteEditor.editor.field).blocks;
  p.live.notes=new Map(blocks.map((b,i)=>[b.id,{id:b.id,text:b.text,at:0,enhanced:{text:`Detail for row ${i}.`},excerpts:[],state:'done'}]));p.noteEditor.refresh(true);
 });
 await page.waitForTimeout(500);
 metrics.listAlignment=await page.evaluate(()=>{
  const cm=wsTestView().editor.cm;return [...cm.dom.querySelectorAll('.ws-editor-ai')].map(el=>{const pos=cm.posAtDOM(el),line=cm.state.doc.lineAt(pos),prefix=line.text.match(/^\s*(?:[-+*]|\d+[.)])\s+(?:\[.\]\s+)?/)?.[0].length??0;return {line:line.text,expected:cm.coordsAtPos(line.from+prefix)?.left,actual:el.querySelector('.ws-editor-ai-button').getBoundingClientRect().left};});
 });
 await page.screenshot({path:resolve(output,'list-indent.png')});
 assert.equal(metrics.listAlignment.length,9);
 assert.ok(metrics.listAlignment.every(m=>Math.abs(m.expected-m.actual)<=.5),JSON.stringify(metrics.listAlignment));
 assert.equal(await page.locator('.ws-open-meeting').isVisible(),false,'Open note link stays hidden while that note is visible');
 metrics.composerBounds=await page.evaluate(()=>({bottom:document.querySelector('.ws-composer-info')?.getBoundingClientRect().bottom,statusTop:document.querySelector('.status-bar')?.getBoundingClientRect().top}));
 assert.ok(metrics.composerBounds.bottom<=metrics.composerBounds.statusTop-12,'Composer footer stays above status bar with breathing room');
 await page.evaluate(()=>{
   const p=app.plugins.plugins.workscribe;p.settings.yourName='Andrew';p.settings.livePanelTab='qa';
   p.live.answers=[{id:'general',at:1,question:'What did Andrew decide?',answer:'The review is Friday.',citations:[],done:true},{id:'direct',at:2,question:'Andrew, can you own the rollout?',answer:'The rollout follows the migration review.',citations:[],done:true}];
   p.notify(new Set(['answer']));
 });
 await page.waitForTimeout(250);
 metrics.questionOrder=await page.locator('.ws-qa-q').allTextContents();
 assert.equal(metrics.questionOrder[0],'Andrew, can you own the rollout?');
 assert.equal(await page.locator('.ws-asked-of-you').count(),1);
 await page.screenshot({path:resolve(output,'asked-of-you.png')});
 assert.deepEqual(errors,[]);metrics.errors=errors;
} finally {
 capture=false;await loop;writeFileSync(resolve(output,'native-metrics.json'),JSON.stringify(metrics,null,2));
 writeFileSync(resolve(output,'frames.txt'),frames.map((s,i)=>`file '${s.name}'\nduration ${i+1<frames.length?(frames[i+1].stamp-s.stamp)/1000:.2}`).join('\n')+'\n');
 await mock.close();await browser.close();
}
console.log(JSON.stringify(metrics,null,2));
