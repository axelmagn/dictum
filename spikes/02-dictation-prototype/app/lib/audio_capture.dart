import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

import 'device_service.dart';

class RecordingStats {
  final String wavPath;
  final int totalSamples;
  final int totalDurationMs;
  final int wallClockMs;
  final int overrunCount;

  RecordingStats({
    required this.wavPath,
    required this.totalSamples,
    required this.totalDurationMs,
    required this.wallClockMs,
    required this.overrunCount,
  });

  factory RecordingStats.fromMap(Map<dynamic, dynamic> map) {
    return RecordingStats(
      wavPath: map['wavPath'] as String? ?? '',
      totalSamples: (map['totalSamples'] as num?)?.toInt() ?? 0,
      totalDurationMs: (map['totalDurationMs'] as num?)?.toInt() ?? 0,
      wallClockMs: (map['wallClockMs'] as num?)?.toInt() ?? 0,
      overrunCount: (map['overrunCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class AudioCaptureController {
  static const MethodChannel _controlChannel =
      MethodChannel('dev.dictum.spike/audio_control');
  static const EventChannel _streamChannel =
      EventChannel('dev.dictum.spike/audio_stream');

  StreamSubscription? _streamSub;
  final StreamController<Float32List> _frameController =
      StreamController<Float32List>.broadcast();

  Stream<Float32List> get audioFrames => _frameController.stream;

  Future<bool> hasPermission() => DeviceService.hasAudioPermission();

  Future<bool> requestPermission() => DeviceService.requestAudioPermission();

  Future<bool> startRecording(String wavPath) async {
    final ok = await _controlChannel.invokeMethod<bool>(
      'startRecording',
      {'wavPath': wavPath},
    );
    if (ok == true) {
      await _streamSub?.cancel();
      _streamSub = _streamChannel.receiveBroadcastStream().listen((dynamic event) {
        if (event is Uint8List) {
          // Convert 16-bit PCM s16le to Float32List normalized to [-1.0, 1.0]
          final byteData = ByteData.sublistView(event);
          final sampleCount = event.lengthInBytes ~/ 2;
          final floatList = Float32List(sampleCount);
          for (int i = 0; i < sampleCount; i++) {
            final sampleInt = byteData.getInt16(i * 2, Endian.little);
            floatList[i] = sampleInt / 32768.0;
          }
          _frameController.add(floatList);
        }
      });
      return true;
    }
    return false;
  }

  Future<RecordingStats> stopRecording() async {
    await _streamSub?.cancel();
    _streamSub = null;
    final res =
        await _controlChannel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
    return RecordingStats.fromMap(res ?? {});
  }

  void dispose() {
    _streamSub?.cancel();
    _frameController.close();
  }
}
