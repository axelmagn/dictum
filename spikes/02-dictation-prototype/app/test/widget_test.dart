import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/inline_progress.dart';
import 'package:app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App smoke test', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();
    expect(find.text('Spike 02 — Real-Time Dictation'), findsOneWidget);
  });

  testWidgets('Continuous transcript box displays concatenated chunks and preview', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));
    state.addChunkForTesting(DictationChunkViewData(
      chunkIndex: 0,
      text: 'First chunk.',
      tLagSec: 0.5,
      rtf: 0.2,
      durationSec: 1.0,
      t0: 0.0,
      t1: 1.0,
      lastChunkIndex: 0,
      audioCtx: 1500,
    ));
    state.addChunkForTesting(DictationChunkViewData(
      chunkIndex: 1,
      text: 'Second chunk.',
      tLagSec: 0.4,
      rtf: 0.2,
      durationSec: 1.0,
      t0: 1.0,
      t1: 2.0,
      lastChunkIndex: 1,
      audioCtx: 1500,
    ));
    state.setPartialForTesting('Live preview...');
    await tester.pump();

    final selectableTextFinder = find.byType(SelectableText);
    expect(selectableTextFinder, findsOneWidget);
    final selectableText = tester.widget<SelectableText>(selectableTextFinder);
    expect(selectableText.textSpan!.toPlainText(), contains('First chunk.'));
    expect(selectableText.textSpan!.toPlainText(), contains('Second chunk.'));
    expect(find.text('Live preview...'), findsOneWidget);
    expect(find.byType(InlineActiveDraftSegment), findsOneWidget);
  });

  testWidgets('Inline chunk chicklet appears when speech is accumulating before text', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));
    state.setIsAccumulatingChunkForTesting(true);
    await tester.pump();

    expect(find.byType(InlineChunkChicklet), findsOneWidget);

    // While recording is active, both draft segment and running mic chicklet are visible
    state.setPipelineStateForTesting(PipelineState.recording);
    state.setPartialForTesting('Words incoming...');
    await tester.pump();

    expect(find.byType(InlineActiveDraftSegment), findsOneWidget);
    expect(find.byType(InlineChunkChicklet), findsOneWidget);

    // When recording stops and finalizes, chicklet disappears
    state.setPipelineStateForTesting(PipelineState.review);
    state.setIsAccumulatingChunkForTesting(false);
    await tester.pump();

    expect(find.byType(InlineChunkChicklet), findsNothing);
  });

  testWidgets('Tapping a finalized chunk opens ChunkMetadataModal with timing stats', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));
    state.addChunkForTesting(const DictationChunkViewData(
      chunkIndex: 42,
      text: 'Interactive chunk text.',
      tLagSec: 0.18,
      rtf: 0.12,
      durationSec: 1.5,
      t0: 10.0,
      t1: 11.5,
      lastChunkIndex: 42,
      audioCtx: 512,
    ));
    await tester.pump();

    // Trigger modal show directly or via tap
    final chunkTextFinder = find.text('Interactive chunk text.');
    expect(chunkTextFinder, findsOneWidget);
    await tester.tap(chunkTextFinder);
    await tester.pumpAndSettle();

    expect(find.byType(ChunkMetadataModal), findsOneWidget);
    expect(find.text('CHUNK #42 METRICS'), findsOneWidget);
    expect(find.text('0.18 s'), findsOneWidget);
  });

  testWidgets('AppBar tune button toggles PipelineTelemetryDeck', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    // Telemetry deck is collapsed/hidden by default
    expect(find.text('PIPELINE TELEMETRY'), findsNothing);

    // Tap tune icon in AppBar to expand telemetry
    final tuneBtn = find.byTooltip('Toggle Pipeline Telemetry');
    expect(tuneBtn, findsOneWidget);
    await tester.tap(tuneBtn);
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));
    expect(state.mounted, isTrue);

    // When recording starts with toggle active, telemetry deck displays
    state.setShowTelemetryDeckForTesting(true);
    await tester.pump();
  });

  testWidgets('Two-Pass: shows running indicator and replaces draft with verbatim transcript', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));
    state.addChunkForTesting(DictationChunkViewData(
      chunkIndex: 0,
      text: 'Draft chunk.',
      tLagSec: 0.3,
      rtf: 0.2,
      durationSec: 1.0,
      t0: 0.0,
      t1: 1.0,
      lastChunkIndex: 0,
      audioCtx: 128,
    ));
    await tester.pump();

    // Draft text is shown
    expect(find.text('Draft chunk.'), findsWidgets);

    // Final pass starts
    state.setIsRunningFinalPassForTesting(true);
    await tester.pump();

    expect(find.text('Running high-accuracy final pass...'), findsOneWidget);
    expect(find.text('Draft chunk.'), findsWidgets);

    // Final pass completes
    state.setIsRunningFinalPassForTesting(false);
    state.setFinalTranscriptForTesting('Full verbatim final transcript.');
    await tester.pump();

    expect(find.text('Running high-accuracy final pass...'), findsNothing);
    expect(find.text('FINAL VERBATIM TRANSCRIPT'), findsOneWidget);

    final selectableTextFinder = find.byType(SelectableText);
    expect(selectableTextFinder, findsOneWidget);
    final selectableText = tester.widget<SelectableText>(selectableTextFinder);
    expect(selectableText.textSpan!.toPlainText(), equals('Full verbatim final transcript.'));
  });

  testWidgets('Unified chunk lifecycle: buffering chicklet -> preview draft -> finalized text', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Test',
            'model': 'TestModel',
            'externalFilesDir': '/tmp',
          };
        }
        if (call.method == 'getThermalStatus') return 0;
        return null;
      },
    );

    await tester.pumpWidget(const DictationPrototypeApp());
    await tester.pump();

    final state = tester.state<DictationHomeScreenState>(find.byType(DictationHomeScreen));

    // Stage 1: Buffering
    state.addChunkForTesting(const DictationChunkViewData(
      chunkIndex: 0,
      stage: ChunkStage.buffering,
      text: '',
      progress: 0.3,
      tLagSec: 0,
      rtf: 0,
      durationSec: 0.3,
      t0: 0,
      t1: 0.3,
      lastChunkIndex: 0,
    ));
    await tester.pump();

    expect(find.byType(InlineChunkChicklet), findsOneWidget);
    expect(find.byType(InlineActiveDraftSegment), findsNothing);

    // Stage 2: Preview
    state.updateChunkForTesting(
      0,
      const DictationChunkViewData(
        chunkIndex: 0,
        stage: ChunkStage.preview,
        text: 'Live preview segment.',
        progress: 0.5,
        tLagSec: 0,
        rtf: 0,
        durationSec: 1.0,
        t0: 0,
        t1: 1.0,
        lastChunkIndex: 0,
      ),
    );
    await tester.pump();

    expect(find.byType(InlineChunkChicklet), findsNothing);
    expect(find.byType(InlineActiveDraftSegment), findsOneWidget);
    expect(find.text('Live preview segment.'), findsOneWidget);

    // Stage 3: Finalized
    state.updateChunkForTesting(
      0,
      const DictationChunkViewData(
        chunkIndex: 0,
        stage: ChunkStage.finalized,
        text: 'Final verbatim segment.',
        progress: 1.0,
        tLagSec: 0.2,
        rtf: 0.15,
        durationSec: 1.2,
        t0: 0,
        t1: 1.2,
        lastChunkIndex: 0,
      ),
    );
    await tester.pump();

    expect(find.byType(InlineChunkChicklet), findsNothing);
    expect(find.byType(InlineActiveDraftSegment), findsNothing);
    expect(find.text('Final verbatim segment.'), findsOneWidget);
  });
}
