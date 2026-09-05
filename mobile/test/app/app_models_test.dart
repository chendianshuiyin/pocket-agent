import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/app/app_models.dart';

void main() {
  test(
    'terminal decodes UTF-8 characters split across output chunks',
    () async {
      final handle = _FakeShellHandle();
      final session = TerminalSessionModel(
        id: 'shell-1',
        title: 'UTF-8',
        persistent: false,
        handle: handle,
      );
      final bytes = utf8.encode('中🙂文\r\n');

      for (final byte in bytes) {
        handle.add([byte]);
      }
      await handle.finish();

      final output = session.terminal.buffer.getText();
      expect(output, contains('中🙂文'));
      expect(output, isNot(contains('�')));
      expect(output, isNot(contains('终端连接发生错误')));
      await session.dispose();
    },
  );

  test(
    'terminal replaces an incomplete UTF-8 tail without stream failure',
    () async {
      final handle = _FakeShellHandle();
      final session = TerminalSessionModel(
        id: 'shell-2',
        title: 'truncated UTF-8',
        persistent: false,
        handle: handle,
      );
      final incomplete = utf8.encode('尾').sublist(0, 2);

      handle.add(incomplete);
      await handle.finish();

      final output = session.terminal.buffer.getText();
      expect(output, contains('�'));
      expect(output, contains('会话已结束'));
      expect(output, isNot(contains('终端连接发生错误')));
      await session.dispose();
    },
  );
}

class _FakeShellHandle implements ShellHandle {
  final _output = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get output => _output.stream;

  void add(List<int> bytes) => _output.add(Uint8List.fromList(bytes));

  Future<void> finish() => _output.close();

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  void write(String data) {}
}
