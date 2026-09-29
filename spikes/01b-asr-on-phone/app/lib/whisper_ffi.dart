// ignore_for_file: camel_case_types, non_constant_identifier_names, library_private_types_in_public_api

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

class WhisperSegment {
  final double t0; // start time in seconds
  final double t1; // end time in seconds
  final String text;

  WhisperSegment({
    required this.t0,
    required this.t1,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
    't0': t0,
    't1': t1,
    'text': text,
  };
}

class VadSegment {
  final double t0; // seconds
  final double t1; // seconds

  VadSegment({required this.t0, required this.t1});

  @override
  String toString() => 'VadSegment(t0: ${t0.toStringAsFixed(2)}, t1: ${t1.toStringAsFixed(2)})';
}

typedef _dw_init_c = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _dw_init_dart = Pointer<Void> Function(Pointer<Utf8> modelPath);

typedef _dw_transcribe_c = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Float> pcm,
  Int32 nSamples,
  Pointer<Utf8> prompt,
  Int32 nThreads,
  Int32 carryPrompt,
);
typedef _dw_transcribe_dart = int Function(
  Pointer<Void> ctx,
  Pointer<Float> pcm,
  int nSamples,
  Pointer<Utf8> prompt,
  int nThreads,
  int carryPrompt,
);

typedef _dw_n_segments_c = Int32 Function(Pointer<Void> ctx);
typedef _dw_n_segments_dart = int Function(Pointer<Void> ctx);

typedef _dw_segment_text_c = Pointer<Utf8> Function(Pointer<Void> ctx, Int32 i);
typedef _dw_segment_text_dart = Pointer<Utf8> Function(Pointer<Void> ctx, int i);

typedef _dw_segment_t0_c = Int64 Function(Pointer<Void> ctx, Int32 i);
typedef _dw_segment_t0_dart = int Function(Pointer<Void> ctx, int i);

typedef _dw_segment_t1_c = Int64 Function(Pointer<Void> ctx, Int32 i);
typedef _dw_segment_t1_dart = int Function(Pointer<Void> ctx, int i);

typedef _dw_vad_init_c = Pointer<Void> Function(Pointer<Utf8> vadModelPath);
typedef _dw_vad_init_dart = Pointer<Void> Function(Pointer<Utf8> vadModelPath);

typedef _dw_vad_segments_c = Int32 Function(
  Pointer<Void> vctx,
  Pointer<Float> pcm,
  Int32 n,
  Pointer<Float> outT0T1,
  Int32 maxSegments,
);
typedef _dw_vad_segments_dart = int Function(
  Pointer<Void> vctx,
  Pointer<Float> pcm,
  int n,
  Pointer<Float> outT0T1,
  int maxSegments,
);

typedef _dw_system_info_c = Pointer<Utf8> Function();
typedef _dw_system_info_dart = Pointer<Utf8> Function();

typedef _dw_free_c = Void Function(Pointer<Void> ctx);
typedef _dw_free_dart = void Function(Pointer<Void> ctx);

typedef _dw_vad_free_c = Void Function(Pointer<Void> vctx);
typedef _dw_vad_free_dart = void Function(Pointer<Void> vctx);

class WhisperBindings {
  static final WhisperBindings instance = WhisperBindings._internal();

  late final DynamicLibrary _lib;
  late final _dw_init_dart dw_init;
  late final _dw_transcribe_dart dw_transcribe;
  late final _dw_n_segments_dart dw_n_segments;
  late final _dw_segment_text_dart dw_segment_text;
  late final _dw_segment_t0_dart dw_segment_t0;
  late final _dw_segment_t1_dart dw_segment_t1;
  late final _dw_vad_init_dart dw_vad_init;
  late final _dw_vad_segments_dart dw_vad_segments;
  late final _dw_system_info_dart dw_system_info;
  late final _dw_free_dart dw_free;
  late final _dw_vad_free_dart dw_vad_free;

