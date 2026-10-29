// Exercise the exact release APK on an ephemeral GitHub Actions Android emulator.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exerciseWellbeing } from './android_wellbeing_smoke.mjs';
import { exerciseBackup } from './android_backup_smoke.mjs';

const packageName = 'com.anggit.mula.mula';
const output = path.resolve(process.env.MULA_SMOKE_OUTPUT ?? 'build/smoke');
const appPids = new Set();
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
let sequence = 0;

function adb(args, { binary = false, timeout = 30000 } = {}) {
  return execFileSync('adb', ['-e', ...args], {
    encoding: binary ? null : 'utf8', timeout,
    maxBuffer: 20 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function decodeXml(value) {
  return value.replace(/&#x([0-9a-f]+);|&#(\d+);|&(quot|apos|lt|gt|amp);/gi,
    (_, hex, decimal, named) => hex ? String.fromCodePoint(parseInt(hex, 16))
      : decimal ? String.fromCodePoint(Number(decimal))
        : ({ quot: '"', apos: "'", lt: '<', gt: '>', amp: '&' })[named.toLowerCase()]);
}

export function parseNodes(xml) {
  return [...xml.matchAll(/<node\b([^>]+)>/g)].map((match) => {
    const attributes = Object.fromEntries([...match[1].matchAll(/([\w-]+)="([^"]*)"/g)]
      .map((attribute) => [attribute[1], decodeXml(attribute[2])]));
    const coordinates = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(attributes.bounds ?? '');
    return {
      ...attributes,
      label: [attributes.text, attributes['content-desc']].filter(Boolean).join('\n'),
      bounds: coordinates ? coordinates.slice(1).map(Number) : null,
    };
  });
}

export function appLogErrors(log, pids) {
  return log.split('\n').filter((line) => {
    const pid = /^\d\d-\d\d\s+[\d:.]+\s+(\d+)\s+\d+\s/.exec(line)?.[1];
    return pids.has(pid) && /NoSuchMethodError|ClassNotFoundException|Mirror preferensi Android tidak tersedia|PreferenceMirror.*(?:fail|error)|FATAL EXCEPTION/i.test(line);
  });
}

function capturePid() {
  const result = adb(['shell', 'pidof', packageName]).trim();
  for (const pid of result.split(/\s+/).filter(Boolean)) appPids.add(pid);
  if (!result) throw new Error('The release application is no longer running.');
}

function logcat() {
  return adb(['logcat', '-d', '-v', 'threadtime']);
}

function assertHealthy(nodes) {
  const labels = nodes.map((node) => node.label).join('\n');
  if (/Data lokal belum dapat dibuka|Coba buka kembali|NoSuchMethodError|PlatformException/.test(labels)) {
    throw new Error('The release APK displayed the local-data error screen.');
  }
  capturePid();
  const errors = appLogErrors(logcat(), appPids);
  if (errors.length) throw new Error(`Android plugin failure:\n${errors.join('\n')}`);
}

async function snapshot(label) {
  const filename = `${String(++sequence).padStart(2, '0')}-${label}`;
  adb(['shell', 'uiautomator', 'dump', '--compressed', '/sdcard/mula-smoke.xml'], { timeout: 20000 });
  const xml = adb(['shell', 'cat', '/sdcard/mula-smoke.xml']);
  if (!xml.includes('<hierarchy')) throw new Error('UIAutomator returned no accessibility hierarchy.');
  fs.writeFileSync(path.join(output, `${filename}.xml`), xml);
  const nodes = parseNodes(xml);
  assertHealthy(nodes);
  return nodes;
}

async function waitFor(label, predicate, { attempts = 12 } = {}) {
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const nodes = await snapshot(label);
      if (predicate(nodes)) return nodes;
      lastError = new Error(`Visible labels: ${nodes.map((node) => node.label).filter(Boolean).join(' | ')}`);
    } catch (error) {
      lastError = error;
      if (/plugin failure|error screen|no longer running/.test(error.message)) throw error;
    }
    await delay(1000);
  }
  throw new Error(`Timed out waiting for ${label}: ${lastError?.message}`);
}

const includesLabel = (nodes, value) => nodes.some((node) => node.label.includes(value));

function tap(node) {
  if (!node?.bounds) throw new Error('No visible bounds for the requested control.');
  const [left, top, right, bottom] = node.bounds;
  if (right <= left || bottom <= top) throw new Error('The requested control is outside the viewport.');
  adb(['shell', 'input', 'tap', String(Math.round((left + right) / 2)), String(Math.round((top + bottom) / 2))]);
}

function dimensions() {
  const match = /(\d+)x(\d+)/.exec(adb(['shell', 'wm', 'size']));
  if (!match) throw new Error('Cannot determine emulator display dimensions.');
  return match.slice(1).map(Number);
}

async function scroll(down = true) {
  const [width, height] = dimensions();
  const x = String(Math.round(width / 2));
  const start = Math.round(height * (down ? 0.73 : 0.3));
  const end = Math.round(height * (down ? 0.3 : 0.73));
  adb(['shell', 'input', 'swipe', x, String(start), x, String(end), '350']);
  await delay(350);
}

async function findControl(label) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const nodes = await snapshot('find-control');
    const node = nodes.find((candidate) => candidate.label.includes(label) && candidate.bounds &&
      candidate.bounds[2] > candidate.bounds[0] && candidate.bounds[3] > candidate.bounds[1] && candidate.enabled !== 'false');
    if (node) return node;
    await scroll();
  }
  throw new Error(`Cannot find visible control: ${label}`);
}

