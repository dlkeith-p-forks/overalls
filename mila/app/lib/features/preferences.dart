// Mila's persisted settings: added deployments, the app lock and each
// deployment's push registration record. Never credentials, tokens or keys.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads and writes the settings document.
abstract interface class PreferencesStore {
  Future<Map<String, Object?>> read();
  Future<void> write(Map<String, Object?> values);
}

/// Settings kept in memory: tests and the demo flavour.
final class MemoryPreferences implements PreferencesStore {
  MemoryPreferences([Map<String, Object?>? initial]) : values = {...?initial};
  Map<String, Object?> values;
  @override
  Future<Map<String, Object?>> read() async => Map.of(values);
  @override
  Future<void> write(Map<String, Object?> values) async => this.values = Map.of(values);
}

final preferencesStoreProvider = Provider<PreferencesStore>((ref) => MemoryPreferences());

/// The settings document, loaded once and written through.
final preferencesProvider = NotifierProvider<PreferencesNotifier, Map<String, Object?>?>(
  PreferencesNotifier.new,
);

final class PreferencesNotifier extends Notifier<Map<String, Object?>?> {
  Future<void>? _writing;
  late Future<void> _loaded;

  @override
  Map<String, Object?>? build() {
    _loaded = _load();
    return null;
  }

  Future<void> _load() async {
    final loaded = await ref.read(preferencesStoreProvider).read();
    state = Map.unmodifiable(loaded);
  }

  /// Completes once the stored document has been read.
  Future<void> get loaded => _loaded;

  /// Sets [key] to [value] (null removes it) and persists the document.
  Future<void> put(String key, Object? value) async {
    await _loaded;
    final next = {...?state};
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    state = Map.unmodifiable(next);
    final previous = _writing;
    final write = () async {
      await previous;
      await ref.read(preferencesStoreProvider).write(next);
    }();
    _writing = write;
    await write;
  }
}
