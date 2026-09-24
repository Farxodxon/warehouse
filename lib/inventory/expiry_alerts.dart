import 'package:postgres/postgres.dart';

/// Builds the expiring-batches alert list for an organization.
///
/// Returns only batches whose expiry_date is within [days] days from today
/// (earliest first); expired batches (negative days_remaining) are included.
/// Containers located in warehouses the user has no access to are ignored for
/// non super-admin users. This function is READ-ONLY: it never mutates data.
Future<List<Map<String, dynamic>>> buildExpiryAlerts(
  PostgreSQLExecutionContext db, {
  required int userId,
  required int organizationId,
  required int days,
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
    'days': days,
  };

  final warehouseClause = isSuperAdmin
      ? ''
      : '''
      AND sl.warehouse_id IN (
        SELECT warehouse_id FROM user_warehouse_access
        WHERE user_id = @userId
      )''';

  final result = await db.query(
    '''
    SELECT b.id, b.product_id, p.name, b.lot_number, b.expiry_date,
           (b.expiry_date - CURRENT_DATE) AS days_remaining,
           bc.quantity, sl.code, w.name
    FROM batch_containers bc
    JOIN batches b ON b.id = bc.batch_id
    JOIN products p ON p.id = b.product_id
    LEFT JOIN storage_locations sl ON sl.id = bc.location_id
    LEFT JOIN warehouses w ON w.id = sl.warehouse_id
    WHERE b.organization_id = @organizationId
      AND b.quality_status = 'approved'
      AND b.expiry_date IS NOT NULL
      AND b.expiry_date <= CURRENT_DATE + @days::int4
      AND bc.status = 'active'
      AND bc.quantity > 0
      $warehouseClause
    ORDER BY b.expiry_date ASC, b.id, bc.id
    ''',
    substitutionValues: values,
  );

  final items = <Map<String, dynamic>>[];
  final byBatch = <int, Map<String, dynamic>>{};
  for (final row in result) {
    final batchId = row[0] as int;
    final daysRemaining = _toInt(row[5]);
    final quantity = _toNum(row[6]);
    final entry = byBatch[batchId];
    if (entry == null) {
      byBatch[batchId] = {
        'batch_id': batchId,
        'product_id': row[1],
        'product_name': row[2],
        'lot_number': row[3],
        'expiry_date': _dateToString(row[4]),
        'days_remaining': daysRemaining,
        'urgency': _urgencyFor(daysRemaining),
        'total_active_quantity': quantity,
        'locations': [
          {
            'warehouse_name': row[8] as String? ?? '',
            'location_code': row[7] as String? ?? '',
            'quantity': quantity,
          },
        ],
      };
      items.add(byBatch[batchId]!);
    } else {
      entry['total_active_quantity'] =
          (_toNum(entry['total_active_quantity'])) + quantity;
      final locations = entry['locations'] as List<Map<String, dynamic>>;
      final locationKey = '${row[8]}|${row[7]}';
      final locIndex =
          locations.indexWhere((l) => '${l['warehouse_name']}|${l['location_code']}' == locationKey);
      if (locIndex >= 0) {
        locations[locIndex]['quantity'] =
            _toNum(locations[locIndex]['quantity']) + quantity;
      } else {
        locations.add({
          'warehouse_name': row[8] as String? ?? '',
          'location_code': row[7] as String? ?? '',
          'quantity': quantity,
        });
      }
    }
  }

  return items;
}

String _urgencyFor(int daysRemaining) {
  if (daysRemaining < 0) return 'expired';
  if (daysRemaining <= 7) return 'critical';
  return 'warning';
}

int _toInt(dynamic value) {
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

num _toNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value;
  if (value is String) return num.tryParse(value) ?? 0;
  return 0;
}

String _dateToString(dynamic value) {
  if (value == null) return '';
  if (value is DateTime) return value.toIso8601String().split('T').first;
  return value.toString();
}