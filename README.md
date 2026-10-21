# MULA

**Mulai kecil. Tumbuh setiap hari.**

Pendamping rutinitas Android untuk Anggit dengan Flutter Material 3, Riverpod tanpa generator, dan SQLite lokal. Prinsipnya: **Saya tidak harus sempurna. Saya hanya wajib kembali ke sistem pada blok berikutnya.**

## Membuat APK tanpa Flutter SDK di laptop

1. Buat repository GitHub, lalu unggah seluruh isi folder proyek ini, termasuk `.github/`, `android/`, `lib/`, `test/`, `tool/`, dan `pubspec.yaml`. Gunakan branch `main` atau `master`.
2. Buka tab **Actions**, pilih **Build MULA Android APK**. Push ke `main`/`master` akan menjalankan workflow otomatis. Untuk menjalankan ulang, pilih **Run workflow**.
3. Tunggu seluruh langkah selesai. Buka hasil run, kemudian unduh artifact **MULA-Android-APK**.
4. Ekstrak arsip artifact, pindahkan `app-release.apk` ke HP Android, lalu instal. Android mungkin meminta izin instalasi dari sumber yang digunakan untuk membuka APK tersebut.

Laptop tidak memerlukan Flutter SDK, Android Studio, atau Gradle. GitHub Actions menyiapkan Java 17 dan Flutter stable, mem-backup source MULA, menjalankan:

```sh
flutter create --org com.anggit.mula --project-name mula --platforms android --no-pub .
```

Source `lib/`, `pubspec.yaml`, manifest, activity, dan resource Android custom lalu dikembalikan menggunakan `cp -r`. Script `tool/configure_android.mjs` mengaktifkan desugaring, Java 17, Android minSdk 24, compileSdk minimal 36, serta AppCompat untuk biometrik. Seluruh wrapper Gradle dan berkas mesin Android dibuat di server.

Workflow melanjutkan dengan:

```sh
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build apk --release --no-tree-shake-icons
```

Artifact disimpan selama 14 hari. `flutter create` membuat konfigurasi tanda tangan debug untuk build release ini, sehingga APK ditujukan untuk instalasi pribadi. Rilis distribusi permanen memerlukan keystore milik pemilik aplikasi agar pembaruan APK selalu menggunakan identitas tanda tangan yang sama.

## Isi Fase 1

- Onboarding menyimpan nama, jam bangun, jam tidur, dan tingkat ketegasan ke database.
- Tujuh tabel utama: `users`, `schedule_templates`, `daily_tasks`, `focus_sessions`, `thought_parkings`, `anxiety_sessions`, dan `daily_scores`, lengkap dengan indeks, relasi, validasi nilai, dan fondasi migrasi.
- Seeder idempoten mengisi rutinitas Anggit dan membuat aktivitas hari berjalan tanpa menggandakan data saat aplikasi dibuka kembali.
- Rotasi deep work kerja dan side job mengikuti hari, dengan override proyek untuk deadline aktif.
- Lima tab: Hari Ini, Fokus, Pikiran, Progres, dan Pengaturan. Aksi pengguna disimpan ke SQLite dan dimuat ulang melalui Riverpod.
- Tema circadian mengikuti waktu Pagi 04.30–08.00, Kerja 08.00–16.00, Keluarga 16.00–20.00, Malam 20.00–22.00, serta suasana istirahat di luar rentang tersebut. Sanctuary Mode memberi suasana tenang saat cemas, stuck, atau Hari Buruk.
- MULA Seed tumbuh dari Benih ke Tunas, Berdaun, lalu Berbunga mengikuti skor otomatis.
- Timer fokus menyimpan timestamp sesi. Tampilan sisa waktu dihitung ulang dari selisih waktu sehingga tidak bergantung pada tick saat layar terkunci.
- Infrastruktur pengingat lokal menggunakan `flutter_local_notifications`, `android_alarm_manager_plus`, dan zona waktu `Asia/Jakarta`. Fitur pikiran sensitif memakai autentikasi perangkat melalui `local_auth`.

## Isi Fase 2

Tab **Hari Ini** menampilkan tanggal, sapaan circadian, MULA Seed, skor otomatis, dan streak. Aksi cepat menyimpan tugas, memulai fokus 5 menit, mengaktifkan Sanctuary saat cemas, serta memarkir pikiran ke SQLite.

