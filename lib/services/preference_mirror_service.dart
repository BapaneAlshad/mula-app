import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional Android preferences mirror. SQLite remains authoritative.
class PreferenceMirrorService {
  PreferenceMirrorService({Future<SharedPreferences> Function()? load})
      : _load = load ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _load;
  SharedPreferences? _preferences;
  bool _disabled = false;

  Future<void> initialize() async {
    if (_disabled || _preferences != null) return;
    try {
      _preferences = await _load();
    } catch (error) {
      _disable(error);
    }
  }

  Future<void> writeString(String key, String value) async {
    if (_disabled) return;
    await initialize();
    if (_disabled) return;
    try {
      final saved = await _preferences!.setString(key, value);
      if (!saved) _disable(StateError('Android preferences did not save.'));
    } catch (error) {
      _disable(error);
    }
  }

  void _disable(Object error) {
    _disabled = true;
    _preferences = null;
    debugPrint('Mirror preferensi Android tidak tersedia; SQLite tetap aktif: $error');
  }
}
