import 'package:flutter_test/flutter_test.dart';
import 'package:app/diagnostics.dart';

void main() {
  group('DiagnosticsTracker tests', () {
    test('Calculates median T_lag correctly', () {
      final tracker = DiagnosticsTracker();

      tracker.addChunkMetric(
        chunkIndex: 0,
        tLagSec: 0.8,
        rtf: 0.4,
        audioDurationSec: 2.0,
        transcribeSec: 0.8,
        text: 'hello',
      );
      expect(tracker.medianTLagSec, equals(0.8));

      tracker.addChunkMetric(
        chunkIndex: 1,
        tLagSec: 1.2,
        rtf: 0.45,
        audioDurationSec: 3.0,
        transcribeSec: 1.35,
        text: 'world',
      );
      // Even number: (0.8 + 1.2) / 2 = 1.0
      expect(tracker.medianTLagSec, equals(1.0));

      tracker.addChunkMetric(
        chunkIndex: 2,
        tLagSec: 0.5,
        rtf: 0.35,
        audioDurationSec: 1.5,
        transcribeSec: 0.52,
        text: 'testing',
      );
      // Odd number sorted: [0.5, 0.8, 1.2] -> mid is 0.8
      expect(tracker.medianTLagSec, equals(0.8));
      expect(tracker.tLagPass, isTrue); // <= 1.5s
    });

    test('Audio clock discrepancy test', () {
      final tracker = DiagnosticsTracker();
      tracker.totalRecordedSamples = 16000 * 10; // 10 seconds of samples
      tracker.wallClockDurationMs = 10020; // 10.02 seconds wall clock
      tracker.overrunCount = 0;

      expect(tracker.audioClockDiscrepancyPercent, closeTo(0.2, 0.05));
      expect(tracker.audioIntegrityPass, isTrue); // <= 0.5%
    });

    test('Phonetic script filler evaluation passes on standardized script', () {
      const script =
          "Um, hello. I am testing... uh, testing the new prototype. I— I want to see if it catches my pauses. Hmm... like, you know, when I stop to think, uh, does it keep every single word? That's, um, that's the whole question.";

      final analysis = DiagnosticsTracker.evaluatePhoneticTestScript(script);

      expect(analysis.retainedCount, equals(6));
      expect(analysis.totalCount, equals(6));
      expect(analysis.retainedPercent, equals(100.0));
      expect(analysis.passed, isTrue);
    });

    test('Phonetic script filler evaluation catches dropped fillers', () {
      // Cleaned up script where "Um" and "uh" were stripped
      const cleaned =
          "Hello. I am testing the new prototype. I want to see if it catches my pauses. Like, when I stop to think, does it keep every single word? That's the whole question.";

      final analysis = DiagnosticsTracker.evaluatePhoneticTestScript(cleaned);

      expect(analysis.retainedCount, lessThan(4));
      expect(analysis.passed, isFalse);
    });
  });
}
