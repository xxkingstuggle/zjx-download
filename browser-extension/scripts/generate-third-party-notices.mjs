import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const extensionRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lock = JSON.parse(fs.readFileSync(path.join(extensionRoot, 'package-lock.json'), 'utf8'));
const runtimePackages = Object.entries(lock.packages)
  .filter(([key, metadata]) => key.startsWith('node_modules/') && metadata.dev !== true)
  .sort(([left], [right]) => left.localeCompare(right));

const licenseFilesFor = (directory) => {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory)
    .filter((name) => /^(license|licence|copying|notice)(\.|$)/i.test(name))
    .sort()
    .map((name) => ({ name, text: fs.readFileSync(path.join(directory, name), 'utf8').trim() }))
    .filter(({ text }) => text.length > 0);
};

const allPackageDirectories = [...new Set(Object.keys(lock.packages)
  .filter((key) => key.startsWith('node_modules/'))
  .map((key) => path.join(extensionRoot, key)))];
const sections = [
  '# Third-party notices',
  '',
  `Generated from package-lock.json for ${runtimePackages.length} production dependency package instances.`,
  'Each package retains its upstream license terms and authorship. The project license and source attribution are in ../LICENSE and ../README.md.',
  '',
];
const missing = [];

for (const [key, metadata] of runtimePackages) {
  const directory = path.join(extensionRoot, key);
  let licenseFiles = licenseFilesFor(directory);
  if (licenseFiles.length === 0) {
    const packageName = key.slice('node_modules/'.length).split('/').at(-1);
    const peer = allPackageDirectories.find((candidate) => {
      const packagePath = path.join(candidate, 'package.json');
      if (!fs.existsSync(packagePath)) return false;
      const packageJSON = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
      return packageJSON.name === packageName && packageJSON.license === metadata.license && licenseFilesFor(candidate).length > 0;
    });
    if (peer) licenseFiles = licenseFilesFor(peer);
  }

  sections.push(`## ${key.slice('node_modules/'.length)} ${metadata.version}`);
  sections.push(`- Declared license: ${metadata.license ?? 'UNDECLARED'}`);
  if (metadata.resolved) sections.push(`- Source package: ${metadata.resolved}`);
  if (!metadata.license) missing.push(`${key}: missing SPDX/license expression`);
  if (licenseFiles.length === 0) {
    sections.push('- The installed npm package does not contain a license text file; consult its declared license expression and source package.');
    missing.push(`${key}: missing license text`);
  } else {
    for (const file of licenseFiles) {
      sections.push('', `### ${file.name}`, '', '```text', file.text, '```');
    }
  }
  sections.push('');
}

if (missing.length > 0) {
  process.stderr.write(`Incomplete third-party notices:\n${missing.join('\n')}\n`);
  process.exitCode = 1;
} else {
  const outputPath = path.join(extensionRoot, 'public', 'THIRD_PARTY_NOTICES.txt');
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${sections.join('\n')}\n`);
  process.stdout.write(`Wrote ${outputPath} (${runtimePackages.length} production package instances).\n`);
}
