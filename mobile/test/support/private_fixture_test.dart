import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'private_fixture.dart';

void main() {
  const secret = 'SYNTHETIC_DO_NOT_LEAK_92f16c';

  test('malformed JSON does not expose its source', () {
    _expectSanitizedFailure(utf8.encode('{"password":"$secret",'));
  });

  test('malformed UTF-8 does not expose decoded fixture content', () {
    _expectSanitizedFailure(<int>[...utf8.encode(secret), 0xff]);
  });

  test('invalid fixture shape does not expose parsed values', () {
    _expectSanitizedFailure(
      utf8.encode(jsonEncode(<String, Object?>{'password': secret})),
    );
  });
}

void _expectSanitizedFailure(List<int> bytes) {
  try {
    decodePrivateFixture(bytes);
    fail('Expected fixture decoding to fail');
  } catch (error) {
    expect(error, isA<StateError>());
    expect(error.toString(), 'Bad state: Private fixture is malformed');
    expect(error.toString(), isNot(contains('SYNTHETIC_DO_NOT_LEAK')));
  }
}
