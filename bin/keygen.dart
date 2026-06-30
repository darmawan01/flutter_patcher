import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_patcher/src/signing.dart';

/// Generates an Ed25519 keypair for signing patches.
///
///   dart run flutter_patcher:keygen
///   dart run flutter_patcher:keygen --out keys/   # write seed + pubkey files
///
/// Prints the private seed (keep secret) and the X.509 public key to paste into
/// `FlutterPatcher.init(publicKeyBase64: ...)` (or `publicKeysBase64:` for rotation).
Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('out', help: 'Directory to write patch_signing.seed + patch_signing.pub.')
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
    stdout.writeln('flutter_patcher keygen — Ed25519 signing keypair\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  final kp = PatchSigning.generateKeypair();

  final outDir = args['out'] as String?;
  if (outDir != null) {
    final dir = Directory(outDir)..createSync(recursive: true);
    File('${dir.path}/patch_signing.seed').writeAsStringSync('${kp.seedBase64}\n');
    File('${dir.path}/patch_signing.pub').writeAsStringSync('${kp.publicKeySpkiBase64}\n');
    stdout.writeln('[keygen] wrote ${dir.path}/patch_signing.seed (PRIVATE — keep secret)');
    stdout.writeln('[keygen] wrote ${dir.path}/patch_signing.pub');
  }

  stdout.writeln('');
  stdout.writeln('PRIVATE seed (base64, keep secret — pass to `pack --key`):');
  stdout.writeln('  ${kp.seedBase64}');
  stdout.writeln('');
  stdout.writeln('PUBLIC key (base64 X.509 — paste into FlutterPatcher.init):');
  stdout.writeln('  ${kp.publicKeySpkiBase64}');
  stdout.writeln('');
  stdout.writeln('  await FlutterPatcher.init(publicKeyBase64: \'${kp.publicKeySpkiBase64}\');');
  return 0;
}
