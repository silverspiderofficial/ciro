/// Minimal PCM WAV helpers for the narration track (pure Dart, every platform).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Mono 16-bit PCM audio.
class PcmAudio {
  PcmAudio(this.samples, this.sampleRate);

  /// Signed 16-bit samples.
  final Int16List samples;
  final int sampleRate;

  double get seconds => sampleRate == 0 ? 0 : samples.length / sampleRate;

  static PcmAudio silence(double seconds, int sampleRate) =>
      PcmAudio(Int16List((seconds * sampleRate).round().clamp(0, 1 << 30)), sampleRate);

  /// Converts float samples in [-1, 1] (what TTS engines return).
  static PcmAudio fromFloat(Float32List data, int sampleRate) {
    final out = Int16List(data.length);
    for (var i = 0; i < data.length; i++) {
      final v = (data[i] * 32767).round();
      out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
    }
    return PcmAudio(out, sampleRate);
  }
}

class WavFormatException implements Exception {
  const WavFormatException(this.message);
  final String message;
  @override
  String toString() => 'WavFormatException: $message';
}

Uint8List encodeWav(PcmAudio audio) {
  final dataBytes = audio.samples.length * 2;
  final b = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, audio.sampleRate, Endian.little);
  b.setUint32(28, audio.sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < audio.samples.length; i++) {
    b.setInt16(44 + i * 2, audio.samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Decodes 16-bit PCM or 32-bit float WAV (mono or stereo, stereo is mixed down).
PcmAudio decodeWav(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const WavFormatException('not a RIFF/WAVE file');
  }
  var offset = 12;
  int? format, channels, rate, bits;
  while (offset + 8 <= bytes.length) {
    final id = tag(offset);
    final size = b.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      format = b.getUint16(body, Endian.little);
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (format == null || channels == null || rate == null || bits == null) {
        throw const WavFormatException('data before fmt');
      }
      final end = math.min(body + size, bytes.length);
      final frameBytes = (bits ~/ 8) * channels;
      if (frameBytes == 0) throw const WavFormatException('bad format');
      final frames = (end - body) ~/ frameBytes;
      final out = Int16List(frames);
      for (var f = 0; f < frames; f++) {
        var acc = 0.0;
        for (var c = 0; c < channels; c++) {
          final p = body + f * frameBytes + c * (bits ~/ 8);
          if (format == 1 && bits == 16) {
            acc += b.getInt16(p, Endian.little);
          } else if (format == 3 && bits == 32) {
            acc += b.getFloat32(p, Endian.little) * 32767;
          } else {
            throw WavFormatException('unsupported format $format/$bits');
          }
        }
        out[f] = (acc / channels).round().clamp(-32768, 32767);
      }
      return PcmAudio(out, rate);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  throw const WavFormatException('no data chunk');
}

/// Linear resampling (narration only; good enough for speech).
PcmAudio resample(PcmAudio a, int rate) {
  if (a.sampleRate == rate || a.samples.isEmpty) return PcmAudio(a.samples, rate);
  final n = (a.samples.length * rate / a.sampleRate).round();
  final out = Int16List(n);
  final step = a.sampleRate / rate;
  for (var i = 0; i < n; i++) {
    final pos = i * step;
    final i0 = pos.floor();
    final i1 = math.min(i0 + 1, a.samples.length - 1);
    final t = pos - i0;
    out[i] = (a.samples[math.min(i0, a.samples.length - 1)] * (1 - t) + a.samples[i1] * t).round();
  }
  return PcmAudio(out, rate);
}

/// Places each clip at its start time (seconds) on one track of [totalSeconds].
/// Clips are resampled to [sampleRate]; overlapping clips are mixed with clipping.
PcmAudio layoutTrack(List<({double start, PcmAudio audio})> clips, double totalSeconds, int sampleRate) {
  final total = Int32List((totalSeconds * sampleRate).ceil());
  for (final c in clips) {
    final a = resample(c.audio, sampleRate);
    final startIdx = (c.start * sampleRate).round();
    for (var i = 0; i < a.samples.length; i++) {
      final j = startIdx + i;
      if (j < 0 || j >= total.length) continue;
      total[j] += a.samples[i];
    }
  }
  final out = Int16List(total.length);
  for (var i = 0; i < total.length; i++) {
    out[i] = total[i].clamp(-32768, 32767);
  }
  return PcmAudio(out, sampleRate);
}

Future<PcmAudio> readWavFile(String path) async => decodeWav(await File(path).readAsBytes());

Future<void> writeWavFile(String path, PcmAudio audio) async => File(path).writeAsBytes(encodeWav(audio), flush: true);
