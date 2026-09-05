import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/ssh/ssh_connection.dart';

void main() {
  group('HostKeyVerifier', () {
    test('accepts an exact pin without asking for confirmation', () async {
      var confirmations = 0;
      final verifier = HostKeyVerifier(
        profile: profile(
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:expected',
        ),
        onFirstUseHostKey: (_) async {
          confirmations += 1;
          return true;
        },
      );

      expect(await verifier.verify('ssh-ed25519', 'SHA256:expected'), isTrue);
      expect(confirmations, 0);
    });

    test('rejects a mismatched pin without asking for confirmation', () async {
      var confirmations = 0;
      final verifier = HostKeyVerifier(
        profile: profile(
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:expected',
        ),
        onFirstUseHostKey: (_) async {
          confirmations += 1;
          return true;
        },
      );

      await expectLater(
        verifier.verify('ssh-ed25519', 'SHA256:attacker'),
        throwsA(isA<HostKeyMismatchException>()),
      );
      expect(confirmations, 0);
    });

    test('waits for explicit first-use approval before persisting', () async {
      final decision = Completer<bool>();
      ServerProfile? persisted;
      final verifier = HostKeyVerifier(
        profile: profile(),
        onFirstUseHostKey: (_) => decision.future,
        persistProfile: (value) async => persisted = value,
      );

      final verification = verifier.verify('ssh-ed25519', 'SHA256:new');
      expect(persisted, isNull);
      decision.complete(true);

      expect(await verification, isTrue);
      expect(persisted?.hostKeyType, 'ssh-ed25519');
      expect(persisted?.hostKeyFingerprint, 'SHA256:new');
      expect(verifier.profile.hasPinnedHostKey, isTrue);
    });

    test('does not persist a rejected first-use key', () async {
      var persisted = false;
      final verifier = HostKeyVerifier(
        profile: profile(),
        onFirstUseHostKey: (_) async => false,
        persistProfile: (_) async => persisted = true,
      );

      expect(await verifier.verify('ssh-rsa', 'SHA256:no'), isFalse);
      expect(persisted, isFalse);
      expect(verifier.profile.hasPinnedHostKey, isFalse);
    });
  });
}

ServerProfile profile({String? keyType, String? fingerprint}) {
  return ServerProfile(
    id: 'id',
    name: 'Server',
    host: 'example.com',
    username: 'user',
    authentication: SshAuthentication.password,
    hostKeyType: keyType,
    hostKeyFingerprint: fingerprint,
  );
}
