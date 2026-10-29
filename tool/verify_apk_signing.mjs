import { execFileSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import fs from 'node:fs';
const apk = process.argv[2] ?? 'build/app/outputs/flutter-apk/app-release.apk';
const output = execFileSync(process.env.MULA_APKSIGNER ?? 'apksigner', ['verify', '--verbose', '--print-certs', apk], { encoding: 'utf8' });
const digest = /Signer #1 certificate SHA-256 digest:\s*([a-f0-9]+)/i.exec(output)?.[1].toLowerCase();
if (!digest) throw new Error('APK signer certificate was not found.');
if (process.env.MULA_PERMANENT_SIGNING === 'true') {
  const pinned = new X509Certificate(fs.readFileSync('android/app/mula-release-cert.pem')).fingerprint256.replaceAll(':', '').toLowerCase();
  if (digest !== pinned) throw new Error('Release signer differs from the pinned MULA certificate. Refusing to distribute.');
  console.log(`Verified permanent MULA certificate: ${digest}`);
} else {
  console.log(`Preview signing only (not permanent): ${digest}`);
}
