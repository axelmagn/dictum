import 'dart:ffi';
import 'package:ffi/ffi.dart';

typedef _DwInitC = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _DwInitDart = Pointer<Void> Function(Pointer<Utf8> modelPath);

typedef _DwTranscribeC = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Float> pcm,
  Int32 nSamples,
  Pointer<Utf8> prompt,
  Int32 nThreads,
  Int32 carryPrompt,
  Int32 audioCtx,
);
typedef _DwTranscribeDart = int Function(
  Pointer<Void> ctx,
  Pointer<Float> pcm,
  int nSamples,
  Pointer<Utf8> prompt,
  int nThreads,
  int carryPrompt,
  int audioCtx,
);

typedef _DwNSegmentsC = Int32 Function(Pointer<Void> ctx);
typedef _DwNSegmentsDart = int Function(Pointer<Void> ctx);

typedef _DwSegmentTextC = Pointer<Utf8> Function(Pointer<Void> ctx, Int32 i);
typedef _DwSegmentTextDart = Pointer<Utf8> Function(Pointer<Void> ctx, int i);

typedef _DwSystemInfoC = Pointer<Utf8> Function();
typedef _DwSystemInfoDart = Pointer<Utf8> Function();

typedef _DwFreeC = Void Function(Pointer<Void> ctx);
typedef _DwFreeDart = void Function(Pointer<Void> ctx);

typedef _DwSuppressLogsC = Void Function();
typedef _DwSuppressLogsDart = void Function();

typedef _DwVadStreamInitC = Pointer<Void> Function(Pointer<Utf8> vadModelPath);
typedef _DwVadStreamInitDart = Pointer<Void> Function(Pointer<Utf8> vadModelPath);

typedef _DwVadStreamFeedC = Float Function(Pointer<Void> vctx, Pointer<Float> pcm512);
typedef _DwVadStreamFeedDart = double Function(Pointer<Void> vctx, Pointer<Float> pcm512);

typedef _DwVadStreamResetC = Void Function(Pointer<Void> vctx);
typedef _DwVadStreamResetDart = void Function(Pointer<Void> vctx);

typedef _DwVadStreamFreeC = Void Function(Pointer<Void> vctx);
typedef _DwVadStreamFreeDart = void Function(Pointer<Void> vctx);

typedef _DwSetProgressCbC = Void Function(Pointer<NativeFunction<Void Function(Int32)>> cb);
typedef _DwSetProgressCbDart = void Function(Pointer<NativeFunction<Void Function(Int32)>> cb);

class WhisperBindings {
  static WhisperBindings? _instance;
  static WhisperBindings get instance => _instance ??= WhisperBindings._internal();

  late final DynamicLibrary _lib;
  late final _DwInitDart _dwInit;
  late final _DwTranscribeDart _dwTranscribe;
  late final _DwNSegmentsDart _dwNSegments;
  late final _DwSegmentTextDart _dwSegmentText;
  late final _DwSystemInfoDart _dwSystemInfo;
  late final _DwFreeDart _dwFree;
  late final _DwSuppressLogsDart _dwSuppressLogs;
  late final _DwVadStreamInitDart _dwVadStreamInit;
  late final _DwVadStreamFeedDart _dwVadStreamFeed;
  late final _DwVadStreamResetDart _dwVadStreamReset;
  late final _DwVadStreamFreeDart _dwVadStreamFree;

  bool isAvailable = false;

