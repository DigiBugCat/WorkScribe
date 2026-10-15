import test from 'node:test';
import assert from 'node:assert/strict';
import {parseTrace, parseMoment} from '../src/lib/parse';

test('scene trace preserves thumbnail and time without inventing OCR',()=>{
 const source={kind:'screen',title:'Revenue dashboard',text:'',link:'workscribe://meeting/m?seconds=25',thumbnail:'/tmp/scene.jpg',start:25,end:42};
 const trace=parseTrace({steps:[],sources:[source]});
 assert.deepEqual(trace?.sources?.[0],source);
 const m=parseMoment({...source,snippet:source.text});
 assert.equal(m.kind,'screen');assert.equal(m.thumbnail,'/tmp/scene.jpg');assert.equal(m.start,25);
});
