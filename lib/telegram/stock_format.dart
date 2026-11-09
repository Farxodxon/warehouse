/// Telegram qoldiq buyrug'i uchun formatlash va bazadan o'qish.
///
/// Bu fayldagi funksiyalar ikki turda:
/// 1) SOF funksiyalar ([formatQty], [normalizeCode], [stockLine],
///    [groupSummary], [buildOutMessage]) - bazaga bog'liq emas;
/// 2) [lookupStock] - bazadan faqat SELECT (yozuv yo'q).
library;

/// 1 soniya ichida aniqlik: 93.5 -> "93.5", 170 -> "170".
///
/// Butun sonlar kasrsiz, kasrlar 2 xonagacha, ortiqcha nolsiz.
String formatQty(num value) {
  if (value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) {
      text = text.substring(0, text.length - 1);
    }
  }
  return text;
}

/// Kodni birlashtiradi: barcha bo'shliqlarni olib tashlab katta harfga
/// o'tkazadi. `"L 001/2"` va `"l001/2"` bir xil bo'ladi.
String normalizeCode(String value) =>
    value.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// Guruhlar jami miqdori (hajm * soni).
num _groupsTotal(List<(num, int)> groups) =>
    groups.fold<num>(0, (sum, group) => sum + group.$1 * group.$2);

/// Qoldiqni guruhlar ko'rinishida: `210*170kg=35700kg` yoki
/// `209*170kg + 1*93kg = 35623kg`.
///
/// Guruhlar soni bo'yicha kamayish tartibida. 6 tadan ko'p guruh bo'lsa:
/// birinchi 6 tasi ko'rsatiladi va ` + yana N ta konteyner` qo'shiladi
/// (N - yashirilgan guruhlardagi konteynerlar soni).
String groupSummary(List<(num, int)> groups, String unit) {
  final total = _groupsTotal(groups);
  if (total <= 0) return "qoldiq yo'q (0$unit)";

  final sorted = [...groups]..sort((a, b) => b.$2.compareTo(a.$2));
  if (sorted.length == 1) {
    final (quantity, count) = sorted.first;
    return '${formatQty(count)}*${formatQty(quantity)}$unit'
        '=${formatQty(total)}$unit';
  }

  const maxGroups = 6;
  final shown = sorted.take(maxGroups);
  final parts = [
    for (final (quantity, count) in shown)
      '${formatQty(count)}*${formatQty(quantity)}$unit',
  ];
  var text = parts.join(' + ');
  if (sorted.length > maxGroups) {
    final hiddenContainers = sorted
        .skip(maxGroups)
        .fold<int>(0, (sum, group) => sum + group.$2);
    text += ' + yana $hiddenContainers ta konteyner';
  }
  return '$text = ${formatQty(total)}$unit';
}

/// Bitta qoldiq satri: `L 001/2 - 210*170kg=35700kg qoldi`.
///
/// Qoldiq 0 bo'lsa: `L 001/2 - qoldiq yo'q (0kg)`.
String stockLine(String sku, String unit, List<(num, int)> groups) {
  if (_groupsTotal(groups) <= 0) return '$sku - ${groupSummary(groups, unit)}';
  return '$sku - ${groupSummary(groups, unit)} qoldi';
}

/// Toshkent vaqti (UTC+5, yozgi vaqtga o'tmaydi):
/// `16.10.2026 17:05`.
String tashkentTime(DateTime time) {
  final local = time.toUtc().add(const Duration(hours: 5));
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${pad(local.day)}.${pad(local.month)}.${local.year} '
      '${pad(local.hour)}:${pad(local.minute)}';
}

/// Muvaffaqiyatli chiqimdan keyin guruhga yuboriladigan xabar.
///
/// Xabar matni (emoji `📤` shu qatorda):
/// ```
/// 📤 CHIQIM
/// L 003 - 1000kg
/// Qoldiq: 1*32000kg + 1*1000kg = 33000kg
/// Kim: Admin | 09.11.2026 12:14
/// ```
/// FEFO bir nechta konteynerdan chiqarsa - miqdorlar yig'indisi bitta
/// qatorda, keyin bitta umumiy `Qoldiq:` qatori (chiqimdan KEYINGI holat).
String buildOutMessage({
  required String sku,
  required String unit,
  required List<num> quantities,
  required List<(num, int)> remainingGroups,
  required String performer,
  required DateTime time,
}) {
  final totalOut = quantities.fold<num>(0, (sum, value) => sum + value);
  final lines = <String>[
    '📤 CHIQIM',
    '$sku - ${formatQty(totalOut)}$unit',
    'Qoldiq: ${groupSummary(remainingGroups, unit)}',
    'Kim: $performer | ${tashkentTime(time)}',
  ];
  return lines.join('\n');
}

