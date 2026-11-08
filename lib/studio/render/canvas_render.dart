/// Shared dart:ui drawing helpers (every platform): image loading, cover fitting, text that
/// fits a box (Persian RTL aware) and PNG encoding.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

const kiroFont = 'Vazirmatn';

final _rtlChars = RegExp(r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]');
final _ltrChars = RegExp(r'[A-Za-z]');

/// Direction of a paragraph from its first strong character.
TextDirection directionOf(String text) {
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_rtlChars.hasMatch(ch)) return TextDirection.rtl;
    if (_ltrChars.hasMatch(ch)) return TextDirection.ltr;
  }
  return TextDirection.rtl;
}

/// Largest size in [minSize, maxSize] for which [fits] is true (binary search, 0.5px steps).
double fitFontSize(bool Function(double size) fits, {required double minSize, required double maxSize}) {
  if (fits(maxSize)) return maxSize;
  var lo = minSize, hi = maxSize;
  if (!fits(lo)) return lo;
  while (hi - lo > 0.5) {
    final mid = (lo + hi) / 2;
    if (fits(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

TextPainter layoutText(
  String text, {
  required double maxWidth,
  required double size,
  Color color = const Color(0xFFFFFFFF),
  FontWeight weight = FontWeight.w700,
  TextAlign align = TextAlign.center,
  double height = 1.45,
  int? maxLines,
  List<Shadow>? shadows,
}) {
  final dir = directionOf(text);
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: kiroFont, fontSize: size, fontWeight: weight, color: color, height: height, shadows: shadows),
    ),
    textAlign: align,
    textDirection: dir,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  );
  tp.layout(maxWidth: maxWidth);
  return tp;
}

/// Lays out [text] at the largest size that fits [box].
TextPainter fittedText(
  String text,
  Size box, {
  double minSize = 22,
  double maxSize = 96,
  Color color = const Color(0xFFFFFFFF),
  FontWeight weight = FontWeight.w700,
  TextAlign align = TextAlign.center,
  double height = 1.45,
  List<Shadow>? shadows,
}) {
  final size = fitFontSize(
    (s) {
      final tp = layoutText(text, maxWidth: box.width, size: s, weight: weight, align: align, height: height);
      final ok = tp.height <= box.height && !tp.didExceedMaxLines && tp.width <= box.width + 0.5;
      tp.dispose();
      return ok;
    },
    minSize: minSize,
    maxSize: maxSize,
  );
  return layoutText(text, maxWidth: box.width, size: size, color: color, weight: weight, align: align, height: height, shadows: shadows);
}

/// Decodes an image file, downscaled so its longer side is at most [maxSide].
Future<ui.Image> loadImageFile(String path, {int maxSide = 2048}) async {
  final bytes = await File(path).readAsBytes();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width, h = descriptor.height;
  final scale = math.min(1.0, maxSide / math.max(w, h));
  final codec = await descriptor.instantiateCodec(
    targetWidth: (w * scale).round(),
    targetHeight: (h * scale).round(),
  );
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

/// Source rectangle that covers [target] with [image] (centre crop).
Rect coverSource(Size image, Size target) {
  final scale = math.max(target.width / image.width, target.height / image.height);
  final w = target.width / scale, h = target.height / scale;
  return Rect.fromLTWH((image.width - w) / 2, (image.height - h) / 2, w, h);
}

void drawCover(Canvas canvas, ui.Image image, Rect dest, {double blurSigma = 0, Color? tint}) {
  final src = coverSource(Size(image.width.toDouble(), image.height.toDouble()), dest.size);
  final paint = Paint()..filterQuality = FilterQuality.high;
  if (blurSigma > 0) paint.imageFilter = ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma, tileMode: TileMode.clamp);
  canvas.save();
  canvas.clipRect(dest);
  canvas.drawImageRect(image, src, dest, paint);
  if (tint != null) canvas.drawRect(dest, Paint()..color = tint);
  canvas.restore();
}

Future<Uint8List> pictureToPng(ui.Picture picture, int width, int height) async {
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw StateError('PNG encoding failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> renderPng(int width, int height, void Function(Canvas canvas, Size size) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  paint(canvas, Size(width.toDouble(), height.toDouble()));
  return pictureToPng(recorder.endRecording(), width, height);
}
