// Creates a durable PKCS12 signing identity without installing Java/Android SDK.
// Private material stays in ignored .signing/; never upload that directory as an artifact.
import { execFileSync } from 'node:child_process';
import { randomBytes, X509Certificate } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const folder = path.resolve('.signing');
const credentialsFile = path.join(folder, 'credentials.json');
const keystoreFile = path.join(folder, 'mula-release.p12');
if (fs.existsSync(keystoreFile) || fs.existsSync(credentialsFile)) {
  throw new Error('Signing identity already exists. Keep the original key; creation never overwrites it.');
}
fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
if (process.platform === 'win32') {
  const user = execFileSync('whoami', [], { encoding: 'utf8' }).trim();
  const owner = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    '(Get-Acl -LiteralPath (Get-Location).Path).Owner'], { encoding: 'utf8' }).trim();
  const identities = [...new Set([user.toLowerCase(), owner.toLowerCase()])];
  execFileSync('icacls', [folder, '/inheritance:r', '/grant:r',
    ...identities.map((identity) => `${identity}:(OI)(CI)F`), 'SYSTEM:(OI)(CI)F'], { stdio: 'pipe' });
}
const password = randomBytes(32).toString('hex');
const openssl = process.env.MULA_OPENSSL ?? (process.platform === 'win32'
  ? 'C:\\Program Files\\Git\\usr\\bin\\openssl.exe' : 'openssl');
const env = { ...process.env, MULA_SIGNING_PASSWORD: password };
const keyFile = path.join(folder, 'encrypted-private-key.pem');
const certificateFile = path.join(folder, 'certificate.pem');
const run = (args) => execFileSync(openssl, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
run(['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-aes-256-cbc',
  '-pass', 'env:MULA_SIGNING_PASSWORD', '-out', keyFile]);
run(['req', '-new', '-x509', '-sha256', '-days', '10000', '-key', keyFile,
  '-passin', 'env:MULA_SIGNING_PASSWORD', '-subj', '/CN=MULA Release/O=Anggit/C=ID', '-out', certificateFile]);
run(['pkcs12', '-export', '-name', 'mula', '-inkey', keyFile, '-in', certificateFile,
  '-passin', 'env:MULA_SIGNING_PASSWORD', '-passout', 'env:MULA_SIGNING_PASSWORD', '-out', keystoreFile]);
fs.writeFileSync(credentialsFile, JSON.stringify({ alias: 'mula', storePassword: password, keyPassword: password }, null, 2), { mode: 0o600 });
const certificate = new X509Certificate(fs.readFileSync(certificateFile));
// Public certificate/fingerprint can safely be tracked to detect wrong signing keys.
fs.copyFileSync(certificateFile, path.resolve('android/app/mula-release-cert.pem'));
console.log(`Signing identity created in ignored .signing/. SHA-256 certificate: ${certificate.fingerprint256}`);
console.log('Keep a secure backup of .signing/. Configure GitHub Actions secrets using tool/upload_signing_secrets.mjs.');
