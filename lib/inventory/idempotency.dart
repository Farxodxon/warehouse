import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import 'package:wms_backend/db/connection.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Response _json(int status, Map<String, dynamic> body) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// Idempotency-Key sarlavhasi bo'lsa, bir xil kalit bilan takroriy so'rov
/// ikkinchi marta bajarilmaydi: birinchi javob qaytariladi.
Handler idempotent(Handler inner) {
  return (Request request) async {
    final key = request.headers['idempotency-key']?.trim();
    final userId = request.context['userId'];
    if (key == null || key.isEmpty || userId is! int) return inner(request);
    if (key.length > 100) {
      return _json(400, {'error': 'invalid_idempotency_key'});
    }
    final path = '${request.method} ${request.requestedUri.path}';
    final connection = await openConnection();
    try {
      // 1) kalitni band qilish
      final claimed = await _claim(connection, key, userId, path);
      if (!claimed) {
        final rows = await connection.query(
          'SELECT status_code, response_body, method_path '
          'FROM idempotency_keys WHERE idem_key = @key AND user_id = @userId',
          substitutionValues: {'key': key, 'userId': userId},
        );
        if (rows.isNotEmpty) {
          final status = rows.first[0] as int;
          final stored = rows.first[1] as String;
          final storedPath = rows.first[2] as String;
          if (storedPath != path) {
            return _json(422, {'error': 'idempotency_key_reused'});
          }
          if (status != 0) {
            return Response(status,
                body: stored,
                headers: {..._jsonHeaders, 'idempotent-replay': 'true'});
          }
          return _json(409, {'error': 'request_in_progress'});
        }
        return _json(409, {'error': 'request_in_progress'});
      }
      // 2) asosiy handler
      Response response;
      try {
        response = await inner(request);
      } catch (_) {
        await _release(connection, key, userId);
        rethrow;
      }
      final body = await response.readAsString();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        await connection.execute(
          'UPDATE idempotency_keys SET status_code = @status, '
          'response_body = @body WHERE idem_key = @key AND user_id = @userId',
          substitutionValues: {
            'status': response.statusCode,
            'body': body,
            'key': key,
            'userId': userId,
          },
        );
      } else {
        await _release(connection, key, userId); // xato saqlanmaydi
      }
      final headers = Map<String, Object>.from(response.headers)
        ..remove('content-length');
      return Response(response.statusCode, body: body, headers: headers);
    } finally {
      await connection.close();
    }
  };
}

Future<bool> _claim(
  PostgreSQLConnection connection,
  String key,
  int userId,
  String path,
) async {
  final result = await connection.query(
    'INSERT INTO idempotency_keys (idem_key, user_id, method_path) '
    'VALUES (@key, @userId, @path) '
    'ON CONFLICT (idem_key, user_id) DO NOTHING RETURNING 1',
    substitutionValues: {'key': key, 'userId': userId, 'path': path},
  );
  return result.isNotEmpty;
}

Future<void> _release(
  PostgreSQLConnection connection,
  String key,
  int userId,
) async {
  await connection.execute(
    'DELETE FROM idempotency_keys WHERE idem_key = @key AND user_id = @userId',
    substitutionValues: {'key': key, 'userId': userId},
  );
}
