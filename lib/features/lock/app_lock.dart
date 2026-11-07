import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../../app/services.dart';
import '../../core/format.dart';
import '../../data/secure_store.dart';
import '../../data/settings.dart';
import '../../l10n/strings.dart';

/// PIN / biometric lock state. Locks on cold start and after 30 s in the background.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController(this._settings, this._secure, {LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication() {
    _locked = _settings.lockEnabled;
    WidgetsBinding.instance.addObserver(this);
  }

  final SettingsController _settings;
  final SecureStore _secure;
  final LocalAuthentication _auth;

  static const _relockAfter = Duration(seconds: 30);
  static const _maxAttempts = 5;
  static const _lockout = Duration(seconds: 30);

  bool _locked = false;
  DateTime? _pausedAt;
  int _failed = 0;
  DateTime? _lockedOutUntil;

  bool get locked => _locked && _settings.lockEnabled;

  Duration? get lockoutRemaining {
    final until = _lockedOutUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_settings.lockEnabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _pausedAt;
      _pausedAt = null;
      if (since != null && DateTime.now().difference(since) >= _relockAfter) {
        _locked = true;
        notifyListeners();
      }
    }
  }

  Future<bool> hasPin() async => (await _secure.read(SecureStore.pinHash)) != null;

  Future<void> setPin(String pin) async {
    await _secure.write(SecureStore.pinHash, PinHasher.hash(pin));
    await _settings.setLockEnabled(true);
    _locked = false;
    notifyListeners();
  }

  Future<void> disableLock() async {
    await _secure.delete(SecureStore.pinHash);
    await _settings.setLockEnabled(false);
    await _settings.setBiometricEnabled(false);
    _locked = false;
    notifyListeners();
  }

  /// Returns null on success, otherwise a message key.
  Future<String?> unlockWithPin(String pin) async {
    if (lockoutRemaining != null) return 'tooManyAttempts';
    final stored = await _secure.read(SecureStore.pinHash);
    if (stored != null && PinHasher.verify(toLatinDigits(pin), stored)) {
      _failed = 0;
      _locked = false;
      notifyListeners();
      return null;
    }
    _failed++;
    if (_failed >= _maxAttempts) {
      _failed = 0;
      _lockedOutUntil = DateTime.now().add(_lockout);
      notifyListeners();
      return 'tooManyAttempts';
    }
    return 'wrongPin';
  }

  Future<bool> biometricAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> unlockWithBiometric(String reason) async {
    if (!_settings.biometricEnabled) return false;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
      if (ok) {
        _locked = false;
        notifyListeners();
      }
      return ok;
    } on PlatformException {
      return false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Covers the whole app (every route) with the lock screen while locked. The app's
/// navigation stack stays alive underneath but is not painted, focusable or animated.
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locked = context.watch<AppLockController>().locked;
    return Stack(
      children: [
        Offstage(
          offstage: locked,
          child: ExcludeFocus(
            excluding: locked,
            child: TickerMode(enabled: !locked, child: child),
          ),
        ),
        if (locked)
          Positioned.fill(
            child: HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, __, ___) => const LockScreen(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    unawaited(services.bridge.setSecureScreen(true));
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    final lock = context.read<AppLockController>();
    final reason = context.sRead.t('unlockReason');
    await lock.unlockWithBiometric(reason);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final lock = context.read<AppLockController>();
    final services = context.read<AppServices>();
    final err = await lock.unlockWithPin(_pin.text);
    if (!mounted) return;
    if (err == null) {
      unawaited(services.bridge.setSecureScreen(false));
      return;
    }
    final s = context.sRead;
    setState(() {
      _busy = false;
      _pin.clear();
      _error = err == 'tooManyAttempts'
          ? s.t(err, {'seconds': localizeDigits('${lock.lockoutRemaining?.inSeconds ?? 30}', s.languageCode)})
          : s.t(err);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = context.watch<SettingsController>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(s.t('locked'), style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pin,
                    autofocus: !settings.biometricEnabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    textAlign: TextAlign.center,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9۰-۹]'))],
                    decoration: InputDecoration(labelText: s.t('enterPin'), errorText: _error, counterText: ''),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(onPressed: _busy ? null : _submit, child: Text(s.t('unlock'))),
                  ),
                  if (settings.biometricEnabled) ...[
                    const SizedBox(height: 8),
                    IconButton.filledTonal(
                      iconSize: 32,
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.fingerprint),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
