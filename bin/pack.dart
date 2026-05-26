import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';

const _abiPriority = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];
const _flutterAssetsPrefix = 'assets/flutter_assets/';
const _assetManifestPath = '${_flutterAssetsPrefix}AssetManifest.bin';

Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'apk',
      abbr: 'a',
      help: 'Path to the release APK to extract libapp.so and assets from.',
    )
    ..addMultiOption(
      'assets',
      help: 'Flutter asset key(s) from pubspec.yaml to include in patch.zip. '
          'Can be repeated or comma-separated. '
          'Use --assets @path/to/list.txt to read keys from a UTF-8 file '
          '(one per line, # starts comments). Inline keys and @file can be mixed: '
          '--assets @list.txt,assets/extra.png',
    )
    ..addOption(
      'version',
      help: 'Patch version string (goes into manifest.version).',
    )
    ..addOption(
      'target-version-code',
      help: 'Host APK versionCode the patch is built for (integer).',
    )
    ..addOption(
      'abi',
      help: 'ABI to extract. Default: first match among $_abiPriority.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Output directory. Created if absent.',
      defaultsTo: 'dist',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln(parser.usage);
    return 64;
  }

  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher pack CLI\n');
    stdout.writeln('usage: dart run flutter_patcher:pack [options]\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  final apkPath = args['apk'] as String?;
  final version = args['version'] as String?;
  final vcRaw = args['target-version-code'] as String?;
  if (apkPath == null || version == null || vcRaw == null) {
    stderr.writeln(
      'error: --apk, --version, --target-version-code are required.',
    );
    stderr.writeln(parser.usage);
    return 64;
  }

  final targetVersionCode = int.tryParse(vcRaw);
  if (targetVersionCode == null) {
    stderr.writeln('error: --target-version-code must be an integer.');
    return 64;
  }

  final preferredAbi = args['abi'] as String?;
  final outDir = Directory(args['out'] as String);
  final List<String> requestedAssets;
  try {
    requestedAssets = _readRequestedAssets(
      assetsArgs: args['assets'] as List<String>,
    );
  } on PackException catch (e) {
    stderr.writeln('error: ${e.message}');
    return e.exitCode;
  }

  final apkFile = File(apkPath);
  if (!apkFile.existsSync()) {
    stderr.writeln('error: APK not found: $apkPath');
    return 66;
  }

  stdout.writeln('[pack] reading ${apkFile.path}');
  final apkBytes = apkFile.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(apkBytes);

  final chosen = _pickLibappSo(archive, preferredAbi);
  if (chosen == null) {
    stderr.writeln(
      'error: libapp.so not found in APK for any of $_abiPriority '
      '(or requested --abi $preferredAbi).',
    );
    return 1;
  }

  final abi = chosen.$1;
  final soBytes = _archiveFileBytes(chosen.$2);
  stdout.writeln(
    '[pack] extracted lib/$abi/libapp.so (${_fmtBytes(soBytes.length)})',
  );

  outDir.createSync(recursive: true);
  try {
    _writePatchPackage(
      outDir: outDir,
      archive: archive,
      abi: abi,
      soBytes: soBytes,
      version: version,
      targetVersionCode: targetVersionCode,
      requestedAssets: requestedAssets,
    );
    return 0;
  } on PackException catch (e) {
    stderr.writeln('error: ${e.message}');
    return e.exitCode;
  }
}

