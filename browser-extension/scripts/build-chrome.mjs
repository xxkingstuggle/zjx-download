import {cp, mkdir, rm, readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const root = resolve(new URL('..', import.meta.url).pathname);
const source = resolve(root, 'src');
const output = resolve(root, 'dist/chrome');
const manifest = JSON.parse(await readFile(resolve(source, 'manifest.json'), 'utf8'));
const packageInfo = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
if (manifest.name !== 'zjx-download' || manifest.version !== packageInfo.version ||
    manifest.background?.service_worker !== 'background.js' || manifest.background?.type !== 'module') {
  throw new Error('Chrome manifest identity, version or module worker declaration is invalid.');
}
await rm(output, {recursive: true, force: true});
await mkdir(output, {recursive: true});
for (const file of ['manifest.json','background.js','content.js','app-api.js','storage.js','utils.js','popup.html','popup.js','options.html','options.js','ui.css']) await cp(resolve(source,file), resolve(output,file));
await cp(resolve(root,'public/icons'), resolve(output,'icons'), {recursive:true});
await cp(resolve(root,'public/THIRD_PARTY_NOTICES.txt'), resolve(output,'THIRD_PARTY_NOTICES.txt'));
console.log(`Built Chrome MV3 extension at ${output}`);
