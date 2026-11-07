import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../drafts/drafts_screen.dart';
import '../home/home_shell.dart';
import '../lock/app_lock.dart';
import '../models/model_manager_screen.dart';
import '../onboarding/device_check_screen.dart';
import 'api_settings_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const appVersion = '1.0.0';

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final lang = s.languageCode;
    final settings = context.watch<SettingsController>();
    final security = context.watch<SecurityState>();
    final theme = Theme.of(context);

    Widget section(String key) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 20, 16, 4),
          child: Text(s.t(key), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(s.t('settingsTitle'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (security.status.compromised)
            Material(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.gpp_maybe_outlined),
                title: Text(s.t('securityWarning')),
                subtitle: Text(s.t('securityWarningBody', {'reasons': securityReasons(security, s)})),
              ),
            ),
          section('secModels'),
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text(s.t('manageModels')),
            onTap: () => _push(context, const ModelManagerScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: Text(s.t('deviceCheck')),
            onTap: () => _push(context, const DeviceCheckScreen()),
          ),
          _SliderTile(
            label: s.t('threads'),
            value: settings.threads.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            display: localizeDigits('${settings.threads}', lang),
            onChanged: (v) => settings.setThreads(v.round()),
          ),
          ListTile(
            title: Text(s.t('contextSize')),
            subtitle: Text(s.t('reloadToApply')),
            trailing: DropdownButton<int>(
              value: const [1024, 2048, 4096, 8192].contains(settings.contextSize) ? settings.contextSize : 2048,
              items: [
                for (final c in const [1024, 2048, 4096, 8192])
                  DropdownMenuItem(value: c, child: Text(localizeDigits('$c', lang))),
              ],
              onChanged: (v) {
                if (v != null) settings.setContextSize(v);
              },
            ),
          ),
          _SliderTile(
            label: s.t('temperature'),
            value: settings.temperature,
            min: 0,
            max: 1.5,
            divisions: 15,
            display: localizeDigits(settings.temperature.toStringAsFixed(1), lang),
            onChanged: (v) => settings.setTemperature(double.parse(v.toStringAsFixed(1))),
          ),
          _SliderTile(
            label: s.t('maxTokens'),
            value: settings.maxTokens.toDouble(),
            min: 128,
            max: 2048,
            divisions: 15,
            display: localizeDigits('${settings.maxTokens}', lang),
            onChanged: (v) => settings.setMaxTokens((v / 128).round() * 128),
          ),
          _SliderTile(
            label: s.t('agentSteps'),
            value: settings.agentMaxSteps.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            display: localizeDigits('${settings.agentMaxSteps}', lang),
            onChanged: (v) => settings.setAgentMaxSteps(v.round()),
          ),
          section('secApi'),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(s.t('apiTitle')),
            subtitle: Text(
              !security.apiAllowed
                  ? s.t('apiLocked')
                  : settings.useRemote
                      ? '${s.t('engineRemote')} · ${settings.remoteModel}'
                      : s.t('engineOnDevice'),
            ),
            enabled: security.apiAllowed,
            onTap: () => _push(context, const ApiSettingsScreen()),
          ),
          section('secAppearance'),
          ListTile(
            title: Text(s.t('theme')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(value: ThemeMode.system, label: Text(s.t('themeSystem'))),
                  ButtonSegment(value: ThemeMode.light, label: Text(s.t('themeLight'))),
                  ButtonSegment(value: ThemeMode.dark, label: Text(s.t('themeDark'))),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (v) => settings.setThemeMode(v.first),
              ),
            ),
          ),
          ListTile(
            title: Text(s.t('language')),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'fa', label: Text('فارسی')),
                  ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {settings.languageCode},
                onSelectionChanged: (v) => settings.setLanguageCode(v.first),
              ),
            ),
          ),
          section('secSecurity'),
          const _LockTiles(),
          ListTile(
            leading: Icon(security.status.compromised ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined),
            title: Text(s.t('securityStatus')),
            subtitle: Text(security.status.compromised
                ? securityReasons(security, s)
                : s.t('securityOk')),
          ),
          section('secData'),
          ListTile(
            leading: const Icon(Icons.drafts_outlined),
            title: Text(s.t('openDrafts')),
            onTap: () => _push(context, const DraftsScreen()),
          ),
          section('secAbout'),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(s.t('privacy')),
            onTap: () => _push(context, const PrivacyScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(s.t('licenses')),
            onTap: () => showLicensePage(
              context: context,
              applicationName: s.t('appName'),
              applicationVersion: appVersion,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(s.t('appName')),
            subtitle: Text(s.t('version', {'version': localizeDigits(appVersion, lang)})),
          ),
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Row(children: [Expanded(child: Text(label)), Text(display)]),
      subtitle: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}

class _LockTiles extends StatefulWidget {
  const _LockTiles();

  @override
  State<_LockTiles> createState() => _LockTilesState();
}

class _LockTilesState extends State<_LockTiles> {
  bool? _bioAvailable;

  @override
  void initState() {
    super.initState();
    context.read<AppLockController>().biometricAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
  }

  Future<String?> _askNewPin() async {
    final s = context.sRead;
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(s.t('setPin')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: a,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: InputDecoration(labelText: s.t('newPin'), counterText: ''),
              ),
              TextField(
                controller: b,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: InputDecoration(labelText: s.t('confirmPin'), errorText: error, counterText: ''),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('cancel'))),
            TextButton(
              onPressed: () {
                final p1 = toLatinDigits(a.text.trim());
                final p2 = toLatinDigits(b.text.trim());
                if (!RegExp(r'^[0-9]{4,8}$').hasMatch(p1)) {
                  setLocal(() => error = s.t('pinInvalid'));
                } else if (p1 != p2) {
                  setLocal(() => error = s.t('pinMismatch'));
                } else {
                  Navigator.pop(ctx, p1);
                }
              },
              child: Text(s.t('save')),
            ),
          ],
        ),
      ),
    );
    a.dispose();
    b.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = context.watch<SettingsController>();
    final lock = context.read<AppLockController>();
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.pin_outlined),
          title: Text(s.t('appLock')),
          value: settings.lockEnabled,
          onChanged: (v) async {
            if (v) {
              final pin = await _askNewPin();
              if (pin != null) await lock.setPin(pin);
            } else {
              await lock.disableLock();
            }
          },
        ),
        if (settings.lockEnabled)
          ListTile(
            leading: const Icon(Icons.password),
            title: Text(s.t('changePin')),
            onTap: () async {
              final pin = await _askNewPin();
              if (pin != null) await lock.setPin(pin);
            },
          ),
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: Text(s.t('biometric')),
          subtitle: _bioAvailable == false ? Text(s.t('biometricUnavailable')) : null,
          value: settings.biometricEnabled && settings.lockEnabled,
          onChanged: (settings.lockEnabled && (_bioAvailable ?? false)) ? (v) => settings.setBiometricEnabled(v) : null,
        ),
      ],
    );
  }
}
