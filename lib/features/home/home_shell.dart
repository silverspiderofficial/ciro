import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../l10n/strings.dart';
import '../chat/chat_screen.dart';
import '../placeholder/coming_soon_screen.dart';
import '../settings/settings_screen.dart';
import '../studio/studio_screen.dart';
import '../skills/skills_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWarnSecurity());
  }

  Future<void> _maybeWarnSecurity() async {
    final security = context.read<SecurityState>();
    if (!security.status.compromised || security.warningShown) return;
    security.warningShown = true;
    final s = context.sRead;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_outlined),
        title: Text(s.t('securityWarning')),
        content: Text(s.t('securityWarningBody', {'reasons': securityReasons(security, s)})),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('ok')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final pages = <Widget>[
      const ChatScreen(),
      const StudioScreen(),
      ComingSoonScreen(
        title: s.t('tabQueue'),
        icon: Icons.view_agenda_outlined,
        items: [s.t('queueSoon1'), s.t('queueSoon2'), s.t('queueSoon3')],
      ),
      ComingSoonScreen(
        title: s.t('tabSchedules'),
        icon: Icons.event_repeat_outlined,
        items: [s.t('schedSoon1'), s.t('schedSoon2'), s.t('schedSoon3')],
      ),
      const SkillsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.chat_bubble_outline), selectedIcon: const Icon(Icons.chat_bubble), label: s.t('tabChat')),
          NavigationDestination(icon: const Icon(Icons.auto_awesome_outlined), selectedIcon: const Icon(Icons.auto_awesome), label: s.t('tabStudio')),
          NavigationDestination(icon: const Icon(Icons.view_agenda_outlined), selectedIcon: const Icon(Icons.view_agenda), label: s.t('tabQueue')),
          NavigationDestination(icon: const Icon(Icons.event_repeat_outlined), selectedIcon: const Icon(Icons.event_repeat), label: s.t('tabSchedules')),
          NavigationDestination(icon: const Icon(Icons.psychology_outlined), selectedIcon: const Icon(Icons.psychology), label: s.t('tabSkills')),
          NavigationDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: s.t('tabSettings')),
        ],
      ),
    );
  }
}

String securityReasons(SecurityState security, S s) {
  final st = security.status;
  return [
    if (st.rooted) s.t('reasonRoot'),
    if (st.debugger) s.t('reasonDebugger'),
    if (st.hooked) s.t('reasonHook'),
    if (st.signature == 'mismatch') s.t('reasonSignature'),
    if (st.debuggable) s.t('reasonDebuggable'),
  ].join(s.isFa ? '، ' : ', ');
}
