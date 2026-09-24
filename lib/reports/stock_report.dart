import 'package:excel/excel.dart';
import 'package:postgres/postgres.dart';

Future<List<int>> buildStockReport(
  PostgreSQLExecutionContext db, {
  required int userId,
  required int organizationId,
  int? warehouseId,
}) async {
  final roleResult = await db.query(
    'SELECT role FROM users WHERE id = @userId',
    substitutionValues: {'userId': userId},
  );
  final isSuperAdmin =
      roleResult.isNotEmpty && roleResult.first.first == 'super_admin';

  final values = <String, dynamic>{
    'userId': userId,
    'organizationId': organizationId,
  };
  final conditions = <String>[
    'b.organization_id = @organizationId',
    "bc.status = 'active'",
    'bc.quantity > 0',
  ];
  if (warehouseId != null) {
    conditions.add('sl.warehouse_id = @warehouseId');
    values['warehouseId'] = warehouseId;
  }
  if (!isSuperAdmin) {
    conditions.add(
      'sl.warehouse_id IN '
      '(SELECT warehouse_id FROM user_warehouse_access WHERE user_id = @userId)',
    );
  }

  final result = await db.query(
    '''
    SELECT p.name, p.sku, c.name, b.lot_number, b.expiry_date,
           bc.container_barcode, bc.quantity, w.name, z.name, sl.code,
           (b.expiry_date - CURRENT_DATE)
    FROM batch_containers bc
    JOIN batches b ON b.id = bc.batch_id
    JOIN products p ON p.id = b.product_id
    JOIN product_categories c ON c.id = p.category_id
    LEFT JOIN storage_locations sl ON sl.id = bc.location_id
    LEFT JOIN warehouses w ON w.id = sl.warehouse_id
    LEFT JOIN zones z ON z.id = sl.zone_id
    WHERE ${conditions.join(' AND ')}
    ORDER BY p.name, b.expiry_date NULLS LAST, bc.container_barcode
    ''',
    substitutionValues: values,
  );

  const headers = [
    'Mahsulot',
    'SKU',
    'Kategoriya',
    'Lot raqami',
    'Muddat',
    'Konteyner',
    'Miqdor',
    'Ombor',
    'Zona',
    'Joylashuv kodi',
  ];

  final excel = Excel.createExcel();
  excel.rename(excel.getDefaultSheet()!, 'Qoldiq');
  final sheet = excel['Qoldiq'];

  final headerStyle = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.indigo900,
    fontColorHex: ExcelColor.white,
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  for (var c = 0; c < headers.length; c++) {
    sheet.updateCell(
      CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
      TextCellValue(headers[c]),
      cellStyle: headerStyle,
    );
  }

  const widths = [28.0, 14.0, 18.0, 14.0, 12.0, 18.0, 10.0, 20.0, 14.0, 16.0];
  for (var c = 0; c < widths.length; c++) {
    sheet.setColumnWidth(c, widths[c]);
  }

  final expiringStyle = CellStyle(
    backgroundColorHex: ExcelColor.red100,
    verticalAlign: VerticalAlign.Center,
  );

  var rowIndex = 1;
  for (final row in result) {
    final daysRemaining = _toIntOrNull(row[10]);
    final isExpiring = daysRemaining != null && daysRemaining <= 7;

    final cellValues = <CellValue?>[
      TextCellValue('${row[0] ?? ''}'),
      TextCellValue('${row[1] ?? ''}'),
      TextCellValue('${row[2] ?? ''}'),
      TextCellValue('${row[3] ?? ''}'),
      TextCellValue(_dateToString(row[4])),
      TextCellValue('${row[5] ?? ''}'),
      _quantityCell(row[6]),
      TextCellValue('${row[7] ?? ''}'),
      TextCellValue('${row[8] ?? ''}'),
      TextCellValue('${row[9] ?? ''}'),
    ];
    for (var c = 0; c < cellValues.length; c++) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex),
        cellValues[c],
        cellStyle: isExpiring ? expiringStyle : null,
      );
    }
    rowIndex++;
  }

  final bytes = excel.encode();
  if (bytes == null) {
    throw StateError('xlsx encode failed');
  }
  return bytes;
}

CellValue _quantityCell(dynamic value) {
  final n = _toNum(value);
  final normalized = n.toDouble();
  if (normalized == normalized.roundToDouble()) {
    return IntCellValue(normalized.toInt());
  }
  return DoubleCellValue(normalized);
}

num _toNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  if (value is String) return num.tryParse(value) ?? 0;
  return 0;
}

int? _toIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _dateToString(dynamic value) {
  if (value == null) return '';
  if (value is DateTime) return value.toIso8601String().split('T').first;
  return value.toString();
}