import 'dart:io';

import 'package:args/args.dart';

/// `flutter_patcher init` — wire an existing Flutter project up to a patch server.
///
///   dart run flutter_patcher:init --server https://you.up.railway.app \
///       --public-key BASE64_FROM_SERVER_KEYGEN
///
/// Writes `lib/patcher_bootstrap.dart` (a `setupPatcher()` you call from main),
/// makes sure the dependency is declared, and prints the remaining steps to land
/// your first patch.
Future<int> main(List<String> argv) async {
  return exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('dir', defaultsTo: '.', help: 'Flutter project directory.')
    ..addOption('server', help: 'Patch server base URL, e.g. https://you.up.railway.app')
    ..addOption('public-key', help: 'Server public key (base64) from `npm run keygen`.')
    ..addFlag('no-wire-main', negatable: false, help: "Don't auto-insert setupPatcher() into lib/main.dart.")
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n${parser.usage}');
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher init — onboard a Flutter project\n\n${parser.usage}');
    return 0;
  }

  final dir = args['dir'] as String;
  final pubspec = File('$dir/pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('error: no pubspec.yaml in "$dir". Run inside a Flutter project '
        '(or `flutter create` a new one first).');
    return 66;
  }
  final pubspecText = pubspec.readAsStringSync();
  if (!pubspecText.contains('flutter:\n    sdk: flutter') &&
      !pubspecText.contains('sdk: flutter')) {
    stderr.writeln('warning: this does not look like a Flutter app (no flutter sdk dep).');
  }

  final server = (args['server'] as String?)?.trim();
  final publicKey = (args['public-key'] as String?)?.trim();
  final serverLit = (server == null || server.isEmpty)
      ? 'https://YOUR-SERVER.up.railway.app'
      : server.replaceAll(RegExp(r'/+$'), '');
  final keyLit = (publicKey == null || publicKey.isEmpty)
      ? 'PASTE_PUBLIC_KEY_FROM_SERVER_KEYGEN'
      : publicKey;

  // 1) Ensure the dependency is declared (non-destructive: insert under dependencies:).
  final libDir = Directory('$dir/lib')..createSync(recursive: true);
  final depPresent = RegExp(r'^\s*flutter_patcher\s*:', multiLine: true).hasMatch(pubspecText);
  if (!depPresent) {
    final updated = pubspecText.replaceFirst(
      RegExp(r'^dependencies:\s*$', multiLine: true),
      'dependencies:\n  flutter_patcher:\n'
          '    git:\n'
          '      url: https://github.com/darmawan01/flutter_patcher.git\n'
          '      ref: main',
    );
    if (updated != pubspecText) {
      pubspec.writeAsStringSync(updated);
      stdout.writeln('[init] added flutter_patcher (git) to pubspec.yaml dependencies');
    } else {
      stdout.writeln('[init] could not auto-edit pubspec — add this under dependencies:');
      stdout.writeln('         flutter_patcher:\n           git: { url: https://github.com/darmawan01/flutter_patcher.git, ref: main }');
    }
  } else {
    stdout.writeln('[init] flutter_patcher already in pubspec.yaml');
  }

  // 2) Write the bootstrap helper.
  final bootstrap = File('${libDir.path}/patcher_bootstrap.dart');
  bootstrap.writeAsStringSync(_bootstrapSource(serverLit, keyLit));
  stdout.writeln('[init] wrote ${bootstrap.path}');

  // 3) Auto-wire setupPatcher() into main() (best-effort; common shapes only).
  var mainWired = false;
  final mainFile = File('$dir/lib/main.dart');
  if (!(args['no-wire-main'] as bool) && mainFile.existsSync()) {
    final res = _wireMainDart(mainFile.readAsStringSync());
    if (res.updated != null) {
      mainFile.writeAsStringSync(res.updated!);
      mainWired = true;
      stdout.writeln('[init] ${res.note} (lib/main.dart)');
    } else {
      stdout.writeln('[init] ${res.note}');
    }
  }

  // 4) Next steps.
  final step2 = mainWired
      ? 'main() is wired — run `dart run flutter_patcher:doctor --project .` to verify'
      : "In your main(), before runApp():\n\n"
          "       import 'patcher_bootstrap.dart';\n"
          "       Future<void> main() async {\n"
          "         WidgetsFlutterBinding.ensureInitialized();\n"
          "         await setupPatcher();   // checks + stages a patch for the next launch\n"
          "         runApp(const MyApp());\n"
          "       }";
  stdout.writeln('''

Next:
  1. flutter pub get
  2. $step2
${keyLit.startsWith('PASTE') ? '''
  3. On your server run `npm run keygen`, then re-run init with
     --server <url> --public-key <key> (or edit patcher_bootstrap.dart).''' : ''}
  ${keyLit.startsWith('PASTE') ? '4' : '3'}. Ship a patch:
       flutter build apk --release
       dart run flutter_patcher:pack --apk build/app/outputs/flutter-apk/app-release.apk \\
         --version 1.0.1-h1 --target-version-code <yourVersionCode> --patch-number 1
       # upload dist/patch.zip + dist/manifest.json in the server dashboard, make it live.

Docs: https://github.com/darmawan01/flutter_patcher/tree/main/docs
''');
  return 0;
}

