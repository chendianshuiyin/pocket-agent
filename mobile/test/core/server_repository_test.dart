import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_repository.dart';
import 'package:pocket_agent/core/server_secret.dart';

void main() {
  group('ServerRepository', () {
    late MemoryProfileStore profiles;
    late MemorySecretStore secrets;
    late ServerRepository repository;

    setUp(() {
      profiles = MemoryProfileStore();
      secrets = MemorySecretStore();
      repository = ServerRepository(
        profileStore: profiles,
        secretStore: secrets,
      );
    });

    test('keeps credentials out of the profile store', () async {
      await repository.save(
        profile(id: 'one'),
        ServerSecret(
          password: 'not-in-preferences',
          privateKeyPem: 'private-pem',
          privateKeyPassphrase: 'key-passphrase',
        ),
      );

      expect(
        profiles.values.values.single,
        isNot(contains('not-in-preferences')),
      );
      expect(profiles.values.values.single, isNot(contains('private-pem')));
      expect(
        (await repository.getSecret('one'))?.password,
        'not-in-preferences',
      );
    });

    test(
      'serializes concurrent profile read-modify-write operations',
      () async {
        profiles.readDelay = const Duration(milliseconds: 10);

        await Future.wait([
          repository.saveProfile(profile(id: 'one')),
          repository.saveProfile(profile(id: 'two')),
        ]);

        expect(
          (await repository.listProfiles()).map((item) => item.id),
          containsAll(<String>['one', 'two']),
        );
      },
    );

    test('rolls back a secret when saving the profile fails', () async {
      await repository.save(
        profile(id: 'one', name: 'Original'),
        ServerSecret(password: 'old-password'),
      );
      profiles.failNextWrite = true;

      await expectLater(
        repository.save(
          profile(id: 'one', name: 'Changed'),
          ServerSecret(password: 'new-password'),
        ),
        throwsA(isA<StateError>()),
      );

      expect((await repository.getProfile('one'))?.name, 'Original');
      expect((await repository.getSecret('one'))?.password, 'old-password');
    });

    test('restores a secret when deleting the profile fails', () async {
      await repository.save(
        profile(id: 'one'),
        ServerSecret(password: 'password'),
      );
      profiles.failNextDelete = true;

      await expectLater(repository.delete('one'), throwsA(isA<StateError>()));

      expect(await repository.getProfile('one'), isNotNull);
      expect((await repository.getSecret('one'))?.password, 'password');
    });
  });
}

ServerProfile profile({required String id, String name = 'Server'}) {
  return ServerProfile(
    id: id,
    name: name,
    host: 'example.com',
    username: 'user',
    authentication: SshAuthentication.password,
  );
}

class MemoryProfileStore implements ProfileStore {
  final Map<String, String> values = {};
  Duration readDelay = Duration.zero;
  bool failNextWrite = false;
  bool failNextDelete = false;

  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(readDelay);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('profile write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw StateError('profile delete failed');
    }
    values.remove(key);
  }
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
