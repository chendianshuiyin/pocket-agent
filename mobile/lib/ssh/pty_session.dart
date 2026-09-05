import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class PtySession {
  PtySession({required this.id, required SSHSession session})
    : _session = session,
      output = _mergeOutput(session),
      done = _waitForExit(session);

  final String id;
  final SSHSession _session;
  final Stream<Uint8List> output;
  final Future<int?> done;

  void write(String value) =>
      writeBytes(Uint8List.fromList(utf8.encode(value)));

  void writeBytes(Uint8List value) => _session.write(value);

  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    if (columns < 1 || rows < 1) {
      throw ArgumentError('Terminal dimensions must be positive');
    }
    _session.resizeTerminal(columns, rows, pixelWidth, pixelHeight);
  }

  Future<void> close() async {
    _session.close();
    try {
      await _session.done.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _session.channel.destroy();
    }
  }

  static Stream<Uint8List> _mergeOutput(SSHSession session) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? stdoutSubscription;
    StreamSubscription<Uint8List>? stderrSubscription;
    var openStreams = 2;

    void handleDone() {
      openStreams -= 1;
      if (openStreams == 0) unawaited(controller.close());
    }

    controller = StreamController<Uint8List>(
      onListen: () {
        stdoutSubscription = session.stdout.listen(
          controller.add,
          onError: controller.addError,
          onDone: handleDone,
        );
        stderrSubscription = session.stderr.listen(
          controller.add,
          onError: controller.addError,
          onDone: handleDone,
        );
      },
      onPause: () {
        stdoutSubscription?.pause();
        stderrSubscription?.pause();
      },
      onResume: () {
        stdoutSubscription?.resume();
        stderrSubscription?.resume();
      },
      onCancel: () async {
        await stdoutSubscription?.cancel();
        await stderrSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  static Future<int?> _waitForExit(SSHSession session) async {
    await session.done;
    return session.exitCode;
  }
}

class PersistentShell {
  const PersistentShell({required this.id, required this.attached});

  final String id;
  final bool attached;
}
