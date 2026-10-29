// Native delivery test on the disposable CI emulator. Audible delivery still
// requires a person running the in-app test on their own phone.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { parseNodes } from './android_release_smoke.mjs';

const packageName = 'com.anggit.mula.mula';
const output = path.resolve(process.env.MULA_SMOKE_OUTPUT ?? 'build/smoke', 'alarm');
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
let sequence = 0;

function adb(args, { binary = false, timeout = 30000 } = {}) {
  return execFileSync('adb', ['-e', ...args], {
    encoding: binary ? null : 'utf8', timeout, maxBuffer: 20 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function screenshot(label) {
  fs.writeFileSync(path.join(output, `${label}.png`), adb(['exec-out', 'screencap', '-p'], { binary: true }));
}

function snapshot() {
  adb(['shell', 'uiautomator', 'dump', '--compressed', '/sdcard/mula-alarm.xml']);
  const xml = adb(['shell', 'cat', '/sdcard/mula-alarm.xml']);
  fs.writeFileSync(path.join(output, `${String(++sequence).padStart(2, '0')}-ui.xml`), xml);
  if (!xml.includes('<hierarchy')) throw new Error('Missing Android UI hierarchy.');
  const nodes = parseNodes(xml);
  if (nodes.some((node) => /Data lokal belum dapat dibuka|NoSuchMethodError|PlatformException/.test(node.label))) {
    throw new Error('The alarm smoke test encountered an application error.');
  }
  return nodes;
}

function tap(node) {
  if (!node?.bounds) throw new Error('Missing tap target.');
  const [left, top, right, bottom] = node.bounds;
  adb(['shell', 'input', 'tap', String(Math.round((left + right) / 2)), String(Math.round((top + bottom) / 2))]);
}

function size() {
  const match = /(\d+)x(\d+)/.exec(adb(['shell', 'wm', 'size']));
  if (!match) throw new Error('Unknown display dimensions.');
  return match.slice(1).map(Number);
}

async function scroll(down = true) {
  const [width, height] = size();
  adb(['shell', 'input', 'swipe', String(Math.round(width / 2)),
    String(Math.round(height * (down ? 0.75 : 0.3))),
    String(Math.round(width / 2)), String(Math.round(height * (down ? 0.3 : 0.75))), '350']);
  await delay(350);
}

async function findControl(label, { enabled = true, attempts = 10, fromTop = false } = {}) {
  if (fromTop) {
    await scroll(false);
    await scroll(false);
    await scroll(false);
  }
  for (let attempt = 0; attempt < attempts; attempt++) {
    const nodes = snapshot();
    const matches = nodes.filter((node) => node.label.includes(label) && node.bounds &&
      node.bounds[2] > node.bounds[0] && node.bounds[3] > node.bounds[1] &&
      (!enabled || node.enabled !== 'false'));
    const exact = matches.find((node) => node.text === label || node['content-desc'] === label);
    if (exact) return exact;
    if (matches.length) return matches.sort((a, b) =>
      (a.bounds[2] - a.bounds[0]) * (a.bounds[3] - a.bounds[1]) -
      (b.bounds[2] - b.bounds[0]) * (b.bounds[3] - b.bounds[1]))[0];
    await scroll();
  }
  throw new Error(`Cannot find alarm diagnostic control: ${label}`);
}

async function run() {
  if (process.env.CI !== 'true') throw new Error('Run only against the disposable GitHub Actions emulator.');
  fs.mkdirSync(output, { recursive: true });
  const sdk = Number(adb(['shell', 'getprop', 'ro.build.version.sdk']).trim());
  if (sdk >= 33) adb(['shell', 'pm', 'grant', packageName, 'android.permission.POST_NOTIFICATIONS']);
  if (sdk >= 31) adb(['shell', 'appops', 'set', packageName, 'SCHEDULE_EXACT_ALARM', 'allow']);
  adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
  adb(['shell', 'wm', 'dismiss-keyguard']);
  adb(['shell', 'am', 'start', '-W', '-n', `${packageName}/.MainActivity`]);
  await delay(1500);
  const settings = snapshot().filter((node) => node.label.includes('Pengaturan') && node.bounds)
    .sort((a, b) => b.bounds[1] - a.bounds[1])[0];
  tap(settings);
  await delay(750);
  tap(await findControl('Periksa alarm di HP'));
  await delay(750);
  screenshot('diagnostics');
  tap(await findControl('Jadwalkan uji 1 menit'));
  await delay(500);
  await findControl('Alarm dijadwalkan pukul', { enabled: false, fromTop: true });
  screenshot('scheduled');
  // Do not force-stop: Android intentionally removes scheduled work on a force stop.
  adb(['shell', 'input', 'keyevent', 'KEYCODE_SLEEP']);
  await delay(500);
  const lockedPower = adb(['shell', 'dumpsys', 'power']);
  fs.writeFileSync(path.join(output, 'power-locked.txt'), lockedPower);
  if (!/mWakefulness=(?:Asleep|Dozing)/.test(lockedPower)) {
    throw new Error('The emulator did not enter a screen-off power state for the alarm test.');
  }
  let posted = false;
  for (let attempt = 0; attempt < 16; attempt++) {
    await delay(5000);
    const notifications = adb(['shell', 'dumpsys', 'notification', '--noredact']);
    fs.writeFileSync(path.join(output, 'notifications.txt'), notifications);
    const record = notifications.split(/(?=NotificationRecord\()/).find((section) =>
      section.includes(`pkg=${packageName}`) && /\bid=730001\b/.test(section));
    if (record) {
      posted = true;
      fs.writeFileSync(path.join(output, 'posted-record.txt'), record);
      break;
    }
  }
  if (!posted) throw new Error('The 60-second test alarm was not posted while the emulator screen was locked.');
  screenshot('locked-alarm');
  adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
  adb(['shell', 'wm', 'dismiss-keyguard']);
  adb(['shell', 'am', 'start', '-W', '-n', `${packageName}/.MainActivity`]);
  await delay(750);
  await findControl('Waktu uji sudah lewat', { enabled: false, fromTop: true });
  const labels = snapshot().map((node) => node.label).join('\n');
  if (labels.includes('Kamu mengonfirmasi alarm terdengar')) {
    throw new Error('The application falsely inferred a user-confirmed audible alarm.');
  }
  await findControl('Alarm terdengar');
  screenshot('awaiting-user-confirmation');
  fs.writeFileSync(path.join(output, 'result.txt'),
    `PASS: API ${sdk} native scheduled notification id730001 posted while screen was locked; audible result remains unconfirmed.\n`);
  console.log(`Alarm smoke passed on API ${sdk}: native locked-screen delivery; no inferred audible confirmation.`);
}

try {
  await run();
} catch (error) {
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'failure.txt'), `${error.stack ?? error}\n`);
  try { screenshot('failure'); } catch { /* The emulator may have stopped. */ }
  console.error(error.stack ?? error);
  process.exitCode = 1;
} finally {
  try { fs.writeFileSync(path.join(output, 'logcat.txt'), adb(['logcat', '-d', '-v', 'threadtime'])); }
  catch { /* Failure details are already retained. */ }
}
