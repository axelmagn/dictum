import 'package:flutter/services.dart';

class DeviceInfo {
  final String manufacturer;
  final String model;
  final String socModel;
  final int totalRamBytes;
  final String androidRelease;
  final int sdkInt;
  final int cpuCoreCount;
  final String externalFilesDir;

  const DeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.socModel,
    required this.totalRamBytes,
    required this.androidRelease,
    required this.sdkInt,
    required this.cpuCoreCount,
    required this.externalFilesDir,
  });

  factory DeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    return DeviceInfo(
      manufacturer: map['manufacturer'] as String? ?? 'Unknown',
      model: map['model'] as String? ?? 'Unknown',
      socModel: map['socModel'] as String? ?? 'Unknown',
      totalRamBytes: (map['totalRamBytes'] as num?)?.toInt() ?? 0,
      androidRelease: map['androidRelease'] as String? ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      cpuCoreCount: (map['cpuCoreCount'] as num?)?.toInt() ?? 1,
      externalFilesDir: map['externalFilesDir'] as String? ?? '',
    );
  }

  String get deviceTag => '${manufacturer}_$model'.replaceAll(' ', '_');
}

class DeviceService {
  static const MethodChannel _deviceChannel =
      MethodChannel('dev.dictum.spike/device');

  static Future<DeviceInfo?> getDeviceInfo() async {
    try {
      final info =
          await _deviceChannel.invokeMethod<Map<dynamic, dynamic>>('getDeviceInfo');
      if (info != null) {
        return DeviceInfo.fromMap(info);
      }
    } catch (_) {}
    return null;
  }

  static Future<int> getThermalStatus() async {
    try {
      final status = await _deviceChannel.invokeMethod<int>('getThermalStatus');
      return status ?? -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<bool> hasAudioPermission() async {
    try {
      final res = await _deviceChannel.invokeMethod<bool>('hasAudioPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestAudioPermission() async {
    try {
      final res =
          await _deviceChannel.invokeMethod<bool>('requestAudioPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setKeepScreenOn(bool enabled) async {
    try {
      await _deviceChannel.invokeMethod<bool>('setKeepScreenOn', enabled);
    } catch (_) {}
  }
}