- **Normal** menampilkan jadwal lengkap dan tiga slot prioritas unik. Memulai Top 2/3 sebelum Top 1 dimulai meminta pengakuan lewat pengingat lembut.
- **Hari Buruk / Minimum** menyembunyikan jadwal padat dan menampilkan tujuh checklist dasar. Progres jadwal normal tetap disimpan; skor dihitung dari checklist minimum selama mode ini aktif. Catatan penutupan hari harus ditulis sebelum checklist catatan ditandai selesai.
- **Hari Adaptasi** meminta salah satu dari enam alasan valid, menonaktifkan konsekuensi harian, dan melindungi streak. Aksi cemas atau stuck hanya mengaktifkan suasana tenang; perlindungan Adaptasi tetap memerlukan alasan.
- Perencanaan dapat dimulai pukul **08.00–09.30**, satu kali per hari. Deadline 20 menit disimpan di `planning_sessions`. Ketika habis, form ditutup dan aplikasi berpindah ke sesi fokus Top 1 selama 25 menit. Jika belum ada Top 1, sistem membuat satu tindakan konkret. Pemulihan setelah aplikasi tertutup memulai eksekusi saat aplikasi kembali aktif, tanpa memberi kredit fokus untuk waktu offline. Beralih ke Minimum membatalkan perencanaan.
- Form tugas menyimpan judul, deskripsi, kategori, deadline, durasi, energi, prioritas, subtask, dan bobot poin. Asisten lokal menawarkan konversi judul abstrak menjadi output terukur. Bobot mengatur pembagian poin dalam kelompok skor; total harian tetap maksimal 100.
- Geser kanan menyelesaikan tugas dan menyediakan **Undo selama 5 detik**, termasuk pemulihan checklist, status, dan skor. Geser kiri membuka pengaturan status. Menunda atau melewati tugas memerlukan alasan.
- Modul **VALORANT** ada di blok 11.45–13.00. Akses memerlukan Top 1 selesai atau satu sesi fokus pagi selesai, kuota satu match, dan tidak ada penalti kemarin. Izin notifikasi dan alarm presisi wajib tersedia sebelum kuota terpakai. Sistem memasang alarm 45 menit dan pengingat pukul 13.00; kegagalan pemasangan alarm mengembalikan kuota. Pengguna tetap wajib mengonfirmasi game sudah ditutup. Konfirmasi melewati pukul 13.00, termasuk sesi yang dibiarkan tanpa konfirmasi, mengunci akses keesokan hari kecuali konsekuensi hari itu dinonaktifkan oleh Adaptasi.

Migrasi SQLite versi 2 menambahkan field tugas dan perlindungan hari, serta tabel `planning_sessions` dan `valorant_sessions`, tanpa menghapus data versi 1. Seluruh timer memakai timestamp persisten. MULA mencatat izin bermain dan konfirmasi pengguna; penguncian ini berlaku pada tombol akses dalam MULA, bukan pemblokiran proses game oleh Android.

## Jadwal dan penyesuaian

Jadwal mengikuti blok yang diminta, termasuk buffer sebelum 07.00, jeda tanpa HP, syarat VALORANT, rutinitas Alshad, rotasi RUMA/Sidangode, dan ritual shutdown. Celah 16.00–17.00 tetap tersedia sebagai transisi karena tidak ada blok eksplisit pada permintaan awal.

Ada perbedaan durasi dalam spesifikasi: blok **20.45–21.45 berlangsung 60 menit**, sedangkan checklist **50 menit fokus + 10 menit istirahat + 5 menit mencatat hasil berjumlah 65 menit**. Seeder mempertahankan jam blok dan 50 menit fokus + 10 menit istirahat. Catatan hasil 5 menit diselesaikan pada awal shutdown, 21.45–21.50, sehingga persiapan tidur tetap berakhir 22.00. Teks checklist menyebutkan penyesuaian ini.

Skor harian memiliki batas 100: Pagi 20, Kerja 35, Kesehatan/Keluarga 25, dan Side Job 20. Masing-masing kelompok membagi poin menurut durasi aktivitas yang direncanakan. Aktivitas selesai mendapat cakupan penuh; aktivitas lain memakai nilai terbesar antara proporsi checklist selesai dan durasi fokus aktual. Interval fokus yang bertumpuk digabung agar tidak menghasilkan poin ganda. Penyelesaian aktivitas dan sesi fokus memperbarui skor secara otomatis; pengguna tidak memasukkan skor manual. Catatan emosi dan mode hari disimpan terpisah dari perhitungan poin.

## Data, pengingat, dan penguncian

