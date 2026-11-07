/// Device facts reported by the Android side (kiro/device "info").
class DeviceInfo {
  const DeviceInfo({
    required this.totalRamBytes,
    required this.availRamBytes,
    required this.cores,
    required this.bigCores,
    required this.maxFreqMhz,
    required this.soc,
    required this.socManufacturer,
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
    required this.release,
    required this.abis,
    required this.dotprod,
    required this.i8mm,
    required this.freeStorageBytes,
  });

  final int totalRamBytes;
  final int availRamBytes;
  final int cores;
  final int bigCores;
  final int maxFreqMhz;
  final String soc;
  final String socManufacturer;
  final String manufacturer;
  final String model;
  final int sdkInt;
  final String release;
  final List<String> abis;
  final bool dotprod;
  final bool i8mm;
  final int freeStorageBytes;

  bool get isArm64 => abis.contains('arm64-v8a');

  factory DeviceInfo.fromMap(Map<Object?, Object?> m) {
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    String s(String k) => (m[k] as String?) ?? '';
    bool b(String k) => (m[k] as bool?) ?? false;
    return DeviceInfo(
      totalRamBytes: i('totalRam'),
      availRamBytes: i('availRam'),
      cores: i('cores'),
      bigCores: i('bigCores'),
      maxFreqMhz: i('maxFreqMhz'),
      soc: s('soc'),
      socManufacturer: s('socManufacturer'),
      manufacturer: s('manufacturer'),
      model: s('model'),
      sdkInt: i('sdkInt'),
      release: s('release'),
      abis: ((m['abis'] as List<Object?>?) ?? const []).whereType<String>().toList(),
      dotprod: b('dotprod'),
      i8mm: b('i8mm'),
      freeStorageBytes: i('freeStorage'),
    );
  }
}

/// Integrity status reported by the Android side (kiro/device "security").
class SecurityStatus {
  const SecurityStatus({
    this.rooted = false,
    this.debugger = false,
    this.debuggable = false,
    this.hooked = false,
    this.emulator = false,
    this.signature = 'unchecked',
    this.compromised = false,
  });

  final bool rooted;
  final bool debugger;
  final bool debuggable;
  final bool hooked;
  final bool emulator;

  /// "match" | "mismatch" | "unchecked"
  final String signature;
  final bool compromised;

  static const clean = SecurityStatus();

  factory SecurityStatus.fromMap(Map<Object?, Object?> m) => SecurityStatus(
        rooted: (m['rooted'] as bool?) ?? false,
        debugger: (m['debugger'] as bool?) ?? false,
        debuggable: (m['debuggable'] as bool?) ?? false,
        hooked: (m['hooked'] as bool?) ?? false,
        emulator: (m['emulator'] as bool?) ?? false,
        signature: (m['signature'] as String?) ?? 'unchecked',
        compromised: (m['compromised'] as bool?) ?? false,
      );
}
