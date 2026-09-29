import 'package:flutter_test/flutter_test.dart';
import 'package:app/whisper_worker.dart';

void main() {
  test('audioCtxFor sizes encoder window to chunk', () {
    expect(audioCtxFor(16000 * 3, 0), 0); // disabled -> full window
    expect(audioCtxFor(16000 * 3, 128), 150 + 32);
    expect(audioCtxFor(16000 * 2, 256), 256); // floor
    expect(audioCtxFor(16000 * 5, 512), 512); // floor (5*50 + 32 = 282 <= 512)
    expect(audioCtxFor(16000 * 10, 512), 532); // above floor (10*50 + 32 = 532)
    expect(audioCtxFor(16000 * 25, 256), 1282);
    expect(audioCtxFor(16000 * 30, 256), 1500); // ceiling
    expect(audioCtxFor(16000, 2000), 1500);
  });
}