Seluruh data utama disimpan di SQLite dalam penyimpanan aplikasi. Preferensi sederhana memakai SharedPreferences. Aplikasi tidak memerlukan akun cloud atau koneksi internet setelah terpasang. Menghapus data aplikasi atau menghapus instalasi juga menghapus database lokal; ekspor dan sinkronisasi belum termasuk Fase 1.

Manifest menyertakan seluruh izin yang diminta, receiver notifikasi dan reboot, layanan AlarmManager, serta ikon notifikasi yang dipertahankan pada build release. Notifikasi Android 13+ tetap mengikuti izin pengguna. Jika alarm presisi tidak tersedia, aplikasi perlu memakai pengingat tidak presisi; izin yang tercantum pada manifest tidak menggantikan keputusan pengguna dan pengaturan Android. Pembatasan baterai dari produsen HP atau force stop dapat menunda atau membatalkan pengingat sampai aplikasi dibuka kembali. Pengingat saat layar terkunci perlu diperiksa pada perangkat Android yang digunakan Anggit.

Penguncian memakai biometrik atau PIN/pola/kata sandi **perangkat**, bukan PIN aplikasi terpisah. Perangkat harus memiliki metode penguncian yang didukung. Autentikasi membatasi akses layar sensitif; SQLite Fase 1 belum dienkripsi.

## Pemeriksaan

Pemeriksaan source tanpa Flutter SDK di Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\verify_source.ps1
```

Verifier memeriksa struktur proyek, dependency tanpa code generation, langkah wajib workflow, XML Android, permission, FragmentActivity, dan pola tombol kosong. Pemeriksaan ini tidak menggantikan analyzer, pengujian Flutter, build APK, atau pemeriksaan perilaku di HP.

Pengujian Flutter dijalankan oleh GitHub Actions. Tidak ada klaim analyzer, `flutter test`, atau build APK berhasil di laptop yang tidak memiliki SDK. Hasil run Actions pertama menjadi bukti kompilasi dan pengujian cloud.

## Rujukan konfigurasi dependency

Versi API dipilih dari dokumentasi paket resmi: [Riverpod 2.6.1](https://pub.dev/packages/flutter_riverpod/versions/2.6.1), [notifikasi 19.5.0](https://pub.dev/packages/flutter_local_notifications/versions/19.5.0), [AlarmManager 4.0.8](https://pub.dev/packages/android_alarm_manager_plus/versions/4.0.8), [local_auth 2.3.0](https://pub.dev/packages/local_auth/versions/2.3.0), dan [timezone 0.10.1](https://pub.dev/packages/timezone/versions/0.10.1). Tidak ada `riverpod_generator`, `freezed`, atau `build_runner`.

`pubspec.lock` disimpan dari resolusi cloud yang sudah digunakan untuk build aplikasi. Build berikutnya mempertahankan versi dependency tersebut; artifact **MULA-Dependency-Lock** tetap tersedia untuk pemeriksaan hasil resolusi.

## Perbaikan startup Android 1.0.1

`shared_preferences_android` 2.5.1 memakai JNI untuk memanggil fungsi Kotlin. R8 pada build release dapat mengubah nama kelas coroutine yang dibutuhkan JNI sehingga `SharedPreferencesApiRegistrar.getAll()` melempar `NoSuchMethodError`. [Laporan Flutter](https://github.com/flutter/flutter/issues/194649) dan [perbaikan upstream](https://github.com/flutter/packages/pull/13311) menjelaskan aturan keep yang diperlukan.

MULA mempertahankan enam kelas Kotlin tersebut lewat `android/app/proguard-rules.pro`, yang dipasang eksplisit ke konfigurasi release oleh script pembuat Android. SQLite dibuka terlebih dahulu. Salinan preferensi di SharedPreferences bersifat tambahan; bila plugin gagal, perubahan tetap tersimpan di SQLite dan aplikasi tetap dapat dibuka. Perbaikan ini tidak menghapus atau mengganti database pengguna.

Selain tes Dart dan konfigurasi Gradle, workflow memasang APK release yang akan dibagikan pada emulator Android di GitHub Actions. Pemeriksaan menjalankan onboarding, navigasi, penulisan preferensi, serta membuka ulang aplikasi, dan menolak error JNI maupun kegagalan salinan preferensi di logcat. Hasil screenshot, XML layar, dan logcat tersedia sebagai artifact diagnostik. Flutter SDK dan emulator tetap hanya berjalan di cloud.
