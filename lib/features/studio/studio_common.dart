import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../l10n/studio_strings.dart';
import '../../studio/studio_errors.dart';
import '../../studio/studio_service.dart';
import '../../studio/templates/templates.dart';
import '../../studio/video/video_project.dart';

/// UI state shared by the three Studio tabs (kept while the app runs).
class StudioUiState extends ChangeNotifier {
  StudioUiState({required String languageCode})
      : project = VideoProject(
          voice: languageCode == 'en' ? NarratorVoice.english : NarratorVoice.persian,
          musicTrackId: 'happy_loop',
        );

  VideoProject project;
  String? lastImage;
  String? lastVideo;
  TemplateData template = const TemplateData(kind: TemplateKind.quote);
  String? lastTemplate;

  /// Asks the Studio screen to switch tab (0 image, 1 templates, 2 video).
  final ValueNotifier<int?> tabRequest = ValueNotifier(null);

  void setProject(VideoProject p) {
    project = p;
    notifyListeners();
  }

  void addScene(String imagePath, {String text = ''}) {
    project = project.copyWith(scenes: [...project.scenes, VideoScene(imagePath: imagePath, overlayText: text)]);
    notifyListeners();
  }

  void updateScene(int i, VideoScene s) {
    final list = [...project.scenes];
    list[i] = s;
    project = project.copyWith(scenes: list);
    notifyListeners();
  }

  void removeScene(int i) {
    final list = [...project.scenes]..removeAt(i);
    project = project.copyWith(scenes: list);
    notifyListeners();
  }

  void moveScene(int from, int to) {
    if (to < 0 || to >= project.scenes.length) return;
    final list = [...project.scenes];
    final s = list.removeAt(from);
    list.insert(to, s);
    project = project.copyWith(scenes: list);
    notifyListeners();
  }

  void setTemplate(TemplateData t) {
    template = t;
    notifyListeners();
  }

  void setLastImage(String? path) {
    lastImage = path;
    notifyListeners();
  }

  void setLastVideo(String? path) {
    lastVideo = path;
    notifyListeners();
  }

  void setLastTemplate(String? path) {
    lastTemplate = path;
    notifyListeners();
  }
}

String studioErrorText(S s, Object error, SettingsController settings) {
  if (error is StudioException) {
    return s.t(studioErrorKey(error.code), {'n': '${settings.heavyWorkMinBattery}', 'code': error.code});
  }
  return s.t('studioErr_generic', {'code': '$error'});
}

/// Runs Studio work and shows a localised message on failure. Returns null on failure.
Future<T?> runStudio<T>(BuildContext context, Future<T> Function() work) async {
  final messenger = ScaffoldMessenger.of(context);
  final s = context.sRead;
  final settings = context.read<SettingsController>();
  try {
    return await work();
  } on StudioException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(studioErrorText(s, e, settings))));
    return null;
  } on Object catch (e) {
    if (kDebugMode) debugPrint('studio error: $e');
    messenger.showSnackBar(SnackBar(content: Text(studioErrorText(s, e, settings))));
    return null;
  }
}

/// Progress of the running Studio job with a stop button.
class StudioJobBar extends StatelessWidget {
  const StudioJobBar({super.key});

  @override
  Widget build(BuildContext context) {
    final studio = context.watch<StudioService>();
    final job = studio.job;
    if (job == null) return const SizedBox.shrink();
    final s = context.s;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(job.detail.isEmpty
                      ? s.t('studioPhase_${job.phase}')
                      : '${s.t('studioPhase_${job.phase}')} ${localizeDigits(job.detail, s.languageCode)}'),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: job.fraction),
                ],
              ),
            ),
            if (job.kind != StudioJobKind.template)
              TextButton.icon(
                onPressed: studio.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(s.t('studioCancel')),
              ),
          ],
        ),
      ),
    );
  }
}

/// Save / reuse actions under a finished image or video.
class MediaActions extends StatelessWidget {
  const MediaActions({super.key, required this.path, this.title = '', this.extra, this.onAddToVideo, this.onUseAsBackground});
  final String path;
  final String title;
  final String? extra;
  final VoidCallback? onAddToVideo;
  final VoidCallback? onUseAsBackground;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final studio = context.read<StudioService>();
    final messenger = ScaffoldMessenger.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: Text(s.t('studioSaveGallery')),
          onPressed: () async {
            final r = await runStudio(context, () => studio.saveToGallery(path));
            if (r != null) messenger.showSnackBar(SnackBar(content: Text(s.t('studioSavedGallery'))));
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.drafts_outlined),
          label: Text(s.t('studioSaveDraft')),
          onPressed: () async {
            final r = await runStudio(context, () => studio.saveMediaDraft(title: title, path: path, extra: extra));
            if (r != null) messenger.showSnackBar(SnackBar(content: Text(s.t('studioSavedDraft'))));
          },
        ),
        if (onAddToVideo != null)
          OutlinedButton.icon(icon: const Icon(Icons.movie_creation_outlined), label: Text(s.t('studioAddToVideo')), onPressed: onAddToVideo),
        if (onUseAsBackground != null)
          OutlinedButton.icon(icon: const Icon(Icons.wallpaper_outlined), label: Text(s.t('studioUseAsBackground')), onPressed: onUseAsBackground),
      ],
    );
  }
}

class FileImagePreview extends StatelessWidget {
  const FileImagePreview({super.key, required this.path, this.aspect = 1});
  final String path;
  final double aspect;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Image.file(File(path), fit: BoxFit.contain, key: ValueKey(path), gaplessPlayback: true),
        ),
      );
}
