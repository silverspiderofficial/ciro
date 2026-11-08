/// Draws the video's still frames and text layers with Flutter (so Persian is shaped exactly
/// like in the app, with the Vazirmatn font): scene backgrounds at 1.5x the output size for
/// smooth Ken Burns motion, animated-text plates and burned-in subtitle lines.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../render/canvas_render.dart';
import 'video_project.dart';

const sceneScale = 1.5;
final int sceneWidth = (VideoProject.width * sceneScale).round();
final int sceneHeight = (VideoProject.height * sceneScale).round();

/// True when the picture is close enough to 9:16 to simply fill the frame.
bool fillsVertical(int width, int height) {
  final aspect = width / height;
  return (aspect - 9 / 16).abs() / (9 / 16) < 0.15;
}

Future<void> renderSceneStill(String imagePath, String outPath) async {
  final img = await loadImageFile(imagePath, maxSide: 2880);
  try {
    final png = await renderPng(sceneWidth, sceneHeight, (canvas, size) {
      final full = Offset.zero & size;
      if (fillsVertical(img.width, img.height)) {
        drawCover(canvas, img, full);
        return;
      }
      // Blurred, darkened copy fills the frame; the picture itself sits in the middle.
      drawCover(canvas, img, full, blurSigma: 40, tint: const Color(0x66000000));
      final scale = size.width / img.width;
      final h = img.height * scale;
      final dest = h <= size.height * 0.8
          ? Rect.fromLTWH(0, (size.height - h) / 2, size.width, h)
          : Rect.fromCenter(center: full.center, width: size.width, height: size.height * 0.8);
      drawCover(canvas, img, dest);
    });
    await File(outPath).writeAsBytes(png, flush: true);
  } finally {
    img.dispose();
  }
}

/// Big hook/title text for the upper part of the frame, on a translucent plate.
Future<void> renderTitleOverlay(String text, String outPath) async {
  final png = await renderPng(VideoProject.width, VideoProject.height, (canvas, size) {
    final w = size.width;
    final maxBox = Size(w * 0.84, size.height * 0.24);
    final tp = fittedText(text, maxBox, minSize: 40, maxSize: 92, height: 1.35,
        shadows: const [Shadow(color: Color(0x80000000), blurRadius: 10)]);
    final pad = w * 0.045;
    final plate = Rect.fromCenter(
      center: Offset(w / 2, size.height * 0.2 + tp.height / 2),
      width: tp.width + pad * 2,
      height: tp.height + pad * 1.4,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(plate, Radius.circular(w * 0.04)), Paint()..color = const Color(0x8C000000));
    tp.paint(canvas, Offset(plate.center.dx - tp.width / 2, plate.center.dy - tp.height / 2));
    tp.dispose();
  });
  await File(outPath).writeAsBytes(png, flush: true);
}

/// One subtitle line, near the bottom but above Instagram's caption area.
Future<void> renderSubtitle(String text, String outPath) async {
  final png = await renderPng(VideoProject.width, VideoProject.height, (canvas, size) {
    final w = size.width;
    final tp = layoutText(text, maxWidth: w * 0.84, size: 52, weight: FontWeight.w700, height: 1.4, maxLines: 3);
    final pad = 26.0;
    final plate = Rect.fromCenter(
      center: Offset(w / 2, size.height * 0.74),
      width: tp.width + pad * 2,
      height: tp.height + pad,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(plate, const Radius.circular(22)), Paint()..color = const Color(0xB3000000));
    tp.paint(canvas, Offset(plate.center.dx - tp.width / 2, plate.center.dy - tp.height / 2));
    tp.dispose();
  });
  await File(outPath).writeAsBytes(png, flush: true);
}

Future<void> renderTransparent(String outPath) async {
  final png = await renderPng(VideoProject.width, VideoProject.height, (canvas, size) {});
  await File(outPath).writeAsBytes(png, flush: true);
}

/// Poster frame / thumbnail of a still (used for previews).
Future<ui.Image> decodeForPreview(String path) => loadImageFile(path, maxSide: 720);
