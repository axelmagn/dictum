import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'text_sanitizer.dart';
import 'whisper_ffi.dart';

/// Encoder context frames per second of audio (1500 ctx = 30 s).
const int _ctxPerSec = 50;
const int _ctxMargin = 32;
const int _fullAudioCtx = 1500;
const int _maxMergedSamples = 16000 * 25;

/// Encoder window sized to the chunk. [minCtx] <= 0 disables (full 30 s window).
int audioCtxFor(int nSamples, int minCtx) {
  if (minCtx <= 0) return 0;
  final needed = (nSamples * _ctxPerSec / 16000).ceil() + _ctxMargin;
  return needed.clamp(min(minCtx, _fullAudioCtx), _fullAudioCtx);
}

class WhisperChunkRequest {
  /// Final: chunk index. Partial: index the utterance will get once finalized.
  final int chunkIndex;
  final TransferableTypedData transferableAudio;
  final int sampleCount;
  /// Final: pause-detected time. Partial: submit time.
  final int tPauseDetectedMs;
  final int masterSampleOffset;
  final bool isPartial;
  final int minAudioCtx;
  final bool isFinalPass;

  WhisperChunkRequest({
    required this.chunkIndex,
    required this.transferableAudio,
    required this.sampleCount,
    required this.tPauseDetectedMs,
    required this.masterSampleOffset,
    required this.isPartial,
    required this.minAudioCtx,
    this.isFinalPass = false,
  });
}

class WhisperChunkResponse {
  final int chunkIndex;
  /// Last chunk index covered when queued finals were merged into one call.
  final int lastChunkIndex;
  final String text;
  final double audioDurationSec;
  final double transcribeSec;
  final double rtf;
  final int tPauseDetectedMs;
  final double masterT0Sec;
  final double masterT1Sec;
  final bool isPartial;
  final int audioCtx;
  final bool isFinalPass;

  WhisperChunkResponse({
    required this.chunkIndex,
    required this.lastChunkIndex,
    required this.text,
    required this.audioDurationSec,
    required this.transcribeSec,
    required this.rtf,
    required this.tPauseDetectedMs,
    required this.masterT0Sec,
    required this.masterT1Sec,
    required this.isPartial,
    required this.audioCtx,
    this.isFinalPass = false,
  });
}

class WhisperWorkerStatus {
  final bool isBusy;
  final int pendingCount;
  final int? activeChunkIndex;
  final int? lastChunkIndex;
  final bool isPartial;
  final bool isFinalPass;
  final double audioDurationSec;
  final int audioCtx;
  final double progress;

  const WhisperWorkerStatus({
    required this.isBusy,
    required this.pendingCount,
    this.activeChunkIndex,
    this.lastChunkIndex,
    this.isPartial = false,
    this.isFinalPass = false,
    this.audioDurationSec = 0.0,
    this.audioCtx = 0,
    this.progress = 0.0,
  });

  static const idle = WhisperWorkerStatus(isBusy: false, pendingCount: 0);
}

class _WorkerInit {
  final String modelPath;
  final SendPort handshakePort;
  final SendPort responsePort;

  _WorkerInit({
    required this.modelPath,
    required this.handshakePort,
    required this.responsePort,
  });
}

class WhisperWorker {
  static const String modeC2Prompt =
      'Umm, so, I-I was like, hmm... uh, you know, I— I mean.';

  late final Isolate _isolate;
  late final SendPort _workerSendPort;
  late final ReceivePort _responsePort;
  final StreamController<WhisperChunkResponse> _responseController =
      StreamController<WhisperChunkResponse>.broadcast();
  final StreamController<WhisperWorkerStatus> _statusController =
      StreamController<WhisperWorkerStatus>.broadcast();

  Stream<WhisperChunkResponse> get responses => _responseController.stream;
  Stream<WhisperWorkerStatus> get statusUpdates => _statusController.stream;

  WhisperWorker._();

