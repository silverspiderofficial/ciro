/// Ready-made graphic templates drawn with Flutter's canvas (no model needed, so they work
/// on every phone and on desktop): quote card, carousel slide, title card and list.
/// Exported as 1080x1350 (feed, 4:5) or 1080x1920 (story/reels, 9:16) PNG.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../render/canvas_render.dart';

enum TemplateKind {
  quote('quote'),
  carousel('carousel'),
  title('title'),
  list('list');

  const TemplateKind(this.key);
  final String key;

  static TemplateKind fromKey(String? k) => TemplateKind.values.firstWhere((t) => t.key == k, orElse: () => TemplateKind.title);
}

enum TemplateFormat {
  portrait('portrait', 1080, 1350),
  story('story', 1080, 1920);

  const TemplateFormat(this.key, this.width, this.height);
  final String key;
  final int width;
  final int height;

  static TemplateFormat fromKey(String? k) => TemplateFormat.values.firstWhere((t) => t.key == k, orElse: () => TemplateFormat.portrait);
}

class TemplatePalette {
  const TemplatePalette(this.id, this.top, this.bottom, this.text, this.accent, this.muted);
  final String id;
  final Color top;
  final Color bottom;
  final Color text;
  final Color accent;
  final Color muted;
}

const templatePalettes = [
  TemplatePalette('violet', Color(0xFF2B1A6B), Color(0xFF6D4AFF), Color(0xFFFFFFFF), Color(0xFFFFD166), Color(0xCCFFFFFF)),
  TemplatePalette('sunset', Color(0xFFFF7A59), Color(0xFFB8336A), Color(0xFFFFFFFF), Color(0xFFFFF1C1), Color(0xD9FFFFFF)),
  TemplatePalette('ocean', Color(0xFF0B3C5D), Color(0xFF1D84B5), Color(0xFFFFFFFF), Color(0xFF7CF5D9), Color(0xCCFFFFFF)),
  TemplatePalette('mint', Color(0xFFE9FFF6), Color(0xFFBFF0DD), Color(0xFF113A2E), Color(0xFF1E9E73), Color(0xB3113A2E)),
  TemplatePalette('paper', Color(0xFFFFFBF2), Color(0xFFF3E9D2), Color(0xFF2D2A26), Color(0xFFE4572E), Color(0xB32D2A26)),
  TemplatePalette('night', Color(0xFF0F1115), Color(0xFF262A33), Color(0xFFF5F5F5), Color(0xFF00E0A4), Color(0xB3F5F5F5)),
];

TemplatePalette paletteById(String id) => templatePalettes.firstWhere((p) => p.id == id, orElse: () => templatePalettes.first);

class TemplateData {
  const TemplateData({
    required this.kind,
    this.title = '',
    this.body = '',
    this.items = const [],
    this.footer = '',
    this.slideIndex = 1,
    this.slideCount = 1,
    this.paletteId = 'violet',
    this.backgroundImagePath,
    this.format = TemplateFormat.portrait,
  });

  final TemplateKind kind;
  final String title;
  final String body;
  final List<String> items;

  /// Page handle or signature, e.g. "@my.page".
  final String footer;
  final int slideIndex;
  final int slideCount;
  final String paletteId;
  final String? backgroundImagePath;
  final TemplateFormat format;

  TemplateData copyWith({
    TemplateKind? kind,
    String? title,
    String? body,
    List<String>? items,
    String? footer,
    int? slideIndex,
    int? slideCount,
    String? paletteId,
    String? backgroundImagePath,
    bool clearBackground = false,
    TemplateFormat? format,
  }) =>
      TemplateData(
        kind: kind ?? this.kind,
        title: title ?? this.title,
        body: body ?? this.body,
        items: items ?? this.items,
        footer: footer ?? this.footer,
        slideIndex: slideIndex ?? this.slideIndex,
        slideCount: slideCount ?? this.slideCount,
        paletteId: paletteId ?? this.paletteId,
        backgroundImagePath: clearBackground ? null : (backgroundImagePath ?? this.backgroundImagePath),
        format: format ?? this.format,
      );
}

/// Splits a numbered or bulleted text into list items ("1. a", "- b", "• c", one per line).
List<String> parseListItems(String text) => text
    .split('\n')
    .map((l) => l.trim().replaceFirst(RegExp(r'^([-•*–]|[0-9۰-۹]+[.)\-]|[0-9۰-۹]+\s*[-–])\s*'), '').trim())
    .where((l) => l.isNotEmpty)
    .take(7)
    .toList();

String _digits(int n, TextDirection dir) {
  final s = '$n';
  if (dir == TextDirection.ltr) return s;
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  return s.split('').map((c) => fa[int.parse(c)]).join();
}

