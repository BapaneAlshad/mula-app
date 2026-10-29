// CI-only: recover permanent signing from repository secrets, fail closed on a partial configuration.
import fs from 'node:fs';
import path from 'node:path';
const names = ['MULA_KEYSTORE_BASE64', 'MULA_STORE_PASSWORD', 'MULA_KEY_PASSWORD'];
const configured = names.map((name) => Boolean(process.env[name]));
if (configured.some(Boolean) && !configured.every(Boolean)) throw new Error('All three MULA signing secrets are required.');
const permanent = configured.every(Boolean);
if (permanent) {
  const store = path.resolve(process.env.RUNNER_TEMP ?? 'build', 'mula-release.p12');
  fs.mkdirSync(path.dirname(store), { recursive: true });
  fs.writeFileSync(store, Buffer.from(process.env.MULA_KEYSTORE_BASE64, 'base64'), { mode: 0o600 });
  const quote = (value) => value.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/=/g, '\\=').replace(/:/g, '\\:');
  fs.writeFileSync('android/key.properties', [
    `storeFile=${quote(store)}`, 'storeType=PKCS12', 'keyAlias=mula',
    `storePassword=${quote(process.env.MULA_STORE_PASSWORD)}`,
    `keyPassword=${quote(process.env.MULA_KEY_PASSWORD)}`, '',
  ].join('\n'), { mode: 0o600 });
}
if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `permanent=${permanent}\n`);
console.log(permanent ? 'Permanent MULA release signing configured.' : 'Signing secrets absent: building a clearly labelled preview APK.');
