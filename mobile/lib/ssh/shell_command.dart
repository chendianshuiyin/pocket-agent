final RegExp _safeExecutable = RegExp(r'^[A-Za-z0-9_./+-]+$');

String quoteShellArgument(String value) {
  if (value.contains('\u0000')) {
    throw ArgumentError.value(value, 'value', 'must not contain NUL');
  }
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}

String buildShellCommand(String executable, Iterable<String> arguments) {
  if (executable.isEmpty || !_safeExecutable.hasMatch(executable)) {
    throw ArgumentError.value(
      executable,
      'executable',
      'contains unsupported shell characters',
    );
  }
  return <String>[executable, ...arguments.map(quoteShellArgument)].join(' ');
}

String validatePocketSessionId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(id)) {
    throw ArgumentError.value(id, 'id', 'must match [A-Za-z0-9_-]{1,48}');
  }
  return id;
}
