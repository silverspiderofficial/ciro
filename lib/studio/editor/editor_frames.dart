/// Flutter-drawn layers for the video editor (Persian shaped with Vazirmatn, RTL-aware):
/// still images fitted to the output frame, text overlays, subtitle lines and the preview
/// watermark. All PNGs are full-frame so FFmpeg overlays them at 0:0.
library;

import 'dart:io';

import 'package:flutter/painting.dart';

import '../render/canvas_render.dart';
import 'edit_project.dart';

/// A still picture at the output size: cropped to fill, or whole over a blurred copy.
Future<void> renderEditImage(String imagePath, String outPath, {required int width, required int height, required FitMode fit}) async {
  final img = await loadImageFile(imagePath, maxSide: 2400);
  try {
    final png = await renderPng(width, height, (canvas, size) {
      final full = Offset.zero & size;
      if (fit == FitMode.crop) {
        drawCover(canvas, img, full);
        return;
      }
      drawCover(canvas, img, full, blurSigma: 40, tint: const Color(0x66000000));
      final scale = (size.width / img.width).clamp(0.0, size.height / img.height);
      final w = img.width * scale, h = img.height * scale;
      drawCover(canvas, img, Rect.fromCenter(center: full.center, width: w, height: h));
    });
    await File(outPath).writeAsBytes(png, flush: true);
  } finally {
    img.dispose();
  }
}

/// A text overlay on a translucent plate at the top, centre or bottom of the frame.
Future<void> renderEditText(String text, String outPath,
    {required int width, required int height, TextPosition position = TextPosition.top, int size = 1}) async {
  final png = await renderPng(width, height, (canvas, s) {
    final w = s.width;
    final maxSize = const [56.0, 80.0, 108.0][size.clamp(0, 2)];
    final tp = fittedText(text, Size(w * 0.84, s.height * 0.26), minSize: 30, maxSize: maxSize, height: 1.35,
        shadows: const [Shadow(color: Color(0x80000000), blurRadius: 10)]);
    final pad = w * 0.04;
    final cy = switch (position) {
      TextPosition.top => s.height * 0.16 + tp.height / 2,
      TextPosition.center => s.height / 2,
      TextPosition.bottom => s.height * 0.62 - tp.height / 2,
    };
    final plate = Rect.fromCenter(center: Offset(w / 2, cy), width: tp.width + pad * 2, height: tp.height + pad * 1.4);
    canvas.drawRRect(RRect.fromRectAndRadius(plate, Radius.circular(w * 0.035)), Paint()..color = const Color(0x8C000000));
    tp.paint(canvas, Offset(plate.center.dx - tp.width / 2, plate.center.dy - tp.height / 2));
    tp.dispose();
  });
  await File(outPath).writeAsBytes(png, flush: true);
}

/// One subtitle line near the bottom (above Instagram's caption area).
Future<void> renderEditSubtitle(String text, String outPath, {required int width, required int height}) async {
  final png = await renderPng(width, height, (canvas, s) {
    final w = s.width;
    final tp = layoutText(text, maxWidth: w * 0.84, size: 50, weight: FontWeight.w700, height: 1.4, maxLines: 3);
    const pad = 24.0;
    final plate = Rect.fromCenter(center: Offset(w / 2, s.height * 0.76), width: tp.width + pad * 2, height: tp.height + pad);
    canvas.drawRRect(RRect.fromRectAndRadius(plate, const Radius.circular(20)), Paint()..color = const Color(0xB3000000));
    tp.paint(canvas, Offset(plate.center.dx - tp.width / 2, plate.center.dy - tp.height / 2));
    tp.dispose();
  });
  await File(outPath).writeAsBytes(png, flush: true);
}

Future<void> renderEditBlank(String outPath, {required int width, required int height}) async {
  final png = await renderPng(width, height, (canvas, size) {});
  await File(outPath).writeAsBytes(png, flush: true);
}

/// Diagonal "preview" marks so a preview is not a finished video.
Future<void> renderPreviewWatermark(String outPath, {required int width, required int height}) async {
  final png = await renderPng(width, height, (canvas, s) {
    final tp = layoutText('پیش‌نمایش · PREVIEW', maxWidth: s.width, size: s.width * 0.07, color: const Color(0x66FFFFFF));
    canvas.save();
    canvas.translate(s.width / 2, s.height / 2);
    canvas.rotate(-0.5);
    for (final dy in [-s.height * 0.3, 0.0, s.height * 0.3]) {
      tp.paint(canvas, Offset(-tp.width / 2, dy - tp.height / 2));
    }
    canvas.restore();
    tp.dispose();
  });
  await File(outPath).writeAsBytes(png, flush: true);
}