  static Future<WhisperWorker> spawn(String modelPath) async {
    final initPort = ReceivePort();
    final worker = WhisperWorker._();
    worker._responsePort = ReceivePort();

    worker._isolate = await Isolate.spawn(
      _workerEntryPoint,
      _WorkerInit(
        modelPath: modelPath,
        handshakePort: initPort.sendPort,
        responsePort: worker._responsePort.sendPort,
      ),
    );

    worker._workerSendPort = await initPort.first as SendPort;
    initPort.close();

    worker._responsePort.listen((message) {
      if (message is WhisperChunkResponse) {
        worker._responseController.add(message);
      } else if (message is WhisperWorkerStatus) {
        worker._statusController.add(message);
      }
    });

    return worker;
  }

  void submitChunk({
    required int chunkIndex,
    required Float32List samples,
    required int tPauseDetectedMs,
    required int masterSampleOffset,
    bool isPartial = false,
    int minAudioCtx = 512,
  }) {
    final transferable = TransferableTypedData.fromList([samples]);
    _workerSendPort.send(WhisperChunkRequest(
      chunkIndex: chunkIndex,
      transferableAudio: transferable,
      sampleCount: samples.length,
      tPauseDetectedMs: tPauseDetectedMs,
      masterSampleOffset: masterSampleOffset,
      isPartial: isPartial,
      minAudioCtx: minAudioCtx,
    ));
  }

  void submitFinalPass({
    required Float32List samples,
  }) {
    final transferable = TransferableTypedData.fromList([samples]);
    _workerSendPort.send(WhisperChunkRequest(
      chunkIndex: -1,
      transferableAudio: transferable,
      sampleCount: samples.length,
      tPauseDetectedMs: DateTime.now().millisecondsSinceEpoch,
      masterSampleOffset: 0,
      isPartial: false,
      minAudioCtx: 0,
      isFinalPass: true,
    ));
  }

  void stop() {
    _workerSendPort.send('stop');
  }

  void dispose() {
    stop();
    _isolate.kill(priority: Isolate.immediate);
    _responsePort.close();
    _responseController.close();
    _statusController.close();
  }
}

class _Job {
  final WhisperChunkRequest req;
  final Float32List samples;
  _Job(this.req) : samples = req.transferableAudio.materialize().asFloat32List();
}