  WhisperBindings._internal() {
    _lib = DynamicLibrary.open('libdictum_whisper.so');

    dw_init = _lib.lookupFunction<_dw_init_c, _dw_init_dart>('dw_init');
    dw_transcribe = _lib.lookupFunction<_dw_transcribe_c, _dw_transcribe_dart>('dw_transcribe');
    dw_n_segments = _lib.lookupFunction<_dw_n_segments_c, _dw_n_segments_dart>('dw_n_segments');
    dw_segment_text = _lib.lookupFunction<_dw_segment_text_c, _dw_segment_text_dart>('dw_segment_text');
    dw_segment_t0 = _lib.lookupFunction<_dw_segment_t0_c, _dw_segment_t0_dart>('dw_segment_t0');
    dw_segment_t1 = _lib.lookupFunction<_dw_segment_t1_c, _dw_segment_t1_dart>('dw_segment_t1');
    dw_vad_init = _lib.lookupFunction<_dw_vad_init_c, _dw_vad_init_dart>('dw_vad_init');
    dw_vad_segments = _lib.lookupFunction<_dw_vad_segments_c, _dw_vad_segments_dart>('dw_vad_segments');
    dw_system_info = _lib.lookupFunction<_dw_system_info_c, _dw_system_info_dart>('dw_system_info');
    dw_free = _lib.lookupFunction<_dw_free_c, _dw_free_dart>('dw_free');
    dw_vad_free = _lib.lookupFunction<_dw_vad_free_c, _dw_vad_free_dart>('dw_vad_free');
  }

  String getSystemInfo() {
    final ptr = dw_system_info();
    return ptr.toDartString();
  }

  Pointer<Void> initContext(String modelPath) {
    final pathPtr = modelPath.toNativeUtf8();
    try {
      return dw_init(pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  Pointer<Void> initVadContext(String vadModelPath) {
    final pathPtr = vadModelPath.toNativeUtf8();
    try {
      return dw_vad_init(pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  int transcribe({
    required Pointer<Void> ctx,
    required Float32List samples,
    required String prompt,
    required int nThreads,
    required bool carryPrompt,
  }) {
    final promptPtr = prompt.toNativeUtf8();
    final pcmPtr = calloc<Float>(samples.length);
    final pcmList = pcmPtr.asTypedList(samples.length);
    pcmList.setAll(0, samples);

    try {
      return dw_transcribe(
        ctx,
        pcmPtr,
        samples.length,
        promptPtr,
        nThreads,
        carryPrompt ? 1 : 0,
      );
    } finally {
      calloc.free(pcmPtr);
      calloc.free(promptPtr);
    }
  }

  List<WhisperSegment> getSegments(Pointer<Void> ctx, {double offsetSeconds = 0.0}) {
    final n = dw_n_segments(ctx);
    final segments = <WhisperSegment>[];
    for (int i = 0; i < n; i++) {
      final textPtr = dw_segment_text(ctx, i);
      final text = textPtr.toDartString();
      // t0 and t1 in centiseconds
      final t0 = (dw_segment_t0(ctx, i) / 100.0) + offsetSeconds;
      final t1 = (dw_segment_t1(ctx, i) / 100.0) + offsetSeconds;
      segments.add(WhisperSegment(t0: t0, t1: t1, text: text));
    }
    return segments;
  }

  List<VadSegment> detectVadSegments({
    required Pointer<Void> vctx,
    required Float32List samples,
    int maxSegments = 4096,
  }) {
    final pcmPtr = calloc<Float>(samples.length);
    final pcmList = pcmPtr.asTypedList(samples.length);
    pcmList.setAll(0, samples);

    final outBuf = calloc<Float>(maxSegments * 2);

    try {
      final count = dw_vad_segments(vctx, pcmPtr, samples.length, outBuf, maxSegments);
      final outList = outBuf.asTypedList(count * 2);
      final segments = <VadSegment>[];
      for (int i = 0; i < count; i++) {
        segments.add(VadSegment(
          t0: outList[i * 2],
          t1: outList[i * 2 + 1],
        ));
      }
      return segments;
    } finally {
      calloc.free(pcmPtr);
      calloc.free(outBuf);
    }
  }

  void freeContext(Pointer<Void> ctx) {
    if (ctx != nullptr) {
      dw_free(ctx);
    }
  }

  void freeVadContext(Pointer<Void> vctx) {
    if (vctx != nullptr) {
      dw_vad_free(vctx);
    }
  }
}
