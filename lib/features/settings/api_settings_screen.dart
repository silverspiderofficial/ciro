import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../data/secure_store.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';
import '../../llm/remote_backend.dart';

/// Optional user API key. The key is write-only from the UI: it is stored in the Keystore-backed
/// secure storage and never displayed again (only "saved / not saved").
class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final _key = TextEditingController();
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  bool? _hasKey;
  String? _urlError;
  late final AppServices _services;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    final settings = _services.settings;
    _baseUrl = TextEditingController(text: settings.remoteBaseUrl);
    _model = TextEditingController(text: settings.remoteModel);
    unawaited(_services.bridge.setSecureScreen(true));
    _refreshKey();
  }

  @override
  void dispose() {
    unawaited(_services.bridge.setSecureScreen(false));
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _refreshKey() async {
    final k = await _services.secure.read(SecureStore.apiKey);
    if (mounted) setState(() => _hasKey = k != null && k.isNotEmpty);
  }

  Future<void> _saveKey() async {
    final s = context.sRead;
    final messenger = ScaffoldMessenger.of(context);
    final value = _key.text.trim();
    if (value.isEmpty) return;
    await _services.secure.write(SecureStore.apiKey, value);
    _key.clear();
    await _refreshKey();
    messenger.showSnackBar(SnackBar(content: Text(s.t('keySaved'))));
  }

  Future<void> _removeKey() async {
    final s = context.sRead;
    final messenger = ScaffoldMessenger.of(context);
    await _services.secure.delete(SecureStore.apiKey);
    await _services.settings.setUseRemote(false);
    await _refreshKey();
    messenger.showSnackBar(SnackBar(content: Text(s.t('keyRemoved'))));
  }

  Future<void> _saveEndpoint(SettingsController settings) async {
    final s = context.sRead;
    if (settings.remoteProvider == RemoteProvider.openAiCompatible) {
      final err = RemoteBackend.validateBaseUrl(_baseUrl.text);
      if (err != null) {
        setState(() => _urlError = s.t(err == 'https_only' ? 'errHttps' : 'errInvalidUrl'));
        return;
      }
    }
    setState(() => _urlError = null);
    await settings.setRemoteBaseUrl(_baseUrl.text);
    await settings.setRemoteModel(_model.text.isEmpty ? SettingsController.defaultGeminiModel : _model.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = context.watch<SettingsController>();
    final security = context.watch<SecurityState>();
    final locked = !security.apiAllowed;
    final isGemini = settings.remoteProvider == RemoteProvider.gemini;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('apiTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('apiIntro')),
          if (locked) ...[
            const SizedBox(height: 12),
            Text(s.t('apiLocked'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('useApi')),
            value: settings.useRemote && !locked,
            onChanged: locked || _hasKey != true ? null : (v) => settings.setUseRemote(v),
          ),
          const SizedBox(height: 8),
          Text(s.t('provider'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<RemoteProvider>(
            segments: [
              ButtonSegment(value: RemoteProvider.gemini, label: Text(s.t('providerGemini'))),
              ButtonSegment(value: RemoteProvider.openAiCompatible, label: Text(s.t('providerOpenAi'))),
            ],
            selected: {settings.remoteProvider},
            onSelectionChanged: locked
                ? null
                : (v) async {
                    await settings.setRemoteProvider(v.first);
                    if (v.first == RemoteProvider.gemini && _model.text.trim().isEmpty) {
                      _model.text = SettingsController.defaultGeminiModel;
                    }
                  },
          ),
          const SizedBox(height: 16),
          if (!isGemini) ...[
            TextField(
              controller: _baseUrl,
              enabled: !locked,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: s.t('baseUrl'),
                hintText: 'https://api.example.com/v1',
                errorText: _urlError,
              ),
              onSubmitted: (_) => _saveEndpoint(settings),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _model,
            enabled: !locked,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: s.t('modelName'), hintText: isGemini ? SettingsController.defaultGeminiModel : ''),
            onSubmitted: (_) => _saveEndpoint(settings),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: locked ? null : () => _saveEndpoint(settings), child: Text(s.t('save'))),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_hasKey == true ? Icons.lock : Icons.lock_open),
            title: Text(s.t('apiKey')),
            subtitle: Text(_hasKey == true ? s.t('apiKeySaved') : s.t('apiKeyNotSet')),
            trailing: _hasKey == true
                ? TextButton(onPressed: locked ? null : _removeKey, child: Text(s.t('removeKey')))
                : null,
          ),
          TextField(
            controller: _key,
            enabled: !locked,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: _hasKey == true ? s.t('replaceKey') : s.t('apiKey')),
            onSubmitted: (_) => _saveKey(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(onPressed: locked ? null : _saveKey, child: Text(s.t('save'))),
          ),
        ],
      ),
    );
  }
}
