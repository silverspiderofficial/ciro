import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../studio/studio_service.dart';
import '../caption/caption_screen.dart';
import '../drafts/drafts_screen.dart';
import 'image_tab.dart';
import 'studio_assets_screen.dart';
import 'studio_common.dart';
import 'templates_tab.dart';
import 'video_tab.dart';

/// The Studio tab: image generation, templates and the video timeline.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  StudioUiState? _ui;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ui = context.read<StudioUiState>();
    if (!identical(ui, _ui)) {
      _ui?.tabRequest.removeListener(_onTabRequest);
      _ui = ui..tabRequest.addListener(_onTabRequest);
    }
  }

  void _onTabRequest() {
    final i = _ui?.tabRequest.value;
    if (i != null) {
      _tabs.animateTo(i);
      _ui!.tabRequest.value = null;
    }
  }

  @override
  void dispose() {
    _ui?.tabRequest.removeListener(_onTabRequest);
    _tabs.dispose();
    super.dispose();
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final studio = context.watch<StudioService?>();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('tabStudio')),
        actions: [
          IconButton(tooltip: s.t('openCaptionTool'), icon: const Icon(Icons.tag), onPressed: () => _push(const CaptionScreen())),
          IconButton(tooltip: s.t('openDrafts'), icon: const Icon(Icons.drafts_outlined), onPressed: () => _push(const DraftsScreen())),
          if (studio != null)
            IconButton(tooltip: s.t('studioAssets'), icon: const Icon(Icons.tune), onPressed: () => _push(const StudioAssetsScreen())),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(icon: const Icon(Icons.auto_awesome_outlined), text: s.t('studioTabImage')),
            Tab(icon: const Icon(Icons.dashboard_customize_outlined), text: s.t('studioTabTemplates')),
            Tab(icon: const Icon(Icons.movie_outlined), text: s.t('studioTabVideo')),
          ],
        ),
      ),
      body: studio == null
          ? Center(child: Text(s.t('studioErr_generic', {'code': 'unavailable'})))
          : Column(
              children: [
                const StudioJobBar(),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: const [ImageTab(), TemplatesTab(), VideoTab()],
                  ),
                ),
              ],
            ),
    );
  }
}
