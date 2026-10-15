import { chromium } from 'playwright';
import { mkdirSync, writeFileSync, copyFileSync, rmSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
import { startMockServer } from './mock-server.mjs';

const root = resolve('../.artifacts/native-images'), vault = join(root,'ui-vault'), profile = join(root,'profile');
rmSync(root,{recursive:true,force:true});
mkdirSync(join(vault,'.obsidian/plugins/workscribe'),{recursive:true}); mkdirSync(profile,{recursive:true});
const server = await startMockServer({vault,discovery:join(root,'api.json'),live:true,quiet:true,speed:1});
for(const name of ['main.js','manifest.json','styles.css']) copyFileSync(resolve(name),join(vault,'.obsidian/plugins/workscribe',name));
writeFileSync(join(vault,'.obsidian/plugins/workscribe/data.json'),JSON.stringify({apiJsonPath:server.discoveryPath,autoOpenLiveView:true}));
writeFileSync(join(vault,'.obsidian/community-plugins.json'),JSON.stringify(['workscribe']));
writeFileSync(join(vault,'.obsidian/app.json'),JSON.stringify({attachmentFolderPath:'./images',alwaysUpdateLinks:true}));
writeFileSync(join(profile,'obsidian.json'),JSON.stringify({vaults:{'aabbccddeeff1234':{path:vault,ts:Date.now(),open:true}}}));
const appProcess=spawn('/Applications/Obsidian.app/Contents/MacOS/Obsidian',[`--user-data-dir=${profile}`,'--remote-debugging-port=9243','--no-sandbox'],{stdio:'ignore'});
let browser, recordingDone; const frames=[]; let capture=true;
try {
 for(let i=0;i<80;i++){try{browser=await chromium.connectOverCDP('http://127.0.0.1:9243');break;}catch{await new Promise(r=>setTimeout(r,250));}}
 assert.ok(browser,'isolated Obsidian started');
 const page=browser.contexts()[0].pages().find(p=>p.url().startsWith('app://obsidian.md/'));
 assert.ok(page); await page.waitForFunction(()=>window.app?.vault,null,{timeout:25000});
 console.log('opened', await page.evaluate(()=>app.vault.adapter.getBasePath()));
 assert.equal(await page.evaluate(()=>app.vault.adapter.getBasePath()),vault);
 for(let i=0;i<40;i++){if(await page.evaluate(()=>!!app.plugins.plugins.workscribe)) break;if(await page.getByRole('button',{name:'Trust author and enable plugins',exact:true}).count()) break;await page.waitForTimeout(250);}
 const trust=page.getByRole('button',{name:'Trust author and enable plugins',exact:true}); if(await trust.count()) await trust.click();
 await page.evaluate(async()=>{if(!app.plugins.plugins.workscribe) await app.plugins.enablePlugin('workscribe');});
 await page.waitForFunction(()=>app.plugins.plugins.workscribe?.recording,null,{timeout:15000});
 assert.equal(await page.evaluate(()=>app.vault.adapter.getBasePath()),vault);
 await page.evaluate(async()=>{ const p=app.plugins.plugins.workscribe; await p.activateLiveView(); const file=await p.noteEditor.open(p.live.meetingId); window.imageTestView=app.workspace.getLeavesOfType('markdown').find(l=>l.view.file?.path===file.path).view; const v=imageTestView;v.editor.setValue(v.editor.getValue()+'\n\nBefore\n\nAfter');v.editor.setCursor(v.editor.offsetToPos(v.editor.getValue().indexOf('Before')+6));v.editor.focus(); });
 recordingDone=(async()=>{while(capture){const path=join(root,`frame-${String(frames.length).padStart(4,'0')}.png`);await page.screenshot({path});frames.push(path);await new Promise(r=>setTimeout(r,200));}})();
 const fixture=readFileSync(resolve('../.artifacts/fixtures/stall.png')).toString('base64');
 await page.evaluate(png=>{const p=app.plugins.plugins.workscribe,original=p.client.grabMoment.bind(p.client);p.client.grabMoment=async id=>({...await original(id),png});},fixture);
 await page.waitForTimeout(1000); await page.screenshot({path:join(root,'before.png')});
 // Start command while its IO is pending, then edit before the anchor. The image follows the mapped location.
 const result=await page.evaluate(async()=>{
   const p=app.plugins.plugins.workscribe,v=imageTestView,e=v.editor;
   const didExecute=app.commands.executeCommandById('workscribe:grab-moment');
   e.replaceRange('PREFIX\n', e.offsetToPos(e.getValue().indexOf('Before')));
   for(let i=0;i<100&&!e.getValue().includes('Meeting screen mock');i++) await new Promise(r=>setTimeout(r,50));
   await p.noteEditor.flush();
   const text=e.getValue(), images=app.vault.getFiles().filter(f=>f.extension==='png');
   const blocks=v.editor.cm.state.field(p.noteEditor.editor.field).blocks;
   const png=images[0] && new Uint8Array(await app.vault.readBinary(images[0]));
   const inserted=blocks.find(b=>b.kind==='image');
   return {didExecute,text,paths:images.map(f=>f.path),png:png?Array.from(png.slice(0,8)):[],imageBlock:inserted?{id:inserted.id,shorthand:inserted.shorthand,images:inserted.images}:null,commandHotkeys:app.hotkeyManager.getDefaultHotkeys?.('workscribe:grab-moment')??[]};
 });
 assert.equal(result.didExecute,true); assert.equal(result.commandHotkeys.length,0);
 assert.equal(result.paths.length,1); assert.match(result.paths[0],/\/images\/Meeting screen mock.png$/);
 assert.deepEqual(result.png,[137,80,78,71,13,10,26,10]);assert.ok(result.imageBlock); assert.equal(result.imageBlock.shorthand,'');
 assert.match(result.text,/Before\n\n!\[.*Meeting screen mock.*\n\n\n\nAfter/s);
 await page.screenshot({path:join(root,'after.png')});
 await page.evaluate(()=>imageTestView.editor.focus()); await page.keyboard.press('Meta+z'); await page.waitForTimeout(300);
 result.undoText=await page.evaluate(()=>imageTestView.editor.getValue()); assert.ok(!result.undoText.includes('Meeting screen mock'));
 result.attachmentsAfterUndo=await page.evaluate(()=>app.vault.getFiles().filter(f=>f.extension==='png').length); assert.equal(result.attachmentsAfterUndo,1);
 writeFileSync(join(root,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
} finally { capture=false; await recordingDone; if(frames.length) writeFileSync(join(root,'frames.txt'),frames.map(f=>`file '${f}'\nduration 0.2`).join('\n')); await browser?.close(); appProcess.kill('SIGTERM'); await server.close(); }
