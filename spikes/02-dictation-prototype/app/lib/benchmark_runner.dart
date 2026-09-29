import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'audio_utils.dart';
import 'device_service.dart';
import 'diagnostics.dart';
import 'vad_chunker.dart';
import 'whisper_worker.dart';

typedef BenchmarkProgressCallback = void Function({
  required int durationMs,
  required String statusText,
  SpeechChunk? speechChunk,
  Float32List? livePartialSamples,
  int? livePartialStartOffset,
});

class BenchmarkResult {
  final String reportFilePath;
  final FillerAnalysis fillerAnalysis;
  final String fullTranscript;

  const BenchmarkResult({
    required this.reportFilePath,
    required this.fillerAnalysis,
    required this.fullTranscript,
  });
}

class BenchmarkRunner {
  static const int sampleRate = 16000;
  static const int frameSize = 512;
  static const int partialIntervalMs = 1000;
  static const int firstPartialAfterMs = 500;

  static Future<String> run({
    required String wavPath,
    required bool fiveMinutes,
    required String externalFilesDir,
    required DeviceInfo? deviceInfo,
    required StreamingVadChunker vadChunker,
    required WhisperWorker whisperWorker,
    required DiagnosticsTracker diagnostics,
    required int minAudioCtx,
    required List<double> firstPartialLagsSec,
    required List<Map<String, dynamic>> recordedChunkData,
    required BenchmarkProgressCallback onProgress,
    required bool Function() isCancelled,
    required bool Function() allFinalsReceived,
  }) async {
    final audioData = await AudioUtils.loadWavFile(wavPath);
    final totalSamples = fiveMinutes
        ? min(audioData.samples.length, sampleRate * 300) // 5 minutes
        : audioData.samples.length;

    final totalDurationMs = (totalSamples * 1000) ~/ sampleRate;
    diagnostics.totalRecordedSamples = totalSamples;
    diagnostics.wallClockDurationMs = totalDurationMs;

    int sampleOffset = 0;
    int lastPartialSubmitMs = 0;
    bool wasInSpeech = false;
    final stopwatch = Stopwatch()..start();

    while (sampleOffset + frameSize <= totalSamples && !isCancelled()) {
      final frame = Float32List(frameSize);
      for (int i = 0; i < frameSize; i++) {
        frame[i] = audioData.samples[sampleOffset + i];
      }
      sampleOffset += frameSize;

      final chunk = vadChunker.feedFrame(frame);
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      if (vadChunker.inSpeech && !wasInSpeech) {
        lastPartialSubmitMs = nowMs - partialIntervalMs + firstPartialAfterMs;
      }
      wasInSpeech = vadChunker.inSpeech;

      Float32List? partialSamples;
      int? partialOffset;

      if (chunk != null) {
        whisperWorker.submitChunk(
          chunkIndex: chunk.chunkIndex,
          samples: chunk.samples,
          tPauseDetectedMs: chunk.tPauseDetectedMs,
          masterSampleOffset: chunk.masterSampleOffset,
          minAudioCtx: minAudioCtx,
        );
      } else if (vadChunker.inSpeech && nowMs - lastPartialSubmitMs >= partialIntervalMs) {
        final samples = vadChunker.currentUtteranceSamples();
        if (samples != null) {
          lastPartialSubmitMs = nowMs;
          partialSamples = samples;
          partialOffset = vadChunker.currentUtteranceStartOffset;
          whisperWorker.submitChunk(
            chunkIndex: vadChunker.chunkCounter,
            samples: samples,
            tPauseDetectedMs: nowMs,
            masterSampleOffset: vadChunker.currentUtteranceStartOffset,
            isPartial: true,
            minAudioCtx: minAudioCtx,
          );
        }
      }

      final currentDurationMs = (sampleOffset * 1000) ~/ sampleRate;
      String statusText = '';
      if (sampleOffset % (sampleRate * 5) == 0) {
        statusText =
            'Streaming: ${(sampleOffset / sampleRate).toStringAsFixed(1)}s / ${(totalSamples / sampleRate).toStringAsFixed(1)}s';
      }

      onProgress(
        durationMs: currentDurationMs,
        statusText: statusText,
        speechChunk: chunk,
        livePartialSamples: partialSamples,
        livePartialStartOffset: partialOffset,
      );

      final targetElapsedMs = (sampleOffset * 1000) ~/ sampleRate;
      final actualElapsedMs = stopwatch.elapsedMilliseconds;
      if (targetElapsedMs > actualElapsedMs) {
        await Future.delayed(Duration(milliseconds: targetElapsedMs - actualElapsedMs));
      }
    }

    // Flush trailing chunk
    final finalChunk = vadChunker.flush();
    if (finalChunk != null) {
      whisperWorker.submitChunk(
        chunkIndex: finalChunk.chunkIndex,
        samples: finalChunk.samples,
        tPauseDetectedMs: finalChunk.tPauseDetectedMs,
        masterSampleOffset: finalChunk.masterSampleOffset,
        minAudioCtx: minAudioCtx,
      );
    }

    // Wait until worker finishes transcription
    final waitStart = DateTime.now();
    while (!allFinalsReceived() &&
        DateTime.now().difference(waitStart).inSeconds < 60 &&
        !isCancelled()) {
      await Future.delayed(const Duration(milliseconds: 150));
    }

    return saveReport(
      fiveMinutes: fiveMinutes,
      externalFilesDir: externalFilesDir,
      deviceInfo: deviceInfo,
      diagnostics: diagnostics,
      minAudioCtx: minAudioCtx,
      firstPartialLagsSec: firstPartialLagsSec,
      recordedChunkData: recordedChunkData,
    );
  }

