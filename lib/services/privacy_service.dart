import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class PrivacyService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> authenticate() async {
    try {
      if (!await _auth.isDeviceSupported()) {
        throw StateError('Pasang PIN atau biometrik di pengaturan Android dahulu.');
      }
      return await _auth.authenticate(
        localizedReason: 'Buka catatan pikiran pribadimu di MULA',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (error) {
      throw StateError('Penguncian perangkat belum tersedia (${error.code}).');
    }
  }
}
