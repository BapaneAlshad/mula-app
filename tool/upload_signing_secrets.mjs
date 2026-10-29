// Uses an already-authenticated GitHub CLI; no token or private key is logged.
// https://cli.github.com/manual/gh_secret_set
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const repo = 'BapaneAlshad/mula-app';
const folder = path.resolve('.signing');
const config = JSON.parse(fs.readFileSync(path.join(folder, 'credentials.json'), 'utf8'));
const secrets = {
  MULA_KEYSTORE_BASE64: fs.readFileSync(path.join(folder, 'mula-release.p12')).toString('base64'),
  MULA_STORE_PASSWORD: config.storePassword,
  MULA_KEY_PASSWORD: config.keyPassword,
};
execFileSync('gh', ['auth', 'status', '--hostname', 'github.com'], { stdio: 'pipe' });
const existing = JSON.parse(execFileSync('gh', ['secret', 'list', '--repo', repo, '--json', 'name'], { encoding: 'utf8' }));
if (existing.some((item) => Object.hasOwn(secrets, item.name))) {
  throw new Error('Signing secrets already exist. Refusing to replace an established signing identity.');
}
for (const [name, value] of Object.entries(secrets)) {
  execFileSync('gh', ['secret', 'set', name, '--repo', repo], { input: value, stdio: ['pipe', 'pipe', 'pipe'] });
  console.log(`Stored ${name} in ${repo}.`);
}
console.log('Signing secrets configured. Run the Android workflow to verify the pinned certificate.');