void _writePatchPackage({
  required Directory outDir,
  required Archive archive,
  required String abi,
  required List<int> soBytes,
  required String version,
  required int targetVersionCode,
  required List<String> requestedAssets,
}) {
  final patchFiles = <String, _PatchAssetFile>{};
  final operations = <Map<String, dynamic>>[];
  var baseManifestSize = 0;

  if (requestedAssets.isNotEmpty) {
    final manifestEntry = _findFile(archive, _assetManifestPath);
    if (manifestEntry == null) {
      throw PackException(
        'AssetManifest.bin not found in APK: $_assetManifestPath',
        65,
      );
    }
    final manifestBytes = _archiveFileBytes(manifestEntry);
    baseManifestSize = manifestBytes.length;
    final decoded = _FlutterStandardMessageCodec().decode(manifestBytes);
    if (decoded is! Map) {
      throw PackException('AssetManifest.bin must decode to a map.', 65);
    }
    final assetManifest = Map<String, dynamic>.from(decoded);

    for (final key in requestedAssets) {
      final variantsRaw = assetManifest[key];
      if (variantsRaw is! List) {
        throw PackException('asset key not found in AssetManifest.bin: $key', 65);
      }
      final variants = variantsRaw
          .map((variant) => Map<String, dynamic>.from(variant as Map))
          .toList(growable: false);
      operations.add({
        'op': 'upsert',
        'key': key,
        'variants': variants,
      });
      for (final variant in variants) {
        final assetPath = variant['asset'];
        if (assetPath is! String || assetPath.isEmpty) {
          throw PackException('invalid variant asset for key $key', 65);
        }
        _validateArchiveRelativePath(assetPath, 'asset path');
        final apkPath = '$_flutterAssetsPrefix$assetPath';
        final entry = _findFile(archive, apkPath);
        if (entry == null) {
          throw PackException(
            'variant file for $key not found in APK: $apkPath',
            65,
          );
        }
        final bytes = _archiveFileBytes(entry);
        patchFiles[assetPath] = _PatchAssetFile(
          path: assetPath,
          bytes: bytes,
          md5Hex: md5.convert(bytes).toString(),
        );
      }
    }
  }

  final zipManifest = <String, dynamic>{
    'schemaVersion': 2,
    'version': version,
    'targetVersionCode': targetVersionCode,
    'lib': {
      abi: {
        'path': 'lib/$abi/libapp.so',
        'md5': md5.convert(soBytes).toString(),
      },
    },
    if (requestedAssets.isNotEmpty)
      'assets': {
        'mode': 'overlay',
        'manifestPatch': 'manifest_patch.json',
        'prefix': 'assets/',
        'files': patchFiles.values
            .map((file) => {
                  'path': file.path,
                  'md5': file.md5Hex,
                  'size': file.bytes.length,
                })
            .toList(),
      },
  };

  final package = Archive()
    ..addFile(_jsonArchiveFile('manifest.json', zipManifest))
    ..addFile(ArchiveFile('lib/$abi/libapp.so', soBytes.length, soBytes));

  if (requestedAssets.isNotEmpty) {
    final manifestPatch = <String, dynamic>{
      'schemaVersion': 1,
      'manifestFormat': 'bin',
      'baseManifestSize': baseManifestSize,
      'operations': operations,
    };
    package.addFile(_jsonArchiveFile('manifest_patch.json', manifestPatch));
    for (final file in patchFiles.values) {
      package.addFile(
        ArchiveFile('assets/${file.path}', file.bytes.length, file.bytes),
      );
    }
  }

  final packageBytes = ZipEncoder().encode(package);
  final outZip = File('${outDir.path}/patch.zip');
  outZip.writeAsBytesSync(packageBytes);

  final payloadMd5 = md5.convert(packageBytes).toString();
  final outerManifest = <String, dynamic>{
    'schemaVersion': 2,
    'version': version,
    'md5': payloadMd5,
    'targetVersionCode': targetVersionCode,
    'abi': abi,
    'payload': 'patch.zip',
  };
  _writeJson(File('${outDir.path}/manifest.json'), outerManifest);

  if (requestedAssets.isNotEmpty) {
    stdout.writeln('[pack] assets: ${requestedAssets.length} key(s)');
    stdout.writeln('[pack] overlay files: ${patchFiles.length}');
  }
  stdout.writeln('[pack] payload: ${outZip.path}');
  stdout.writeln('[pack] md5: $payloadMd5');
  stdout.writeln('[pack] manifest: ${outDir.path}/manifest.json');
}

ArchiveFile _jsonArchiveFile(String name, Map<String, dynamic> json) {
  final bytes =
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(json)}\n');
  return ArchiveFile(name, bytes.length, bytes);
}

List<String> _readRequestedAssets({
  Iterable<String> assetsArgs = const [],
}) {
  final result = <String>[];
  final seen = <String>{};

  void appendKey(String raw, {required String source}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return;
    if (trimmed.startsWith('@')) {
      throw PackException(
        'nested @-includes are not supported inside $source. '
        'List asset keys directly, one per line.',
        65,
      );
    }
    final normalized = trimmed.replaceAll('\\', '/');
    _validateArchiveRelativePath(normalized, 'asset key');
    if (seen.add(normalized)) result.add(normalized);
  }

  for (final assetsArg in assetsArgs) {
    if (assetsArg.trim().isEmpty) continue;
    for (final token in assetsArg.split(',')) {
      final trimmed = token.trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.startsWith('@')) {
        appendKey(trimmed, source: '--assets');
        continue;
      }
      final filePath = trimmed.substring(1);
      if (filePath.isEmpty) {
        throw PackException(
          'invalid --assets value: "@" must be followed by a file path.',
          64,
        );
      }
      final file = File(filePath);
      if (!file.existsSync()) {
        throw PackException('asset list file not found: $filePath', 66);
      }
      final List<String> lines;
      try {
        lines = file.readAsLinesSync();
      } on FileSystemException catch (e) {
        throw PackException(
          'failed to read asset list as UTF-8 text: $filePath. '
          'For a single binary asset, drop the "@" and pass the path directly. '
          '(${e.message})',
          65,
        );
      }
      for (final line in lines) {
        appendKey(line, source: filePath);
      }
    }
  }
  return result;
}

