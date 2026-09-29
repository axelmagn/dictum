import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/inline_progress.dart';
import 'package:app/main.dart';

void main() {
  group('Inline Progress UI components', () {
    testWidgets('InlineChunkChicklet renders with progress bar and mic', (tester) async {
      final progress = ValueNotifier<double>(0.4);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: InlineChunkChicklet(
                progress: progress,
                isSpeaking: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InlineChunkChicklet), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Verify progress update
      progress.value = 0.8;
      await tester.pump();
      final indicator = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(indicator.value, closeTo(0.8, 0.001));
    });

    testWidgets('InlineChunkChicklet renders with progressValue double directly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: InlineChunkChicklet(
                progressValue: 0.75,
                isSpeaking: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InlineChunkChicklet), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(indicator.value, closeTo(0.75, 0.001));
    });

    testWidgets('InlineActiveDraftSegment renders text and progress bar', (tester) async {
      final progress = ValueNotifier<double>(0.6);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: InlineActiveDraftSegment(
                text: 'Testing live draft...',
                progress: progress,
                isWorkerBusy: false,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Testing live draft...'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      final indicator = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(indicator.value, closeTo(0.6, 0.001));
    });

    testWidgets('InlineActiveDraftSegment does not peg progress to 1.0 when isWorkerBusy is true', (tester) async {
      final progress = ValueNotifier<double>(0.4);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: InlineActiveDraftSegment(
                text: 'Testing busy draft...',
                progress: progress,
                isWorkerBusy: true,
              ),
            ),
          ),
        ),
      );

      final indicator = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      // Should show the true progress value (0.4), NOT clamped/pegged to 1.0
      expect(indicator.value, closeTo(0.4, 0.001));
    });

    testWidgets('GlobalFinalPassRail displays running pass indicator with percentage', (tester) async {
      final progress = ValueNotifier<double>(0.45);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlobalFinalPassRail(progress: progress),
          ),
        ),
      );

      expect(find.text('Running high-accuracy final pass...'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      progress.value = 0.90;
      await tester.pump();
      expect(find.text('90%'), findsOneWidget);
    });

    testWidgets('ChunkMetadataModal shows latency and metrics and copy button', (tester) async {
      const chunk = DictationChunkViewData(
        chunkIndex: 3,
        text: 'This is a sample chunk.',
        tLagSec: 0.25,
        rtf: 0.18,
        durationSec: 1.4,
        t0: 3.2,
        t1: 4.6,
        lastChunkIndex: 3,
        audioCtx: 512,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChunkMetadataModal(chunk: chunk),
          ),
        ),
      );

      expect(find.text('CHUNK #3 METRICS'), findsOneWidget);
      expect(find.text('PASS (<0.5s)'), findsOneWidget);
      expect(find.text('0.25 s'), findsOneWidget);
      expect(find.text('0.180'), findsOneWidget);
      expect(find.text('1.40 s'), findsOneWidget);
      expect(find.text('3.2s - 4.6s'), findsOneWidget);
      expect(find.text('This is a sample chunk.'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });
  });
}
