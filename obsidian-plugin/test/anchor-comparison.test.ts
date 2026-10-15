// Executable prototypes. Marker storage does not ship in the plugin.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChangeSet } from '@codemirror/state';
import { reconcile } from '../src/lib/anchors';

test('compare clean transaction/content anchors with an inline-comment prototype',()=>{
  const seed='alpha bravo\n\ncharlie';
  let seq=0;const make=()=>`new-${++seq}`;
  const initial=reconcile(seed,[],4,undefined,make);
  const markerSeed='alpha bravo <!--ws:a-->\n\ncharlie <!--ws:b-->';
  const markerRead=(source:string)=>{
    const occurrences=[...source.matchAll(/<!--ws:([\w-]+)-->/g)].map(m=>m[1]);
    // A pasted marker cannot identify which of its occurrences is the original.
    return occurrences.filter(id=>occurrences.filter(x=>x===id).length===1);
  };
  const cases=[
    {name:'typing inside block',from:5,to:5,insert:' bold',keep:[0,1],marker:markerSeed.replace('alpha','alpha bold'),markerKeep:['a','b']},
    {name:'heading before blocks',from:0,to:0,insert:'# Heading\n\n',keep:[0,1],marker:'# Heading\n\n'+markerSeed,markerKeep:['a','b']},
    {name:'new paragraph before',from:0,to:0,insert:'new\n\n',keep:[0,1],marker:'new\n\n'+markerSeed,markerKeep:['a','b']},
    {name:'copy identical block before',from:0,to:0,insert:'alpha bravo\n\n',keep:[0,1],marker:'alpha bravo <!--ws:a-->\n\n'+markerSeed,markerKeep:['a','b']},
    {name:'delete first block',from:0,to:13,insert:'',keep:[1],marker:'charlie <!--ws:b-->',markerKeep:['b']},
    {name:'split paragraph',from:5,to:6,insert:'\n\n',keep:[0,1],marker:markerSeed.replace('alpha bravo','alpha\n\nbravo'),markerKeep:['a','b']},
    {name:'merge paragraphs',from:11,to:13,insert:' ',keep:[0],marker:markerSeed.replace('\n\n',' '),markerKeep:['a']},
    {name:'unicode insertion',from:5,to:5,insert:' 👩🏽‍💻',keep:[0,1],marker:markerSeed.replace('alpha','alpha 👩🏽‍💻'),markerKeep:['a','b']},
    {name:'clear all',from:0,to:seed.length,insert:'',keep:[],marker:'',markerKeep:[]},
    {name:'external unique reorder',from:0,to:seed.length,insert:'charlie\n\nalpha bravo',keep:[0,1],marker:'charlie <!--ws:b-->\n\nalpha bravo <!--ws:a-->',markerKeep:['a','b']},
    {name:'edit comment accidentally',from:0,to:0,insert:'',keep:[0,1],marker:markerSeed.replace('<!--ws:a-->',''),markerKeep:['a','b']},
  ];
  let clean=0,comments=0;
  const rows=[];
  for(const c of cases){
    const changes=ChangeSet.of({from:c.from,to:c.to,insert:c.insert},seed.length);
    const source=seed.slice(0,c.from)+c.insert+seed.slice(c.to);
    const result=reconcile(source,initial,9,changes,make);
    const retained=new Set(result.map(b=>b.id));
    const good=c.keep.every(i=>retained.has(initial[i].id)) && new Set(result.map(b=>b.id)).size===result.length;
    const markerIDs=markerRead(c.marker);
    const normalize=(s:string)=>s.replace(/<!--ws:[\w-]+-->/g,'').replace(/\s+/g,' ').trim();
    const markerOwners=new Map(c.marker.split('\n\n').flatMap(part=>{
      const first=part.match(/<!--ws:([\w-]+)-->/)?.[1]; return first ? [[first,normalize(part)] as const] : [];
    }));
    const markerGood=c.markerKeep.every(id=>markerIDs.includes(id)) && c.keep.every(i=>{
      const expected=result.find(b=>b.id===initial[i].id)?.text;
      return markerOwners.get(i===0?'a':'b')===normalize(expected ?? '');
    });
    clean+=Number(good);comments+=Number(markerGood);rows.push({case:c.name,clean:good,comments:markerGood});
  }
  assert.equal(clean,cases.length); assert.equal(comments,cases.length-3);
  assert.equal(new TextEncoder().encode(markerSeed).length-new TextEncoder().encode(seed).length,24);
  console.log('anchor comparison: '+JSON.stringify({cases:rows,clean:`${clean}/${cases.length}`,comments:`${comments}/${cases.length}`,markerBytes:24}));
});
