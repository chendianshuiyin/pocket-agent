import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _sourcePath = 'assets/brand/agent-portrait-candidate.png';
const _sourceSha256 =
    '33fe04a8538f297de60ced7e1e29900848f3247bbf5cb178c99aec2bbcf098d9';

void main() {
  final failures = <String>[];

  final source = File(_sourcePath);
  _expect(
    source.existsSync(),
    'Missing launcher source: $_sourcePath',
    failures,
  );
  if (source.existsSync()) {
    final sourceBytes = source.readAsBytesSync();
    final sourceInfo = _readPng(source.path, failures);
    _expect(
      sha256.convert(sourceBytes).toString() == _sourceSha256,
      'Launcher source digest changed; update the candidate and checksum '
      'intentionally before regenerating icons.',
      failures,
    );
    _expect(
      sourceInfo?.width == sourceInfo?.height && sourceInfo?.width == 1254,
      'Launcher source must remain the original 1254x1254 square PNG.',
      failures,
    );
  }

  _verifyAndroid(failures);
  _verifyIos(failures);

  if (failures.isNotEmpty) {
    stderr.writeln('Launcher icon verification failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Launcher icons verified: source integrity, Android legacy/adaptive, '
    'and iOS catalog dimensions/alpha.',
  );
}

void _verifyAndroid(List<String> failures) {
  const legacySizes = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  for (final entry in legacySizes.entries) {
    final path = 'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png';
    final info = _readPng(path, failures);
    _expect(
      info?.width == entry.value && info?.height == entry.value,
      '$path must be ${entry.value}x${entry.value}.',
      failures,
    );
  }

  const adaptivePath =
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml';
  final adaptiveFile = File(adaptivePath);
  _expect(adaptiveFile.existsSync(), 'Missing $adaptivePath', failures);
  if (adaptiveFile.existsSync()) {
    final xml = adaptiveFile.readAsStringSync();
    _expect(
      xml.contains('@color/ic_launcher_background'),
      '$adaptivePath must reference @color/ic_launcher_background.',
      failures,
    );
    _expect(
      xml.contains('@drawable/ic_launcher_foreground'),
      '$adaptivePath must reference @drawable/ic_launcher_foreground.',
      failures,
    );
    _expect(
      xml.contains('android:inset="16%"'),
      '$adaptivePath must retain the configured 16% foreground inset.',
      failures,
    );
  }

  const backgroundPath = 'android/app/src/main/res/values/colors.xml';
  final backgroundFile = File(backgroundPath);
  _expect(backgroundFile.existsSync(), 'Missing $backgroundPath', failures);
  if (backgroundFile.existsSync()) {
    _expect(
      backgroundFile.readAsStringSync().contains('#1D2B3D'),
      '$backgroundPath must retain the configured #1D2B3D background.',
      failures,
    );
  }

  for (final density in legacySizes.keys) {
    final path =
        'android/app/src/main/res/drawable-$density/'
        'ic_launcher_foreground.png';
    final densityScale = switch (density) {
      'mdpi' => 1,
      'hdpi' => 1.5,
      'xhdpi' => 2,
      'xxhdpi' => 3,
      'xxxhdpi' => 4,
      _ => throw StateError('Unsupported Android density: $density'),
    };
    final expectedPixels = (108 * densityScale).round();
    final info = _readPng(path, failures);
    _expect(
      info?.width == expectedPixels && info?.height == expectedPixels,
      '$path must be ${expectedPixels}x$expectedPixels.',
      failures,
    );
  }

  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  final manifest = File(manifestPath);
  _expect(manifest.existsSync(), 'Missing $manifestPath', failures);
  if (manifest.existsSync()) {
    _expect(
      manifest.readAsStringSync().contains(
        'android:icon="@mipmap/ic_launcher"',
      ),
      '$manifestPath must reference @mipmap/ic_launcher.',
      failures,
    );
  }
}

void _verifyIos(List<String> failures) {
  const catalogPath = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final contentsFile = File('$catalogPath/Contents.json');
  _expect(contentsFile.existsSync(), 'Missing ${contentsFile.path}', failures);
  if (!contentsFile.existsSync()) {
    return;
  }

  final contents = jsonDecode(contentsFile.readAsStringSync());
  if (contents is! Map<String, dynamic> || contents['images'] is! List) {
    failures.add('${contentsFile.path} has an invalid images catalog.');
    return;
  }

  final images = contents['images'] as List<dynamic>;
  _expect(images.isNotEmpty, '${contentsFile.path} has no images.', failures);
  for (final rawImage in images) {
    if (rawImage is! Map<String, dynamic>) {
      failures.add('${contentsFile.path} contains an invalid image entry.');
      continue;
    }

    final filename = rawImage['filename'] as String?;
    final size = rawImage['size'] as String?;
    final scaleText = rawImage['scale'] as String?;
    if (filename == null || size == null || scaleText == null) {
      failures.add(
        'Every iOS AppIcon entry must reference a file, size, and scale.',
      );
      continue;
    }

    final logicalWidth = double.tryParse(size.split('x').first);
    final scale = double.tryParse(scaleText.replaceAll('x', ''));
    if (logicalWidth == null || scale == null) {
      failures.add('Invalid iOS AppIcon size metadata for $filename.');
      continue;
    }

    final expectedPixels = (logicalWidth * scale).round();
    final path = '$catalogPath/$filename';
    final info = _readPng(path, failures);
    _expect(
      info?.width == expectedPixels && info?.height == expectedPixels,
      '$path must be ${expectedPixels}x$expectedPixels.',
      failures,
    );
    _expect(
      info != null && !info.hasAlpha,
      '$path must not contain an alpha channel.',
      failures,
    );
    _expect(
      info?.bitDepth == 8 && info?.colorType == 2,
      '$path must be an 8-bit RGB PNG (color type 2).',
      failures,
    );
  }

  const projectPath = 'ios/Runner.xcodeproj/project.pbxproj';
  final project = File(projectPath);
  _expect(project.existsSync(), 'Missing $projectPath', failures);
  if (project.existsSync()) {
    final projectText = project.readAsStringSync();
    _expect(
      !projectText.contains(
        'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = '
        'AppIcon;',
      ),
      '$projectPath contains a flutter_launcher_icons 0.14.4 build-setting '
      'regression; restore GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS to YES.',
      failures,
    );
  }
}

_PngInfo? _readPng(String path, List<String> failures) {
  final file = File(path);
  if (!file.existsSync()) {
    failures.add('Missing PNG: $path');
    return null;
  }

  final bytes = file.readAsBytesSync();
  const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 26) {
    failures.add('Invalid PNG header: $path');
    return null;
  }
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) {
      failures.add('Invalid PNG signature: $path');
      return null;
    }
  }

  final data = ByteData.sublistView(bytes);
  final firstChunkLength = data.getUint32(8, Endian.big);
  final firstChunkType = String.fromCharCodes(bytes.sublist(12, 16));
  if (firstChunkLength != 13 || firstChunkType != 'IHDR') {
    failures.add('PNG must begin with a 13-byte IHDR chunk: $path');
    return null;
  }

  var hasTransparencyChunk = false;
  var sawIend = false;
  var chunkOffset = 8;
  while (chunkOffset + 12 <= bytes.length) {
    final chunkLength = data.getUint32(chunkOffset, Endian.big);
    final chunkEnd = chunkOffset + 12 + chunkLength;
    if (chunkEnd > bytes.length) {
      failures.add('Invalid PNG chunk length: $path');
      return null;
    }
    final chunkType = String.fromCharCodes(
      bytes.sublist(chunkOffset + 4, chunkOffset + 8),
    );
    hasTransparencyChunk |= chunkType == 'tRNS';
    chunkOffset = chunkEnd;
    if (chunkType == 'IEND') {
      if (chunkLength != 0) {
        failures.add('PNG IEND chunk must be empty: $path');
        return null;
      }
      sawIend = true;
      break;
    }
  }
  if (!sawIend || chunkOffset != bytes.length) {
    failures.add('PNG must end at a complete IEND chunk: $path');
    return null;
  }

  final width = data.getUint32(16, Endian.big);
  final height = data.getUint32(20, Endian.big);
  if (width == 0 || height == 0) {
    failures.add('PNG dimensions must be positive: $path');
    return null;
  }

  return _PngInfo(
    width: width,
    height: height,
    bitDepth: bytes[24],
    colorType: bytes[25],
    hasTransparencyChunk: hasTransparencyChunk,
  );
}

void _expect(bool condition, String message, List<String> failures) {
  if (!condition) {
    failures.add(message);
  }
}

class _PngInfo {
  const _PngInfo({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.hasTransparencyChunk,
  });

  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final bool hasTransparencyChunk;

  bool get hasAlpha => colorType == 4 || colorType == 6 || hasTransparencyChunk;
}
