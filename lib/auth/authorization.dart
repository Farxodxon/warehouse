import 'package:wms_backend/db/connection.dart';

Future<String?> getUserRoleForWarehouse(int userId, int warehouseId) async {
  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT role FROM user_warehouse_access '
      'WHERE user_id = @userId AND warehouse_id = @warehouseId',
      substitutionValues: {'userId': userId, 'warehouseId': warehouseId},
    );
    if (result.isEmpty) return null;
    return result.first.first as String;
  } finally {
    await connection.close();
  }
}

Future<bool> isSuperAdmin(int userId) async {
  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT role FROM users WHERE id = @userId',
      substitutionValues: {'userId': userId},
    );
    if (result.isEmpty) return false;
    return result.first.first as String == 'super_admin';
  } finally {
    await connection.close();
  }
}