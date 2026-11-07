import {queries} from './export-queries.mjs';
import {execFileSync} from 'node:child_process';import {mkdirSync,writeFileSync} from 'node:fs';import {resolve,join} from 'node:path';
const [env,from,to,out]=process.argv.slice(2);
if(!['staging','production'].includes(env)||!/^\d{4}-\d{2}-\d{2}$/.test(from??'')||!/^\d{4}-\d{2}-\d{2}$/.test(to??'')||from>to||!out)throw Error('Usage: node UsageService/export.mjs staging|production YYYY-MM-DD YYYY-MM-DD NEW_DIRECTORY');
mkdirSync(out); // Do not overwrite an earlier export.
for(const [name,{sql,columns}] of Object.entries(queries(from,to))){
 const raw=execFileSync(process.execPath,['NekoWidget/SharingService/node_modules/wrangler/bin/wrangler.js','d1','execute','neko-usage-'+env,'--remote','--config','UsageService/wrangler.'+env+'.json','--json','--command',sql],{encoding:'utf8',windowsHide:true,stdio:['ignore','pipe','pipe']});
 const result=JSON.parse(raw)[0];if(!result.success)throw Error('Export failed');const rows=result.results,keys=columns;
 const cell=x=>'"'+String(x??'').replaceAll('"','""')+'"';
 writeFileSync(join(out,name+'.csv'),'\uFEFF'+[keys,...rows.map(r=>keys.map(k=>r[k]))].map(r=>r.map(cell).join(',')).join('\r\n')+'\r\n');console.log(name,rows.length,'rows');
}
console.log('Exported aggregate counts only to',resolve(out));
