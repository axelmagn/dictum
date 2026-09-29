import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'audio_utils.dart';
import 'whisper_ffi.dart';

const String kVerbatimPrompt = "Umm, so, I-I was like, hmm... uh, you know, I— I mean.";

class BenchmarkConfig {
  final String modelPath;
  final String modelName;
  final String vadModelPath;
  final String audioPath;
  final String audioName;
  final String mode; // 'C1', 'C2', 'C3'
  final int threads;
  final String prompt;
  final String outDir;
  final String runId;

  BenchmarkConfig({
    required this.modelPath,
    required this.modelName,
    required this.vadModelPath,
    required this.audioPath,
    required this.audioName,
    required this.mode,
    required this.threads,
    this.prompt = kVerbatimPrompt,
    required this.outDir,
    String? runId,
  }) : runId = runId ?? "${modelName}__${mode}__th${threads}__${audioName.replaceAll('.wav', '')}";
}

class ChunkRecord {
  final int chunkIndex;
  final double startSec;
  final double endSec;
  final double durationSec;
  final int wallTimeMs;
  final double rtf;
  final int segmentCount;

  ChunkRecord({
    required this.chunkIndex,
    required this.startSec,
    required this.endSec,
    required this.durationSec,
    required this.wallTimeMs,
    required this.rtf,
    required this.segmentCount,
  });

  Map<String, dynamic> toJson() => {
    'chunkIndex': chunkIndex,
    'startSec': startSec,
    'endSec': endSec,
    'durationSec': durationSec,
    'wallTimeMs': wallTimeMs,
    'rtf': rtf,
    'segmentCount': segmentCount,
  };
}

class BenchmarkResult {
  final String runId;
  final Map<String, dynamic> device;
  final String systemInfo;
  final String model;
  final String mode;
  final int threads;
  final String audioFile;
  final double audioDurationSec;
  final int modelLoadTimeMs;
  final int vadTimeMs;
  final int transcribeWallTimeMs;
  final int totalWallTimeMs;
  final double rtf;
  final int peakRssKb;
  final double peakRssMb;
  final int vmHwmKb;
  final double vmHwmMb;
  final int thermalStart;
  final int thermalEnd;
  final int batteryPercentStart;
  final int batteryPercentEnd;
  final int batteryDelta;
  final List<ChunkRecord> perChunkTimeline;
  final List<WhisperSegment> segments;

  BenchmarkResult({
    required this.runId,
    required this.device,
    required this.systemInfo,
    required this.model,
    required this.mode,
    required this.threads,
    required this.audioFile,
    required this.audioDurationSec,
    required this.modelLoadTimeMs,
    required this.vadTimeMs,
    required this.transcribeWallTimeMs,
    required this.totalWallTimeMs,
    required this.rtf,
    required this.peakRssKb,
    required this.peakRssMb,
    required this.vmHwmKb,
    required this.vmHwmMb,
    required this.thermalStart,
    required this.thermalEnd,
    required this.batteryPercentStart,
    required this.batteryPercentEnd,
    required this.batteryDelta,
    required this.perChunkTimeline,
    required this.segments,
  });

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'device': device,
    'systemInfo': systemInfo,
    'model': model,
    'mode': mode,
    'threads': threads,
    'audioFile': audioFile,
    'audioDurationSec': audioDurationSec,
    'timings': {
      'modelLoadTimeMs': modelLoadTimeMs,
      'vadTimeMs': vadTimeMs,
      'transcribeWallTimeMs': transcribeWallTimeMs,
      'totalWallTimeMs': totalWallTimeMs,
      'rtf': rtf,
    },
    'memory': {
      'peakRssKb': peakRssKb,
      'peakRssMb': peakRssMb,
      'vmHwmKb': vmHwmKb,
      'vmHwmMb': vmHwmMb,
    },
    'thermal': {
      'thermalStart': thermalStart,
      'thermalEnd': thermalEnd,
    },
    'battery': {
      'batteryPercentStart': batteryPercentStart,
      'batteryPercentEnd': batteryPercentEnd,
      'batteryDelta': batteryDelta,
    },
    'perChunkTimeline': perChunkTimeline.map((c) => c.toJson()).toList(),
    'segmentCount': segments.length,
    'segments': segments.map((s) => s.toJson()).toList(),
  };

  String toTranscriptText() {
    final sb = StringBuffer();
    for (final seg in segments) {
      final t0Str = _formatTimestamp(seg.t0);
      final t1Str = _formatTimestamp(seg.t1);
      sb.writeln('[$t0Str --> $t1Str]   ${seg.text.trimLeft()}');
    }
    return sb.toString();
  }

  static String _formatTimestamp(double seconds) {
    final totalMs = (seconds * 1000).round();
    final ms = (totalMs % 1000).clamp(0, 999);
    final totalSec = totalMs ~/ 1000;
    final s = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final m = totalMin % 60;
    final h = totalMin ~/ 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${ms.toString().padLeft(3, '0')}';
  }
}

