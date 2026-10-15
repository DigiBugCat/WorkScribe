// Fixture port of NoteDocument.finalizedInsertions. Keep offsets in UTF-16 units.
export function finalizeFormat(mt) {
 const source=mt.document.source,insertions=[];
 const esc=s=>s.replace(/([\\*_])/g,'\\$1');
 for(const block of mt.document.blocks){
  const n=mt.notes.find(n=>n.id===block.id);if(block.owned||!n?.enhanced)continue;
  const indent=' '.repeat(block.text.match(/^(\s*(?:[-+*]|\d+[.)])\s+)/)?.[0].length??0);
  insertions.push({at:block.to,text:'\n'+n.enhanced.text.split('\n').map(t=>indent+'*'+esc(t)+'*').join('\n')});
 }
 const header=source.match(/^---\n[\s\S]*?\n---\n/)?.[0]??'';
 if(mt.brief?.trim()){
  const at=header.length+(source[header.length]==='\n'?1:0);
  insertions.push({at,text:(header&&source[header.length]!=='\n'?'\n':'')+'*'+esc(mt.brief.replaceAll('\n',' '))+'*\n\n'});
 }
 const norm=s=>s.replace(/\[\[[^\]]+\]\]/g,'').replace(/📅 \d{4}-\d{2}-\d{2}/g,'').toLowerCase().trim().replace(/\s+/g,' ');
 const seen=new Set(source.split('\n').filter(s=>/^\s*- \[.\] /.test(s)).map(s=>norm(s.replace(/^\s*- \[.\] /,''))));
 const actions=mt.actionItems.filter(a=>{const key=norm(a.text);if(seen.has(key))return false;seen.add(key);return true;});
 let tail='';
 if(mt.missedTopics.length)tail+='\n\n## Also discussed\n\n'+mt.missedTopics.map(t=>'- *'+esc(t.topic.replace(/\.$/,'')+'. '+t.text)+'*').join('\n')+'\n';
 if(actions.length)tail+=(tail?'\n':'\n\n')+'## Action items\n\n'+actions.map(a=>'- [ ] '+(a.owner?'[['+a.owner+']] ':'')+esc(a.text)+(a.due?' 📅 '+a.due:'')).join('\n')+'\n';
 if(tail){if(source.endsWith('\n'))tail=tail.slice(1);insertions.push({at:source.length,text:tail});}
 let text=source;for(const i of [...insertions].sort((a,b)=>b.at-a.at))text=text.slice(0,i.at)+i.text+text.slice(i.at);
 return {text,insertions};
}
