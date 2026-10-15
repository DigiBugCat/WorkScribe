// Isolated browser proof of the production trace renderer. No user vault/profile is opened.
import {build} from 'esbuild';
import {chromium} from 'playwright';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const out=resolve('../.artifacts/trace-check');await mkdir(out,{recursive:true});
const result=await build({stdin:{contents:`import {renderTrace} from './src/ui/trace';window.renderTrace=renderTrace;`,resolveDir:process.cwd()},bundle:true,write:false,format:'iife',plugins:[{name:'obsidian-stub',setup(b){b.onResolve({filter:/^obsidian$/},()=>({path:'obsidian',namespace:'fixture'}));b.onResolve({filter:/^node:/},args=>({path:args.path,namespace:'node-stub'}));b.onLoad({filter:/.*/,namespace:'node-stub'},()=>({contents:'export const realpathSync={native:x=>x};export const dirname=x=>x;export const basename=x=>x;export const join=(...x)=>x.join("/");export const resolve=join;export const isAbsolute=x=>x.startsWith("/");'}));b.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:'export class App{};export class Component{};export class ToggleComponent{};export const MarkdownRenderer={};export const setIcon=()=>{};export const setTooltip=()=>{};'}));}}]});
const browser=await chromium.launch({headless:true,channel:'chrome'});const context=await browser.newContext({viewport:{width:900,height:700},recordVideo:{dir:out,size:{width:900,height:700}}});const page=await context.newPage();
await page.setContent('<!doctype html><html><body><h2>Why this line?</h2><main></main><p id="opened"></p></body></html>');
await page.addStyleTag({content:await readFile('styles.css','utf8')});
await page.addScriptTag({content:`Object.assign(HTMLElement.prototype,{
 createEl(tag,o={}){const e=document.createElement(tag);if(o.cls)e.className=o.cls;if(o.text)e.textContent=o.text;for(const [k,v] of Object.entries(o.attr||{}))e.setAttribute(k,v);this.append(e);return e},
 createDiv(o={}){return this.createEl('div',o)},createSpan(o={}){return this.createEl('span',o)},setAttr(k,v){this.setAttribute(k,v)}
});`});
await page.addScriptTag({content:result.outputFiles[0].text});
const image=await readFile(resolve('../.artifacts/scene-benchmark/app-switches.png')).catch(()=>null);
const thumb=image?'data:image/png;base64,'+image.toString('base64'):'data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300"><rect width="480" height="300" fill="#d8e8ff"/><text x="30" y="80" font-size="30">Dashboard fixture</text></svg>');
await page.evaluate(thumb=>{window.renderTrace(document.querySelector('main'),{steps:[],sources:[{kind:'screen',title:'Dashboard review',text:'Revenue increased in the dashboard',link:'workscribe://meeting/fixture?seconds=25',thumbnail:thumb,start:25,end:42}]},{open:true,onSource:m=>{document.querySelector('#opened').textContent='Opened scene at '+m.start+' seconds';}})},thumb);
await page.waitForTimeout(700);await page.getByText('What else it read',{exact:true}).click();
await page.locator('.ws-thumb').waitFor({state:'visible'});await page.waitForTimeout(500);
if(!await page.locator('.ws-moment').innerText().then(t=>t.includes('00:25')))throw Error('time missing');
await page.locator('.ws-moment').focus();await page.keyboard.press('Enter');
await page.getByText('Opened scene at 25 seconds',{exact:true}).waitFor();
await page.screenshot({path:out+'/expanded.png'});await page.waitForTimeout(700);
const video=page.video();await context.close();const path=await video.path();await browser.close();
await writeFile(out+'/result.json',JSON.stringify({thumbnailVisible:true,timeVisible:'00:25',keyboardOpenedAt:25,video:path},null,2));console.log(path);
