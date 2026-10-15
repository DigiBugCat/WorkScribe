import {mkdirSync,writeFileSync,copyFileSync,rmSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {resolve,join} from 'node:path';
import {chromium} from 'playwright';
const root=resolve('../.artifacts/native-polish-integration'),vault=join(root,'polish'),profile=join(root,'profile');
rmSync(root,{recursive:true,force:true});mkdirSync(join(vault,'.obsidian/plugins/workscribe'),{recursive:true});mkdirSync(profile,{recursive:true});
for(const name of ['main.js','manifest.json','styles.css'])copyFileSync(resolve(name),join(vault,'.obsidian/plugins/workscribe',name));
writeFileSync(join(vault,'.obsidian/plugins/workscribe/data.json'),JSON.stringify({apiJsonPath:join(root,'offline-api.json')}));
writeFileSync(join(vault,'.obsidian/community-plugins.json'),JSON.stringify(['workscribe']));
writeFileSync(join(profile,'obsidian.json'),JSON.stringify({vaults:{aabbccddeeff5678:{path:vault,ts:Date.now(),open:true}}}));
const app=spawn('/Applications/Obsidian.app/Contents/MacOS/Obsidian',[`--user-data-dir=${profile}`,'--remote-debugging-port=9258','--no-sandbox'],{stdio:'ignore'});
try {
 let ready=false;
 for(let i=0;i<100;i++) {try{const b=await chromium.connectOverCDP('http://127.0.0.1:9258');const p=b.contexts()[0].pages().find(p=>p.url().startsWith('app://obsidian'));ready=!!p&&await p.evaluate(()=>!!window.app?.vault);await b.close();if(ready)break;}catch{}await new Promise(r=>setTimeout(r,250));}
 if(!ready)throw Error('Isolated Obsidian did not start');
 const test=spawn(process.execPath,['dev/native-editor-check.mjs',process.argv[2] ?? '../docs/research/leftovers'],{stdio:'inherit',env:{...process.env,OBSIDIAN_CDP:'http://127.0.0.1:9258',OBSIDIAN_TEST_VAULT:vault}});
 const code=await new Promise(r=>test.on('exit',r));if(code!==0)process.exitCode=code??1;
}finally{app.kill('SIGTERM');}
