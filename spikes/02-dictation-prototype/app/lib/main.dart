import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'audio_capture.dart';
import 'audio_player.dart';
import 'audio_utils.dart';
import 'benchmark_runner.dart';
import 'device_service.dart';
import 'diagnostics.dart';
import 'inline_progress.dart';
import 'pipeline_telemetry.dart';
import 'vad_chunker.dart';
import 'whisper_worker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DictationPrototypeApp());
}

enum AppMode {
  liveMic,
  benchmarking,
}

enum PipelineState {
  idle,
  requestingPermission,
  recording,
  stopping,
  review,
}

enum ChunkStage {
  buffering,
  preview,
  finalized,
}

class DictationChunkViewData {
  final int chunkIndex;
  final ChunkStage stage;
  final String text;
  final double progress;
  final ValueNotifier<double>? progressNotifier;
  final double tLagSec;
  final double rtf;
  final double durationSec;
  final double t0;
  final double t1;
  final int lastChunkIndex;
  final int audioCtx;

  const DictationChunkViewData({
    required this.chunkIndex,
    this.stage = ChunkStage.finalized,
    required this.text,
    this.progress = 1.0,
    this.progressNotifier,
    required this.tLagSec,
    required this.rtf,
    required this.durationSec,
    required this.t0,
    required this.t1,
    required this.lastChunkIndex,
    this.audioCtx = 0,
  });

  double get currentProgress => progressNotifier?.value ?? progress;

  DictationChunkViewData copyWith({
    int? chunkIndex,
    ChunkStage? stage,
    String? text,
    double? progress,
    ValueNotifier<double>? progressNotifier,
    double? tLagSec,
    double? rtf,
    double? durationSec,
    double? t0,
    double? t1,
    int? lastChunkIndex,
    int? audioCtx,
  }) {
    return DictationChunkViewData(
      chunkIndex: chunkIndex ?? this.chunkIndex,
      stage: stage ?? this.stage,
      text: text ?? this.text,
      progress: progress ?? this.progress,
      progressNotifier: progressNotifier ?? this.progressNotifier,
      tLagSec: tLagSec ?? this.tLagSec,
      rtf: rtf ?? this.rtf,
      durationSec: durationSec ?? this.durationSec,
      t0: t0 ?? this.t0,
      t1: t1 ?? this.t1,
      lastChunkIndex: lastChunkIndex ?? this.lastChunkIndex,
      audioCtx: audioCtx ?? this.audioCtx,
    );
  }

  Map<String, dynamic> toJson() => {
    'index': chunkIndex,
    'stage': stage.name,
    'progress': currentProgress,
    'lastIndex': lastChunkIndex,
    'audioCtx': audioCtx,
    't0': t0,
    't1': t1,
    'duration': durationSec,
    'tLagSec': tLagSec,
    'rtf': rtf,
    'text': text,
  };
}

class DictationPrototypeApp extends StatelessWidget {
  const DictationPrototypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike 02 — Dictation Prototype',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F1117),
        cardColor: const Color(0xFF1A1D27),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF10B981),
          error: Color(0xFFEF4444),
          surface: Color(0xFF1A1D27),
        ),
      ),
      home: const DictationHomeScreen(),
    );
  }
}

class DictationHomeScreen extends StatefulWidget {
  const DictationHomeScreen({super.key});

  @override
  State<DictationHomeScreen> createState() => DictationHomeScreenState();
}

class DictationHomeScreenState extends State<DictationHomeScreen> {
  @visibleForTesting
  void addChunkForTesting(DictationChunkViewData chunk) {
    setState(() {
      _chunks.add(chunk);
    });
  }

  @visibleForTesting
  void updateChunkForTesting(int index, DictationChunkViewData chunk) {
    setState(() {
      _chunks[index] = chunk;
    });
  }

  @visibleForTesting
  void setPartialForTesting(String text) {
    setState(() {
      _partialText = text;
    });
  }

  @visibleForTesting
  void setFinalTranscriptForTesting(String? text) {
    setState(() {
      _finalVerbatimTranscript = text;
    });
  }

  @visibleForTesting
  void setIsRunningFinalPassForTesting(bool isRunning) {
    setState(() {
      _isRunningFinalPass = isRunning;
    });
  }

  @visibleForTesting
  void setIsAccumulatingChunkForTesting(bool isAccumulating) {
    setState(() {
      _isAccumulatingChunk = isAccumulating;
    });
  }

  @visibleForTesting
  void setShowTelemetryDeckForTesting(bool show) {
    setState(() {
      _showTelemetryDeck = show;
    });
  }

  @visibleForTesting
  void setPipelineStateForTesting(PipelineState state) {
    setState(() {
      _state = state;
    });
  }

  @visibleForTesting
  ValueNotifier<double> get finalPassProgressForTesting => _finalPassProgress;
  // Device & paths
  DeviceInfo? _deviceInfo;
  String _externalFilesDir = '';
  String _modelPath = '';
  String _vadModelPath = '';
  String _testAudioPath = '';
  bool _modelsReady = false;

