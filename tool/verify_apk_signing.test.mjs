import assert from 'node:assert/strict';
import { X509Certificate } from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';
import { apkSignerDigests } from './verify_apk_signing.mjs';

const cert = new X509Certificate(fs.readFileSync(new URL('../android/app/mula-release-cert.pem', import.meta.url)));
const digest = cert.fingerprint256.replaceAll(':', '').toLowerCase();
const int32 = (value) => { const buffer = Buffer.alloc(4); buffer.writeUInt32LE(value); return buffer; };
const int64 = (value) => { const buffer = Buffer.alloc(8); buffer.writeBigUInt64LE(BigInt(value)); return buffer; };
const field = (value) => Buffer.concat([int32(value.length), value]);
function fixture(ids) {
  const signed = Buffer.concat([field(Buffer.alloc(0)), field(field(cert.raw)), field(Buffer.alloc(0))]);
  const signer = Buffer.concat([field(signed), field(Buffer.alloc(0)), field(Buffer.alloc(0))]);
  const signers = field(field(signer));
  const pairs = Buffer.concat(ids.map((id) => Buffer.concat([int64(4 + signers.length), int32(id), signers])));
  const blockSize = pairs.length + 24;
  const block = Buffer.concat([int64(blockSize), pairs, int64(blockSize), Buffer.from('APK Sig Block 42')]);
  const directory = Buffer.alloc(22);
  directory.writeUInt32LE(0x06054b50);
  directory.writeUInt32LE(block.length, 16);
  return Buffer.concat([block, directory]);
}
test('extracts the real certificate independent of apksigner output or signing scheme', () => {
  for (const ids of [[0x7109871a], [0xf05368c0], [0x7109871a, 0xf05368c0]]) {
    assert.deepEqual(apkSignerDigests(fixture(ids)), [digest]);
  }
});
test('rejects missing, unsupported and truncated signature data', () => {
  assert.throws(() => apkSignerDigests(Buffer.from('not an APK')), /ZIP/);
  assert.throws(() => apkSignerDigests(fixture([123])), /exactly one/);
  const bad = fixture([0x7109871a]);
  bad.writeBigUInt64LE(0xffffffffffffffffn, 8);
  assert.throws(() => apkSignerDigests(bad), /entry length/);
  assert.throws(() => apkSignerDigests(fixture([0x7109871a]).subarray(0, -3)), /ZIP/);
});
