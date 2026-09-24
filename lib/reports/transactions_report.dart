import 'package:excel/excel.dart';
import 'package:postgres/postgres.dart';

Future<List<int>> buildTransactionsReport(
  PostgreSQLExecutionContext db, {
  required int userId,
  required int organizationId,
  required String from,
  required String to,
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
    'from': from,
    'to': to,
  };
  final conditions = <String>[
    'it.organization_id = @organizationId',
    'it.created_at::date BETWEEN @from::date AND @to::date',
  ];
  if (warehouseId != null) {
    conditions.add(
      '(sl_from.warehouse_id = @warehouseId OR '
      'sl_to.warehouse_id = @warehouseId)',
    );
    values['warehouseId'] = warehouseId;
  }
  if (!isSuperAdmin) {
    conditions.add(
      '(sl_from.warehouse_id IN '
      '(SELECT warehouse_id FROM user_warehouse_access WHERE user_id = @userId) '
      'OR sl_to.warehouse_id IN '
      '(SELECT warehouse_id FROM user_warehouse_access WHERE user_id = @userId))',
    );
  }

  final result = await db.query(
    '''
    SELECT it.created_at, it.type, p.name, bc.container_barcode, it.quantity,
           sl_from.code, sl_to.code, u.full_name, it.note
    FROM inventory_transactions it
    JOIN batch_containers bc ON bc.id = it.batch_container_id
    JOIN batches b ON b.id = bc.batch_id
    JOIN products p ON p.id = b.product_id
    LEFT JOIN storage_locations sl_from ON sl_from.id = it.from_location_id
    LEFT JOIN storage_locations sl_to ON sl_to.id = it.to_location_id
    JOIN users u ON u.id = it.performed_by
    WHERE ${conditions.join(' AND ')}
    ORDER BY it.created_at, it.id
    ''',
    substitutionValues: values,
  );

  const headers = [
    'Sana',
    'Turi',
    'Mahsulot',
    'Konteyner',
    'Miqdor',
    'Qayerdan',
    'Qayerga',
    'Kim bajargan',
    'Izoh',
  ];

  final excel = Excel.createExcel();
  excel.rename(excel.getDefaultSheet()!, 'Harakatlar');
  final sheet = excel['Harakatlar'];

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

  const widths = [20.0, 14.0, 28.0, 18.0, 10.0, 16.0, 16.0, 20.0, 32.0];
  for (var c = 0; c < widths.length; c++) {
    sheet.setColumnWidth(c, widths[c]);
  }

  var rowIndex = 1;
  for (final row in result) {
    final type = row[1] as String? ?? '';
    final cellValues = <CellValue?>[
      TextCellValue(_dateTimeToString(row[0])),
      TextCellValue(type),
      TextCellValue('${row[2] ?? ''}'),
      TextCellValue('${row[3] ?? ''}'),
      _quantityCell(row[4]),
      TextCellValue('${row[5] ?? ''}'),
      TextCellValue('${row[6] ?? ''}'),
      TextCellValue('${row[7] ?? ''}'),
      TextCellValue('${row[8] ?? ''}'),
    ];
    for (var c = 0; c < cellValues.length; c++) {
      final style = c == 1 ? _typeStyle(type) : null;
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex),
        cellValues[c],
        cellStyle: style,
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

CellStyle _typeStyle(String type) {
  final background = switch (type) {
    'OUT' => ExcelColor.red100,
    'TRANSFER' => ExcelColor.blue100,
    'ADJUSTMENT' => ExcelColor.yellow100,
    _ => ExcelColor.none,
  };
  return CellStyle(
    backgroundColorHex: background,
    verticalAlign: VerticalAlign.Center,
  );
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

String _dateTimeToString(dynamic value) {
  if (value == null) return '';
  if (value is DateTime) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
  return value.toString();
}