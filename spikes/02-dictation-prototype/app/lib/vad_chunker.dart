import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'whisper_ffi.dart';

class SpeechChunk {
  final int chunkIndex;
  final Float32List samples;
  final int tPauseDetectedMs;
  final int masterSampleOffset;
  final double durationSec;

  SpeechChunk({
    required this.chunkIndex,
    required this.samples,
    required this.tPauseDetectedMs,
    required this.masterSampleOffset,
    required this.durationSec,
  });
}

class StreamingVadChunker {
  final WhisperBindings _bindings = WhisperBindings.instance;
  Pointer<Void> _vadCtx = nullptr;
  Pointer<Float> _framePtr = nullptr;

  // Configuration constants from SPEC.md Section 5
  static const int sampleRate = 16000;
  static const int frameSize = 512; // 32 ms
  static const double speechOnsetThreshold = 0.5;
  static const int speechOnsetFrames = 2; // 64 ms (>= 2 frames)
  static const double pauseThreshold = 0.35;
  static const int pauseFrames = 16; // ~512 ms (>= 16 frames)
  static const int shortPauseFrames = 32; // ~1024 ms (> 1.0 s)
  static const int preSpeechBufferFrames = 10; // 320 ms (~300 ms lookback)
  static const int postSpeechMarginFrames = 10; // 320 ms (~300 ms margin)
  static const double minChunkDurationSec = 1.5;
  static const double maxChunkDurationSec = 25.0;

  // Circular pre-speech buffer (retains last 10 frames = 320ms)
  final Queue<Float32List> _preSpeechQueue = Queue<Float32List>();

  // Active chunk frames
  final List<Float32List> _activeChunkFrames = <Float32List>[];

  bool _inSpeech = false;
  double _lastSpeechProb = 0.0;
  int _consecutiveOnsetFrames = 0;
  int _consecutivePauseFrames = 0;
  int _chunkCounter = 0;
  int _masterSampleOffset = 0;
  int _chunkStartSampleOffset = 0;

  bool get inSpeech => _inSpeech;
  int get chunkCounter => _chunkCounter;
  double get lastSpeechProb => _lastSpeechProb;
  int get consecutivePauseFrames => _consecutivePauseFrames;
  int get targetPauseFrames => pauseFrames;
  int get consecutiveOnsetFrames => _consecutiveOnsetFrames;
  int get targetOnsetFrames => speechOnsetFrames;
  double get currentUtteranceDurationSec =>
      (_activeChunkFrames.length * frameSize) / sampleRate;

  StreamingVadChunker();

  void init(String vadModelPath) {
    dispose();
    _vadCtx = _bindings.initVadStreamContext(vadModelPath);
    _framePtr = calloc<Float>(frameSize);
    reset();
  }

  void reset() {
    _preSpeechQueue.clear();
    _activeChunkFrames.clear();
    _inSpeech = false;
    _lastSpeechProb = 0.0;
    _consecutiveOnsetFrames = 0;
    _consecutivePauseFrames = 0;
    _chunkCounter = 0;
    _masterSampleOffset = 0;
    _chunkStartSampleOffset = 0;
    if (_vadCtx != nullptr) {
      _bindings.vadStreamReset(_vadCtx);
    }
  }