  // Controllers & engines
  final AudioCaptureController _captureController = AudioCaptureController();
  final AudioPlayerController _playerController = AudioPlayerController();
  final StreamingVadChunker _vadChunker = StreamingVadChunker();
  final DiagnosticsTracker _diagnostics = DiagnosticsTracker();
  final PipelineTelemetryController _telemetry = PipelineTelemetryController();
  WhisperWorker? _whisperWorker;

  // Pipeline State
  PipelineState _state = PipelineState.idle;
  AppMode _mode = AppMode.liveMic;
  String _activeWavPath = '';

  // Stream subscriptions & tickers
  StreamSubscription? _audioFrameSub;
  StreamSubscription? _whisperSub;
  StreamSubscription? _workerStatusSub;
  StreamSubscription? _playerSub;
  Timer? _durationTimer;
  Timer? _diagnosticsTimer;
  Timer? _stoppingTimeoutTimer;
  Timer? _finalPassTimer;

  // UI State
  int _recordingDurationMs = 0;
  final ValueNotifier<double> _vuMeterLevel = ValueNotifier<double>(0.0);
  final List<DictationChunkViewData> _chunks = [];
  final ScrollController _scrollController = ScrollController();
  bool _isRunningFinalPass = false;
  final ValueNotifier<double> _finalPassProgress = ValueNotifier<double>(0.0);
  String? _finalVerbatimTranscript;
  bool _showTelemetryDeck = false;
  bool _isAccumulatingChunk = false;

  // Live partials & backlog tracking
  static const int _partialIntervalMs = 1000;
  static const int _firstPartialAfterMs = 500;
  static const List<int> _audioCtxOptions = [0, 256, 384, 512, 768]; // 0 = full 30 s
  int _minAudioCtx = 512;
  String _partialText = '';
  int _partialIndex = -1;
  int _lastPartialSubmitMs = 0;
  int _lastFinalIndex = -1;
  bool _wasInSpeech = false;
  int _utteranceOnsetMs = 0;
  int _firstPartialIndex = -1;
  final List<double> _firstPartialLagsSec = [];
  AudioPlayerStatus _playerStatus = AudioPlayerStatus.idle;

  // Benchmarking status
  String _benchmarkStatusText = '';
  FillerAnalysis? _lastFillerAnalysis;

  @override
  void initState() {
    super.initState();
    _initEnvironment();
  }

