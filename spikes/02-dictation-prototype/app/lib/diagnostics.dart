import 'dart:io';

import 'device_service.dart';

class ChunkMetric {
  final int chunkIndex;
  final double tLagSec;
  final double rtf;
  final double audioDurationSec;
  final double transcribeSec;
  final String text;

  ChunkMetric({
    required this.chunkIndex,
    required this.tLagSec,
    required this.rtf,
    required this.audioDurationSec,
    required this.transcribeSec,
    required this.text,
  });
}

class DiagnosticsTracker {
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  final List<ChunkMetric> chunkMetrics = [];
  int overrunCount = 0;
  int thermalStatus = -1; // 0: NONE, 1: LIGHT, 2: MODERATE, 3: SEVERE
  double peakRssMb = 0.0;
  int totalRecordedSamples = 0;
  int wallClockDurationMs = 0;

  void reset() {
    chunkMetrics.clear();
    overrunCount = 0;
    thermalStatus = -1;
    peakRssMb = 0.0;
    totalRecordedSamples = 0;
    wallClockDurationMs = 0;
  }

  void addChunkMetric({
    required int chunkIndex,
    required double tLagSec,
    required double rtf,
    required double audioDurationSec,
    required double transcribeSec,
    required String text,
  }) {
    chunkMetrics.add(ChunkMetric(
      chunkIndex: chunkIndex,
      tLagSec: tLagSec,
      rtf: rtf,
      audioDurationSec: audioDurationSec,
      transcribeSec: transcribeSec,
      text: text,
    ));
    _updateMemory();
  }

  static double median(List<double> xs) {
    if (xs.isEmpty) return 0.0;
    final sorted = [...xs]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  double get medianTLagSec {
    if (chunkMetrics.isEmpty) return 0.0;
    return median(chunkMetrics.map((m) => m.tLagSec).toList());
  }

  double get maxTLagSec {
    if (chunkMetrics.isEmpty) return 0.0;
    return chunkMetrics.map((m) => m.tLagSec).reduce((a, b) => a > b ? a : b);
  }

  double get averageRtf {
    if (chunkMetrics.isEmpty) return 0.0;
    double totalAudio = 0.0;
    double totalTranscribe = 0.0;
    for (final m in chunkMetrics) {
      totalAudio += m.audioDurationSec;
      totalTranscribe += m.transcribeSec;
    }
    return totalAudio > 0 ? (totalTranscribe / totalAudio) : 0.0;
  }

  double get audioClockDiscrepancyPercent {
    if (wallClockDurationMs <= 0) return 0.0;
    final audioMs = (totalRecordedSamples * 1000.0) / 16000.0;
    final diff = (audioMs - wallClockDurationMs).abs();
    return (diff / wallClockDurationMs) * 100.0;
  }

  bool get audioIntegrityPass {
    return overrunCount == 0 && audioClockDiscrepancyPercent <= 0.5;
  }

  bool get tLagPass {
    return chunkMetrics.isNotEmpty && medianTLagSec <= 1.5;
  }

  Future<void> pollDeviceStatus() async {
    thermalStatus = await DeviceService.getThermalStatus();
    _updateMemory();
  }

  void _updateMemory() {
    try {
      final statusFile = File('/proc/self/status');
      if (statusFile.existsSync()) {
        final lines = statusFile.readAsLinesSync();
        for (final line in lines) {
          if (line.startsWith('VmHWM:') || line.startsWith('VmRSS:')) {
            final parts = line.split(_whitespaceRegex);
            if (parts.length >= 2) {
              final kb = double.tryParse(parts[1]) ?? 0.0;
              final mb = kb / 1024.0;
              if (mb > peakRssMb) {
                peakRssMb = mb;
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Verifies filler retention against Section 8 Phonetic Test Script:
  /// Target fillers (6 items): "Um", "uh", "I— I", "Hmm...", "you know", "um"
  static FillerAnalysis evaluatePhoneticTestScript(String fullTranscript) {
    final lower = fullTranscript.toLowerCase();

    // 1. Um (initial)
    final hasUm1 = lower.contains('um,') || lower.contains('um ') || lower.startsWith('um');
    // 2. uh
    final hasUh = lower.contains('uh,') || lower.contains('uh ') || lower.contains('uh...');
    // 3. I-I / I— I
    final hasIRepeat = lower.contains('i— i') ||
        lower.contains('i- i') ||
        lower.contains('i-- i') ||
        lower.contains('i-i') ||
        lower.contains('i i want');
    // 4. Hmm...
    final hasHmm = lower.contains('hmm') || lower.contains('hm...');
    // 5. you know
    final hasYouKnow = lower.contains('you know');
    // 6. second um ("that's, um, that's")
    final hasUm2 = lower.contains("that's, um") ||
        lower.contains("that's um") ||
        (RegExp(r'\bum\b').allMatches(lower).length >= 2);

    final results = <String, bool>{
      'Um (initial)': hasUm1,
      'uh': hasUh,
      'I— I': hasIRepeat,
      'Hmm...': hasHmm,
      'you know': hasYouKnow,
      'um (final)': hasUm2,
    };

    final passedCount = results.values.where((v) => v).length;
    final totalCount = results.length;
    final rate = (passedCount / totalCount) * 100.0;

    return FillerAnalysis(
      retainedCount: passedCount,
      totalCount: totalCount,
      retainedPercent: rate,
      details: results,
      passed: passedCount >= 5, // >= 5/6 (83%) per SPEC
    );
  }
}

class FillerAnalysis {
  final int retainedCount;
  final int totalCount;
  final double retainedPercent;
  final Map<String, bool> details;
  final bool passed;

  FillerAnalysis({
    required this.retainedCount,
    required this.totalCount,
    required this.retainedPercent,
    required this.details,
    required this.passed,
  });
}
