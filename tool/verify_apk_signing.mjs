import { execFileSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Read the certificate from the APK v2/v3 signing block, independently of the
// apksigner version's human-readable output. apksigner verifies cryptography below.
export function apkSignerDigests(bytes) {
  let eocd = -1;
  for (let offset = bytes.length - 22; offset >= Math.max(0, bytes.length - 65557); offset--) {
    if (bytes.readUInt32LE(offset) === 0x06054b50 &&
        offset + 22 + bytes.readUInt16LE(offset + 20) === bytes.length) { eocd = offset; break; }
  }
  if (eocd < 0) throw new Error('APK ZIP directory was not found.');
  const central = bytes.readUInt32LE(eocd + 16);
  if (central < 32 || central > eocd ||
      bytes.subarray(central - 16, central).toString() !== 'APK Sig Block 42') {
    throw new Error('APK signing block was not found.');
  }
  const size = Number(bytes.readBigUInt64LE(central - 24));
  const start = central - size - 8;
  if (!Number.isSafeInteger(size) || size < 24 || start < 0 ||
      Number(bytes.readBigUInt64LE(start)) !== size) throw new Error('Invalid APK signing block size.');
  function field(value, offset = 0) {
    if (offset < 0 || offset + 4 > value.length) throw new Error('Invalid APK field header.');
    const length = value.readUInt32LE(offset);
    if (offset + 4 + length > value.length) throw new Error('Invalid APK field length.');
    return value.subarray(offset + 4, offset + 4 + length);
  }
  const digests = new Set();
  for (let offset = start + 8; offset < central - 24;) {
    if (offset + 12 > central - 24) throw new Error('Invalid APK signature entry.');
    const length = Number(bytes.readBigUInt64LE(offset));
    if (!Number.isSafeInteger(length) || length < 4 || offset + 8 + length > central - 24) {
      throw new Error('Invalid APK signature entry length.');
    }
    const id = bytes.readUInt32LE(offset + 8);
    if (id === 0x7109871a || id === 0xf05368c0) {
      const signers = field(bytes.subarray(offset + 12, offset + 8 + length));
      for (let signerOffset = 0; signerOffset < signers.length;) {
        const signer = field(signers, signerOffset);
        const signed = field(signer);
        const digestList = field(signed);
        const certificates = field(signed, 4 + digestList.length);
        const certificate = new X509Certificate(field(certificates));
        digests.add(certificate.fingerprint256.replaceAll(':', '').toLowerCase());
        signerOffset += 4 + signer.length;
      }
    }
    offset += 8 + length;
  }
  if (digests.size !== 1) throw new Error('APK must contain exactly one consistent signing identity.');
  return [...digests];
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
const apk = process.argv[2] ?? 'build/app/outputs/flutter-apk/app-release.apk';
execFileSync(process.env.MULA_APKSIGNER ?? 'apksigner', ['verify', '--verbose', apk], { stdio: 'inherit' });
const [digest] = apkSignerDigests(fs.readFileSync(apk));
if (process.env.MULA_PERMANENT_SIGNING === 'true') {
  const pinned = new X509Certificate(fs.readFileSync('android/app/mula-release-cert.pem')).fingerprint256.replaceAll(':', '').toLowerCase();
  if (digest !== pinned) throw new Error('Release signer differs from the pinned MULA certificate. Refusing to distribute.');
  console.log(`Verified permanent MULA certificate: ${digest}`);
} else {
  console.log(`Preview signing only (not permanent): ${digest}`);
}
}