Future<Uint8List> renderTemplate(TemplateData d) async {
  ui.Image? bg;
  if (d.backgroundImagePath != null) {
    try {
      bg = await loadImageFile(d.backgroundImagePath!);
    } on Object {
      bg = null;
    }
  }
  try {
    return await renderPng(d.format.width, d.format.height, (canvas, size) => paintTemplate(canvas, size, d, bg));
  } finally {
    bg?.dispose();
  }
}

void paintTemplate(Canvas canvas, Size size, TemplateData d, ui.Image? background) {
  final pal = paletteById(d.paletteId);
  final rect = Offset.zero & size;
  final w = size.width, h = size.height;
  final margin = w * 0.09;
  final textColor = background != null ? const Color(0xFFFFFFFF) : pal.text;
  final mutedColor = background != null ? const Color(0xD9FFFFFF) : pal.muted;
  final shadow = background != null ? const [Shadow(color: Color(0x99000000), blurRadius: 12)] : null;

  // ---- background ----
  if (background != null) {
    drawCover(canvas, background, rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, 0), Offset(0, h), [const Color(0x33000000), const Color(0xB3000000)]),
    );
  } else {
    canvas.drawRect(rect, Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), [pal.top, pal.bottom]));
    final blob = Paint()..color = pal.accent.withValues(alpha: 0.16);
    canvas.drawCircle(Offset(w * 0.92, h * 0.08), w * 0.32, blob);
    canvas.drawCircle(Offset(w * 0.05, h * 0.95), w * 0.26, blob);
  }

  final footerTp = d.footer.trim().isEmpty
      ? null
      : layoutText(d.footer.trim(), maxWidth: w - margin * 2, size: w * 0.032, color: mutedColor, weight: FontWeight.w500, maxLines: 1);
  final bottomReserve = footerTp == null ? margin : margin + footerTp.height + w * 0.03;
  final content = Rect.fromLTRB(margin, margin * 1.2, w - margin, h - bottomReserve);

  switch (d.kind) {
    case TemplateKind.quote:
      final mark = layoutText('”', maxWidth: w, size: w * 0.28, color: pal.accent, weight: FontWeight.w700, height: 1);
      mark.paint(canvas, Offset((w - mark.width) / 2, content.top - w * 0.02));
      final quoteTop = content.top + mark.height * 0.75;
      final authorTp = d.title.trim().isEmpty
          ? null
          : layoutText('— ${d.title.trim()}', maxWidth: content.width, size: w * 0.042, color: pal.accent, weight: FontWeight.w500, maxLines: 2);
      final authorH = authorTp == null ? 0.0 : authorTp.height + w * 0.05;
      final box = Size(content.width, content.bottom - quoteTop - authorH);
      final body = fittedText(d.body.trim().isEmpty ? '…' : d.body.trim(), box, maxSize: w * 0.085, minSize: w * 0.03, color: textColor, shadows: shadow);
      final y = quoteTop + (box.height - body.height) / 2;
      body.paint(canvas, Offset(content.left + (content.width - body.width) / 2, y));
      authorTp?.paint(canvas, Offset(content.left + (content.width - authorTp.width) / 2, y + body.height + w * 0.05));
      authorTp?.dispose();
      body.dispose();
      mark.dispose();

    case TemplateKind.title:
      final bar = Paint()..color = pal.accent;
      final titleBox = Size(content.width, content.height * 0.55);
      final title = fittedText(d.title.trim().isEmpty ? '…' : d.title.trim(), titleBox, maxSize: w * 0.12, minSize: w * 0.045, color: textColor, shadows: shadow, height: 1.3);
      final sub = d.body.trim().isEmpty
          ? null
          : fittedText(d.body.trim(), Size(content.width, content.height * 0.25), maxSize: w * 0.05, minSize: w * 0.028, color: mutedColor, weight: FontWeight.w500, shadows: shadow);
      final total = title.height + w * 0.07 + (sub == null ? 0 : sub.height + w * 0.04);
      var y = content.top + (content.height - total) / 2;
      title.paint(canvas, Offset(content.left + (content.width - title.width) / 2, y));
      y += title.height + w * 0.03;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, y + w * 0.01), width: w * 0.16, height: w * 0.012), Radius.circular(w)), bar);
      y += w * 0.04;
      sub?.paint(canvas, Offset(content.left + (content.width - sub.width) / 2, y));
      title.dispose();
      sub?.dispose();

    case TemplateKind.carousel:
      final dir = directionOf('${d.title}${d.body}');
      final count = d.slideCount.clamp(1, 20);
      final index = d.slideIndex.clamp(1, count);
      final badge = layoutText('${_digits(index, dir)}/${_digits(count, dir)}', maxWidth: w, size: w * 0.034, color: pal.top.computeLuminance() > 0.5 ? pal.text : pal.top, weight: FontWeight.w700, height: 1.2);
      final badgeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(dir == TextDirection.rtl ? content.right - badge.width - w * 0.06 : content.left, content.top, badge.width + w * 0.06, badge.height + w * 0.03),
        Radius.circular(w),
      );
      canvas.drawRRect(badgeRect, Paint()..color = pal.accent);
      badge.paint(canvas, Offset(badgeRect.left + w * 0.03, badgeRect.top + w * 0.015));
      final top = badgeRect.bottom + w * 0.06;
      final align = dir == TextDirection.rtl ? TextAlign.right : TextAlign.left;
      final title = fittedText(d.title.trim().isEmpty ? '…' : d.title.trim(), Size(content.width, (content.bottom - top) * 0.35), maxSize: w * 0.085, minSize: w * 0.04, color: textColor, align: align, shadows: shadow, height: 1.3);
      title.paint(canvas, Offset(content.left, top));
      final bodyTop = top + title.height + w * 0.05;
      if (d.body.trim().isNotEmpty) {
        final body = fittedText(d.body.trim(), Size(content.width, content.bottom - bodyTop - w * 0.08), maxSize: w * 0.05, minSize: w * 0.028, color: mutedColor, weight: FontWeight.w500, align: align, shadows: shadow, height: 1.6);
        body.paint(canvas, Offset(content.left, bodyTop));
        body.dispose();
      }
      // progress dots + swipe hint
      final dotY = content.bottom - w * 0.02;
      final spacing = w * 0.035;
      final startX = w / 2 - (count - 1) * spacing / 2;
      for (var i = 0; i < count; i++) {
        canvas.drawCircle(Offset(startX + i * spacing, dotY), i + 1 == index ? w * 0.011 : w * 0.007, Paint()..color = i + 1 == index ? pal.accent : mutedColor.withValues(alpha: 0.5));
      }
      if (index < count) {
        final arrow = layoutText(dir == TextDirection.rtl ? '←' : '→', maxWidth: w, size: w * 0.06, color: pal.accent, height: 1);
        arrow.paint(canvas, Offset(dir == TextDirection.rtl ? content.left : content.right - arrow.width, dotY - arrow.height / 2));
        arrow.dispose();
      }
      title.dispose();
      badge.dispose();

    case TemplateKind.list:
      final dir = directionOf('${d.title}${d.items.join()}');
      final align = dir == TextDirection.rtl ? TextAlign.right : TextAlign.left;
      final title = fittedText(d.title.trim().isEmpty ? '…' : d.title.trim(), Size(content.width, content.height * 0.22), maxSize: w * 0.08, minSize: w * 0.04, color: textColor, align: align, shadows: shadow, height: 1.3);
      title.paint(canvas, Offset(content.left, content.top));
      final items = d.items.isEmpty ? parseListItems(d.body) : d.items;
      final listTop = content.top + title.height + w * 0.06;
      final n = items.isEmpty ? 1 : items.length;
      final rowH = (content.bottom - listTop) / n;
      final bullet = w * 0.075;
      final itemSize = fitFontSize((s) {
        for (final it in items) {
          final tp = layoutText(it, maxWidth: content.width - bullet - w * 0.04, size: s, weight: FontWeight.w500, align: align, height: 1.35);
          final ok = tp.height <= rowH - w * 0.02;
          tp.dispose();
          if (!ok) return false;
        }
        return true;
      }, minSize: w * 0.026, maxSize: w * 0.05);
      for (var i = 0; i < items.length; i++) {
        final y = listTop + i * rowH;
        final tp = layoutText(items[i], maxWidth: content.width - bullet - w * 0.04, size: itemSize, color: textColor, weight: FontWeight.w500, align: align, height: 1.35, shadows: shadow);
        final cy = y + tp.height / 2;
        final cx = dir == TextDirection.rtl ? content.right - bullet / 2 : content.left + bullet / 2;
        canvas.drawCircle(Offset(cx, cy), bullet / 2, Paint()..color = pal.accent);
        final num = layoutText(_digits(i + 1, dir), maxWidth: bullet, size: bullet * 0.5, color: pal.top.computeLuminance() > 0.5 ? pal.text : pal.top, height: 1);
        num.paint(canvas, Offset(cx - num.width / 2, cy - num.height / 2));
        final tx = dir == TextDirection.rtl ? content.right - bullet - w * 0.04 - tp.width : content.left + bullet + w * 0.04;
        tp.paint(canvas, Offset(tx, y));
        tp.dispose();
        num.dispose();
      }
      title.dispose();
  }

  if (footerTp != null) {
    footerTp.paint(canvas, Offset((w - footerTp.width) / 2, h - margin * 0.6 - footerTp.height));
    footerTp.dispose();
  }
}
