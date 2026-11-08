/// Timeline maths for the video renderer: scene timing, cross-fade offsets, narration
/// placement and subtitle cues. Pure Dart so it is unit-tested and identical on every platform.
library;

import 'dart:math' as math;

import 'video_project.dart';

class SceneTiming {
  const SceneTiming({
    required this.index,
    required this.start,
    required this.duration,
    required this.narrationStart,
    required this.narrationSeconds,
    required this.textStart,
    required this.textEnd,
    required this.transitionIn,
  });

  final int index;

  /// Start of the scene on the output timeline (it overlaps the previous scene by [transitionIn]).
  final double start;
  final double duration;
  final double narrationStart;
  final double narrationSeconds;

  /// Window of the animated on-screen text.
  final double textStart;
  final double textEnd;

  /// Length of the cross-fade from the previous scene (0 for the first scene or a cut).
  final double transitionIn;

  double get end => start + duration;
}

class TimelinePlan {
  const TimelinePlan(this.scenes, this.totalSeconds);
  final List<SceneTiming> scenes;
  final double totalSeconds;
}

class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);
  final double start;
  final double end;
  final String text;

  @override
  String toString() => 'SubtitleCue(${start.toStringAsFixed(2)}-${end.toStringAsFixed(2)}: $text)';
}

const double minSceneSeconds = 2.5;
const double maxSceneSeconds = 30;
const double narrationLeadIn = 0.25;
const double narrationTail = 0.45;

/// A cut is rendered as a very short cross-fade so every boundary uses the same filter.
const double cutSeconds = 0.05;

double transitionLength(SceneTransition t, double configured) => t == SceneTransition.cut ? cutSeconds : configured;

/// [narrationSeconds] holds the spoken length of each scene (0 when silent).
TimelinePlan planTimeline(VideoProject project, List<double> narrationSeconds) {
  assert(narrationSeconds.length == project.scenes.length);
  final out = <SceneTiming>[];
  var cursor = 0.0;
  for (var i = 0; i < project.scenes.length; i++) {
    final scene = project.scenes[i];
    final tIn = i == 0 ? 0.0 : transitionLength(project.scenes[i - 1].transition, project.transitionSeconds);
    final tOut = i == project.scenes.length - 1 ? 0.0 : transitionLength(scene.transition, project.transitionSeconds);
    final speech = narrationSeconds[i];
    final lead = tIn + narrationLeadIn;
    final needed = speech > 0 ? lead + speech + narrationTail + tOut : 0.0;
    var duration = scene.durationSeconds ?? math.max(minSceneSeconds, needed);
    // A fixed duration never cuts the narrator off, and every scene outlasts its transitions.
    duration = math.max(duration, needed);
    duration = math.max(duration, tIn + tOut + 0.5);
    duration = math.min(duration, math.max(maxSceneSeconds, needed));
    final start = cursor - tIn;
    final textStart = start + tIn + 0.15;
    final textEnd = math.max(textStart + 0.6, start + duration - tOut - 0.1);
    out.add(SceneTiming(
      index: i,
      start: start < 0 ? 0 : start,
      duration: duration,
      narrationStart: start + lead,
      narrationSeconds: speech,
      textStart: textStart,
      textEnd: textEnd,
      transitionIn: tIn,
    ));
    cursor = (start < 0 ? 0 : start) + duration;
  }
  return TimelinePlan(out, cursor);
}

/// Splits narration into short readable lines (by words, at most [maxChars] each, preferring
/// sentence and comma boundaries) and spreads them over the spoken time by length.
List<SubtitleCue> buildSubtitleCues(TimelinePlan plan, List<String> narrations, {int maxChars = 38}) {
  final cues = <SubtitleCue>[];
  for (final t in plan.scenes) {
    final text = narrations[t.index].trim();
    if (text.isEmpty || t.narrationSeconds <= 0) continue;
    final lines = splitSubtitleLines(text, maxChars: maxChars);
    final weights = lines.map((l) => math.max(4, l.replaceAll(' ', '').length)).toList();
    final total = weights.fold<int>(0, (a, b) => a + b);
    var at = t.narrationStart;
    for (var i = 0; i < lines.length; i++) {
      final len = t.narrationSeconds * weights[i] / total;
      cues.add(SubtitleCue(at, at + len, lines[i]));
      at += len;
    }
  }
  return cues;
}

final _sentenceEnd = RegExp(r'[.!?؟…:;؛]$');
final _softBreak = RegExp(r'[,،]$');

List<String> splitSubtitleLines(String text, {int maxChars = 38}) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final lines = <String>[];
  final current = <String>[];
  var length = 0;
  void flush() {
    if (current.isNotEmpty) {
      lines.add(current.join(' '));
      current.clear();
      length = 0;
    }
  }

  for (final w in words) {
    final add = current.isEmpty ? w.length : w.length + 1;
    if (current.isNotEmpty && length + add > maxChars) flush();
    current.add(w);
    length += current.length == 1 ? w.length : w.length + 1;
    if (_sentenceEnd.hasMatch(w) && length >= maxChars * 0.35) {
      flush();
    } else if (_softBreak.hasMatch(w) && length >= maxChars * 0.6) {
      flush();
    }
  }
  flush();
  return lines;
}

/// Offsets for chained FFmpeg xfade filters: the i-th entry is the offset of the cross-fade
/// that brings in scene i+1, measured on the accumulated output.
List<double> xfadeOffsets(TimelinePlan plan) =>
    [for (var i = 1; i < plan.scenes.length; i++) plan.scenes[i].start];