/// Best-effort insertion of `setupPatcher()` into a Flutter `main()`. Handles the
/// shapes `flutter create` produces (block and arrow `main`); returns
/// `(updated: null)` with a note when it can't safely edit, so init falls back to
/// printing the snippet.
({String? updated, String note}) _wireMainDart(String original) {
  if (original.contains('setupPatcher(')) {
    return (updated: null, note: 'main() already calls setupPatcher() — left as-is');
  }
  if (!original.contains('runApp(')) {
    return (updated: null, note: 'no runApp() in lib/main.dart — wire setupPatcher() in manually');
  }
  var src = original;

  // Ensure the bootstrap import is present (after the last import, else at top).
  if (!src.contains('patcher_bootstrap.dart')) {
    final imports = RegExp(r'^import .*;$', multiLine: true).allMatches(src).toList();
    const importLine = "import 'patcher_bootstrap.dart';";
    if (imports.isNotEmpty) {
      final last = imports.last;
      src = '${src.substring(0, last.end)}\n$importLine${src.substring(last.end)}';
    } else {
      src = '$importLine\n$src';
    }
  }

  // Arrow form: `main() => runApp(...);`
  final arrow = RegExp(
    r'(?:void|Future<void>)\s+main\s*\(\s*\)\s*(?:async\s*)?=>\s*runApp\((.*?)\);',
    dotAll: true,
  );
  final am = arrow.firstMatch(src);
  if (am != null) {
    final replacement = 'Future<void> main() async {\n'
        '  WidgetsFlutterBinding.ensureInitialized();\n'
        '  await setupPatcher();\n'
        '  runApp(${am.group(1)});\n'
        '}';
    return (updated: src.replaceRange(am.start, am.end, replacement), note: 'wired main() (arrow form)');
  }

  // Block form: make async (unless already), inject before the first runApp line.
  src = src.replaceFirst(RegExp(r'\bvoid\s+main\s*\(\s*\)(?!\s*async)'), 'Future<void> main() async');
  final runIdx = src.indexOf('runApp(');
  final lineStart = src.lastIndexOf('\n', runIdx) + 1;
  final indent = RegExp(r'^[ \t]*').firstMatch(src.substring(lineStart))!.group(0)!;
  final inject = StringBuffer();
  if (!src.contains('WidgetsFlutterBinding.ensureInitialized(')) {
    inject.write('${indent}WidgetsFlutterBinding.ensureInitialized();\n');
  }
  inject.write('${indent}await setupPatcher();\n');
  src = src.replaceRange(lineStart, lineStart, inject.toString());
  return (updated: src, note: 'wired main() (await setupPatcher())');
}

String _bootstrapSource(String server, String publicKey) => '''
// Generated by `dart run flutter_patcher:init`. Edit the constants as needed.
import 'package:flutter/widgets.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// Your patch server's /check endpoint.
const String kPatchCheckUrl = '$server/check';

/// The server's public key (base64). The device only applies patches signed by it.
const String kPatchPublicKey = '$publicKey';

/// Call once in main() before runApp(). Safe no-op on non-Android platforms.
Future<void> setupPatcher() async {
  await FlutterPatcher.init(
    publicKeyBase64: kPatchPublicKey,
    onEvent: (e) {
      debugPrint('[patcher] \$e');
      // For device adoption in the dashboard, POST e.toJson() to
      // '\$kPatchCheckUrl'.replaceFirst('/check', '/api/telemetry') (e.g. via package:http).
    },
  );
  // Downloads + verifies + stages any patch; it goes live on the NEXT cold start.
  final r = await FlutterPatcher.checkAndStage(kPatchCheckUrl);
  debugPrint('[patcher] \${r.outcome}');
}
''';
