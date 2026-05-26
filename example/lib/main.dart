import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_patcher/flutter_patcher.dart';

import 'diag_card.dart';
import 'log_panel.dart';

const _demoImage = 'assets/patch_demo.png';
const _bundledAssetPatch = 'assets/asset_patch_preload.zip';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_patcher example',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      useMaterial3: true,
    ),
    home: const Demo(),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});

  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  final _log = LogController();

  Future<void> _applyBundledAssetPatch() async {
    _log.log('loading bundled patch.zip...');
    final bytes = (await rootBundle.load(
      _bundledAssetPatch,
    )).buffer.asUint8List();

    final result = await FlutterPatcher.applyPatchBytes(
      bytes,
      version: 'asset-demo-1',
      onProgress: (p) => _log.log('  [${p.phase.name}]'),
    );

    _log.log(
      result.ok
          ? 'APPLIED: force-stop and reopen to see the image replacement'
          : 'failed: ${result.error?.name} / ${result.message}',
    );
    DiagCard.refresh();
  }

  Future<void> _rollback() async {
    await FlutterPatcher.rollback();
    _log.log('ROLLED BACK: force-stop and reopen to restore the APK image');
    DiagCard.refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('flutter_patcher example')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 96,
                  height: 54,
                  child: Image.asset(_demoImage, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'asset key',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      SizedBox(height: 2),
                      Text(
                        _demoImage,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const DiagCard(),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _applyBundledAssetPatch,
              child: const Text('Apply patch'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _rollback, child: const Text('Rollback')),
            const SizedBox(height: 16),
            Expanded(child: LogPanel(controller: _log)),
          ],
        ),
      ),
    ),
  );
}
