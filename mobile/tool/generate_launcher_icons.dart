import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _protectedSetting =
    'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS';
final _protectedSettingPattern = RegExp(
  '^([ \\t]*$_protectedSetting[ \\t]*=[ \\t]*)([^;]*)(;.*)\$',
);

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--self-test') {
    _runSelfTest();
    return;
  }
  if (arguments.isNotEmpty) {
    stderr.writeln(
      'Usage: dart run tool/generate_launcher_icons.dart [--self-test]',
    );
    exitCode = 64;
    return;
  }

  final mobileRoot = File.fromUri(Platform.script).parent.parent;
  final projectFile = File(
    '${mobileRoot.path}/ios/Runner.xcodeproj/project.pbxproj',
  );
  if (!projectFile.existsSync()) {
    stderr.writeln('Missing Xcode project: ${projectFile.path}');
    exitCode = 1;
    return;
  }

  final projectBefore = projectFile.readAsStringSync();
  late final _XcodeSettingGuard guard;
  try {
    guard = _XcodeSettingGuard.capture(projectBefore);
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
    return;
  }

  final process = await Process.start(
    Platform.resolvedExecutable,
    const <String>[
      'run',
      'flutter_launcher_icons',
      '-f',
      'flutter_launcher_icons.yaml',
    ],
    workingDirectory: mobileRoot.path,
  );
  final outputTasks = <Future<void>>[
    stdout.addStream(process.stdout),
    stderr.addStream(process.stderr),
  ];
  final generatorExitCode = await process.exitCode;
  await Future.wait(outputTasks);

  final projectAfter = projectFile.readAsStringSync();
  late final _GuardResult result;
  try {
    result = guard.restore(projectAfter);
  } on StateError catch (error) {
    stderr.writeln(
      'Refusing to update the Xcode project because the protected setting '
      'changed unexpectedly: ${error.message}',
    );
    exitCode = 1;
    return;
  }

  if (result.hasUnexpectedChanges) {
    stderr.writeln(
      'Launcher icons were generated, but the Xcode project also received '
      'unexpected changes. The entire project file was preserved as generated '
      'for review; no guarded restoration was written.',
    );
    exitCode = 1;
    return;
  }

  if (result.restoredProject != projectAfter) {
    if (projectFile.readAsStringSync() != projectAfter) {
      stderr.writeln(
        'Refusing to update the Xcode project because it changed while the '
        'launcher icon guard was running.',
      );
      exitCode = 1;
      return;
    }
    projectFile.writeAsStringSync(result.restoredProject, flush: true);
  }

  if (generatorExitCode != 0) {
    stderr.writeln(
      'flutter_launcher_icons failed with exit code $generatorExitCode. The '
      'protected Xcode setting was restored.',
    );
    exitCode = generatorExitCode;
    return;
  }

  stdout.writeln('Launcher icons generated with Xcode settings preserved.');
}

class _XcodeSettingGuard {
  _XcodeSettingGuard._(this._linesBefore, this._originalValues);

  factory _XcodeSettingGuard.capture(String project) {
    final lines = const LineSplitter().convert(project);
    final values = <String>[];
    for (final line in lines) {
      final match = _protectedSettingPattern.firstMatch(line);
      if (match != null) {
        values.add(match.group(2)!);
      }
    }
    if (values.isEmpty) {
      throw StateError('Xcode project does not contain $_protectedSetting.');
    }
    return _XcodeSettingGuard._(lines, values);
  }

  final List<String> _linesBefore;
  final List<String> _originalValues;

  _GuardResult restore(String projectAfter) {
    final linesAfter = const LineSplitter().convert(projectAfter);
    final restoredLines = <String>[];
    var protectedIndex = 0;

    for (final line in linesAfter) {
      final match = _protectedSettingPattern.firstMatch(line);
      if (match == null) {
        restoredLines.add(line);
        continue;
      }
      if (protectedIndex >= _originalValues.length) {
        throw StateError('The protected setting gained an extra occurrence.');
      }

      final originalValue = _originalValues[protectedIndex];
      final currentValue = match.group(2)!;
      if (currentValue.trim() != 'AppIcon' &&
          currentValue.trim() != originalValue.trim()) {
        throw StateError(
          'Occurrence ${protectedIndex + 1} changed to '
          '"${currentValue.trim()}" instead of the generator value "AppIcon".',
        );
      }
      restoredLines.add('${match.group(1)}$originalValue${match.group(3)}');
      protectedIndex++;
    }

    if (protectedIndex != _originalValues.length) {
      throw StateError('The protected setting lost an occurrence.');
    }

    final restoredProject = '${restoredLines.join('\n')}\n';
    return _GuardResult(
      restoredProject: restoredProject,
      hasUnexpectedChanges: !_sameLines(restoredLines, _linesBefore),
    );
  }
}

class _GuardResult {
  const _GuardResult({
    required this.restoredProject,
    required this.hasUnexpectedChanges,
  });

  final String restoredProject;
  final bool hasUnexpectedChanges;
}

bool _sameLines(List<String> first, List<String> second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

void _runSelfTest() {
  const before =
      '''// project
KEEP_SETTING = unchanged;
$_protectedSetting = YES;
  $_protectedSetting = NO;
''';
  const generated =
      '''// project
KEEP_SETTING = unchanged;
$_protectedSetting = AppIcon;
  $_protectedSetting = AppIcon;
''';

  final guard = _XcodeSettingGuard.capture(before);
  final restored = guard.restore(generated);
  _check(!restored.hasUnexpectedChanges, 'Expected generator-only changes.');
  _check(
    restored.restoredProject == before,
    'YES/NO values were not preserved.',
  );

  final withOtherEdit = generated.replaceFirst(
    'KEEP_SETTING = unchanged;',
    'KEEP_SETTING = user_edit;',
  );
  final guardedOtherEdit = guard.restore(withOtherEdit);
  _check(
    guardedOtherEdit.hasUnexpectedChanges,
    'Other edits must fail closed.',
  );
  _check(
    guardedOtherEdit.restoredProject.contains('KEEP_SETTING = user_edit;'),
    'Other edits must not be overwritten.',
  );
  _check(
    guardedOtherEdit.restoredProject.contains('$_protectedSetting = YES;') &&
        guardedOtherEdit.restoredProject.contains('  $_protectedSetting = NO;'),
    'Protected values must still be restored when another edit is detected.',
  );

  var rejectedConflict = false;
  try {
    guard.restore(generated.replaceFirst('AppIcon', 'user_value'));
  } on StateError {
    rejectedConflict = true;
  }
  _check(rejectedConflict, 'Conflicting protected edits must be rejected.');

  stdout.writeln(
    'Launcher icon guard self-test passed: YES/NO preservation, fail-closed '
    'diff detection, and conflict rejection.',
  );
}

void _check(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
