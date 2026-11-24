// Derive prompt/schema resources from the pinned Apache-2.0 upstream source, without rewriting them.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root=path.resolve(import.meta.dirname,'../policy/upstream-codex');
const read=name=>fs.readFileSync(path.join(root,name),'utf8').replace(/^\uFEFF/,'');
const source=JSON.parse(read('source-commit.json'));
if(!/^[a-f0-9]{40}$/.test(source.commit)) throw Error('Missing pinned source commit');
const assessment=read('assessment.rs').replace(/\r\n/g,'\n'), guardian=read('guardian.rs').replace(/\r\n/g,'\n');
const output=assessment.match(/pub fn guardian_output_contract_prompt\(\)[\s\S]*?r#"([\s\S]*?)"#/);
const schema=assessment.match(/pub fn guardian_output_schema\(\)[\s\S]*?serde_json::json!\(([\s\S]*?\})\)\s*\}/);
const rejection=guardian.match(/const REJECTION_INSTRUCTIONS:[\s\S]*?concat!\(([\s\S]*?)\n\);/);
if(!output||!schema||!rejection) throw Error('Upstream source layout changed; review extraction');
const write=(name,text)=>fs.writeFileSync(path.join(root,name),text,'utf8');
write('output-contract.txt',output[1]);
write('output.schema.json',JSON.stringify(JSON.parse(schema[1]),null,2)+'\n');
write('rejection-feedback.txt',[...rejection[1].matchAll(/"(?:[^"\\]|\\.)*"/g)].map(m=>JSON.parse(m[0])).join(''));
const resources=['policy_template.md','policy.md','output-contract.txt','output.schema.json','rejection-feedback.txt','LICENSE'];
const sha256=Object.fromEntries(resources.map(name=>[name,crypto.createHash('sha256').update(read(name),'utf8').digest('hex')]));
write('SOURCE.json',JSON.stringify({...source,derivedResources:['output-contract.txt','output.schema.json','rejection-feedback.txt'],sha256},null,2)+'\n');
console.log('Prepared pinned Codex policy:',source.commit);
// The bundled policy uses the published upstream resources. Native Guardian can
// resolve model-owned rules through its authenticated provider at runtime.
const effective=path.join(root,'../effective-codex');fs.mkdirSync(effective,{recursive:true});
for(const name of resources) fs.writeFileSync(path.join(effective,name),read(name),'utf8');
fs.writeFileSync(path.join(effective,'SOURCE.json'),JSON.stringify({upstreamCommit:source.commit,resolution:'pinned upstream policy',sha256},null,2)+'\n');
