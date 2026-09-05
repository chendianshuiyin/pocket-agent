import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/core/server_profile.dart';
import 'package:pocket_agent/core/server_secret.dart';

void main() {
  test('ServerProfile JSON round trip preserves host pin and ports', () {
    const original = ServerProfile(
      id: 'id',
      name: 'Name',
      host: 'host',
      port: 2222,
      username: 'user',
      authentication: SshAuthentication.privateKey,
      hostKeyType: 'ssh-ed25519',
      hostKeyFingerprint: 'SHA256:abc',
      remoteCodexPort: 4600,
    );

    final restored = ServerProfile.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.port, 2222);
    expect(restored.authentication, SshAuthentication.privateKey);
    expect(restored.hasPinnedHostKey, isTrue);
    expect(restored.remoteCodexPort, 4600);
  });

  test('ServerProfile rejects invalid persisted ports', () {
    expect(
      () => ServerProfile.fromJson({
        'id': 'id',
        'name': 'Name',
        'host': 'host',
        'port': 0,
        'username': 'user',
        'authentication': 'password',
        'remoteCodexPort': 4500,
      }),
      throwsFormatException,
    );
  });

  test('ServerSecret requires at least one authentication secret', () {
    expect(() => ServerSecret(), throwsArgumentError);
    expect(ServerSecret(password: 'value').hasPassword, isTrue);
    expect(ServerSecret(privateKeyPem: 'pem').hasPrivateKey, isTrue);
  });
}
