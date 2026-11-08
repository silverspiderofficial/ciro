import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/repositories.dart';
import '../../l10n/strings.dart';
import '../../studio/studio_service.dart';

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<Draft>? _drafts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await context.read<AppServices>().drafts.all();
    if (mounted) setState(() => _drafts = list);
  }

  Future<void> _delete(Draft d) async {
    final repo = context.read<AppServices>().drafts;
    final s = context.sRead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(s.t('deleteConfirm', {'name': d.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok != true || d.id == null) return;
    await repo.delete(d.id!);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final drafts = _drafts;
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    return Scaffold(
      appBar: AppBar(title: Text(s.t('draftsTitle'))),
      body: drafts == null
          ? const Center(child: CircularProgressIndicator())
          : drafts.isEmpty
              ? Center(child: Text(s.t('noDrafts')))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: drafts.length,
                  itemBuilder: (context, i) {
                    final d = drafts[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ExpansionTile(
                        leading: d.isImage || d.isVideo ? DraftThumbnail(draft: d) : null,
                        title: Text(d.title.isEmpty ? '—' : d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(localizeDigits(fmt.format(d.createdAt), s.languageCode)),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(d.fullText),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              IconButton(
                                tooltip: s.t('copy'),
                                icon: const Icon(Icons.copy),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: d.fullText));
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('copied'))));
                                },
                              ),
                              IconButton(
                                tooltip: s.t('delete'),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(d),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

/// Small preview for image and video drafts. Videos show their poster frame (made when the
/// draft was saved) with a play badge, or a film icon when there is none.
class DraftThumbnail extends StatelessWidget {
  const DraftThumbnail({super.key, required this.draft, this.size = 56});
  final Draft draft;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final video = draft.isVideo;
    final path = video ? StudioService.videoThumbPath(draft.mediaPath!) : draft.mediaPath!;
    final fallback = Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(video ? Icons.movie_outlined : Icons.image_not_supported_outlined, color: scheme.onSurfaceVariant),
    );
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: px,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => fallback,
            ),
            if (video)
              const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 24)),
          ],
        ),
      ),
    );
  }
}
