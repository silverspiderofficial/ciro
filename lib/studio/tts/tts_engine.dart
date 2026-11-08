/// Offline narrator voice: Piper models through sherpa-onnx (Android, Windows, Linux).
/// Synthesis runs on a background isolate; the phonemizer data (a small espeak-ng subset for
/// Persian and English) ships in the app's assets and is copied to disk on first use.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../video/wav.dart';

class VoiceFiles {
  const VoiceFiles({required this.model, required this.tokens, required this.dataDir});
  final String model;
  final String tokens;
  final String dataDir;
}

abstract class TtsEngine {
  /// One clip per text (empty text -> empty clip), same order.
  Future<List<PcmAudio>> synthesizeAll(List<String> texts, VoiceFiles voice, {double speed = 1.0, int threads = 2});
}

/// Removes what a narrator should not read aloud: hashtags, mentions, emojis, URLs, markup.
String cleanForSpeech(String text) {
  var s = text;
  s = s.replaceAll(RegExp(r'https?://\S+'), ' ');
  s = s.replaceAll(RegExp(r'[#@][\w\u0600-\u06FF_]+'), ' ');
  s = s.replaceAll(RegExp(r'[*_`~>|\[\]{}]'), ' ');
  // Emoji and pictographs (surrogate pairs) and variation selectors.
  s = s.replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]', unicode: true), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

const espeakAssetFiles = [
  'phontab',
  'phonindex',
  'phondata',
  'intonations',
  'fa_dict',
  'en_dict',
  'lang/ira/fa',
  'lang/gmw/en',
  'lang/gmw/en-US',
];

/// Copies the bundled espeak-ng data into [supportDir]/espeak-ng-data once; returns its path.
Future<String> ensureEspeakData(String supportDir) async {
  final root = Directory(p.join(supportDir, 'espeak-ng-data'));
  final marker = File(p.join(root.path, '.kiro-v1'));
  if (await marker.exists()) return root.path;
  for (final rel in espeakAssetFiles) {
    final data = await rootBundle.load('assets/tts/espeak-ng-data/$rel');
    final f = File(p.join(root.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  }
  await marker.writeAsString('ok');
  return root.path;
}

class SherpaTtsEngine implements TtsEngine {
  @override
  Future<List<PcmAudio>> synthesizeAll(List<String> texts, VoiceFiles voice, {double speed = 1.0, int threads = 2}) async {
    final cleaned = texts.map(cleanForSpeech).toList();
    final raw = await Isolate.run(() => _synthesize(cleaned, voice.model, voice.tokens, voice.dataDir, speed, threads));
    return [for (final r in raw) r == null ? PcmAudio(Int16List(0), 22050) : PcmAudio.fromFloat(r.$1, r.$2)];
  }
}

List<(Float32List, int)?> _synthesize(List<String> texts, String model, String tokens, String dataDir, double speed, int threads) {
  sherpa.initBindings();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(model: model, tokens: tokens, dataDir: dataDir),
      numThreads: threads,
      debug: false,
      provider: 'cpu',
    ),
    maxNumSenetences: 1,
  ));
  try {
    return [
      for (final t in texts)
        if (t.isEmpty)
          null
        else
          () {
            final a = tts.generate(text: t, sid: 0, speed: speed);
            return (a.samples, a.sampleRate);
          }(),
    ];
  } finally {
    tts.free();
  }
}
