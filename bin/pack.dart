import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher/src/delta.dart';
import 'package:flutter_patcher/src/signing.dart';

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
    ..addOption(
      'base-apk',
      help: 'Optional path to the BASE release APK this patch upgrades FROM. '
          'Records the base libapp.so SHA-256 so the device refuses to apply '
          'the patch onto a different same-versionCode base (engine drift).',
    )
    ..addOption(
      'from-apk',
      help: 'Optional BASE release APK to DELTA against (implies base fingerprint). '
          'Ships a per-ABI binary diff instead of the full libapp.so; the device '
          'reconstructs and verifies. Falls back to full per-ABI when no saving. '
          'Mutually exclusive with --base-apk.',
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
      'patch-number',
      help: 'Monotonic patch sequence number (integer). Bound into the signed '
          'manifest and enforced for downgrade protection on device.',
    )
    ..addOption(
      'key',
      help: 'Ed25519 signing seed (base64 from `keygen`), or @path/to/seed file. '
          'When set, the manifest is signed in place (requires --patch-number). '
          'Without it the patch is unsigned (integrity-only).',
    )
    ..addOption(
      'rollout-percent',
      help: 'Staged rollout percentage 0–100. When set, signs a v2 manifest and '
          'only that slice of installs applies the patch. Default: 100 (everyone).',
    )
    ..addOption(
      'channel',
      help: 'Optional release channel label (e.g. beta), bound into the v2 manifest.',
    )
    ..addOption(
      'abi',
      help: 'ABI(s) to pack, comma-separated (e.g. arm64-v8a,armeabi-v7a). '
          'Default: every ABI present in the APK. The device picks its own.',
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

  final pnRaw = args['patch-number'] as String?;
  final int? patchNumber;
  if (pnRaw == null) {
    patchNumber = null;
  } else {
    patchNumber = int.tryParse(pnRaw);
    if (patchNumber == null) {
      stderr.writeln('error: --patch-number must be an integer.');
      return 64;
    }
  }

  // Resolve the optional signing seed (literal base64 or @file).
  String? signingSeed;
  final keyArg = args['key'] as String?;
  if (keyArg != null && keyArg.isNotEmpty) {
    if (keyArg.startsWith('@')) {
      final keyFile = File(keyArg.substring(1));
      if (!keyFile.existsSync()) {
        stderr.writeln('error: --key file not found: ${keyArg.substring(1)}');
        return 66;
      }
      signingSeed = keyFile.readAsStringSync().trim();
    } else {
      signingSeed = keyArg.trim();
    }
    if (patchNumber == null) {
      stderr.writeln('error: signing (--key) requires --patch-number.');
      return 64;
    }
  }

  // Staged rollout (v2 manifest). Present iff --rollout-percent or --channel set.
  final rolloutRaw = args['rollout-percent'] as String?;
  final channelArg = args['channel'] as String?;
  int? rolloutPercent;
  if (rolloutRaw != null) {
    rolloutPercent = int.tryParse(rolloutRaw);
    if (rolloutPercent == null || rolloutPercent < 0 || rolloutPercent > 100) {
      stderr.writeln('error: --rollout-percent must be an integer 0–100.');
      return 64;
    }
  }
  final useV2 = rolloutRaw != null || (channelArg?.isNotEmpty ?? false);
  if (useV2 && signingSeed == null) {
    stderr.writeln('error: --rollout-percent/--channel require --key (rollout '
        'must be signed to be enforced on device).');
    return 64;
  }
  final int? rolloutPercentFinal = useV2 ? (rolloutPercent ?? 100) : null;
  final channelFinal = channelArg ?? '';

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

  final available = _collectLibappSo(archive);
  if (available.isEmpty) {
    stderr.writeln('error: no lib/<abi>/libapp.so found in APK.');
    return 1;
  }

  // --abi accepts a comma-separated list; default = every ABI in the APK.
  final requestedAbis = (preferredAbi == null || preferredAbi.trim().isEmpty)
      ? <String>[]
      : preferredAbi.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  final List<String> abis;
  if (requestedAbis.isEmpty) {
    abis = available.keys.toList();
  } else {
    for (final a in requestedAbis) {
      if (!available.containsKey(a)) {
        stderr.writeln('error: requested --abi $a not in APK '
            '(present: ${available.keys.join(", ")}).');
        return 1;
      }
    }
    abis = requestedAbis;
  }

  // Optional base APK. --base-apk only fingerprints (full payload + drift guard);
  // --from-apk additionally produces a per-ABI binary delta against that base.
  final baseApkPath = args['base-apk'] as String?;
  final fromApkPath = args['from-apk'] as String?;
  if (baseApkPath != null && fromApkPath != null) {
    stderr.writeln('error: use --base-apk OR --from-apk, not both.');
    return 64;
  }
  final deltaMode = fromApkPath != null;
  final basePath = fromApkPath ?? baseApkPath;
  Archive? baseArchive;
  if (basePath != null) {
    final baseApk = File(basePath);
    if (!baseApk.existsSync()) {
      stderr.writeln('error: base APK not found: $basePath');
      return 66;
    }
    baseArchive = ZipDecoder().decodeBytes(baseApk.readAsBytesSync());
  }

  final libVariants = <_LibVariant>[];
  for (final abi in abis) {
    final soBytes = Uint8List.fromList(_archiveFileBytes(available[abi]!));
    String? baseLibSha256;
    Uint8List? deltaBytes;
    String? newLibSha256;
    if (baseArchive != null) {
      final baseSo = _findFile(baseArchive, 'lib/$abi/libapp.so');
      if (baseSo == null) {
        stderr.writeln('error: lib/$abi/libapp.so not found in base APK.');
        return 1;
      }
      final baseBytes = Uint8List.fromList(_archiveFileBytes(baseSo));
      baseLibSha256 = sha256.convert(baseBytes).toString();
      if (deltaMode) {
        final delta = DeltaCodec.buildDelta(baseBytes, soBytes);
        // Only ship a delta when it actually saves (< 90% of the full .so).
        if (delta.length < (soBytes.length * 9) ~/ 10) {
          deltaBytes = delta;
          newLibSha256 = sha256.convert(soBytes).toString();
          stdout.writeln('[pack] delta lib/$abi: ${_fmtBytes(delta.length)} '
              '(full ${_fmtBytes(soBytes.length)})');
        } else {
          stdout.writeln('[pack] delta lib/$abi not worthwhile '
              '(${_fmtBytes(delta.length)} ≥ 90% of ${_fmtBytes(soBytes.length)}); shipping full');
        }
      }
    }
    if (deltaBytes == null) {
      stdout.writeln('[pack] extracted lib/$abi/libapp.so '
          '(${_fmtBytes(soBytes.length)})${baseLibSha256 != null ? ' base=$baseLibSha256' : ''}');
    }
    libVariants.add(_LibVariant(
      abi: abi,
      soBytes: soBytes,
      baseSha256: baseLibSha256,
      deltaBytes: deltaBytes,
      newLibSha256: newLibSha256,
    ));
  }

  outDir.createSync(recursive: true);
  try {
    _writePatchPackage(
      outDir: outDir,
      archive: archive,
      libVariants: libVariants,
      version: version,
      targetVersionCode: targetVersionCode,
      patchNumber: patchNumber,
      signingSeed: signingSeed,
      rolloutPercent: rolloutPercentFinal,
      channel: channelFinal,
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
  required List<_LibVariant> libVariants,
  required String version,
  required int targetVersionCode,
  required int? patchNumber,
  required String? signingSeed,
  required int? rolloutPercent,
  required String channel,
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
        throw PackException(
            'asset key not found in AssetManifest.bin: $key', 65);
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

  final libMap = <String, dynamic>{
    for (final v in libVariants)
      v.abi: v.deltaBytes != null
          ? {
              'path': 'lib/${v.abi}/libapp.so.delta',
              'format': 'delta',
              'baseSha256': v.baseSha256,
              'sha256': v.newLibSha256, // sha256 of the reconstructed full .so
              'size': v.soBytes.length,
            }
          : {
              'path': 'lib/${v.abi}/libapp.so',
              'md5': md5.convert(v.soBytes).toString(),
              if (v.baseSha256 != null) 'baseSha256': v.baseSha256,
            },
  };
  final zipManifest = <String, dynamic>{
    'schemaVersion': 2,
    'version': version,
    'targetVersionCode': targetVersionCode,
    'lib': libMap,
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

  final package = Archive()..addFile(_jsonArchiveFile('manifest.json', zipManifest));
  for (final v in libVariants) {
    if (v.deltaBytes != null) {
      package.addFile(ArchiveFile(
          'lib/${v.abi}/libapp.so.delta', v.deltaBytes!.length, v.deltaBytes!));
    } else {
      package.addFile(ArchiveFile('lib/${v.abi}/libapp.so', v.soBytes.length, v.soBytes));
    }
  }

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

  // archive 3.x returns List<int>?, 4.x returns List<int>; coerce to bytes
  // so we stay compatible with both major versions of the package.
  // ignore: unnecessary_nullable_for_final_variable_declarations, dead_null_aware_expression
  final List<int> packageBytes = ZipEncoder().encode(package) ?? const <int>[];
  final outZip = File('${outDir.path}/patch.zip');
  outZip.writeAsBytesSync(packageBytes);

  final payloadSha256 = sha256.convert(packageBytes).toString();
  String? signature;
  if (signingSeed != null) {
    final manifest = rolloutPercent != null
        ? PatchSigning.canonicalManifestV2(
            version: version,
            patchNumber: patchNumber!,
            targetVersionCode: targetVersionCode,
            sha256: payloadSha256,
            rolloutPercent: rolloutPercent,
            channel: channel,
          )
        : PatchSigning.canonicalManifest(
            version: version,
            patchNumber: patchNumber!,
            targetVersionCode: targetVersionCode,
            sha256: payloadSha256,
          );
    signature = PatchSigning.sign(signingSeed, manifest);
  }
  final outerManifest = <String, dynamic>{
    'schemaVersion': 2,
    'version': version,
    'sha256': payloadSha256,
    'targetVersionCode': targetVersionCode,
    if (patchNumber != null) 'patchNumber': patchNumber,
    if (rolloutPercent != null) 'rolloutPercent': rolloutPercent,
    if (rolloutPercent != null) 'channel': channel,
    if (signature != null) 'signature': signature,
    'abis': libVariants.map((v) => v.abi).toList(),
    'payload': 'patch.zip',
  };
  _writeJson(File('${outDir.path}/manifest.json'), outerManifest);

  if (requestedAssets.isNotEmpty) {
    stdout.writeln('[pack] assets: ${requestedAssets.length} key(s)');
    stdout.writeln('[pack] overlay files: ${patchFiles.length}');
  }
  stdout.writeln('[pack] payload: ${outZip.path}');
  stdout.writeln('[pack] sha256: $payloadSha256');
  stdout.writeln('[pack] signature: ${signature != null ? 'signed' : 'NONE (unsigned)'}');
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

/// All `lib/<abi>/libapp.so` in the APK, keyed by ABI, ordered by [_abiPriority]
/// first (known ABIs) then any remaining ABIs in archive order.
Map<String, ArchiveFile> _collectLibappSo(Archive archive) {
  final found = <String, ArchiveFile>{};
  final regex = RegExp(r'^lib/([^/]+)/libapp\.so$');
  for (final file in archive.files) {
    final m = regex.firstMatch(file.name);
    if (m != null) found[m.group(1)!] = file;
  }
  final ordered = <String, ArchiveFile>{};
  for (final abi in _abiPriority) {
    final hit = found.remove(abi);
    if (hit != null) ordered[abi] = hit;
  }
  ordered.addAll(found); // any non-priority ABIs (e.g. x86) keep their order
  return ordered;
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

class _LibVariant {
  const _LibVariant({
    required this.abi,
    required this.soBytes,
    required this.baseSha256,
    this.deltaBytes,
    this.newLibSha256,
  });

  final String abi;
  final List<int> soBytes;
  final String? baseSha256;

  /// Non-null => ship a delta for this ABI instead of the full `.so`.
  final List<int>? deltaBytes;

  /// SHA-256 of the full new `.so`; recorded so the device can verify its
  /// delta reconstruction. Set only when [deltaBytes] is non-null.
  final String? newLibSha256;
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