async function selectTab(label) {
  const nodes = await snapshot('navigation');
  const matches = nodes.filter((node) => node.label.includes(label) && node.bounds &&
    node.bounds[2] > node.bounds[0] && node.bounds[3] > node.bounds[1]);
  // A navigation destination is below any matching page text.
  const node = matches.sort((a, b) => b.bounds[1] - a.bounds[1])[0];
  if (!node) throw new Error(`Cannot find the ${label} navigation destination.`);
  tap(node);
  await delay(1000);
}

function screenshot(label) {
  fs.writeFileSync(path.join(output, `${label}.png`), adb(['exec-out', 'screencap', '-p'], { binary: true }));
}

async function launch() {
  const result = adb(['shell', 'am', 'start', '-W', '-n', `${packageName}/.MainActivity`]);
  fs.appendFileSync(path.join(output, 'launch.txt'), result);
  if (/Error:|Exception/.test(result)) throw new Error(`Android did not launch MULA: ${result}`);
  await delay(1500);
  capturePid();
}

async function run() {
  if (process.env.CI !== 'true') throw new Error('Run this smoke check only in CI on the disposable Android emulator.');
  const apk = path.resolve(process.argv[2] ?? 'build/app/outputs/flutter-apk/app-release.apk');
  fs.mkdirSync(output, { recursive: true });
  const hash = createHash('sha256').update(fs.readFileSync(apk)).digest('hex');
  fs.writeFileSync(path.join(output, 'apk-sha256.txt'), `${hash}  ${path.basename(apk)}\n`);
  console.log(`Testing exact release APK SHA-256: ${hash}`);
  adb(['wait-for-device']);
  adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
  adb(['shell', 'wm', 'dismiss-keyguard']);
  adb(['shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0']);
  adb(['shell', 'settings', 'put', 'system', 'user_rotation', '0']);
  adb(['logcat', '-c']);
  const install = adb(['install', '-r', apk], { timeout: 120000 });
  fs.writeFileSync(path.join(output, 'install.txt'), install);
  if (!install.includes('Success')) throw new Error(`APK installation failed: ${install}`);
  await launch();
  await waitFor('onboarding', (nodes) => includesLabel(nodes, 'Mulai kecil. Tumbuh setiap hari.') || includesLabel(nodes, 'Mulai langkah pertama'));
  screenshot('onboarding');
  tap(await findControl('Mulai langkah pertama'));
  await waitFor('today', (nodes) => includesLabel(nodes, 'SKOR HARI INI'));
  screenshot('today');
  await selectTab('Fokus');
  await waitFor('focus', (nodes) => includesLabel(nodes, 'RUANG FOKUS'));
  tap(await findControl('5 menit'));
  // The timer may be above the chips on a short display.
  await scroll(false);
  await scroll(false);
  await waitFor('saved-focus-duration', (nodes) => includesLabel(nodes, '05:00'));
  screenshot('focus-five-minutes');
  adb(['shell', 'am', 'force-stop', packageName]);
  await launch();
  await waitFor('persisted-focus', (nodes) => includesLabel(nodes, 'RUANG FOKUS') && includesLabel(nodes, '05:00'));
  screenshot('persisted-focus');
  await selectTab('Hari Ini');
  await waitFor('today-after-restart', (nodes) => includesLabel(nodes, 'SKOR HARI INI'));
  screenshot('today-after-restart');
  await exerciseWellbeing({ tap, findControl, waitFor, includesLabel, selectTab, scroll, screenshot,
    forceRestart: async () => { adb(['shell', 'am', 'force-stop', packageName]); await launch(); },
  });
  await exerciseBackup({ snapshot, findControl, tap, waitFor, selectTab, scroll, screenshot, adb, delay, launch });
  fs.writeFileSync(path.join(output, 'result.txt'), 'PASS: release onboarding, SQLite startup, native preferences read/write, navigation, and process restart.\n');
  console.log('Release APK smoke check passed: onboarding, preferences write/read, and persisted restart.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await run();
  } catch (error) {
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(path.join(output, 'failure.txt'), `${error.stack ?? error}\n`);
    try { screenshot('failure'); } catch { /* The emulator may have stopped. */ }
    console.error(error.stack ?? error);
    process.exitCode = 1;
  } finally {
    try { fs.writeFileSync(path.join(output, 'logcat.txt'), logcat()); } catch { /* Failure details are already recorded. */ }
  }
}
