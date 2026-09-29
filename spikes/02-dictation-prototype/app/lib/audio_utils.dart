import 'dart:io';
import 'dart:typed_data';

class AudioData {
  final Float32List samples;
  final int sampleRate;
  final double durationSeconds;

  AudioData({
    required this.samples,
    required this.sampleRate,
    required this.durationSeconds,
  });
}

class AudioUtils {
  /// Reads a 16 kHz mono 16-bit PCM WAV file and returns [AudioData].
  /// Asserts and validates audio format strictly according to spike specs.
  static Future<AudioData> loadWavFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException("Audio file does not exist", filePath);
    }
    final bytes = await file.readAsBytes();
    return parseWavBytes(bytes);
  }

  static AudioData parseWavBytes(Uint8List bytes) {
    if (bytes.length < 44) {
      throw FormatException("WAV file too short (${bytes.length} bytes)");
    }

    final data = ByteData.sublistView(bytes);

    // RIFF header
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    if (riff != "RIFF") {
      throw FormatException("Expected 'RIFF' header, got '$riff'");
    }

    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    if (wave != "WAVE") {
      throw FormatException("Expected 'WAVE' format, got '$wave'");
    }

    int offset = 12;
    int audioFormat = 0;
    int numChannels = 0;
    int sampleRate = 0;
    int bitsPerSample = 0;
    int dataOffset = -1;
    int dataSize = -1;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      offset += 8;

      if (chunkId == "fmt ") {
        if (chunkSize < 16) {
          throw FormatException("Invalid 'fmt ' chunk size: $chunkSize");
        }
        audioFormat = data.getUint16(offset, Endian.little);
        numChannels = data.getUint16(offset + 2, Endian.little);
        sampleRate = data.getUint32(offset + 4, Endian.little);
        bitsPerSample = data.getUint16(offset + 14, Endian.little);
        offset += chunkSize;
      } else if (chunkId == "data") {
        dataOffset = offset;
        dataSize = chunkSize;
        break;
      } else {
        // Skip unknown chunk
        offset += chunkSize;
      }
    }

    if (audioFormat != 1) {
      throw FormatException("Audio must be uncompressed PCM (format 1), got $audioFormat");
    }
    if (numChannels != 1) {
      throw FormatException("Audio must be mono (1 channel), got $numChannels");
    }
    if (sampleRate != 16000) {
      throw FormatException("Audio must be 16000 Hz sample rate, got $sampleRate");
    }
    if (bitsPerSample != 16) {
      throw FormatException("Audio must be 16-bit PCM (s16le), got $bitsPerSample-bit");
    }
    if (dataOffset == -1 || dataSize == -1) {
      throw FormatException("No 'data' chunk found in WAV");
    }

    final availableDataBytes = bytes.length - dataOffset;
    final actualDataBytes = dataSize > availableDataBytes ? availableDataBytes : dataSize;
    final numSamples = actualDataBytes ~/ 2;

    final pcmSamples = Float32List(numSamples);
    final pcmData = ByteData.sublistView(bytes, dataOffset, dataOffset + (numSamples * 2));

    for (int i = 0; i < numSamples; i++) {
      final int s16 = pcmData.getInt16(i * 2, Endian.little);
      pcmSamples[i] = s16 / 32768.0;
    }

    final duration = numSamples / sampleRate;

    return AudioData(
      samples: pcmSamples,
      sampleRate: sampleRate,
      durationSeconds: duration,
    );
  }
}
