// Called by android_release_smoke.mjs on its disposable CI emulator.
// Dependencies: tap(node), findControl(label), waitFor(label,predicate),
// includesLabel(nodes,label), selectTab(label), scroll(down), screenshot(label),
// forceRestart() (force-stop the application, then launch the same package).
export async function exerciseWellbeing({
  tap, findControl, waitFor, includesLabel, selectTab, scroll, screenshot,
  forceRestart,
}) {
  tap(await findControl('Saya sedang cemas'));
  await waitFor('anxiety-start', (nodes) => includesLabel(nodes, 'Mulai sesi tenang'));
  tap(await findControl('Mulai sesi tenang'));
  await waitFor('anxiety-breathing', (nodes) => includesLabel(nodes, 'Beralih ke grounding sekarang'));
  screenshot('anxiety-breathing');
  tap(await findControl('Beralih ke grounding sekarang'));
  await waitFor('anxiety-grounding', (nodes) => includesLabel(nodes, 'Kenali sekitarmu'));
  tap(await findControl('Sebutkan 5 hal yang bisa kamu lihat.'));
  await waitFor('anxiety-grounding-saved', (nodes) => nodes.some((node) =>
    node.label.includes('Sebutkan 5 hal yang bisa kamu lihat.') && node.checked === 'true'));
  screenshot('anxiety-grounding-saved');

  // A fresh Flutter process must recover the saved draft, not create a new one.
  await forceRestart();
  await waitFor('anxiety-restart-today', (nodes) => includesLabel(nodes, 'SKOR HARI INI'));
  tap(await findControl('Saya sedang cemas'));
  await waitFor('anxiety-grounding-restored', (nodes) =>
    includesLabel(nodes, 'Kenali sekitarmu') && nodes.some((node) =>
      node.label.includes('Sebutkan 5 hal yang bisa kamu lihat.') && node.checked === 'true'));
  screenshot('anxiety-grounding-restored');
  tap(await findControl('Simpan kondisi & akhiri sesi'));
  await scroll(false);
  await scroll(false);
  await waitFor('anxiety-completed', (nodes) => includesLabel(nodes, 'SKOR HARI INI'));

  await selectTab('Progres');
  await waitFor('progress-page', (nodes) => includesLabel(nodes, 'Tumbuh dengan'));
  await findControl('Tujuh hari terakhir');
  screenshot('weekly-progress');
  await findControl('Kalender & riwayat harian');
  await waitFor('progress-calendar', (nodes) => includesLabel(nodes, 'Kalender & riwayat harian'));
  screenshot('history-calendar');
  await selectTab('Hari Ini');
  await scroll(false);
  await scroll(false);
  await waitFor('wellbeing-return-today', (nodes) => includesLabel(nodes, 'SKOR HARI INI'));
}