(String, ArchiveFile)? _pickLibappSo(Archive archive, String? preferred) {
  final map = <String, ArchiveFile>{};
  final regex = RegExp(r'^lib/([^/]+)/libapp\.so$');
  for (final file in archive.files) {
    final m = regex.firstMatch(file.name);
    if (m != null) map[m.group(1)!] = file;
  }
  if (preferred != null) {
    final hit = map[preferred];
    if (hit != null) return (preferred, hit);
    stderr.writeln('warning: --abi $preferred not in APK; falling back');
  }
  for (final abi in _abiPriority) {
    final hit = map[abi];
    if (hit != null) return (abi, hit);
  }
  return null;
}

ArchiveFile? _findFile(Archive archive, String name) {
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (file.name == name) return file;
  }
  return null;
}

void _writeJson(File file, Map<String, dynamic> json) {
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n');
}

void _validateArchiveRelativePath(String path, String label) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      path.contains('\u0000') ||
      path.split('/').contains('..')) {
    throw PackException('invalid $label: $path', 65);
  }
}

String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
}

List<int> _archiveFileBytes(ArchiveFile file) {
  final dynamic dynamicFile = file;
  try {
    return List<int>.from(dynamicFile.readBytes() as List<int>);
  } on NoSuchMethodError {
    return List<int>.from(dynamicFile.content as List<int>);
  }
}

class _PatchAssetFile {
  const _PatchAssetFile({
    required this.path,
    required this.bytes,
    required this.md5Hex,
  });

  final String path;
  final List<int> bytes;
  final String md5Hex;
}

class PackException implements Exception {
  const PackException(this.message, this.exitCode);

  final String message;
  final int exitCode;
}

class _FlutterStandardMessageCodec {
  late ByteData _data;
  late int _offset;

  Object? decode(List<int> bytes) {
    final list = Uint8List.fromList(bytes);
    _data = ByteData.sublistView(list);
    _offset = 0;
    final value = _readValue();
    if (_offset != _data.lengthInBytes) {
      throw PackException('AssetManifest.bin has trailing bytes.', 65);
    }
    return value;
  }

  Object? _readValue() {
    final type = _readUint8();
    switch (type) {
      case 0:
        return null;
      case 1:
        return true;
      case 2:
        return false;
      case 3:
        return _readInt32();
      case 4:
        return _readInt64();
      case 6:
        _alignTo(8);
        return _readFloat64();
      case 7:
        final len = _readSize();
        final bytes = _readBytes(len);
        return utf8.decode(bytes);
      case 12:
        final len = _readSize();
        return List<Object?>.generate(len, (_) => _readValue());
      case 13:
        final len = _readSize();
        final map = <Object?, Object?>{};
        for (var i = 0; i < len; i++) {
          map[_readValue()] = _readValue();
        }
        return map;
      default:
        throw PackException(
          'unsupported StandardMessageCodec type in AssetManifest.bin: $type',
          65,
        );
    }
  }

  int _readSize() {
    final first = _readUint8();
    if (first < 254) return first;
    if (first == 254) return _readUint16();
    return _readUint32();
  }

  int _readUint8() {
    _ensure(1);
    return _data.getUint8(_offset++);
  }

  int _readUint16() {
    _ensure(2);
    final value = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  int _readUint32() {
    _ensure(4);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int _readInt32() {
    _ensure(4);
    final value = _data.getInt32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int _readInt64() {
    _ensure(8);
    final value = _data.getInt64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  double _readFloat64() {
    _ensure(8);
    final value = _data.getFloat64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  Uint8List _readBytes(int length) {
    _ensure(length);
    final start = _offset;
    _offset += length;
    return _data.buffer.asUint8List(start, length);
  }

  void _alignTo(int alignment) {
    final mod = _offset % alignment;
    if (mod != 0) _offset += alignment - mod;
  }

  void _ensure(int length) {
    if (_offset + length > _data.lengthInBytes) {
      throw PackException('truncated AssetManifest.bin', 65);
    }
  }
}
