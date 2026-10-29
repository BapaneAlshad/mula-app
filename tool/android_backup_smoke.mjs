// Run only against the disposable CI emulator, through the real Android SAF UI.
export async function exerciseBackup({ snapshot, findControl, tap, waitFor,
  selectTab, scroll, screenshot, adb, delay, launch }) {
  if (process.env.CI !== 'true') throw new Error('Backup smoke requires a disposable CI emulator.');
  const has = (nodes, label) => nodes.some((node) => node.label.includes(label));
  const visible = (node) => node?.bounds && node.bounds[2] > node.bounds[0] &&
    node.bounds[3] > node.bounds[1] && node.enabled !== 'false';
  const labels = (nodes) => nodes.map((node) => node.label).filter(Boolean).join(' | ');

  async function saveDocument(kind) {
    let nodes = await waitFor(`backup-${kind}-save-picker`, (items) => items.some((node) =>
      /EditText$/.test(node.class ?? '') && node.text?.includes(`mula-${kind}-`)));
    const field = nodes.find((node) => /EditText$/.test(node.class ?? '') &&
      node.text?.includes(`mula-${kind}-`));
    const filename = field.text;
    if (!/^mula-[a-z-]+-[0-9TZ._-]+\.json$/.test(filename)) {
      throw new Error(`Unexpected native backup filename: ${filename}`);
    }
    let save = nodes.find((node) => /^(save|simpan)$/i.test(node.text ?? '') && visible(node));
    if (!save) {
      const navigation = nodes.find((node) => /show roots|open navigation drawer/i.test(node.label) && visible(node));
      if (navigation) {
        tap(navigation);
        nodes = await waitFor(`backup-${kind}-locations`, (items) => has(items, 'Downloads'));
        tap(nodes.find((node) => /^(downloads|unduhan)$/i.test(node.text ?? '') && visible(node)));
        nodes = await snapshot(`backup-${kind}-downloads`);
        save = nodes.find((node) => /^(save|simpan)$/i.test(node.text ?? '') && visible(node));
      }
    }
    if (!save) throw new Error(`Android document picker has no enabled Save button: ${labels(nodes)}`);
    screenshot(`backup-${kind}-native-save`);
    tap(save);
    await delay(600);
    return filename;
  }

  async function openDocument(filename) {
    let nodes = await snapshot('backup-native-open');
    let document = nodes.find((node) => node.text === filename && visible(node));
    if (!document) {
      const navigation = nodes.find((node) => /show roots|open navigation drawer/i.test(node.label) && visible(node));
      if (navigation) {
        tap(navigation);
        nodes = await waitFor('backup-open-locations', (items) => has(items, 'Downloads'));
        tap(nodes.find((node) => /^(downloads|unduhan)$/i.test(node.text ?? '') && visible(node)));
      }
      nodes = await waitFor('backup-open-file', (items) => items.some((node) =>
        node.text === filename && visible(node)));
      document = nodes.find((node) => node.text === filename && visible(node));
    }
    screenshot('backup-native-open-file');
    tap(document);
  }

  await selectTab('Pengaturan');
  tap(await findControl('Simpan cadangan'));
  const filename = await saveDocument('cadangan');
  await waitFor('backup-exported', (nodes) => has(nodes, 'Cadangan terakhir:') ||
    has(nodes, 'Cadangan tersimpan di lokasi pilihanmu.'));
  screenshot('backup-exported');

  // The initial smoke saved five minutes. Change it to prove restoration uses
  // the saved document rather than merely returning from Android's picker.
  await selectTab('Fokus');
  tap(await findControl('50 menit'));
  await scroll(false);
  await scroll(false);
  await waitFor('backup-mutated-preference', (nodes) => has(nodes, '50:00'));
  await selectTab('Pengaturan');
  tap(await findControl('Pulihkan cadangan'));
  await delay(600);
  await openDocument(filename);
  await waitFor('backup-restore-preview', (nodes) => has(nodes, 'Ganti data dengan cadangan?') &&
    has(nodes, 'tugas') && has(nodes, 'hari progres'));
  screenshot('backup-restore-preview');
  tap(await findControl('Simpan pengaman & pulihkan'));
  await saveDocument('sebelum-pemulihan');
  await waitFor('backup-restored', (nodes) => has(nodes, 'Data cadangan berhasil dipulihkan.') ||
    has(nodes, 'Cadangan & pemulihan'));
  await selectTab('Fokus');
  await scroll(false);
  await scroll(false);
  await waitFor('backup-preference-restored', (nodes) => has(nodes, 'RUANG FOKUS') && has(nodes, '05:00'));
  screenshot('backup-preference-restored');
  adb(['shell', 'am', 'force-stop', 'com.anggit.mula.mula']);
  await launch();
  await waitFor('backup-restored-after-restart', (nodes) => has(nodes, 'RUANG FOKUS') && has(nodes, '05:00'));
  screenshot('backup-restored-after-restart');
  console.log('Backup smoke passed: Android save/open, recovery document, transactional restore, preference, and restart.');
}