void _workerEntryPoint(_WorkerInit init) {
  final commandPort = ReceivePort();
  init.handshakePort.send(commandPort.sendPort);

  final bindings = WhisperBindings.instance;
  final ctx = bindings.initContext(init.modelPath);
  final promptPtr = WhisperWorker.modeC2Prompt.toNativeUtf8();

  final pending = <_Job>[];
  var draining = false;
  var stopRequested = false;
  _Job? currentJob;

  NativeCallable<Void Function(Int32)>? progressCallable;
  try {
    progressCallable = NativeCallable<Void Function(Int32)>.isolateLocal((int prog) {
      if (currentJob != null) {
        init.responsePort.send(WhisperWorkerStatus(
          isBusy: true,
          pendingCount: pending.length,
          activeChunkIndex: currentJob!.req.chunkIndex,
          isPartial: currentJob!.req.isPartial,
          isFinalPass: currentJob!.req.isFinalPass,
          progress: (prog / 100.0).clamp(0.0, 1.0),
        ));
      }
    });
    bindings.setProgressCallback(progressCallable.nativeFunction);
  } catch (_) {}

  void sendStatus({
    required bool isBusy,
    _Job? activeJob,
    int? lastIndex,
    double durationSec = 0.0,
    int audioCtx = 0,
    double progress = 0.0,
  }) {
    init.responsePort.send(WhisperWorkerStatus(
      isBusy: isBusy,
      pendingCount: pending.length,
      activeChunkIndex: activeJob?.req.chunkIndex,
      lastChunkIndex: lastIndex,
      isPartial: activeJob?.req.isPartial ?? false,
      isFinalPass: activeJob?.req.isFinalPass ?? false,
      audioDurationSec: durationSec,
      audioCtx: audioCtx,
      progress: progress,
    ));
  }

  void shutdown() {
    progressCallable?.close();
    calloc.free(promptPtr);
    bindings.freeContext(ctx);
    commandPort.close();
    Isolate.exit();
  }

  void run(List<_Job> jobs) {
    currentJob = jobs.first;
    final first = jobs.first.req;
    final nSamples = jobs.fold<int>(0, (n, j) => n + j.samples.length);
    final audioDurationSec = nSamples / 16000.0;
    final masterOffsetSec = first.masterSampleOffset / 16000.0;
    final audioCtx = audioCtxFor(nSamples, first.minAudioCtx);

    final last = jobs.last.req;
    sendStatus(
      isBusy: true,
      activeJob: jobs.first,
      lastIndex: last.chunkIndex,
      durationSec: audioDurationSec,
      audioCtx: audioCtx == 0 ? _fullAudioCtx : audioCtx,
    );

    final pcmPtr = calloc<Float>(nSamples);
    final pcm = pcmPtr.asTypedList(nSamples);
    var off = 0;
    for (final j in jobs) {
      pcm.setAll(off, j.samples);
      off += j.samples.length;
    }

    final sw = Stopwatch()..start();
    String text = '';
    try {
      text = bindings.transcribe(
        ctx: ctx,
        pcm: pcmPtr,
        nSamples: nSamples,
        prompt: promptPtr,
        nThreads: 4,
        carryPrompt: 0, // Mode C2 chunk prompting
        audioCtx: audioCtx,
      );
    } finally {
      sw.stop();
      calloc.free(pcmPtr);
    }

    text = TextSanitizer.sanitizeRepetitions(text);

    final transcribeSec = sw.elapsedMicroseconds / 1000000.0;
    init.responsePort.send(WhisperChunkResponse(
      chunkIndex: first.chunkIndex,
      lastChunkIndex: last.chunkIndex,
      text: text,
      audioDurationSec: audioDurationSec,
      transcribeSec: transcribeSec,
      rtf: audioDurationSec > 0 ? transcribeSec / audioDurationSec : 0.0,
      // Earliest pause in the batch: conservative T_lag.
      tPauseDetectedMs: first.tPauseDetectedMs,
      masterT0Sec: masterOffsetSec,
      masterT1Sec: last.masterSampleOffset / 16000.0 +
          jobs.last.samples.length / 16000.0,
      isPartial: first.isPartial,
      audioCtx: audioCtx == 0 ? _fullAudioCtx : audioCtx,
      isFinalPass: first.isFinalPass,
    ));

    sendStatus(isBusy: false);
  }

  // Coalesce backlog: finals merged (up to 25 s) and prioritized; partials
  // latest-wins and dropped whenever a final is waiting.
  // Full-audio final pass runs independently without chunk coalescing.
  Future<void> drain() async {
    draining = true;
    try {
      while (pending.isNotEmpty) {
        final finals = pending.where((j) => !j.req.isPartial).toList();
        if (finals.isNotEmpty) {
          final firstFinal = finals.first;
          if (firstFinal.req.isFinalPass) {
            pending.remove(firstFinal);
            run([firstFinal]);
          } else {
            final batch = <_Job>[];
            var n = 0;
            for (final j in finals) {
              if (j.req.isFinalPass) break;
              if (batch.isNotEmpty && n + j.samples.length > _maxMergedSamples) break;
              batch.add(j);
              n += j.samples.length;
            }
            pending.removeWhere(batch.contains);
            run(batch);
          }
        } else {
          final partial = pending.last;
          pending.clear();
          run([partial]);
        }
        // Yield so requests that arrived during inference land in [pending].
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      draining = false;
      sendStatus(isBusy: false);
      if (stopRequested) shutdown();
    }
  }

  commandPort.listen((message) {
    if (message == 'stop') {
      stopRequested = true;
      if (!draining) shutdown();
    } else if (message is WhisperChunkRequest) {
      pending.add(_Job(message));
      sendStatus(isBusy: draining);
      if (!draining) drain();
    }
  });
}
