import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  const ann = PatchAnnouncement(
    title: 'New version ready',
    body: 'Faster startup and a crash fix.',
    severity: 'important',
    url: 'https://example.com/notes',
  );

  group('PatchUpdatePrompt.severityColor', () {
    test('maps severities to distinct accents', () {
      final info = PatchUpdatePrompt.severityColor('info');
      final important = PatchUpdatePrompt.severityColor('important');
      final critical = PatchUpdatePrompt.severityColor('critical');
      expect(info == important, isFalse);
      expect(important == critical, isFalse);
      // unknown falls back to the info accent
      expect(PatchUpdatePrompt.severityColor('whatever'), info);
    });
  });

  group('PatchUpdatePrompt banner', () {
    testWidgets('renders the announcement and fires onUpdate then dismisses', (tester) async {
      var updated = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchUpdatePrompt(announcement: ann, onUpdate: () => updated++),
        ),
      ));

      expect(find.text('New version ready'), findsOneWidget);
      expect(find.text('Faster startup and a crash fix.'), findsOneWidget);

      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();

      expect(updated, 1);
      // dismissOnAction default → banner gone
      expect(find.text('New version ready'), findsNothing);
    });

    testWidgets('Later fires onLater; Learn more passes the url', (tester) async {
      var later = 0;
      String? learnedUrl;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchUpdatePrompt(
            announcement: ann,
            onLater: () => later++,
            onLearnMore: (u) => learnedUrl = u,
          ),
        ),
      ));

      await tester.tap(find.text('Learn more'));
      await tester.pump();
      expect(learnedUrl, 'https://example.com/notes');

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(later, 1);
      expect(find.text('New version ready'), findsNothing);
    });

    testWidgets('builder gives full control and reuses update/later plumbing', (tester) async {
      var updated = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchUpdatePrompt(
            announcement: ann,
            onUpdate: () => updated++,
            builder: (context, s) => s.dismissed
                ? const Text('done')
                : Column(
                    children: [
                      Text('custom: ${s.announcement.title}'),
                      TextButton(onPressed: s.update, child: const Text('go')),
                    ],
                  ),
          ),
        ),
      ));

      expect(find.text('custom: New version ready'), findsOneWidget);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(updated, 1);
      expect(find.text('done'), findsOneWidget);
    });
  });

  group('PatchUpdatePrompt.showAsDialog', () {
    testWidgets('returns the chosen action', (tester) async {
      late Future<PatchUpdateAction?> result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                result = PatchUpdatePrompt.showAsDialog(context, announcement: ann);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('New version ready'), findsOneWidget);

      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(await result, PatchUpdateAction.update);
    });
  });
}
