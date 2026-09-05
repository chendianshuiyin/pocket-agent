import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_profile.dart';
import 'server_secret.dart';

abstract interface class ProfileStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class ServerRepository {
  factory ServerRepository({
    required ProfileStore profileStore,
    required SecretStore secretStore,
  }) => ServerRepository._(profileStore, secretStore);

  ServerRepository._(this._profileStore, this._secretStore);

  static const _profilesKey = 'pocket_agent.server_profiles.v1';
  static const _secretPrefix = 'pocket_agent.server_secret.v1.';

  final ProfileStore _profileStore;
  final SecretStore _secretStore;
  Future<void> _mutations = Future<void>.value();

  static Future<ServerRepository> create() async {
    final preferences = await SharedPreferences.getInstance();
    return ServerRepository(
      profileStore: SharedPreferencesProfileStore(preferences),
      secretStore: const SecureStorageSecretStore(
        FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
          ),
        ),
      ),
    );
  }

  Future<List<ServerProfile>> listProfiles() async {
    final encoded = await _profileStore.read(_profilesKey);
    if (encoded == null) return const [];
    final value = jsonDecode(encoded);
    if (value is! List<Object?>) {
      throw const FormatException('Stored server profiles must be a list');
    }
    return value
        .map((item) {
          if (item is! Map<String, Object?>) {
            throw const FormatException(
              'Stored server profile must be an object',
            );
          }
          return ServerProfile.fromJson(item);
        })
        .toList(growable: false);
  }

  Future<ServerProfile?> getProfile(String id) async {
    for (final profile in await listProfiles()) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<ServerSecret?> getSecret(String id) async {
    final encoded = await _secretStore.read('$_secretPrefix$id');
    if (encoded == null) return null;
    final value = jsonDecode(encoded);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Stored server secret must be an object');
    }
    final password = value['password'];
    final privateKeyPem = value['privateKeyPem'];
    final privateKeyPassphrase = value['privateKeyPassphrase'];
    if (password != null && password is! String ||
        privateKeyPem != null && privateKeyPem is! String ||
        privateKeyPassphrase != null && privateKeyPassphrase is! String) {
      throw const FormatException('Stored server secret has invalid fields');
    }
    return ServerSecret(
      password: password as String?,
      privateKeyPem: privateKeyPem as String?,
      privateKeyPassphrase: privateKeyPassphrase as String?,
    );
  }

  Future<void> save(ServerProfile profile, ServerSecret secret) async {
    await _serialized(() async {
      final secretKey = '$_secretPrefix${profile.id}';
      final previousSecret = await _secretStore.read(secretKey);
      await _secretStore.write(secretKey, _encodeSecret(secret));
      try {
        await _saveProfileUnlocked(profile);
      } catch (_) {
        await _restoreSecret(secretKey, previousSecret);
        rethrow;
      }
    });
  }

  Future<void> saveProfile(ServerProfile profile) async {
    await _serialized(() => _saveProfileUnlocked(profile));
  }

  Future<void> _saveProfileUnlocked(ServerProfile profile) async {
    final profiles = [...await listProfiles()];
    final index = profiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    await _profileStore.write(
      _profilesKey,
      jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> delete(String id) async {
    await _serialized(() async {
      final profiles = [...await listProfiles()]
        ..removeWhere((item) => item.id == id);
      final secretKey = '$_secretPrefix$id';
      final previousSecret = await _secretStore.read(secretKey);
      await _secretStore.delete(secretKey);
      try {
        if (profiles.isEmpty) {
          await _profileStore.delete(_profilesKey);
        } else {
          await _profileStore.write(
            _profilesKey,
            jsonEncode(profiles.map((item) => item.toJson()).toList()),
          );
        }
      } catch (_) {
        await _restoreSecret(secretKey, previousSecret);
        rethrow;
      }
    });
  }

  String _encodeSecret(ServerSecret secret) => jsonEncode({
    'password': secret.password,
    'privateKeyPem': secret.privateKeyPem,
    'privateKeyPassphrase': secret.privateKeyPassphrase,
  });

  Future<void> _restoreSecret(String key, String? value) {
    return value == null
        ? _secretStore.delete(key)
        : _secretStore.write(key, value);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _mutations = _mutations.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

class SharedPreferencesProfileStore implements ProfileStore {
  SharedPreferencesProfileStore(this._preferences);

  final SharedPreferences _preferences;

  @override
  Future<String?> read(String key) async => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) async {
    final saved = await _preferences.setString(key, value);
    if (!saved) throw StateError('Failed to save server profiles');
  }

  @override
  Future<void> delete(String key) async {
    final removed = await _preferences.remove(key);
    if (!removed && _preferences.containsKey(key)) {
      throw StateError('Failed to delete server profiles');
    }
  }
}

class SecureStorageSecretStore implements SecretStore {
  const SecureStorageSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
