/// Extracts an ISBN from a free-text query.
///
/// 13 digits pass through unchanged; 10 digits whose first nine are digits and
/// whose last is a digit or X (either case) are uppercased. Anything else
/// — separators, surrounding words, the wrong length — is not an ISBN, so the
/// result is empty.
String queryIsbn(String query) {
  final digits = query.replaceAll(RegExp(r'[^0-9Xx]'), '');
  final isDigit = RegExp(r'^[0-9]+$');
  if (digits.length == 13 && isDigit.hasMatch(digits)) return digits;
  if (digits.length == 10 &&
      isDigit.hasMatch(digits.substring(0, 9)) &&
      (isDigit.hasMatch(digits[9]) || digits[9].toUpperCase() == 'X')) {
    return digits.toUpperCase();
  }
  return '';
}
