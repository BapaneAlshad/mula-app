import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/app_controller.dart';
import 'domain/app_snapshot.dart';
import 'theme/circadian_theme.dart';
import 'ui/mula_shell.dart';
import 'ui/onboarding_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MulaApp()));
}

class MulaApp extends ConsumerStatefulWidget {
  const MulaApp({super.key});

  @override
  ConsumerState<MulaApp> createState() => _MulaAppState();
}

class _MulaAppState extends ConsumerState<MulaApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      ref.read(thoughtsUnlockedProvider.notifier).state = false;
    }
    if (state == AppLifecycleState.resumed &&
        ref.read(appControllerProvider).hasValue) {
      unawaited(ref.read(appControllerProvider.notifier).onResume().catchError(
        (Object error, StackTrace stack) => debugPrint('Pemulihan MULA: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final circadian = ref.watch(circadianThemeProvider);
    final app = ref.watch(appControllerProvider);
    return MaterialApp(
      title: 'MULA',
      debugShowCheckedModeBanner: false,
      theme: circadian.theme,
      themeAnimationDuration: const Duration(milliseconds: 550),
      home: app.when(
        data: (snapshot) => snapshot.user.flag('onboardingCompleted')
            ? MulaShell(snapshot: snapshot)
            : OnboardingScreen(snapshot: snapshot),
        loading: () => const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.spa_outlined, size: 56),
                SizedBox(height: 20),
                Text('MULA', style: TextStyle(fontSize: 28, letterSpacing: 6)),
                SizedBox(height: 8),
                Text('Mulai kecil. Tumbuh setiap hari.'),
                SizedBox(height: 28),
                CircularProgressIndicator(),
              ],
            ),
          ),
        ),
        error: (error, stack) => Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_outlined, size: 48),
                    const SizedBox(height: 16),
                    const Text('Data lokal belum dapat dibuka.'),
                    const SizedBox(height: 8),
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => ref.invalidate(appControllerProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Coba buka kembali'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