/// Mahsulot qoldig'i: bitta yoki bir nechta moslik.
class StockMatch {
  const StockMatch({
    required this.sku,
    required this.name,
    required this.unit,
    required this.groups,
  });

  final String sku;
  final String name;
  final String unit;

  /// (hajm, soni) juftliklari - faol konteynerlar guruhlangan holda.
  final List<(num, int)> groups;
}

const _exactSkuSql = r'''
SELECT p.sku, p.name, p.unit, bc.quantity
FROM products p
JOIN batches b ON b.product_id = p.id
JOIN batch_containers bc ON bc.batch_id = b.id
WHERE bc.status = 'active'
  AND bc.quantity > 0
  AND upper(regexp_replace(p.sku, '\s', '', 'g')) = @code
ORDER BY p.sku, bc.quantity DESC
''';

const _byNameSql = r'''
SELECT p.id, p.sku, p.name, p.unit
FROM products p
WHERE p.name ILIKE '%' || @q || '%'
ORDER BY p.sku
LIMIT 5
''';

const _containersSql = r'''
SELECT bc.quantity
FROM batch_containers bc
JOIN batches b ON b.id = bc.batch_id
WHERE b.product_id = @productId
  AND bc.status = 'active'
  AND bc.quantity > 0
''';

/// Bazadan qoldiqni topadi - FAQAT SELECT, 0..5 ta moslik qaytaradi.
///
/// Avval SKU bo'yicha aniq qidiruv (`L 001/2` == `l001/2`), aniq moslik
/// topilmasa nom bo'yicha `ILIKE`. [connection] - postgres connection
/// (yoki testdagi soxta obyekt).
Future<List<StockMatch>> lookupStock(dynamic connection, String rawQuery) async {
  final code = normalizeCode(rawQuery);
  if (code.isEmpty) return [];

  final exactRows = await connection.query(
    _exactSkuSql,
    substitutionValues: {'code': code},
  );
  if (exactRows.isNotEmpty) {
    return [_matchFromRows(exactRows)];
  }

  final nameRows = await connection.query(
    _byNameSql,
    substitutionValues: {'q': rawQuery.trim()},
  );
  if (nameRows.isEmpty) return [];

  final matches = <StockMatch>[];
  for (final row in nameRows) {
    final groups = await fetchProductGroups(connection, row[0] as int);
    matches.add(StockMatch(
      sku: row[1] as String,
      name: row[2] as String,
      unit: row[3] as String,
      groups: groups,
    ));
  }
  return matches;
}

/// Bitta mahsulotning FAOL konteynerlarini (hajm, soni) guruhlab o'qiydi.
/// Chiqimdan KEYINGI qoldiqni hisoblash uchun ham ishlatiladi.
Future<List<(num, int)>> fetchProductGroups(
    dynamic connection, int productId) async {
  final rows = await connection.query(
    _containersSql,
    substitutionValues: {'productId': productId},
  );
  return groupByQuantity([for (final row in rows) _toNum(row[0])]);
}

/// [rows] - (sku, name, unit, quantity) qatorlari (bitta mahsulot).
StockMatch _matchFromRows(List<dynamic> rows) {
  final sku = rows.first[0] as String;
  final name = rows.first[1] as String;
  final unit = rows.first[2] as String;
  final quantities = [for (final row in rows) _toNum(row[3])];
  return StockMatch(
    sku: sku,
    name: name,
    unit: unit,
    groups: groupByQuantity(quantities),
  );
}

/// Miqdor bo'yicha guruhlaydi: (hajm, soni) juftliklari.
List<(num, int)> groupByQuantity(List<num> quantities) {
  final counts = <num, int>{};
  for (final quantity in quantities) {
    counts[quantity] = (counts[quantity] ?? 0) + 1;
  }
  return counts.entries
      .map((entry) => (entry.key, entry.value))
      .toList(growable: false);
}

num _toNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  if (value is String) return num.tryParse(value) ?? 0;
  return 0;
}
