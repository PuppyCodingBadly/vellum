import 'package:test/test.dart';
import 'package:vellum/core/isbn.dart';

void main() {
  group('queryIsbn', () {
    test('valid ISBN-13 passes through unchanged', () {
      expect(queryIsbn('9780123456789'), '9780123456789');
    });

    test('valid ISBN-10 passes through unchanged', () {
      expect(queryIsbn('0123456789'), '0123456789');
    });

    test('hyphens are stripped', () {
      expect(queryIsbn('978-0-12-345678-9'), '9780123456789');
      expect(queryIsbn('0-306-40615-2'), '0306406152');
    });

    test('spaces are stripped', () {
      expect(queryIsbn('978 0 12 345678 9'), '9780123456789');
      expect(queryIsbn('0 306 40615 2'), '0306406152');
    });

    test('surrounding text is ignored', () {
      expect(queryIsbn('ISBN: 9780123456789'), '9780123456789');
    });

    test('ISBN-10 with check digit X is accepted', () {
      expect(queryIsbn('030640615X'), '030640615X');
    });

    test('lowercase x check digit is uppercased', () {
      expect(queryIsbn('030640615x'), '030640615X');
      expect(queryIsbn('0-306-40615-x'), '030640615X');
    });

    test('empty input returns empty', () {
      expect(queryIsbn(''), '');
    });

    test('non-numeric garbage returns empty', () {
      expect(queryIsbn('hello world'), '');
    });

    test('too few digits returns empty', () {
      expect(queryIsbn('12345'), '');
      expect(queryIsbn('978012345678'), '');
    });

    test('too many digits returns empty', () {
      expect(queryIsbn('97801234567890'), '');
    });

    test('X within the first nine digits of ISBN-10 is rejected', () {
      expect(queryIsbn('0X06406152'), '');
    });

    test('ISBN-13 containing X is rejected', () {
      expect(queryIsbn('978012345678X'), '');
    });
  });
}