  /// Feeds a 512-sample float32 audio frame into streaming VAD.
  /// Returns a [SpeechChunk] if a pause closure or max duration split occurred, else null.
  SpeechChunk? feedFrame(Float32List frame512) {
    assert(frame512.length == frameSize);
    if (_vadCtx == nullptr || _framePtr == nullptr) {
      return null;
    }

    final pcmList = _framePtr.asTypedList(frameSize);
    pcmList.setAll(0, frame512);

    final prob = _bindings.vadStreamFeed(_vadCtx, _framePtr);
    _lastSpeechProb = prob;
    final currentOffset = _masterSampleOffset;
    _masterSampleOffset += frameSize;

    final frameCopy = Float32List.fromList(frame512);

    if (!_inSpeech) {
      // Maintain pre-speech circular buffer
      _preSpeechQueue.addLast(frameCopy);
      if (_preSpeechQueue.length > preSpeechBufferFrames) {
        _preSpeechQueue.removeFirst();
      }

      if (prob >= speechOnsetThreshold) {
        _consecutiveOnsetFrames++;
        if (_consecutiveOnsetFrames >= speechOnsetFrames) {
          // Onset confirmed! Transition to SPEECH
          _inSpeech = true;
          _consecutiveOnsetFrames = 0;
          _consecutivePauseFrames = 0;

          // Prepend pre-speech lookback buffer
          _activeChunkFrames.clear();
          for (final f in _preSpeechQueue) {
            _activeChunkFrames.add(f);
          }
          // The start offset is the start of the pre-speech buffer
          final lookbackSamples = _activeChunkFrames.length * frameSize;
          _chunkStartSampleOffset = (currentOffset + frameSize) - lookbackSamples;
          if (_chunkStartSampleOffset < 0) _chunkStartSampleOffset = 0;
        }
      } else {
        _consecutiveOnsetFrames = 0;
      }
      return null;
    } else {
      // Actively accumulating speech
      _activeChunkFrames.add(frameCopy);

      if (prob < pauseThreshold) {
        _consecutivePauseFrames++;
      } else {
        _consecutivePauseFrames = 0;
      }

      final durationSec = (_activeChunkFrames.length * frameSize) / sampleRate;

      // 1. Normal pause condition: >= 16 frames (~512 ms) and duration >= 1.5 s
      if (_consecutivePauseFrames >= pauseFrames && durationSec >= minChunkDurationSec) {
        final tPauseDetected = DateTime.now().millisecondsSinceEpoch;
        return _emitChunk(tPauseDetected);
      }

      // 2. Short chunk condition: short speech (< 1.5 s) but user paused for > 1.0 s
      if (_consecutivePauseFrames >= shortPauseFrames) {
        final tPauseDetected = DateTime.now().millisecondsSinceEpoch;
        return _emitChunk(tPauseDetected);
      }

      // 3. Max duration ceiling: continuous speech reached 25 s
      if (durationSec >= maxChunkDurationSec) {
        final tPauseDetected = DateTime.now().millisecondsSinceEpoch;
        return _emitChunk(tPauseDetected);
      }

      return null;
    }
  }

  /// Snapshot of the in-progress utterance (for live partials), or null if not in speech.
  Float32List? currentUtteranceSamples() {
    if (!_inSpeech || _activeChunkFrames.isEmpty) return null;
    final out = Float32List(_activeChunkFrames.length * frameSize);
    for (int i = 0; i < _activeChunkFrames.length; i++) {
      out.setAll(i * frameSize, _activeChunkFrames[i]);
    }
    return out;
  }

  int get currentUtteranceStartOffset => _chunkStartSampleOffset;

  /// Flushes any pending speech chunk on recording stop.
  SpeechChunk? flush() {
    if (_inSpeech && _activeChunkFrames.isNotEmpty) {
      final tPauseDetected = DateTime.now().millisecondsSinceEpoch;
      return _emitChunk(tPauseDetected);
    }
    return null;
  }

  SpeechChunk _emitChunk(int tPauseDetected) {
    // Preserve post-speech margin of ~300 ms (10 frames)
    // If consecutive pause frames exceeded 10 frames, trim the excess silence
    int framesToKeep = _activeChunkFrames.length;
    if (_consecutivePauseFrames > postSpeechMarginFrames) {
      final excessSilenceFrames = _consecutivePauseFrames - postSpeechMarginFrames;
      framesToKeep = _activeChunkFrames.length - excessSilenceFrames;
      if (framesToKeep < postSpeechMarginFrames) {
        framesToKeep = _activeChunkFrames.length;
      }
    }

    final totalSamples = framesToKeep * frameSize;
    final merged = Float32List(totalSamples);
    int offset = 0;
    for (int i = 0; i < framesToKeep; i++) {
      merged.setAll(offset, _activeChunkFrames[i]);
      offset += frameSize;
    }

    final chunk = SpeechChunk(
      chunkIndex: _chunkCounter++,
      samples: merged,
      tPauseDetectedMs: tPauseDetected,
      masterSampleOffset: _chunkStartSampleOffset,
      durationSec: totalSamples / sampleRate,
    );

    // Reset state for next utterance
    _activeChunkFrames.clear();
    _preSpeechQueue.clear();
    _inSpeech = false;
    _consecutiveOnsetFrames = 0;
    _consecutivePauseFrames = 0;
    if (_vadCtx != nullptr) {
      _bindings.vadStreamReset(_vadCtx);
    }

    return chunk;
  }

  void dispose() {
    if (_framePtr != nullptr) {
      calloc.free(_framePtr);
      _framePtr = nullptr;
    }
    if (_vadCtx != nullptr) {
      _bindings.freeVadStreamContext(_vadCtx);
      _vadCtx = nullptr;
    }
  }
}
