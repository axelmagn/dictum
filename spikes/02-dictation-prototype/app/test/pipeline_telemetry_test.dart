import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/pipeline_telemetry.dart';
import 'package:app/whisper_worker.dart';

void main() {
  group('PipelineTelemetryController tests', () {
    test('updates frame telemetry accurately', () {
      final controller = PipelineTelemetryController();

      expect(controller.frameCount.value, 0);
      expect(controller.micRms.value, 0.0);
      expect(controller.speechProb.value, 0.0);
      expect(controller.pauseProgress.value, 0.0);
      expect(controller.inSpeech.value, false);

      controller.updateFrame(
        rms: 0.15,
        prob: 0.82,
        consecutivePause: 8,
        maxPause: 16,
        isSpeaking: true,
        elapsedSincePartialMs: 500,
        partialIntervalMs: 1000,
      );

      expect(controller.frameCount.value, 1);
      expect(controller.micRms.value, closeTo(0.6, 0.01));
      expect(controller.speechProb.value, closeTo(0.82, 0.001));
      expect(controller.pauseProgress.value, closeTo(0.5, 0.001));
      expect(controller.pauseFrames.value, 8);
      expect(controller.inSpeech.value, true);
      expect(controller.partialProgress.value, closeTo(0.5, 0.001));
      expect(controller.partialElapsedMs.value, 500);

      controller.reset();
      expect(controller.frameCount.value, 0);
      expect(controller.micRms.value, 0.0);
      expect(controller.speechProb.value, 0.0);
      expect(controller.pauseProgress.value, 0.0);
      expect(controller.inSpeech.value, false);
      expect(controller.partialProgress.value, 0.0);

      controller.dispose();
    });

    test('updates worker status accurately', () {
      final controller = PipelineTelemetryController();

      expect(controller.workerStatus.value.isBusy, false);

      controller.updateWorker(const WhisperWorkerStatus(
        isBusy: true,
        pendingCount: 2,
        activeChunkIndex: 3,
        isPartial: false,
        audioDurationSec: 4.2,
        audioCtx: 256,
      ));

      expect(controller.workerStatus.value.isBusy, true);
      expect(controller.workerStatus.value.pendingCount, 2);
      expect(controller.workerStatus.value.activeChunkIndex, 3);
      expect(controller.workerStatus.value.audioCtx, 256);

      controller.dispose();
    });
  });

  group('PipelineTelemetryDeck Widget test', () {
    testWidgets('renders all 4 stages correctly', (tester) async {
      final controller = PipelineTelemetryController();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PipelineTelemetryDeck(controller: controller),
          ),
        ),
      );

      expect(find.text('PIPELINE TELEMETRY'), findsOneWidget);
      expect(find.text('1. MIC IN'), findsOneWidget);
      expect(find.text('2. SILERO VAD'), findsOneWidget);
      expect(find.text('3. PARTIAL DRAFTER'), findsOneWidget);
      expect(find.text('4. WHISPER INFER'), findsOneWidget);
      expect(find.text('31.2 Hz · 32ms'), findsOneWidget);
      expect(find.text('1.0 Hz · 1000ms'), findsOneWidget);
      expect(find.text('SILENCE'), findsOneWidget);
      expect(find.text('IDLE'), findsOneWidget);

      // Trigger telemetry updates
      controller.updateFrame(
        rms: 0.25,
        prob: 0.95,
        consecutivePause: 4,
        maxPause: 16,
        isSpeaking: true,
        elapsedSincePartialMs: 300,
        partialIntervalMs: 1000,
      );

      controller.updateWorker(const WhisperWorkerStatus(
        isBusy: true,
        pendingCount: 1,
        activeChunkIndex: 5,
        isPartial: true,
        audioCtx: 128,
      ));

      await tester.pump();

      expect(find.text('SPEECH'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('Q: 1'), findsOneWidget);
      expect(find.textContaining('Partial #5'), findsOneWidget);

      controller.dispose();
    });
  });
}
