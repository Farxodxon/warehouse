import 'dart:io';

import 'package:wms_backend/db/connection.dart';

Future<void> main() async {
  final connection = await openConnection();
  try {
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        id SERIAL PRIMARY KEY,
        filename TEXT UNIQUE NOT NULL,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    ''');
    print('OK: schema_migrations jadvali tayyor');

    final applied = <String>{};
    final result =
        await connection.query('SELECT filename FROM schema_migrations');
    for (final row in result) {
      applied.add(row[0] as String);
    }

    final migrationsDir = Directory('lib/db/migrations');
    final files = migrationsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    var skipped = 0;
    var appliedCount = 0;

    for (final file in files) {
      final name = file.uri.pathSegments.last;
      if (applied.contains(name)) {
        print('SKIP: $name (allaqachon bajarilgan)');
        skipped++;
        continue;
      }
      final sql = await file.readAsString();
      await connection.transaction((ctx) async {
        await ctx.execute(sql);
        await ctx.execute(
          'INSERT INTO schema_migrations (filename) VALUES (@filename)',
          substitutionValues: {'filename': name},
        );
      });
      print('APPLIED: $name');
      appliedCount++;
    }

    print('Migratsiya tugadi: $appliedCount qo\'llandi, $skipped o\'tkazildi');
  } catch (e) {
    print('XATO: $e');
    exitCode = 1;
  } finally {
    await connection.close();
  }
}