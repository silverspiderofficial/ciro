/// Exact TON amounts. 1 TON = 10^9 nanotons. Amounts are kept as integer nanotons; decimal
/// strings are parsed digit by digit, never through floating point.
library;

const int nanotonsPerTon = 1000000000;

/// Largest amount accepted by the parser (well inside the 64-bit int range).
const int maxNanotons = 1000000000 * nanotonsPerTon; // 1e9 TON

/// Parses a non-negative decimal TON amount ("0.3", "1", "4.500000000") to nanotons.
/// Accepts '.' or the Arabic decimal separator '٫' and Persian/Arabic-Indic digits.
/// Returns null for anything else (signs, exponents, more than 9 fraction digits, overflow).
int? parseTonToNanotons(String input) {
  var s = _asciiDigits(input.trim()).replaceAll('٫', '.');
  if (s.isEmpty) return null;
  if (!RegExp(r'^\d*(\.\d*)?$').hasMatch(s)) return null;
  if (s == '.') return null;
  final dot = s.indexOf('.');
  var whole = dot < 0 ? s : s.substring(0, dot);
  var frac = dot < 0 ? '' : s.substring(dot + 1);
  if (frac.length > 9) return null;
  if (whole.isEmpty) whole = '0';
  if (whole.length > 10) return null;
  frac = frac.padRight(9, '0');
  s = whole + frac;
  final v = int.parse(s);
  if (v > maxNanotons) return null;
  return v;
}

/// Parses a nanoton integer that an API returned as a JSON string or number.
int? parseNanotonValue(Object? v) {
  if (v is int) return v >= 0 ? v : null;
  if (v is String && RegExp(r'^\d{1,19}$').hasMatch(v)) {
    final n = int.tryParse(v);
    return n != null && n >= 0 ? n : null;
  }
  return null;
}

/// Formats nanotons as a TON decimal string with no trailing zeros ("0.3", "1.2", "8").
String formatNanotons(int nanotons) {
  final neg = nanotons < 0;
  final n = neg ? -nanotons : nanotons;
  final whole = n ~/ nanotonsPerTon;
  var frac = (n % nanotonsPerTon).toString().padLeft(9, '0');
  frac = frac.replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
}

String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0); // Persian
    } else if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660); // Arabic-Indic
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}
