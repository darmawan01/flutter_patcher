import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  group('buildFeedbackPayload', () {
    test('maps rating to wire value', () {
      expect(buildFeedbackPayload(rating: PatchRating.up)['rating'], 'up');
      expect(buildFeedbackPayload(rating: PatchRating.down)['rating'], 'down');
    });

    test('includes version/installId/comment when present', () {
      final p = buildFeedbackPayload(
        rating: PatchRating.up,
        version: '1.2.0+5',
        installId: 'abc',
        comment: '  smooth  ',
      );
      expect(p['version'], '1.2.0+5');
      expect(p['installId'], 'abc');
      expect(p['comment'], 'smooth'); // trimmed
    });

    test('omits empty/null fields', () {
      final p = buildFeedbackPayload(rating: PatchRating.down, version: '', installId: null, comment: '   ');
      expect(p.containsKey('version'), isFalse);
      expect(p.containsKey('installId'), isFalse);
      expect(p.containsKey('comment'), isFalse);
      expect(p.keys.toList(), ['rating']);
    });
  });

  group('PatchFeedback widget', () {
    testWidgets('thumbs up submits an up rating and shows thanks', (tester) async {
      PatchRating? sent;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchFeedback(
            thanksMessage: 'Ta!',
            onSubmit: (rating, comment) async {
              sent = rating;
              return true;
            },
          ),
        ),
      ));

      expect(find.text('Enjoying this update?'), findsOneWidget);
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      expect(sent, PatchRating.up);
      expect(find.text('Ta!'), findsOneWidget);
    });

    testWidgets('thumbs down passes the comment and reports via onDone', (tester) async {
      String? gotComment;
      PatchRating? doneRating;
      bool? doneOk;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchFeedback(
            showComment: true,
            onSubmit: (rating, comment) async {
              gotComment = comment;
              return true;
            },
            onDone: (rating, ok) {
              doneRating = rating;
              doneOk = ok;
            },
          ),
        ),
      ));

      await tester.enterText(find.byType(TextField), 'too slow');
      await tester.tap(find.text('Bad'));
      await tester.pumpAndSettle();

      expect(gotComment, 'too slow');
      expect(doneRating, PatchRating.down);
      expect(doneOk, isTrue);
    });

    testWidgets('builder gives full control and reuses the submit plumbing', (tester) async {
      PatchRating? sent;
      String? sentComment;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchFeedback(
            onSubmit: (rating, comment) async {
              sent = rating;
              sentComment = comment;
              return true;
            },
            builder: (context, s) => s.done
                ? const Text('custom-thanks')
                : TextButton(
                    onPressed: s.submitting ? null : () => s.submit(PatchRating.up, comment: '5 stars'),
                    child: const Text('rate-it'),
                  ),
          ),
        ),
      ));

      expect(find.text('rate-it'), findsOneWidget);
      await tester.tap(find.text('rate-it'));
      await tester.pumpAndSettle();

      expect(sent, PatchRating.up);
      expect(sentComment, '5 stars');
      expect(find.text('custom-thanks'), findsOneWidget);
    });

    testWidgets('stays on the prompt when the submit fails', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PatchFeedback(
            thanksMessage: 'Ta!',
            onSubmit: (rating, comment) async => false,
          ),
        ),
      ));

      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();

      expect(find.text('Ta!'), findsNothing);
      expect(find.text('Enjoying this update?'), findsOneWidget);
    });
  });
}
