import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DeviceService parses getDeviceInfo properly', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.dictum.spike/device'),
      (MethodCall call) async {
        if (call.method == 'getDeviceInfo') {
          return {
            'manufacturer': 'Google',
            'model': 'Pixel 9a',
            'socModel': 'Tensor G4',
            'totalRamBytes': 8589934592,
            'androidRelease': '15',
            'sdkInt': 35,
            'cpuCoreCount': 8,
            'externalFilesDir': '/sdcard/Android/data/dev.dictum.spike.app/files',
          };
        }
        if (call.method == 'getThermalStatus') return 1;
        if (call.method == 'hasAudioPermission') return true;
        return null;
      },
    );

    final info = await DeviceService.getDeviceInfo();
    expect(info, isNotNull);
    expect(info!.manufacturer, equals('Google'));
    expect(info.model, equals('Pixel 9a'));
    expect(info.deviceTag, equals('Google_Pixel_9a'));
    expect(info.cpuCoreCount, equals(8));

    final thermal = await DeviceService.getThermalStatus();
    expect(thermal, equals(1));

    final hasPerm = await DeviceService.hasAudioPermission();
    expect(hasPerm, isTrue);
  });
}
