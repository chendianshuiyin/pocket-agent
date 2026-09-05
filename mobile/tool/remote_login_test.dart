import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/codex/codex.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';

import '../test/live_vps_test.dart'
    show fixtureToken, loadFixture, makeConnection;

const _actionDefine = String.fromEnvironment('POCKET_LOGIN_ACTION');
const _interactiveLogin = bool.fromEnvironment(
  'POCKET_DEVICE_LOGIN_INTERACTIVE',
);
const _requestTimeout = Duration(seconds: 30);
const _loginTimeout = Duration(minutes: 5);
const _cleanupTimeout = Duration(seconds: 10);

typedef _DeviceLogin = ({
  String verificationUrl,
  String userCode,
  String loginId,
});

void main() {
  test('defaults to read-only status and guards interactive login', () {
    expect(_resolveAction(''), 'status');
    expect(
      () => _validateAction('login', interactive: false, isCi: false),
      throwsStateError,
    );
    expect(
      () => _validateAction('login', interactive: true, isCi: true),
      throwsStateError,
    );
    expect(
      () => _validateAction('login', interactive: true, isCi: false),
      returnsNormally,
    );
  });

  test('device-code response exposes only the login ceremony fields', () {
    final login = _parseDeviceLogin(<String, Object?>{
      'type': 'chatgptDeviceCode',
      'verificationUrl': 'https://auth.openai.com/codex/device',
      'userCode': 'ABCD-1234',
      'loginId': 'login-1',
      'accessToken': 'must-not-be-retained',
    });

    expect(login.verificationUrl, 'https://auth.openai.com/codex/device');
    expect(login.userCode, 'ABCD-1234');
    expect(login.loginId, 'login-1');
  });

  test('device-code response rejects non-canonical verification URLs', () {
    for (final verificationUrl in <String>[
      'https://example.com/codex/device',
      'https://auth.openai.com:444/codex/device',
      'https://user@auth.openai.com/codex/device',
      'https://auth.openai.com/codex/device?token=secret',
      'https://auth.openai.com/codex/device#fragment',
      'https://auth.openai.com/other',
    ]) {
      expect(
        () => _parseDeviceLogin(<String, Object?>{
          'type': 'chatgptDeviceCode',
          'verificationUrl': verificationUrl,
          'userCode': 'ABCD-1234',
          'loginId': 'login-1',
        }),
        throwsFormatException,
      );
    }
  });

  test('captures a safe cancel id before ceremony validation', () {
    String? cancelId;
    expect(
      () => _captureDeviceLogin(<String, Object?>{
        'type': 'chatgptDeviceCode',
        'verificationUrl': 'https://example.com/codex/device',
        'userCode': 'ABCD-1234',
        'loginId': 'login-1',
      }, (value) => cancelId = value),
      throwsFormatException,
    );
    expect(cancelId, 'login-1');
  });

  test(
    'late resource success is disposed and late errors are consumed',
    () async {
      final resourceCompleter = Completer<_TestResource>();
      final resource = _TestResource();
      await expectLater(
        _acquireBounded(
          resourceCompleter.future,
          timeout: const Duration(milliseconds: 1),
          disposeLate: (value) => value.dispose(),
        ),
        throwsA(isA<TimeoutException>()),
      );
      resourceCompleter.complete(resource);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resource.disposed, isTrue);

      final errorCompleter = Completer<_TestResource>();
      await expectLater(
        _acquireBounded(
          errorCompleter.future,
          timeout: const Duration(milliseconds: 1),
          disposeLate: (value) => value.dispose(),
        ),
        throwsA(isA<TimeoutException>()),
      );
      errorCompleter.completeError(StateError('late failure'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    },
  );

  test(
    'remote Codex account action',
    () async {
      final action = _resolveAction(_actionDefine);
      _validateAction(
        action,
        interactive: _interactiveLogin,
        isCi: _isCiEnvironment(),
      );

      final fixture = await loadFixture().timeout(_requestTimeout);
      final ssh = makeConnection(fixture);
      CodexTunnel? tunnel;
      CodexClient? client;
      String? pendingLoginId;
      var loginSucceeded = false;
      Object? sanitizedFailure;
      StackTrace? failureStack;

      try {
        await _acquireBounded<void>(
          ssh.connect(onFirstUseHostKey: (_) async => false),
          timeout: _requestTimeout,
          disposeLate: (_) => ssh.disconnect(),
        );
        tunnel = await _acquireBounded<CodexTunnel>(
          CodexTunnel.open(ssh, fixture['remoteCodexPort'] as int),
          timeout: _requestTimeout,
          disposeLate: (value) => value.close(),
        );
        client = await _acquireBounded<CodexClient>(
          CodexClient.connect(
            tunnel.uri,
            reconnectPolicy: const ReconnectPolicy(enabled: false),
          ),
          timeout: _requestTimeout,
          disposeLate: (value) => value.dispose(),
        );

        switch (action) {
          case 'status':
            await _printAuthenticationStatus(client);
          case 'logout':
            await client
                .request('account/logout', const <String, Object?>{})
                .timeout(_requestTimeout);
            final account = await _printAuthenticationStatus(client);
            if (account.isAuthenticated) {
              throw StateError('Remote account remains authenticated');
            }
          case 'login':
            final currentAccount = await client.readAccount().timeout(
              _requestTimeout,
            );
            if (currentAccount.isAuthenticated) {
              throw StateError('Remote account is already authenticated');
            }
            final result = await client
                .request('account/login/start', const <String, Object?>{
                  'type': 'chatgptDeviceCode',
                })
                .timeout(_requestTimeout);
            final login = _captureDeviceLogin(
              result,
              (value) => pendingLoginId = value,
            );

            // These are the only values needed to complete this login ceremony.
            // ignore: avoid_print
            print('verificationUrl=${login.verificationUrl}');
            // ignore: avoid_print
            print('userCode=${login.userCode}');

            final completed = await client.notifications
                .firstWhere(
                  (notification) =>
                      notification.method == 'account/login/completed' &&
                      notification.params['loginId'] == login.loginId,
                )
                .timeout(_loginTimeout);
            if (completed.params['success'] != true) {
              throw StateError('Remote device-code login was not successful');
            }

            loginSucceeded = true;
            final account = await _printAuthenticationStatus(client);
            if (!account.isAuthenticated) {
              throw StateError('Remote account is not authenticated');
            }
        }
      } on TimeoutException catch (_, stack) {
        sanitizedFailure = TimeoutException('Remote account action timed out');
        failureStack = stack;
      } catch (_, stack) {
        sanitizedFailure = StateError('Remote account action failed');
        failureStack = stack;
      } finally {
        if (!loginSucceeded && pendingLoginId != null && client != null) {
          try {
            await client
                .request('account/login/cancel', <String, Object?>{
                  'loginId': pendingLoginId,
                })
                .timeout(_requestTimeout);
          } catch (_) {
            // Cleanup is best effort and must not expose a remote response.
          }
        }
        try {
          await client?.dispose().timeout(_cleanupTimeout);
        } catch (_) {}
        try {
          await tunnel?.close().timeout(_cleanupTimeout);
        } catch (_) {}
        try {
          await ssh.disconnect().timeout(_cleanupTimeout);
        } catch (_) {}
      }

      if (sanitizedFailure != null) {
        Error.throwWithStackTrace(sanitizedFailure, failureStack!);
      }
    },
    skip: fixtureToken.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

String _resolveAction(String configuredAction) =>
    configuredAction.isEmpty ? 'status' : configuredAction;

void _validateAction(
  String action, {
  required bool interactive,
  required bool isCi,
}) {
  if (!const {'login', 'logout', 'status'}.contains(action)) {
    throw StateError('Unsupported POCKET_LOGIN_ACTION');
  }
  if (action == 'login' && (!interactive || isCi)) {
    throw StateError('Interactive device login is not explicitly enabled');
  }
}

bool _isCiEnvironment() {
  const ciKeys = <String>{
    'CI',
    'GITHUB_ACTIONS',
    'GITLAB_CI',
    'TF_BUILD',
    'JENKINS_URL',
    'BUILDKITE',
  };
  return ciKeys.any(Platform.environment.containsKey);
}

_DeviceLogin _captureDeviceLogin(
  Object? value,
  void Function(String loginId) recordCancelableLogin,
) {
  final loginId = _safeLoginId(value);
  if (loginId != null) recordCancelableLogin(loginId);
  return _parseDeviceLogin(value);
}

String? _safeLoginId(Object? value) {
  final loginId = jsonString(jsonMap(value)['loginId']);
  if (loginId == null ||
      !RegExp(r'^[A-Za-z0-9._:-]{1,256}$').hasMatch(loginId)) {
    return null;
  }
  return loginId;
}

_DeviceLogin _parseDeviceLogin(Object? value) {
  final response = jsonMap(value);
  final verificationUrl = jsonString(response['verificationUrl']);
  final userCode = jsonString(response['userCode']);
  final loginId = _safeLoginId(response);
  final uri = verificationUrl == null ? null : Uri.tryParse(verificationUrl);
  if (response['type'] != 'chatgptDeviceCode' ||
      verificationUrl == null ||
      uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host != 'auth.openai.com' ||
      uri.port != 443 ||
      uri.path != '/codex/device' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      userCode == null ||
      userCode.isEmpty ||
      loginId == null ||
      loginId.isEmpty) {
    throw const FormatException('Invalid device-code login response');
  }
  return (
    verificationUrl: verificationUrl,
    userCode: userCode,
    loginId: loginId,
  );
}

Future<T> _acquireBounded<T>(
  Future<T> acquisition, {
  required Duration timeout,
  required Future<void> Function(T value) disposeLate,
}) {
  var timedOut = false;
  acquisition.then<void>(
    (value) {
      if (timedOut) {
        unawaited(_disposeLate(value, disposeLate));
      }
    },
    onError: (Object _, StackTrace _) {
      // Consume errors from an acquisition that finishes after its deadline.
    },
  );
  return acquisition.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      throw TimeoutException('Resource acquisition timed out');
    },
  );
}

Future<void> _disposeLate<T>(
  T value,
  Future<void> Function(T value) dispose,
) async {
  try {
    await dispose(value).timeout(_cleanupTimeout);
  } catch (_) {
    // Late cleanup is best effort and must not leak remote details.
  }
}

Future<AccountStatus> _printAuthenticationStatus(CodexClient client) async {
  final account = await client.readAccount().timeout(_requestTimeout);
  // ignore: avoid_print
  print('authenticated=${account.isAuthenticated}');
  return account;
}

final class _TestResource {
  bool disposed = false;

  Future<void> dispose() async {
    disposed = true;
  }
}