  Future<void> _initEnvironment() async {
    _deviceInfo = await DeviceService.getDeviceInfo();
    _externalFilesDir = _deviceInfo?.externalFilesDir ?? '';

    if (_externalFilesDir.isEmpty) {
      _externalFilesDir = '/sdcard/Android/data/dev.dictum.spike.app/files';
    }

    _modelPath = '$_externalFilesDir/models/ggml-small.en-q5_0.bin';
    _vadModelPath = '$_externalFilesDir/models/ggml-silero-v6.2.0.bin';
    _testAudioPath = '$_externalFilesDir/audio/phonetic_test.wav';

    // Verify model files exist
    final modelExists = File(_modelPath).existsSync();
    final vadExists = File(_vadModelPath).existsSync();

    if (modelExists && vadExists) {
      _vadChunker.init(_vadModelPath);
      _whisperWorker = await WhisperWorker.spawn(_modelPath);

      _whisperSub = _whisperWorker!.responses.listen(_onWhisperChunkReceived);
      _workerStatusSub = _whisperWorker!.statusUpdates.listen((status) {
        _telemetry.updateWorker(status);
        if (status.isFinalPass && status.progress > 0) {
          if (_finalPassProgress.value < status.progress) {
            _finalPassProgress.value = status.progress;
          }
        } else if (!status.isFinalPass) {
          final activeIdx = _chunks.indexWhere((c) =>
              (status.activeChunkIndex != null && c.chunkIndex == status.activeChunkIndex) ||
              (status.activeChunkIndex == null && c.stage != ChunkStage.finalized));
          if (activeIdx != -1) {
            final inferProg = status.progress > 0 ? status.progress : (status.isBusy ? 0.5 : 0.0);
            final newProg = (0.5 + (inferProg * 0.5)).clamp(0.5, 0.98);
            _chunks[activeIdx].progressNotifier?.value = newProg;
          }
        }
      });
      _playerSub = _playerController.statusStream.listen((status) {
        if (mounted) setState(() => _playerStatus = status);
      });

      setState(() {
        _modelsReady = true;
      });
    } else {
      setState(() {
        _modelsReady = false;
        _benchmarkStatusText = 'Models missing at $_modelPath or $_vadModelPath';
      });
    }

    // Diagnostics polling (every 1 second)
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _diagnostics.pollDeviceStatus();
      if (mounted) setState(() {});
    });
  }

  void _onWhisperChunkReceived(WhisperChunkResponse resp) {
    final tRenderMs = DateTime.now().millisecondsSinceEpoch;

    if (resp.isFinalPass) {
      if (!mounted) return;
      _finalPassTimer?.cancel();
      _finalPassProgress.value = 1.0;
      setState(() {
        _finalVerbatimTranscript = resp.text.trim();
        _isRunningFinalPass = false;
      });
      _finalizeReview();
      _scrollToBottom();
      return;
    }

    if (resp.isPartial) {
      // Stale: utterance already finalized.
      if (resp.chunkIndex <= _lastFinalIndex || !mounted) return;
      if (_firstPartialIndex != resp.chunkIndex && resp.text.isNotEmpty) {
        _firstPartialIndex = resp.chunkIndex;
        _firstPartialLagsSec.add((tRenderMs - _utteranceOnsetMs) / 1000.0);
      }
      setState(() {
        _isAccumulatingChunk = false;
        _partialIndex = resp.chunkIndex;
        _partialText = resp.text;
        final targetIdx = _chunks.indexWhere((c) => c.chunkIndex == resp.chunkIndex);
        if (targetIdx != -1) {
          final notifier = _chunks[targetIdx].progressNotifier ?? ValueNotifier<double>(0.0);
          notifier.value = 0.0;
          _chunks[targetIdx] = _chunks[targetIdx].copyWith(
            stage: ChunkStage.preview,
            text: resp.text,
            progress: 0.0,
            progressNotifier: notifier,
          );
        } else {
          _chunks.add(DictationChunkViewData(
            chunkIndex: resp.chunkIndex,
            stage: ChunkStage.preview,
            text: resp.text,
            progress: 0.0,
            progressNotifier: ValueNotifier<double>(0.0),
            tLagSec: 0.0,
            rtf: 0.0,
            durationSec: resp.audioDurationSec,
            t0: resp.masterT0Sec,
            t1: resp.masterT1Sec,
            lastChunkIndex: resp.chunkIndex,
          ));
        }
        _chunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      });
      _scrollToBottom();
      return;
    }
    _lastFinalIndex = resp.lastChunkIndex;
    final tLagSec = (tRenderMs - resp.tPauseDetectedMs) / 1000.0;

    _diagnostics.addChunkMetric(
      chunkIndex: resp.chunkIndex,
      tLagSec: tLagSec,
      rtf: resp.rtf,
      audioDurationSec: resp.audioDurationSec,
      transcribeSec: resp.transcribeSec,
      text: resp.text,
    );

    if (mounted) {
      setState(() {
        _isAccumulatingChunk = false;
        final finalChunk = DictationChunkViewData(
          chunkIndex: resp.chunkIndex,
          stage: ChunkStage.finalized,
          text: resp.text,
          progress: 1.0,
          tLagSec: tLagSec,
          rtf: resp.rtf,
          durationSec: resp.audioDurationSec,
          t0: resp.masterT0Sec,
          t1: resp.masterT1Sec,
          lastChunkIndex: resp.lastChunkIndex,
          audioCtx: resp.audioCtx,
        );

        final matchIdx = _chunks.indexWhere((c) =>
            c.chunkIndex >= resp.chunkIndex && c.chunkIndex <= resp.lastChunkIndex);

        if (matchIdx != -1) {
          _chunks[matchIdx].progressNotifier?.dispose();
          _chunks[matchIdx] = finalChunk;
          _chunks.removeWhere((c) =>
              c != finalChunk &&
              c.chunkIndex >= resp.chunkIndex &&
              c.chunkIndex <= resp.lastChunkIndex);
        } else {
          _chunks.add(finalChunk);
        }

        _chunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

        if (_partialIndex <= resp.lastChunkIndex) {
          _partialText = '';
          _partialIndex = -1;
        }

        // Transition to review once every submitted chunk is transcribed
        if (_state == PipelineState.stopping && _allFinalsReceived) {
          _finishStopping();
        }
      });

      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- Live Recording Flow ---

  Future<void> _startLiveRecording() async {
    if (!_modelsReady || _whisperWorker == null) return;

    setState(() => _state = PipelineState.requestingPermission);

    final hasPerm = await _captureController.hasPermission();
    if (!hasPerm) {
      final granted = await _captureController.requestPermission();
      if (!granted) {
        setState(() => _state = PipelineState.idle);
        _showError('Microphone permission required');
        return;
      }
    }

    _activeWavPath =
        '$_externalFilesDir/recording_${DateTime.now().millisecondsSinceEpoch}.wav';

    _diagnostics.reset();
    _vadChunker.reset();
    _telemetry.reset();
    _resetStreamingState();
    _chunks.clear();
    _finalVerbatimTranscript = null;
    _isRunningFinalPass = false;
    _lastFillerAnalysis = null;
    _recordingDurationMs = 0;
    _vuMeterLevel.value = 0.0;
    _mode = AppMode.liveMic;

    final started = await _captureController.startRecording(_activeWavPath);
    if (!started) {
      setState(() => _state = PipelineState.idle);
      _showError('Failed to initialize AudioRecord native capture thread');
      return;
    }

    _audioFrameSub?.cancel();
    _audioFrameSub = _captureController.audioFrames.listen(_processAudioFrame);

    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _state == PipelineState.recording) {
        setState(() {
          _recordingDurationMs += 100;
        });
      }
    });

    setState(() => _state = PipelineState.recording);
  }

  bool get _allFinalsReceived =>
      _lastFinalIndex >= _vadChunker.chunkCounter - 1;

  void _resetStreamingState() {
    for (final c in _chunks) {
      c.progressNotifier?.dispose();
    }
    _partialText = '';
    _partialIndex = -1;
    _lastPartialSubmitMs = 0;
    _lastFinalIndex = -1;
    _wasInSpeech = false;
    _isAccumulatingChunk = false;
    _utteranceOnsetMs = 0;
    _firstPartialIndex = -1;
    _firstPartialLagsSec.clear();
  }

  void _submitFinal(SpeechChunk chunk) {
    final activeIdx = _chunks.indexWhere((c) => c.chunkIndex == chunk.chunkIndex);
    if (activeIdx != -1) {
      _chunks[activeIdx].progressNotifier?.value = 0.5;
    }
    _whisperWorker?.submitChunk(
      chunkIndex: chunk.chunkIndex,
      samples: chunk.samples,
      tPauseDetectedMs: chunk.tPauseDetectedMs,
      masterSampleOffset: chunk.masterSampleOffset,
      minAudioCtx: _minAudioCtx,
    );
  }

  void _processAudioFrame(Float32List frame512) {
    // Update VU meter (RMS) via ValueNotifier without full rebuild
    double sum = 0.0;
    for (int i = 0; i < frame512.length; i++) {
      sum += frame512[i] * frame512[i];
    }
    final rms = sqrt(sum / frame512.length);
    _vuMeterLevel.value = (rms * 4.0).clamp(0.0, 1.0);

    // Feed streaming VAD
    final chunk = _vadChunker.feedFrame(frame512);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_vadChunker.inSpeech && !_wasInSpeech) {
      _utteranceOnsetMs = nowMs;
      _lastPartialSubmitMs = nowMs - _partialIntervalMs + _firstPartialAfterMs;
      final currentIdx = _vadChunker.chunkCounter;
      if (mounted) {
        setState(() {
          _isAccumulatingChunk = true;
          if (!_chunks.any((c) => c.chunkIndex == currentIdx)) {
            _chunks.add(DictationChunkViewData(
              chunkIndex: currentIdx,
              stage: ChunkStage.buffering,
              text: '',
              progress: 0.05,
              progressNotifier: ValueNotifier<double>(0.05),
              tLagSec: 0.0,
              rtf: 0.0,
              durationSec: 0.0,
              t0: _vadChunker.currentUtteranceStartOffset / 16000.0,
              t1: _vadChunker.currentUtteranceStartOffset / 16000.0,
              lastChunkIndex: currentIdx,
            ));
            _chunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
          }
        });
      }
    } else if (!_vadChunker.inSpeech && _wasInSpeech && _partialText.isEmpty && _isAccumulatingChunk) {
      if (mounted) {
        setState(() {
          _isAccumulatingChunk = false;
          _chunks.removeWhere((c) =>
              c.stage == ChunkStage.buffering &&
              c.text.isEmpty &&
              c.chunkIndex >= _vadChunker.chunkCounter);
        });
      }
    }
    _wasInSpeech = _vadChunker.inSpeech;

    // Update active in-flight chunk progress for the currently speaking utterance
    final currentIdx = _vadChunker.chunkCounter;
    final activeIdx = _chunks.indexWhere((c) => c.chunkIndex == currentIdx && c.stage != ChunkStage.finalized);
    if (activeIdx != -1) {
      final active = _chunks[activeIdx];
      if (active.stage == ChunkStage.buffering) {
        final elapsed = nowMs - _utteranceOnsetMs;
        final isWaitingWorker = elapsed >= _firstPartialAfterMs;
        final prog = isWaitingWorker
            ? 0.90
            : (elapsed / _firstPartialAfterMs).clamp(0.05, 0.85);
        active.progressNotifier?.value = prog;
      } else if (active.stage == ChunkStage.preview) {
        final pauseFrames = _vadChunker.consecutivePauseFrames;
        final maxFrames = _vadChunker.targetPauseFrames;
        if (pauseFrames > 0 && maxFrames > 0) {
          final pauseProg = (pauseFrames / maxFrames).clamp(0.0, 1.0) * 0.5;
          active.progressNotifier?.value = pauseProg;
        }
      }
    }

    final elapsedSincePartial = nowMs - _lastPartialSubmitMs;
    _telemetry.updateFrame(
      rms: rms,
      prob: _vadChunker.lastSpeechProb,
      consecutivePause: _vadChunker.consecutivePauseFrames,
      maxPause: _vadChunker.targetPauseFrames,
      isSpeaking: _vadChunker.inSpeech,
      elapsedSincePartialMs: elapsedSincePartial,
      partialIntervalMs: _partialIntervalMs,
    );

    if (chunk != null) {
      _submitFinal(chunk);
    } else if (_vadChunker.inSpeech &&
        nowMs - _lastPartialSubmitMs >= _partialIntervalMs) {
      final samples = _vadChunker.currentUtteranceSamples();
      if (samples != null) {
        _lastPartialSubmitMs = nowMs;
        _whisperWorker?.submitChunk(
          chunkIndex: _vadChunker.chunkCounter,
          samples: samples,
          tPauseDetectedMs: nowMs,
          masterSampleOffset: _vadChunker.currentUtteranceStartOffset,
          isPartial: true,
          minAudioCtx: _minAudioCtx,
        );
      }
    }
  }

  Future<void> _stopLiveRecording() async {
    if (_state != PipelineState.recording) return;

    setState(() => _state = PipelineState.stopping);
    _durationTimer?.cancel();

    // 1. Stop audio capture and close WAV
    final stats = await _captureController.stopRecording();
    _audioFrameSub?.cancel();
    _audioFrameSub = null;

    _diagnostics.overrunCount = stats.overrunCount;
    _diagnostics.totalRecordedSamples = stats.totalSamples;
    _diagnostics.wallClockDurationMs = stats.wallClockMs;

    // 2. Flush trailing VAD chunk if speech was in progress
    final finalChunk = _vadChunker.flush();
    if (finalChunk != null) _submitFinal(finalChunk);
    if (_allFinalsReceived) {
      _finishStopping();
    } else {
      _stoppingTimeoutTimer?.cancel();
      _stoppingTimeoutTimer = Timer(const Duration(seconds: 60), () {
        if (mounted && _state == PipelineState.stopping) {
          _finishStopping();
        }
      });
    }
  }

  void _finishStopping() {
    _stoppingTimeoutTimer?.cancel();
    _stoppingTimeoutTimer = null;

    if (_mode == AppMode.liveMic &&
        _activeWavPath.isNotEmpty &&
        File(_activeWavPath).existsSync() &&
        _whisperWorker != null) {
      _startFinalPass();
      return;
    }

    _finalizeReview();
  }

  Future<void> _startFinalPass() async {
    setState(() {
      _isRunningFinalPass = true;
      _vuMeterLevel.value = 0.0;
      _partialText = '';
      _partialIndex = -1;
      _finalPassProgress.value = 0.0;
    });

    try {
      final audioData = await AudioUtils.loadWavFile(_activeWavPath);
      _finalPassTimer?.cancel();
      _finalPassTimer = null;
      _whisperWorker?.submitFinalPass(samples: audioData.samples);
    } catch (e) {
      _finalizeReview();
    }
  }

  void _finalizeReview() {
    _finalPassTimer?.cancel();
    _finalPassProgress.value = 0.0;

    // Evaluate phonetic fillers if any
    final fullText = _finalVerbatimTranscript ?? _chunks.map((c) => c.text).join(' ');
    _lastFillerAnalysis = DiagnosticsTracker.evaluatePhoneticTestScript(fullText);

    setState(() {
      _isRunningFinalPass = false;
      _state = PipelineState.review;
      _vuMeterLevel.value = 0.0;
      _partialText = '';
      _partialIndex = -1;
    });
  }

  // --- Automated Benchmarking Flow ---

  Future<void> _runAutomatedBenchmark({bool fiveMinutes = false}) async {
    if (!_modelsReady || _whisperWorker == null || _state != PipelineState.idle) {
      return;
    }

    final testWav = fiveMinutes
        ? '$_externalFilesDir/audio/long30.wav'
        : (File(_testAudioPath).existsSync()
            ? _testAudioPath
            : '$_externalFilesDir/audio/clip8.wav');

    if (!File(testWav).existsSync()) {
      _showError('Benchmark audio missing: $testWav');
      return;
    }

    setState(() {
      _state = PipelineState.recording;
      _mode = AppMode.benchmarking;
      _benchmarkStatusText = 'Loading audio $testWav...';
      _chunks.clear();
      _diagnostics.reset();
      _vadChunker.reset();
      _resetStreamingState();
      _lastFillerAnalysis = null;
      _recordingDurationMs = 0;
      _vuMeterLevel.value = 0.0;
      _activeWavPath = testWav;
    });

    final reportPath = await BenchmarkRunner.run(
      wavPath: testWav,
      fiveMinutes: fiveMinutes,
      externalFilesDir: _externalFilesDir,
      deviceInfo: _deviceInfo,
      vadChunker: _vadChunker,
      whisperWorker: _whisperWorker!,
      diagnostics: _diagnostics,
      minAudioCtx: _minAudioCtx,
      firstPartialLagsSec: _firstPartialLagsSec,
      recordedChunkData: _chunks.map((c) => c.toJson()).toList(),
      onProgress: ({
        required durationMs,
        required statusText,
        speechChunk,
        livePartialSamples,
        livePartialStartOffset,
      }) {
        if (!mounted) return;
        setState(() {
          _recordingDurationMs = durationMs;
          if (statusText.isNotEmpty) {
            _benchmarkStatusText = statusText;
          }
        });
      },
      isCancelled: () => !mounted || _state != PipelineState.recording,
      allFinalsReceived: () => _allFinalsReceived,
    );

    _finishStopping();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Benchmark report saved: $reportPath'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _diagnosticsTimer?.cancel();
    _stoppingTimeoutTimer?.cancel();
    _finalPassTimer?.cancel();
    _audioFrameSub?.cancel();
    _whisperSub?.cancel();
    _workerStatusSub?.cancel();
    _playerSub?.cancel();
    _vuMeterLevel.dispose();
    _telemetry.dispose();
    _finalPassProgress.dispose();
    _captureController.dispose();
    _playerController.dispose();
    _vadChunker.dispose();
    _whisperWorker?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // --- UI Building ---

  @override
  Widget build(BuildContext context) {
    final showTelemetry = _showTelemetryDeck &&
        (_state == PipelineState.recording ||
            _state == PipelineState.stopping ||
            (_mode == AppMode.benchmarking && _state != PipelineState.idle));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _mode == AppMode.benchmarking
              ? 'Spike 02 — Dictation (Benchmark)'
              : 'Spike 02 — Real-Time Dictation',
        ),
        backgroundColor: const Color(0xFF131620),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_showTelemetryDeck ? Icons.tune : Icons.tune_outlined),
            tooltip: 'Toggle Pipeline Telemetry',
            onPressed: () => setState(() => _showTelemetryDeck = !_showTelemetryDeck),
          ),
          PopupMenuButton<int>(
            tooltip: 'Min encoder audio_ctx',
            enabled: _state == PipelineState.idle ||
                _state == PipelineState.review,
            initialValue: _minAudioCtx,
            onSelected: (v) => setState(() => _minAudioCtx = v),
            itemBuilder: (_) => [
              for (final v in _audioCtxOptions)
                PopupMenuItem(
                  value: v,
                  child: Text(v == 0 ? 'ctx: full (1500)' : 'ctx ≥ $v'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  _minAudioCtx == 0 ? 'ctx full' : 'ctx≥$_minAudioCtx',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.assessment_outlined),
            tooltip: 'Run Phonetic Test Benchmark',
            onPressed: (_state == PipelineState.idle && _modelsReady)
                ? () => _runAutomatedBenchmark(fiveMinutes: false)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            tooltip: 'Run 5-Min Continuous Benchmark',
            onPressed: (_state == PipelineState.idle && _modelsReady)
                ? () => _runAutomatedBenchmark(fiveMinutes: true)
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildDiagnosticsOverlay(),
            if (showTelemetry) PipelineTelemetryDeck(controller: _telemetry),
            Expanded(child: _buildTranscriptArea()),
            if (_state == PipelineState.review) _buildPlaybackBar(),
            _buildControlBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsOverlay() {
    final tLag = _diagnostics.medianTLagSec;
    final tLagOk = _diagnostics.tLagPass;
    final rtf = _diagnostics.averageRtf;
    final overruns = _diagnostics.overrunCount;
    final rss = _diagnostics.peakRssMb;
    final thermal = _diagnostics.thermalStatus;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF131620),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetricChip(
                label: 'Median T_lag',
                value: '${tLag.toStringAsFixed(2)} s',
                badgeText: _chunks.isEmpty ? 'IDLE' : (tLagOk ? 'PASS' : 'FAIL'),
                badgeColor: _chunks.isEmpty
                    ? Colors.grey
                    : (tLagOk ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
              ),
              _buildMetricChip(
                label: 'Avg RTF',
                value: rtf.toStringAsFixed(3),
                badgeText: rtf <= 0.5 ? 'OK' : 'HIGH',
                badgeColor: rtf <= 0.5 ? const Color(0xFF10B981) : Colors.amber,
              ),
              _buildMetricChip(
                label: 'Overruns',
                value: '$overruns',
                badgeText: overruns == 0 ? 'PASS' : 'FAIL',
                badgeColor: overruns == 0 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
              ),
              _buildMetricChip(
                label: 'Thermal / RSS',
                value: '${thermal >= 0 ? "T$thermal" : "-"} | ${rss.toStringAsFixed(0)}M',
                badgeText: thermal <= 1 ? 'OK' : 'WARN',
                badgeColor: thermal <= 1 ? const Color(0xFF10B981) : Colors.amber,
              ),
            ],
          ),
          if (_lastFillerAnalysis != null) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: _showFillerDialog,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _lastFillerAnalysis!.passed
                        ? Icons.check_circle_outline
                        : Icons.highlight_off,
                    color: _lastFillerAnalysis!.passed
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Filler Retention: ${_lastFillerAnalysis!.retainedCount}/${_lastFillerAnalysis!.totalCount} (${_lastFillerAnalysis!.retainedPercent.toStringAsFixed(0)}%) — Tap for details',
                    style: TextStyle(
                      fontSize: 12,
                      color: _lastFillerAnalysis!.passed
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricChip({
    required String label,
    required String value,
    required String badgeText,
    required Color badgeColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: badgeColor.withAlpha(40),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: badgeColor, width: 0.8),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: badgeColor,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }


  Widget _buildTranscriptArea() {
    final hasPartial = _partialText.isNotEmpty;
    final hasFinal = _finalVerbatimTranscript != null;
    final showActiveTap = (_state == PipelineState.recording && !_chunks.any((c) => c.stage == ChunkStage.buffering)) || _isAccumulatingChunk;
    if (_chunks.isEmpty && !hasPartial && !hasFinal && !_isRunningFinalPass && !showActiveTap) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _modelsReady ? Icons.mic_none : Icons.error_outline,
              size: 48,
              color: _modelsReady ? Colors.white24 : Colors.redAccent,
            ),
            const SizedBox(height: 12),
            Text(
              _modelsReady
                  ? (_state == PipelineState.recording
                      ? 'Listening for speech pauses...'
                      : 'Tap Record to speak or run benchmark')
                  : _benchmarkStatusText,
              style: const TextStyle(color: Colors.white54, fontSize: 15),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final medianFirstPartial = DiagnosticsTracker.median(_firstPartialLagsSec);

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                hasFinal
                    ? 'FINAL VERBATIM TRANSCRIPT'
                    : 'LIVE TRANSCRIPT (${_chunks.length} chunks) · 1st partial ${medianFirstPartial.toStringAsFixed(2)}s',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: Colors.white60,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy Full Transcript',
                onPressed: () {
                  final fullText = _finalVerbatimTranscript ??
                      _chunks.map((c) => c.text).join(' ');
                  Clipboard.setData(ClipboardData(text: fullText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Transcript copied to clipboard')),
                  );
                },
              ),
            ],
          ),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1D27),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isRunningFinalPass
                      ? const Color(0xFF3B82F6).withAlpha(120)
                      : Colors.white10,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        14,
                        14,
                        _isRunningFinalPass ? 56 : 14,
                      ),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: SelectableText.rich(
                          TextSpan(
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.5,
                              color: Colors.white,
                            ),
                            children: [
                              if (hasFinal) ...[
                                TextSpan(text: _finalVerbatimTranscript!),
                              ] else ...[
                                for (int i = 0; i < _chunks.length; i++) ...[
                                  if (i > 0 && (_chunks[i].text.isNotEmpty || _chunks[i].stage == ChunkStage.buffering))
                                    const TextSpan(text: ' '),
                                  if (_chunks[i].stage == ChunkStage.finalized && _chunks[i].text.isNotEmpty)
                                    TextSpan(
                                      text: _chunks[i].text,
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () => ChunkMetadataModal.show(
                                              context,
                                              _chunks[i],
                                            ),
                                    )
                                  else if (_chunks[i].stage == ChunkStage.preview && _chunks[i].text.isNotEmpty)
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: ValueListenableBuilder<WhisperWorkerStatus>(
                                        valueListenable: _telemetry.workerStatus,
                                        builder: (context, status, _) {
                                          return InlineActiveDraftSegment(
                                            text: _chunks[i].text,
                                            progress: _chunks[i].progressNotifier,
                                            progressValue: _chunks[i].progress,
                                            isWorkerBusy: status.isBusy,
                                          );
                                        },
                                      ),
                                    )
                                  else if (_chunks[i].stage == ChunkStage.buffering)
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: ValueListenableBuilder<bool>(
                                        valueListenable: _telemetry.inSpeech,
                                        builder: (context, speaking, _) {
                                          return InlineChunkChicklet(
                                            progress: _chunks[i].progressNotifier,
                                            progressValue: _chunks[i].progress,
                                            isSpeaking: speaking,
                                          );
                                        },
                                      ),
                                    ),
                                ],
                                if (hasPartial &&
                                    _partialText.trim().isNotEmpty &&
                                    !_chunks.any((c) => c.stage == ChunkStage.preview && c.text.trim() == _partialText.trim())) ...[
                                  if (_chunks.any((c) => c.text.isNotEmpty || c.stage == ChunkStage.buffering))
                                    const TextSpan(text: ' '),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: ValueListenableBuilder<WhisperWorkerStatus>(
                                      valueListenable: _telemetry.workerStatus,
                                      builder: (context, status, _) {
                                        return InlineActiveDraftSegment(
                                          text: _partialText.trim(),
                                          progress: _telemetry.partialProgress,
                                          isWorkerBusy: status.isBusy,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                if (showActiveTap && !_chunks.any((c) => c.stage == ChunkStage.buffering)) ...[
                                  if (_chunks.any((c) => c.text.isNotEmpty) ||
                                      (hasPartial && _partialText.trim().isNotEmpty))
                                    const TextSpan(text: ' '),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: ValueListenableBuilder<bool>(
                                      valueListenable: _telemetry.inSpeech,
                                      builder: (context, speaking, _) {
                                        return InlineChunkChicklet(
                                          progress: _telemetry.partialProgress,
                                          isSpeaking: speaking,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                if (!_chunks.any((c) => c.text.isNotEmpty || c.stage == ChunkStage.buffering) &&
                                    (!hasPartial || _partialText.trim().isEmpty) &&
                                    !showActiveTap)
                                  const TextSpan(
                                    text: '...',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isRunningFinalPass)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: GlobalFinalPassRail(progress: _finalPassProgress),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackBar() {
    final curMs = _playerStatus.positionMs;
    final durMs = max(curMs, _playerStatus.durationMs);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF131620),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(
                  _playerStatus.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: const Color(0xFF3B82F6),
                  size: 28,
                ),
                onPressed: () {
                  if (_playerStatus.isPlaying) {
                    _playerController.pause();
                  } else {
                    if (_playerStatus.positionMs > 0 &&
                        _playerStatus.positionMs < _playerStatus.durationMs) {
                      _playerController.resume();
                    } else {
                      _playerController.start(_activeWavPath);
                    }
                  }
                },
              ),
              Text(
                _formatMs(curMs),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
              Expanded(
                child: Slider(
                  value: durMs > 0 ? (curMs / durMs).clamp(0.0, 1.0) : 0.0,
                  onChanged: (val) {
                    final targetMs = (val * durMs).toInt();
                    _playerController.seek(targetMs);
                  },
                ),
              ),
              Text(
                _formatMs(durMs),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0F1117),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Duration counter
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _state == PipelineState.recording ? 'RECORDING' : 'READY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: _state == PipelineState.recording
                      ? const Color(0xFFEF4444)
                      : Colors.white38,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatMs(_recordingDurationMs),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          // Center: Large Record / Stop Button
          _buildRecordStopButton(),

          // Right: Reset / Clear button
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset Pipeline',
            onPressed: (_state == PipelineState.recording || _isRunningFinalPass)
                ? null
                : () {
                    setState(() {
                      _chunks.clear();
                      _finalVerbatimTranscript = null;
                      _isRunningFinalPass = false;
                      _diagnostics.reset();
                      _lastFillerAnalysis = null;
                      _recordingDurationMs = 0;
                      _vuMeterLevel.value = 0.0;
                      _state = PipelineState.idle;
                    });
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildRecordStopButton() {
    if (_state == PipelineState.stopping || _isRunningFinalPass) {
      return Container(
        width: 72,
        height: 72,
        padding: const EdgeInsets.all(18),
        decoration: const BoxDecoration(
          color: Colors.white10,
          shape: BoxShape.circle,
        ),
        child: const CircularProgressIndicator(
          strokeWidth: 3,
          color: Color(0xFF3B82F6),
        ),
      );
    }

    final isRecording = _state == PipelineState.recording;

    return GestureDetector(
      onTap: () {
        if (!_modelsReady) return;
        if (isRecording) {
          _stopLiveRecording();
        } else {
          _startLiveRecording();
        }
      },
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: isRecording ? const Color(0xFFEF4444) : const Color(0xFF3B82F6),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (isRecording ? const Color(0xFFEF4444) : const Color(0xFF3B82F6))
                  .withAlpha(100),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(
          isRecording ? Icons.stop : Icons.mic,
          color: Colors.white,
          size: 36,
        ),
      ),
    );
  }

  void _showFillerDialog() {
    if (_lastFillerAnalysis == null) return;
    final a = _lastFillerAnalysis!;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1D27),
          title: Text(
            'Phonetic Filler Retention: ${a.retainedCount}/${a.totalCount}',
            style: const TextStyle(fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: a.details.entries.map((e) {
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  e.value ? Icons.check_circle : Icons.cancel,
                  color: e.value
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444),
                ),
                title: Text(
                  e.key,
                  style: TextStyle(
                    color: e.value ? Colors.white : Colors.white54,
                    fontWeight: e.value ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                trailing: Text(
                  e.value ? 'RETAINED' : 'DROPPED',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: e.value
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444),
                  ),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }


  String _formatMs(int ms) {
    final s = ms ~/ 1000;
    final mins = s ~/ 60;
    final remSecs = s % 60;
    return '${mins.toString().padLeft(2, '0')}:${remSecs.toString().padLeft(2, '0')}';
  }
}
