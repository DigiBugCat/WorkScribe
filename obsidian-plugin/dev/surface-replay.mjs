// Scripted TTS meeting transcript. Times are seconds in the spoken fixture;
// wall-clock replay speed is independent. No synthesis/model is needed for UI QA.
export const surfaceFixture = {
  documentId:'surface-demo',
  source:'# Offline sync — v2.4\n\nlww?\n\nship date?\n\nbeta accts\n\nphoto cap\n\nandroid\n\npricing?\n\n```sketch\nCapture -> Queue -> Sync\nOn conflict: ?\n```\n\n| Area | Decision |\n| --- | --- |\n| Photos | cap? |\n\n- [ ] Tell Halvorsen\n\nThe beta has 40 accounts. We ship on October 28.\n',
  blockIds:['lww','ship','beta','photo','android','pricing','sketch','table','task','prose'],
};
const source=(at,quote,speaker='Priya',id='s'+at)=>({kind:'meeting',title:'Offline sync',at,quote,speaker,segmentId:id,meetingId:'surface-demo'});
export const surfaceFrames = [
  {at:0,event:{type:'status',model:'loading'}},
  ...surfaceFixture.blockIds.slice(0,6).map(blockId=>({at:0,event:{type:'line',documentId:'surface-demo',blockId,state:'listening',revision:0,sources:[]}})),
  {at:1,event:{type:'status',model:'ready'}},
  {at:2,event:{type:'line',documentId:'surface-demo',blockId:'lww',state:'found',revision:0,sources:[]}},
  {at:4,event:{type:'line',documentId:'surface-demo',blockId:'lww',state:'answered',text:'Conflict resolution: last-write-wins per record.',revision:1,sources:[source(190,'The sync engine is last-write-wins today, per record.','Marcus')]}},
  {at:5,event:{type:'line',documentId:'surface-demo',blockId:'ship',state:'answered',text:'Ship date: October 28 is at risk.',revision:1,sources:[source(542,"I do not think October 28 survives this.")]}},
  {at:7,event:{type:'line',documentId:'surface-demo',blockId:'lww',state:'answered',text:'Conflict resolution: merge checklists at the field level; keep last-write-wins for the rest.',revision:2,sources:[source(511,'Merge at the field level for checklists, keep last-write-wins for the rest.')]}},
  {at:9,event:{type:'line',documentId:'surface-demo',blockId:'ship',state:'answered',text:'Ship date: moved from October 28 to November 4 for a full week of QA.',revision:2,sources:[source(580,'November 4 then. I will tell Halvorsen on Friday.')]}},
  {at:10,event:{type:'line',documentId:'surface-demo',blockId:'beta',state:'answered',text:'Beta: 40 accounts, Halvorsen first.',revision:1,sources:[source(628,'For the beta, forty accounts. Halvorsen first.')]}},
  {at:11,event:{type:'line',documentId:'surface-demo',blockId:'photo',state:'answered',text:'Photo queue: cap at 200 photos or 1.5 GB, oldest first on reconnect.',revision:1,sources:[source(770,'Cap it: two hundred photos or one and a half gigs, oldest first on reconnect.','You')]}},
  {at:12,event:{type:'pin',documentId:'surface-demo',blockId:'sketch',anchor:{kind:'line',path:[2]},sources:[source(511,'Merge at the field level for checklists, keep last-write-wins for the rest.')]}},
  {at:12,event:{type:'pin',documentId:'surface-demo',blockId:'table',anchor:{kind:'cell',path:[2,1]},sources:[source(770,'Two hundred photos or one and a half gigs.','You')]}},
  {at:12,event:{type:'pin',documentId:'surface-demo',blockId:'task',anchor:{kind:'task',path:[]},sources:[source(580,'I will tell Halvorsen on Friday.')]}},
  {at:13,event:{type:'check',documentId:'surface-demo',blockId:'prose',sentence:{from:0,to:25},verdict:'supported',sources:[source(628,'For the beta, forty accounts.')]}},
  {at:13,event:{type:'check',documentId:'surface-demo',blockId:'prose',sentence:{from:26,to:48},verdict:'differs',note:'November 4, after a full week of QA.',sources:[source(580,'November 4 then.')]}},
  {at:14,event:{type:'line',documentId:'surface-demo',blockId:'android',state:'answered',text:'Android: offline capture lands in 2.5.',revision:1,sources:[source(1334,'Offline for Android lands in 2.5.','Marcus')]}},
  {at:16,event:{type:'line',documentId:'surface-demo',blockId:'pricing',state:'quiet',revision:0,sources:[]}},
];
export function diagramPreview(requestId){return {type:'preview',requestId,kind:'diagram',mermaid:'flowchart LR\n  A[Capture] --> B[Queue]\n  B --> C[Sync]\n  C --> D{Conflict?}\n  D --> E[Merge checklist fields]\n  D --> F[Keep both notes]',sources:[source(511,'Merge at the field level for checklists. Keep both note versions.')]};}
