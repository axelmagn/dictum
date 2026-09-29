import 'dart:async';
import 'package:flutter/services.dart';

class AudioPlayerStatus {
  final bool isPlaying;
  final int positionMs;
  final int durationMs;

  const AudioPlayerStatus({
    required this.isPlaying,
    required this.positionMs,
    required this.durationMs,
  });

  factory AudioPlayerStatus.fromMap(Map<dynamic, dynamic> map) {
    return AudioPlayerStatus(
      isPlaying: map['isPlaying'] as bool? ?? false,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  static const idle = AudioPlayerStatus(isPlaying: false, positionMs: 0, durationMs: 0);
}

class AudioPlayerController {
  static const MethodChannel _playerChannel =
      MethodChannel('dev.dictum.spike/audio_player');

  Timer? _pollTimer;
  final StreamController<AudioPlayerStatus> _statusController =
      StreamController<AudioPlayerStatus>.broadcast();

  Stream<AudioPlayerStatus> get statusStream => _statusController.stream;

  Future<bool> start(String path) async {
    final ok = await _playerChannel.invokeMethod<bool>('startPlayer', {'path': path});
    if (ok == true) {
      _startPolling();
      return true;
    }
    return false;
  }

  Future<bool> pause() async {
    final ok = await _playerChannel.invokeMethod<bool>('pausePlayer');
    return ok ?? false;
  }

  Future<bool> resume() async {
    final ok = await _playerChannel.invokeMethod<bool>('resumePlayer');
    if (ok == true) {
      _startPolling();
      return true;
    }
    return false;
  }

  Future<void> seek(int positionMs) async {
    await _playerChannel.invokeMethod<void>('seekPlayer', {'positionMs': positionMs});
  }

  Future<void> stop() async {
    _stopPolling();
    await _playerChannel.invokeMethod<void>('stopPlayer');
    _statusController.add(AudioPlayerStatus.idle);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final res = await _playerChannel.invokeMethod<Map<dynamic, dynamic>>('getPlayerStatus');
      if (res != null) {
        final status = AudioPlayerStatus.fromMap(res);
        _statusController.add(status);
        if (!status.isPlaying && status.positionMs >= status.durationMs && status.durationMs > 0) {
          _stopPolling();
        }
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void dispose() {
    _stopPolling();
    _statusController.close();
  }
}
