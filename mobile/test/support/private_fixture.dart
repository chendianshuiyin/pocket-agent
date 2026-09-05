import 'dart:convert';

Map<String, dynamic> decodePrivateFixture(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException();
    final fixture = decoded.map<String, dynamic>(
      (key, value) => MapEntry(key.toString(), value),
    );
    for (final key in const <String>[
      'id',
      'host',
      'username',
      'hostKeyType',
      'hostKeyFingerprint',
      'password',
      'cwd',
    ]) {
      final value = fixture[key];
      if (value is! String || value.isEmpty) throw const FormatException();
    }
    for (final key in const <String>['port', 'remoteCodexPort']) {
      final value = fixture[key];
      if (value is! int || value < 1 || value > 65535) {
        throw const FormatException();
      }
    }
    return fixture;
  } catch (_) {
    throw StateError('Private fixture is malformed');
  }
}