class _WorkerParams {
  final String modelPath;
  final String vadModelPath;
  final String mode;
  final int threads;
  final String prompt;
  final Float32List samples;
  final double durationSeconds;

  _WorkerParams({
    required this.modelPath,
    required this.vadModelPath,
    required this.mode,
    required this.threads,
    required this.prompt,
    required this.samples,
    required this.durationSeconds,
  });
}

class _WorkerOutput {
  final int modelLoadTimeMs;
  final int vadTimeMs;
  final int transcribeWallTimeMs;
  final List<ChunkRecord> perChunkTimeline;
  final List<WhisperSegment> segments;

  _WorkerOutput({
    required this.modelLoadTimeMs,
    required this.vadTimeMs,
    required this.transcribeWallTimeMs,
    required this.perChunkTimeline,
    required this.segments,
  });
}

class BenchmarkRunner {
  static const MethodChannel _channel = MethodChannel('dev.dictum.spike/device');

  static Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      final res = await _channel.invokeMethod<Map>('getDeviceInfo');
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  static Future<int> getThermalStatus() async {
    try {
      final res = await _channel.invokeMethod<int>('getThermalStatus');
      return res ?? -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<Map<String, dynamic>> getBatteryStatus() async {
    try {
      final res = await _channel.invokeMethod<Map>('getBatteryStatus');
      return Map<String, dynamic>.from(res ?? {});
    } catch (_) {
      return {'percent': -1, 'isCharging': false};
    }
  }

  static int readVmRssKb() {
    try {
      final file = File('/proc/self/status');
      if (!file.existsSync()) return 0;
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        if (line.startsWith('VmRSS:')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            return int.tryParse(parts[1]) ?? 0;
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  static int readVmHwmKb() {
    try {
      final file = File('/proc/self/status');
      if (!file.existsSync()) return 0;
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        if (line.startsWith('VmHWM:')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            return int.tryParse(parts[1]) ?? 0;
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  /// Executes a single benchmark run.
  static Future<BenchmarkResult> runBenchmark(
    BenchmarkConfig config, {
    void Function(String msg)? onLog,
  }) async {
    void log(String s) {
      if (onLog != null) onLog(s);
    }

    log("Starting benchmark: ${config.runId}");
    final deviceInfo = await getDeviceInfo();
    final thermalStart = await getThermalStatus();
    final batteryStartMap = await getBatteryStatus();
    final batteryStart = batteryStartMap['percent'] as int? ?? -1;

    // Load audio
    log("Loading audio: ${config.audioPath}");
    final audio = await AudioUtils.loadWavFile(config.audioPath);
    log("Audio loaded: ${audio.durationSeconds.toStringAsFixed(2)}s (${audio.samples.length} samples)");

    // System info via FFI
    final sysInfo = WhisperBindings.instance.getSystemInfo();

    // Setup RSS sampling timer (500 ms)
    int peakRss = readVmRssKb();
    final rssTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final current = readVmRssKb();
      if (current > peakRss) {
        peakRss = current;
      }
    });

    final stopwatch = Stopwatch()..start();

    // Run transcription in background isolate
    final workerParams = _WorkerParams(
      modelPath: config.modelPath,
      vadModelPath: config.vadModelPath,
      mode: config.mode,
      threads: config.threads,
      prompt: config.prompt,
      samples: audio.samples,
      durationSeconds: audio.durationSeconds,
    );

    _WorkerOutput output;
    try {
      log("Launching worker isolate for mode ${config.mode}...");
      output = await _runWorker(workerParams);
    } finally {
      rssTimer.cancel();
      stopwatch.stop();
    }

    final vmHwm = readVmHwmKb();
    if (vmHwm > peakRss) {
      peakRss = vmHwm;
    }

    final thermalEnd = await getThermalStatus();
    final batteryEndMap = await getBatteryStatus();
    final batteryEnd = batteryEndMap['percent'] as int? ?? -1;
    final batteryDelta = (batteryStart != -1 && batteryEnd != -1) ? (batteryStart - batteryEnd) : 0;

    final totalWallTimeMs = stopwatch.elapsedMilliseconds;
    final rtf = output.transcribeWallTimeMs / (audio.durationSeconds * 1000.0);

    log("Completed: Wall ${output.transcribeWallTimeMs}ms, RTF ${rtf.toStringAsFixed(3)}, Peak RSS ${(peakRss / 1024.0).toStringAsFixed(1)}MB, Segments ${output.segments.length}");

    final result = BenchmarkResult(
      runId: config.runId,
      device: deviceInfo,
      systemInfo: sysInfo,
      model: config.modelName,
      mode: config.mode,
      threads: config.threads,
      audioFile: config.audioName,
      audioDurationSec: audio.durationSeconds,
      modelLoadTimeMs: output.modelLoadTimeMs,
      vadTimeMs: output.vadTimeMs,
      transcribeWallTimeMs: output.transcribeWallTimeMs,
      totalWallTimeMs: totalWallTimeMs,
      rtf: rtf,
      peakRssKb: peakRss,
      peakRssMb: peakRss / 1024.0,
      vmHwmKb: vmHwm,
      vmHwmMb: vmHwm / 1024.0,
      thermalStart: thermalStart,
      thermalEnd: thermalEnd,
      batteryPercentStart: batteryStart,
      batteryPercentEnd: batteryEnd,
      batteryDelta: batteryDelta,
      perChunkTimeline: output.perChunkTimeline,
      segments: output.segments,
    );

    // Save JSON and TXT
    try {
      final outDir = Directory(config.outDir);
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }

      final jsonFile = File('${config.outDir}/${config.runId}.json');
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.toJson()));

      final txtFile = File('${config.outDir}/${config.runId}.txt');
      txtFile.writeAsStringSync(result.toTranscriptText());
      log("Wrote result files to ${jsonFile.path} and ${txtFile.path}");
    } catch (e) {
      log("Error writing results: $e");
    }

    return result;
  }

  static Future<_WorkerOutput> _runWorker(_WorkerParams params) {
    return Isolate.run(() => _executeTranscription(params));
  }
}

/// Top-level worker method executed in background isolate.
_WorkerOutput _executeTranscription(_WorkerParams params) {
  final whisper = WhisperBindings.instance;

    // 1. Load model
    final loadSw = Stopwatch()..start();
    final ctx = whisper.initContext(params.modelPath);
    loadSw.stop();
    if (ctx.address == 0) {
      throw StateError("Failed to initialize whisper context with model: ${params.modelPath}");
    }

    int vadTimeMs = 0;
    int transcribeWallTimeMs = 0;
    final perChunkTimeline = <ChunkRecord>[];
    final allSegments = <WhisperSegment>[];

    try {
      if (params.mode == 'C1') {
        // Mode C1: Whole file, one dw_transcribe call, prompt once, carry_initial_prompt = 0
        final trSw = Stopwatch()..start();
        final ret = whisper.transcribe(
          ctx: ctx,
          samples: params.samples,
          prompt: params.prompt,
          nThreads: params.threads,
          carryPrompt: false,
        );
        trSw.stop();
        if (ret != 0) {
          throw StateError("whisper.transcribe failed with code $ret");
        }
        transcribeWallTimeMs = trSw.elapsedMilliseconds;
        allSegments.addAll(whisper.getSegments(ctx));
      } else if (params.mode == 'C3') {
        // Mode C3: Whole file, one dw_transcribe call, carry_initial_prompt = 1
        final trSw = Stopwatch()..start();
        final ret = whisper.transcribe(
          ctx: ctx,
          samples: params.samples,
          prompt: params.prompt,
          nThreads: params.threads,
          carryPrompt: true,
        );
        trSw.stop();
        if (ret != 0) {
          throw StateError("whisper.transcribe failed with code $ret");
        }
        transcribeWallTimeMs = trSw.elapsedMilliseconds;
        allSegments.addAll(whisper.getSegments(ctx));
      } else if (params.mode == 'C2') {
        // Mode C2: App-level VAD chunks <= 30s split at silences; prompt on every chunk, no_context=1
        final vadSw = Stopwatch()..start();
        final vctx = whisper.initVadContext(params.vadModelPath);
        if (vctx.address == 0) {
          throw StateError("Failed to initialize VAD context with model: ${params.vadModelPath}");
        }

        List<VadSegment> vadSegments;
        try {
          vadSegments = whisper.detectVadSegments(vctx: vctx, samples: params.samples);
        } finally {
          whisper.freeVadContext(vctx);
          vadSw.stop();
        }
        vadTimeMs = vadSw.elapsedMilliseconds;

        // Group VAD segments into chunks <= 30s
        final chunks = _buildVadChunks(vadSegments, params.durationSeconds);

        final totalTrSw = Stopwatch()..start();
        for (int i = 0; i < chunks.length; i++) {
          final chunk = chunks[i];
          final startSample = (chunk.startSec * 16000).round().clamp(0, params.samples.length);
          final endSample = (chunk.endSec * 16000).round().clamp(startSample, params.samples.length);
          final chunkSamples = params.samples.sublist(startSample, endSample);
          final chunkDuration = chunk.endSec - chunk.startSec;

          final chunkSw = Stopwatch()..start();
          final ret = whisper.transcribe(
            ctx: ctx,
            samples: chunkSamples,
            prompt: params.prompt,
            nThreads: params.threads,
            carryPrompt: false,
          );
          chunkSw.stop();
          if (ret != 0) {
            throw StateError("whisper.transcribe failed on chunk $i with code $ret");
          }

          final chunkWallMs = chunkSw.elapsedMilliseconds;
          final chunkRtf = chunkDuration > 0 ? (chunkWallMs / (chunkDuration * 1000.0)) : 0.0;
          final chunkSegs = whisper.getSegments(ctx, offsetSeconds: chunk.startSec);
          allSegments.addAll(chunkSegs);

          perChunkTimeline.add(ChunkRecord(
            chunkIndex: i,
            startSec: chunk.startSec,
            endSec: chunk.endSec,
            durationSec: chunkDuration,
            wallTimeMs: chunkWallMs,
            rtf: chunkRtf,
            segmentCount: chunkSegs.length,
          ));
        }
        totalTrSw.stop();
        transcribeWallTimeMs = totalTrSw.elapsedMilliseconds;
      } else {
        throw ArgumentError("Unknown mode: ${params.mode}");
      }
    } finally {
      whisper.freeContext(ctx);
    }

    return _WorkerOutput(
      modelLoadTimeMs: loadSw.elapsedMilliseconds,
      vadTimeMs: vadTimeMs,
      transcribeWallTimeMs: transcribeWallTimeMs,
      perChunkTimeline: perChunkTimeline,
      segments: allSegments,
    );
  }

  /// Groups VAD speech segments into continuous chunks <= 30s, splitting only at silence gaps.
  List<_TimeRange> _buildVadChunks(List<VadSegment> vadSegments, double totalDurationSec) {
    if (vadSegments.isEmpty) {
      // Fallback if no speech detected: fixed 30s slices
      final list = <_TimeRange>[];
      double cur = 0.0;
      while (cur < totalDurationSec) {
        final end = min(cur + 30.0, totalDurationSec);
        list.add(_TimeRange(cur, end));
        cur = end;
      }
      return list;
    }

    final speechGroups = <List<VadSegment>>[];
    List<VadSegment> currentGroup = [vadSegments[0]];
    double groupStart = vadSegments[0].t0;

    for (int i = 1; i < vadSegments.length; i++) {
      final seg = vadSegments[i];
      final potentialDuration = seg.t1 - groupStart;

      if (potentialDuration <= 30.0) {
        currentGroup.add(seg);
      } else {
        speechGroups.add(currentGroup);
        currentGroup = [seg];
        groupStart = seg.t0;
      }
    }
    if (currentGroup.isNotEmpty) {
      speechGroups.add(currentGroup);
    }

    // Now turn each group into an audio chunk by splitting at silences
    final chunks = <_TimeRange>[];
    for (int i = 0; i < speechGroups.length; i++) {
      final grp = speechGroups[i];
      final firstSeg = grp.first;
      final lastSeg = grp.last;

      double chunkStart;
      if (i == 0) {
        chunkStart = 0.0;
      } else {
        final prevLastSeg = speechGroups[i - 1].last;
        chunkStart = (prevLastSeg.t1 + firstSeg.t0) / 2.0;
      }

      double chunkEnd;
      if (i == speechGroups.length - 1) {
        chunkEnd = totalDurationSec;
      } else {
        final nextFirstSeg = speechGroups[i + 1].first;
        chunkEnd = (lastSeg.t1 + nextFirstSeg.t0) / 2.0;
      }

      chunks.add(_TimeRange(chunkStart, chunkEnd));
    }

    return chunks;
  }

class _TimeRange {
  final double startSec;
  final double endSec;
  _TimeRange(this.startSec, this.endSec);
}
