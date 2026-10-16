import 'package:wms_backend/auth/password.dart';
import 'package:wms_backend/db/connection.dart';

Future<void> main(List<String> args) async {
  final email = args.isNotEmpty ? args[0] : 'operator@eclair.uz';
  final plain = args.length > 1 ? args[1] : 'Test4321!';
  final conn = await openConnection();
  try {
    final rows = await conn.query(
      'UPDATE users SET password_hash = @h WHERE email = @e RETURNING id, email, role',
      substitutionValues: {'h': hashPassword(plain), 'e': email},
    );
    for (final r in rows) {
      print('reset OK: id=${r[0]} email=${r[1]} role=${r[2]}');
    }
    if (rows.isEmpty) print('NO USER: $email');
  } finally {
    await conn.close();
  }
}