  static String saveReport({
    required bool fiveMinutes,
    required String externalFilesDir,
    required DeviceInfo? deviceInfo,
    required DiagnosticsTracker diagnostics,
    required int minAudioCtx,
    required List<double> firstPartialLagsSec,
    required List<Map<String, dynamic>> recordedChunkData,
  }) {
    final fullText = recordedChunkData.map((c) => c['text'] as String).join(' ');
    final analysis = DiagnosticsTracker.evaluatePhoneticTestScript(fullText);

    final deviceString = deviceInfo != null
        ? '${deviceInfo.manufacturer} ${deviceInfo.model} (${deviceInfo.socModel})'
        : 'Unknown Android Device';

    final report = {
      'timestamp': DateTime.now().toIso8601String(),
      'benchmarkType':
          fiveMinutes ? '5_minute_continuous_session' : 'phonetic_test_script',
      'device': deviceString,
      'model': 'ggml-small.en-q5_0.bin',
      'vad': 'ggml-silero-v6.2.0.bin (Streaming)',
      'summary': {
        'medianTLagSec': diagnostics.medianTLagSec,
        'maxTLagSec': diagnostics.maxTLagSec,
        'averageRtf': diagnostics.averageRtf,
        'bufferOverrunCount': diagnostics.overrunCount,
        'peakRssMb': diagnostics.peakRssMb,
        'thermalStatus': diagnostics.thermalStatus,
        'clockDiscrepancyPercent': diagnostics.audioClockDiscrepancyPercent,
        'tLagPass': diagnostics.tLagPass,
        'audioIntegrityPass': diagnostics.audioIntegrityPass,
        'fillerPass': analysis.passed,
        'fillerRetainedCount': analysis.retainedCount,
        'fillerTotalCount': analysis.totalCount,
        'fillerRetainedPercent': analysis.retainedPercent,
        'minAudioCtx': minAudioCtx,
        'partialCount': firstPartialLagsSec.length,
        'medianFirstPartialSec': DiagnosticsTracker.median(firstPartialLagsSec),
      },
      'fillerDetails': analysis.details,
      'chunks': recordedChunkData,
      'fullTranscript': fullText,
    };

    final outDir = Directory('$externalFilesDir/out');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final outFile = File(
      '$externalFilesDir/out/benchmark_${fiveMinutes ? "5min" : "phonetic"}_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    outFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    return outFile.path;
  }
}
