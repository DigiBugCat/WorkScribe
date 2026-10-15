import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fadeCountdown,wordDiff,continuation} from '../src/lib/care';
import {parseTrace,parseNote,parseAnswer} from '../src/lib/parse';
import {reconcile} from '../src/lib/anchors';
test('fade clock rounds down hours and only uses minutes below one hour',()=>{
 const now=1000000;
 assert.equal(fadeCountdown(new Date(now+23.9*3600000).toISOString(),now),'Transcript fades in 23 h');
 assert.equal(fadeCountdown(new Date(now+59.9*60000).toISOString(),now),'Transcript fades in 59 min');
 assert.equal(fadeCountdown(new Date(now+1).toISOString(),now),'Transcript fades in 1 min');
 assert.equal(fadeCountdown(new Date(now).toISOString(),now),'Transcript fading');
});
test('word diff retains unchanged middle words and reconstructs both versions',()=>{
 const before='Ship Oct 28 after QA.',after='Ship Nov 4 after QA.';
 const diff=wordDiff(before,after);
 assert.equal(diff.filter(p=>p.kind!=='removed').map(p=>p.text).join(''),after);
 assert.equal(diff.filter(p=>p.kind!=='added').map(p=>p.text).join(''),before);
 assert.equal(diff.filter(p=>p.kind==='same').map(p=>p.text).join(''),'Ship   after QA.');
});
test('final continuation escapes emphasis and keeps owned text roman',()=>{
 assert.equal(continuation('Use a_b *literal*','- words'),'  *Use a\\_b \\*literal\\**');
 assert.equal(continuation('My words','- words',true),'  My words');
 assert.equal(continuation('Nested','  1. words'),'     *Nested*');
});
test('a roman continuation remains owned through subsequent reconciliation',()=>{
 const source='- shorthand\n  My words';
 const previous=[{id:'a',from:0,to:11,text:'- shorthand',owned:{from:12,to:22,text:'  My words'}}];
 const blocks=reconcile(source,previous,4);
 assert.equal(blocks.length,1);assert.equal(blocks[0].id,'a');assert.equal(blocks[0].text,'- shorthand');assert.equal(blocks[0].owned?.text,'  My words');
});
test('traces parse on both lines and answers without inventing missing provenance',()=>{
 const trace={model:'Test',location:'On this Mac',durationMs:12,steps:[{title:'Read evidence',status:'complete'}],revisions:[{version:1,text:'Fact',at:'2026-10-14',reason:'First evidence'}]};
 assert.deepEqual(JSON.parse(JSON.stringify(parseNote({id:'n',text:'fact',trace}).trace)),trace);
 assert.deepEqual(JSON.parse(JSON.stringify(parseAnswer({id:'a',trace}).trace)),trace);
 assert.equal(parseTrace(null),undefined);
});

test('image pipeline evidence becomes a clickable trace source without inferred captions',()=>{
 const n=parseNote({id:'n',text:'photo',images:[{target:'Attachments/photo.png',text:'Slide 3',caption:'A roadmap',method:'vision',seconds:2}]});
 assert.equal(n.trace?.sources?.[0].title,'Attachments/photo.png');
 assert.equal(n.trace?.sources?.[0].text,'A roadmap\nSlide 3\nRead on this Mac · vision\n2.0 s');
 assert.equal(n.trace?.sources?.[0].link,'obsidian://open?file=Attachments%2Fphoto.png');
});

test('punctuation rewrites do not re-ink the surviving word',()=>{
 const changes=wordDiff('migration;','migration.');
 assert.deepEqual(changes.filter(p=>p.kind==='same').map(p=>p.text),['migration']);
 assert.deepEqual(changes.filter(p=>p.kind==='added').map(p=>p.text),['.']);
});

test('nested list blocks keep distinct anchors and indentation',()=>{
 const blocks=reconcile('- outer\n  - inner\n    - deepest\n1. next\n   1. child\n- [ ] task\n  - [ ] nested task',[]);
 assert.equal(blocks.length,7);
 assert.deepEqual(blocks.map(b=>b.text),['- outer','  - inner','    - deepest','1. next','   1. child','- [ ] task','  - [ ] nested task']);
 assert.equal(new Set(blocks.map(b=>b.id)).size,7);
});

import {finalizeFormat} from '../dev/finalize-format.mjs';
test('native fixture uses one title, a brief and unique Tasks format commitments',()=>{
 const source='---\nworkscribe: m-1\n---\n\n- [ ] send PRD\n';
 const m={document:{source,blocks:[]},notes:[],brief:'Brief',missedTopics:[{topic:'Risk',text:'a_b'}],actionItems:[{text:' SEND   PRD '},{owner:'Priya',text:'Check scope',due:'2026-10-16'}]};
 const out=finalizeFormat(m);assert.ok(out.text.includes('---\n\n*Brief*\n\n- [ ] send PRD'));
 assert.equal(out.text.match(/send PRD/g)?.length,1);assert.ok(out.text.includes('- [ ] [[Priya]] Check scope 📅 2026-10-16'));
 let rebuilt=source;for(const i of [...out.insertions].sort((a,b)=>b.at-a.at))rebuilt=rebuilt.slice(0,i.at)+i.text+rebuilt.slice(i.at);
 assert.equal(rebuilt,out.text);
});
