import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/ssh/codex_tunnel.dart';

void main() {
  test('bidirectional pump preserves final chunks before EOF', () async {
    final leftInput = StreamController<Uint8List>();
    final rightInput = StreamController<Uint8List>();
    final leftOutput = StreamController<List<int>>();
    final rightOutput = StreamController<List<int>>();
    final receivedByLeft = <int>[];
    final receivedByRight = <int>[];
    leftOutput.stream.listen(receivedByLeft.addAll);
    rightOutput.stream.listen(receivedByRight.addAll);

    final pumping = pumpBidirectionalStreams(
      leftInput: leftInput.stream,
      leftOutput: leftOutput.sink,
      rightInput: rightInput.stream,
      rightOutput: rightOutput.sink,
    );
    leftInput.add(Uint8List.fromList([1, 2]));
    rightInput.add(Uint8List.fromList([7]));
    leftInput.add(Uint8List.fromList([3]));
    rightInput.add(Uint8List.fromList([8, 9]));
    await leftInput.close();
    await rightInput.close();

    await pumping;
    expect(receivedByLeft, [7, 8, 9]);
    expect(receivedByRight, [1, 2, 3]);
  });
}
