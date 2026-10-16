import 'package:wms_backend/db/connection.dart';

Future<void> main() async {
  final conn = await openConnection();
  try {
    final rows = await conn.query(
      'SELECT bc.container_barcode, bc.status, p.organization_id, '
      'bc.location_id, sl.code AS loc, w.name AS wh '
      'FROM batch_containers bc '
      'JOIN batches b ON b.id = bc.batch_id '
      'JOIN products p ON p.id = b.product_id '
      'LEFT JOIN storage_locations sl ON sl.id = bc.location_id '
      'LEFT JOIN warehouses w ON w.id = sl.warehouse_id '
      'ORDER BY bc.id DESC LIMIT 15',
    );
    print('== batch_containers (oxirgi 15) ==');
    for (final r in rows) {
      print('code=${r[0]} status=${r[1]} org=${r[2]} loc=${r[4]} wh=${r[5]}');
    }
    final users = await conn.query(
      'SELECT u.id, u.email, u.role, u.organization_id FROM users u ORDER BY u.id',
    );
    print('== users ==');
    for (final r in users) {
      print('id=${r[0]} email=${r[1]} role=${r[2]} org=${r[3]}');
    }
  } finally {
    await conn.close();
  }
}