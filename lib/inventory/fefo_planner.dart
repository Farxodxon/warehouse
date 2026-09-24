import 'package:postgres/postgres.dart';

/// One planned pick from a single batch container.
class FefoPlanItem {
  FefoPlanItem({
    required this.containerId,
    required this.containerBarcode,
    required this.lotNumber,
    this.expiryDate,
    this.locationCode,
    this.locationId,
    required this.takeQuantity,
  });

  final int containerId;
  final String containerBarcode;
  final String lotNumber;
  final String? expiryDate;
  final String? locationCode;
  final int? locationId;
  final num takeQuantity;

  Map<String, dynamic> toJson() => {
        'container_id': containerId,
        'container_barcode': containerBarcode,
        'lot_number': lotNumber,
        'expiry_date': expiryDate ?? '',
        'location_code': locationCode ?? '',
        'take_quantity': takeQuantity,
      };
}

/// The greedy FEFO plan for a single requested quantity.
class FefoPlan {
  FefoPlan({
    required this.requested,
    required this.covered,
    required this.sufficient,
    required this.plan,
  });

  final num requested;
  final num covered;
  final bool sufficient;
  final List<FefoPlanItem> plan;

  Map<String, dynamic> toJson() => {
        'requested': requested,
        'covered': covered,
        'sufficient': sufficient,
        'plan': plan.map((e) => e.toJson()).toList(),
      };
}

/// Thrown when stock (within user's warehouse access) is not sufficient.
class FefoInsufficientStock implements Exception {
  FefoInsufficientStock(this.available);

  final num available;
}

/// Builds a FEFO plan for [productId]: approved batches ordered by
/// expiry_date ASC NULLS LAST, their active containers greedily collected
/// until [requested] is covered.
///
/// For non super-admin users, containers located in warehouses the user has
/// no access to (user_warehouse_access) are ignored entirely.
Future<FefoPlan> buildFefoPlan(
  PostgreSQLExecutionContext db, {
  required int userId,
  required int organizationId,
  required int productId,
  required num requested,
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
    'productId': productId,
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
    SELECT bc.id, bc.container_barcode, b.lot_number, b.expiry_date,
           sl.code, bc.quantity, bc.location_id
    FROM batch_containers bc
    JOIN batches b ON b.id = bc.batch_id
    LEFT JOIN storage_locations sl ON sl.id = bc.location_id
    WHERE b.product_id = @productId
      AND b.organization_id = @organizationId
      AND b.quality_status = 'approved'
      AND bc.status = 'active'
      AND bc.quantity > 0
      $warehouseClause
    ORDER BY b.expiry_date ASC NULLS LAST, b.id, bc.id
    ''',
    substitutionValues: values,
  );

  final plan = <FefoPlanItem>[];
  var remaining = requested;
  num covered = 0;
  for (final row in result) {
    if (remaining <= 0) break;
    final quantity = _toNum(row[5]);
    if (quantity <= 0) continue;
    final take = quantity < remaining ? quantity : remaining;
    plan.add(FefoPlanItem(
      containerId: row[0] as int,
      containerBarcode: row[1] as String,
      lotNumber: row[2] as String,
      expiryDate: _dateToString(row[3]),
      locationCode: row[4] as String?,
      locationId: row[6] as int?,
      takeQuantity: take,
    ));
    covered += take;
    remaining -= take;
  }

  return FefoPlan(
    requested: requested,
    covered: covered,
    sufficient: remaining <= 0,
    plan: plan,
  );
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