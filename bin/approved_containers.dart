import 'package:wms_backend/db/connection.dart';

Future<void> main() async {
  final conn = await openConnection();
  try {
    final rows = await conn.query(
      'SELECT bc.container_barcode, b.quality_status, bc.status, p.organization_id, '
      'bc.batch_id, bc.quantity, bc.unit_weight_kg '
      'FROM batch_containers bc '
      'JOIN batches b ON b.id = bc.batch_id '
      'JOIN products p ON p.id = b.product_id '
      "WHERE p.organization_id = 1 AND bc.status = 'active' "
      "AND b.quality_status = 'approved' "
      'ORDER BY bc.id DESC LIMIT 10',
    );
    print('== approved containers (org 1) ==');
    for (final r in rows) {
      print('code=${r[0]} quality=${r[1]} status=${r[2]} batch=${r[4]} qty=${r[5]} unit=${r[6]}');
    }
  } finally {
    await conn.close();
  }
}