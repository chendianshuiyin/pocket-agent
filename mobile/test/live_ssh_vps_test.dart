import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';
import 'package:pocket_agent/ssh/remote_runtime.dart';

import 'live_vps_test.dart' show fixtureToken, loadFixture, makeConnection;

void main() {
  test(
    'live VPS without Codex auth: SSH tunnel readiness and signed-out account',
    () async {
      final fixture = await loadFixture();
      final ssh = makeConnection(fixture);
      CodexTunnel? tunnel;
      CodexClient? rpc;
      try {
        await ssh
            .connect(onFirstUseHostKey: (_) async => false)
            .timeout(const Duration(seconds: 30));

        final runtime = RemoteRuntimeManager(ssh);
        final status = await runtime.inspect().timeout(
          const Duration(seconds: 30),
        );
        // ignore: avoid_print
        print('Runtime authenticated transport: ${status.running}');
        expect(status.running, isTrue, reason: status.diagnostic);

        tunnel = await runtime.openExistingTunnel();
        rpc = await CodexClient.connect(
          tunnel.uri,
          headers: tunnel.clientHeaders,
          reconnectPolicy: const ReconnectPolicy(enabled: false),
        ).timeout(const Duration(seconds: 30));
        final account = await rpc.readAccount().timeout(
          const Duration(seconds: 30),
        );
        // ignore: avoid_print
        print(
          'Account status: authenticated=${account.isAuthenticated}; '
          'kind=${account.kind.name}',
        );
        expect(account.isAuthenticated, isFalse);
        expect(account.kind, AccountKind.signedOut);
      } finally {
        await rpc?.dispose();
        await tunnel?.close();
        await ssh.disconnect();
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
