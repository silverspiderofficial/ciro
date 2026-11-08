import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../editor/editor_command.dart' show MediaProbe, parseProbe;
import 'ffmpeg_command.dart';

class FfmpegException implements Exception {
  const FfmpegException(this.code, [this.detail = '']);

  /// missing | failed | cancelled
  final String code;
  final String detail;
  @override
  String toString() => 'FfmpegException($code): $detail';
}

/// Runs an FFmpeg executable as a child process (Android: the binary packaged as
/// lib/arm64-v8a/libkiro_ffmpeg.so; desktop: a bundled ffmpeg[.exe] or one on PATH).
/// Running out of process keeps the UI isolate free and lets cancel kill the work at once.
class FfmpegRunner {
  FfmpegRunner(this.executable);
  final String executable;
  Process? _process;
  bool _cancelled = false;

  Future<bool> isAvailable() async {
    try {
      final r = await Process.run(executable, ['-hide_banner', '-version']).timeout(const Duration(seconds: 10));
      return r.exitCode == 0;
    } on Object {
      return false;
    }
  }

  /// Reads duration, size and audio presence of a media file (`ffmpeg -i`). Null when the file
  /// is not a readable video. Never throws.
  Future<MediaProbe?> probe(String path) async {
    try {
      final r = await Process.run(executable, ['-hide_banner', '-nostdin', '-i', path], stderrEncoding: const Utf8Codec(allowMalformed: true))
          .timeout(const Duration(seconds: 30));
      return parseProbe('${r.stderr}');
    } on Object {
      return null;
    }
  }

  /// Runs FFmpeg; [onProgress] gets 0..1 when [totalSeconds] is known.
  Future<void> run(List<String> args, {double? totalSeconds, void Function(double fraction)? onProgress}) async {
    _cancelled = false;
    final Process p;
    try {
      p = await Process.start(executable, args, runInShell: false);
    } on ProcessException catch (e) {
      throw FfmpegException('missing', e.message);
    }
    _process = p;
    final errLines = <String>[];
    final errSub = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) {
      if (errLines.length > 40) errLines.removeAt(0);
      errLines.add(l);
    });
    final outSub = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) {
      final s = parseProgressSeconds(l);
      if (s != null && totalSeconds != null && totalSeconds > 0) {
        onProgress?.call((s / totalSeconds).clamp(0.0, 1.0));
      }
    });
    final code = await p.exitCode;
    await outSub.cancel();
    await errSub.cancel();
    _process = null;
    if (_cancelled) throw const FfmpegException('cancelled');
    if (code != 0) throw FfmpegException('failed', errLines.join('\n'));
    onProgress?.call(1);
  }

  void cancel() {
    _cancelled = true;
    _process?.kill(ProcessSignal.sigkill);
  }
}
