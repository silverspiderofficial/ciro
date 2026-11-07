/// Small formatting helpers shared by the UI (Persian digits, byte sizes).
library;

const _latin = '0123456789';
const _persian = '۰۱۲۳۴۵۶۷۸۹';

/// Converts ASCII digits to Persian digits.
String toPersianDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final idx = _latin.indexOf(ch);
    buffer.write(idx >= 0 ? _persian[idx] : ch);
  }
  return buffer.toString();
}

/// Converts Persian and Arabic-Indic digits to ASCII (useful for PIN / number input).
String toLatinDigits(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    var idx = _persian.indexOf(ch);
    if (idx < 0) idx = arabic.indexOf(ch);
    buffer.write(idx >= 0 ? _latin[idx] : ch);
  }
  return buffer.toString();
}

/// Localises digits when the UI language is Persian.
String localizeDigits(String input, String languageCode) =>
    languageCode == 'fa' ? toPersianDigits(input) : input;

/// Human readable size, e.g. 1.9 GB.
String formatBytes(int bytes, {String languageCode = 'en'}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? '${value.toInt()} ${units[unit]}' : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  return localizeDigits(text, languageCode);
}
