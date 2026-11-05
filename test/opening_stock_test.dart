import 'package:test/test.dart';
import 'package:wms_backend/inventory/opening_stock.dart';

void main() {
  group('fixHomoglyphs', () {
    test('kirill o\'xshash harflarni lotinga almashtiradi', () {
      expect(fixHomoglyphs('\u0421 045'), 'C 045');
      expect(fixHomoglyphs('\u0430\u0441\u0435\u043e\u0440\u0445'), 'aceopx');
      expect(
          fixHomoglyphs(
              '\u0410\u0412\u0415\u041d\u041a\u041c\u041e\u0420\u0422\u0425'),
          'ABEHKMOPTX');
    });

    test('boshqa belgilarni o\'zgartirmaydi', () {
      expect(fixHomoglyphs('L 001/2'), 'L 001/2');
    });
  });

  group('normalizeSku', () {
    test('bo\'shliqlarni olib tashlaydi va katta harfga o\'tkazadi', () {
      expect(normalizeSku('  l 001/2 '), 'L001/2');
    });

    test('kirill va lotin yozuvlarini bir xil qiladi', () {
      expect(normalizeSku('\u0421 045'), normalizeSku('c 045'));
    });
  });

  group('barcodeSkuPart', () {
    test('slash va bo\'shliqlarni "-" ga almashtiradi', () {
      expect(barcodeSkuPart('L 001/2'), 'L-001-2');
    });

    test('kirill harflarini ham tozalaydi', () {
      expect(barcodeSkuPart('\u0421 045'), 'C-045');
    });

    test('chetki "-" larni kesadi', () {
      expect(barcodeSkuPart(' /L 001/ '), 'L-001');
    });
  });

  group('datePartYYMMDD', () {
    test('ikki xonali oy va kunni qo\'shadi', () {
      expect(datePartYYMMDD(DateTime(2026, 3, 5)), '260305');
    });
  });

  group('nextSeq', () {
    test('bo\'sh ro\'yxat uchun 1 qaytaradi', () {
      expect(nextSeq(const [], 'L-001-2-260305-'), 1);
    });

    test('eng katta raqamdan keyingisini qaytaradi', () {
      final codes = [
        'L-001-2-260305-01',
        'L-001-2-260305-02',
        'L-001-2-260305-07',
        'BOSHQA-01',
      ];
      expect(nextSeq(codes, 'L-001-2-260305-'), 8);
    });

    test('takroriy importda mavjudlardan davom etadi', () {
      expect(nextSeq(['L-001-2-260305-03'], 'L-001-2-260305-'), 4);
    });
  });
}
