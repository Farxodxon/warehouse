/// Boshlang'ich qoldiq importida SKU va shtrix-kodlarni tozalash uchun
/// sof funksiyalar.
library;

const Map<String, String> _homoglyphs = {
  '\u0410': 'A',
  '\u0412': 'B',
  '\u0421': 'C',
  '\u0415': 'E',
  '\u041D': 'H',
  '\u041A': 'K',
  '\u041C': 'M',
  '\u041E': 'O',
  '\u0420': 'P',
  '\u0422': 'T',
  '\u0425': 'X',
  '\u0430': 'a',
  '\u0441': 'c',
  '\u0435': 'e',
  '\u043E': 'o',
  '\u0440': 'p',
  '\u0445': 'x',
};

/// Kirill o'xshash harflarni lotin harflariga almashtiradi.
String fixHomoglyphs(String s) {
  final buffer = StringBuffer();
  for (final rune in s.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_homoglyphs[char] ?? char);
  }
  return buffer.toString();
}

/// SKU ni solishtirish uchun normallashtiradi: homogliflarni tuzatadi,
/// barcha bo'shliqlarni olib tashlaydi va katta harfga o'tkazadi.
String normalizeSku(String s) {
  return fixHomoglyphs(s).replaceAll(RegExp(r'\s+'), '').toUpperCase();
}

/// Shtrix-kodning SKU qismini yasaydi: harflar/raqamlardan boshqa
/// belgilarni '-' ga almashtiradi va chetdagi '-' larni kesadi.
String barcodeSkuPart(String sku) {
  return fixHomoglyphs(sku)
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Sanani YYMMDD ko'rinishida qaytaradi.
String datePartYYMMDD(DateTime d) {
  return '${_two(d.year % 100)}${_two(d.month)}${_two(d.day)}';
}

/// [prefix] bilan boshlanuvchi kodlardagi eng katta "-NN" sonidan
/// keyingi tartib raqamni qaytaradi. Bo'lmasa 1.
int nextSeq(Iterable<String> existing, String prefix) {
  var maxSeq = 0;
  for (final code in existing) {
    if (!code.startsWith(prefix)) continue;
    final suffix = code.substring(prefix.length);
    final value = int.tryParse(suffix);
    if (value != null && value > maxSeq) {
      maxSeq = value;
    }
  }
  return maxSeq + 1;
}