  WhisperBindings._internal() {
    try {
      _lib = DynamicLibrary.open('libdictum_whisper.so');

      _dwInit = _lib.lookupFunction<_DwInitC, _DwInitDart>('dw_init');
      _dwTranscribe = _lib.lookupFunction<_DwTranscribeC, _DwTranscribeDart>('dw_transcribe');
      _dwNSegments = _lib.lookupFunction<_DwNSegmentsC, _DwNSegmentsDart>('dw_n_segments');
      _dwSegmentText = _lib.lookupFunction<_DwSegmentTextC, _DwSegmentTextDart>('dw_segment_text');
      _dwSystemInfo = _lib.lookupFunction<_DwSystemInfoC, _DwSystemInfoDart>('dw_system_info');
      _dwFree = _lib.lookupFunction<_DwFreeC, _DwFreeDart>('dw_free');
      _dwSuppressLogs = _lib.lookupFunction<_DwSuppressLogsC, _DwSuppressLogsDart>('dw_suppress_logs');
      _dwVadStreamInit = _lib.lookupFunction<_DwVadStreamInitC, _DwVadStreamInitDart>('dw_vad_stream_init');
      _dwVadStreamFeed = _lib.lookupFunction<_DwVadStreamFeedC, _DwVadStreamFeedDart>('dw_vad_stream_feed');
      _dwVadStreamReset = _lib.lookupFunction<_DwVadStreamResetC, _DwVadStreamResetDart>('dw_vad_stream_reset');
      _dwVadStreamFree = _lib.lookupFunction<_DwVadStreamFreeC, _DwVadStreamFreeDart>('dw_vad_stream_free');
      try {
        _dwSetProgressCb = _lib.lookupFunction<_DwSetProgressCbC, _DwSetProgressCbDart>('dw_set_progress_callback');
      } catch (_) {
        _hasProgressCb = false;
      }

      // Suppress verbose per-frame logcat output
      _dwSuppressLogs();
      isAvailable = true;
    } catch (_) {
      isAvailable = false;
    }
  }

  bool _hasProgressCb = true;
  _DwSetProgressCbDart? _dwSetProgressCb;

  void setProgressCallback(Pointer<NativeFunction<Void Function(Int32)>> cb) {
    if (isAvailable && _hasProgressCb && _dwSetProgressCb != null) {
      _dwSetProgressCb!(cb);
    }
  }

  String getSystemInfo() {
    if (!isAvailable) return '';
    final ptr = _dwSystemInfo();
    return ptr.toDartString();
  }

  Pointer<Void> initContext(String modelPath) {
    if (!isAvailable) return nullptr;
    final pathPtr = modelPath.toNativeUtf8();
    try {
      return _dwInit(pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void freeContext(Pointer<Void> ctx) {
    if (isAvailable && ctx != nullptr) {
      _dwFree(ctx);
    }
  }

  /// Transcribes the given PCM audio samples and returns the merged segment text.
  String transcribe({
    required Pointer<Void> ctx,
    required Pointer<Float> pcm,
    required int nSamples,
    required Pointer<Utf8> prompt,
    int nThreads = 4,
    int carryPrompt = 0,
    int audioCtx = 0,
  }) {
    if (!isAvailable || ctx == nullptr || pcm == nullptr || nSamples <= 0) {
      return '';
    }

    final res = _dwTranscribe(
      ctx,
      pcm,
      nSamples,
      prompt,
      nThreads,
      carryPrompt,
      audioCtx,
    );

    if (res != 0) return '';

    final sb = StringBuffer();
    final nSegs = _dwNSegments(ctx);
    for (int i = 0; i < nSegs; i++) {
      sb.write(_dwSegmentText(ctx, i).toDartString());
    }
    return sb.toString().trim();
  }

  Pointer<Void> initVadStreamContext(String vadModelPath) {
    if (!isAvailable) return nullptr;
    final pathPtr = vadModelPath.toNativeUtf8();
    try {
      return _dwVadStreamInit(pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  double vadStreamFeed(Pointer<Void> vctx, Pointer<Float> pcm512) {
    if (!isAvailable || vctx == nullptr) return 0.0;
    return _dwVadStreamFeed(vctx, pcm512);
  }

  void vadStreamReset(Pointer<Void> vctx) {
    if (isAvailable && vctx != nullptr) {
      _dwVadStreamReset(vctx);
    }
  }

  void freeVadStreamContext(Pointer<Void> vctx) {
    if (isAvailable && vctx != nullptr) {
      _dwVadStreamFree(vctx);
    }
  }
}
