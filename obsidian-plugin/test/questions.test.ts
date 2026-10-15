import {test} from 'node:test';
import assert from 'node:assert/strict';
import {askedOfYou,rankQuestions} from '../src/lib/questions';
import type {LiveAnswer} from '../src/lib/types';
const answer=(question:string,at=0):LiveAnswer=>({id:question,question,at,answer:'',citations:[],done:true});
test('explicit addresses rank first without confusing asker or third person mentions',()=>{
 const mention=answer('What did Andrew decide?',1),direct=answer('Andrew, can you take this?',2);
 mention.askedBy='Andrew';
 assert.equal(askedOfYou(mention,'Andrew'),false);assert.equal(askedOfYou(direct,'Andrew'),true);
 assert.equal(askedOfYou(answer('Could you do this, Andrew?'),'Andrew'),true);
 assert.equal(askedOfYou(answer('Andrewson, can you?'),'Andrew'),false);
 assert.equal(askedOfYou(direct,''),false);
 assert.deepEqual(rankQuestions([mention,direct],'Andrew'),[direct,mention]);
});
