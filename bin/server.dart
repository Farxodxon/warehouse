import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:wms_backend/auth/jwt.dart';
import 'package:wms_backend/auth/middleware.dart';
import 'package:wms_backend/auth/password.dart';
import 'package:wms_backend/db/connection.dart';

final _router = Router()
  ..get('/health', _healthHandler)
  ..post('/setup', _setupHandler)
  ..post('/login', _loginHandler)
  ..get('/me', authMiddleware()(_meHandler));

Response _jsonResponse(int statusCode, String body) {
  return Response(statusCode,
      body: body,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

Response _jsonResponseBody(int statusCode, Map<String, dynamic> body) {
  return _jsonResponse(statusCode, jsonEncode(body));
}

Future<Response> _healthHandler(Request request) async {
  try {
    final connection = await openConnection();
    await connection.execute('SELECT 1');
    await connection.close();
    return _jsonResponse(200, '{"status":"ok","database":"connected"}');
  } catch (_) {
    return _jsonResponse(503, '{"status":"error","database":"disconnected"}');
  }
}

Future<Response> _setupHandler(Request request) async {
  try {
    final connection = await openConnection();
    try {
      final countResult = await connection.query('SELECT COUNT(*) FROM users');
      final count = countResult.first.first;
      final countInt = count is BigInt ? count.toInt() : count as int;
      if (countInt > 0) {
        return _jsonResponse(403, '{"error":"already_initialized"}');
      }

      final body = jsonDecode(await request.readAsString());
      final email = body['email'] as String;
      final password = body['password'] as String;
      final fullName = body['full_name'] as String;
      final role = 'super_admin';

      final hash = hashPassword(password);
      final result = await connection.query(
        'INSERT INTO users (email, password_hash, full_name, role) '
        'VALUES (@email, @hash, @fullName, @role) '
        'RETURNING id',
        substitutionValues: {
          'email': email,
          'hash': hash,
          'fullName': fullName,
          'role': role,
        },
      );
      final id = result.first.first as int;

      return _jsonResponseBody(201,
          {'id': id, 'email': email, 'full_name': fullName, 'role': role});
    } finally {
      await connection.close();
    }
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
}

Future<Response> _loginHandler(Request request) async {
  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final email = body['email'] as String? ?? '';
  final password = body['password'] as String? ?? '';

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, email, password_hash, full_name, role FROM users '
      'WHERE email = @email',
      substitutionValues: {'email': email},
    );

    if (result.isEmpty) {
      return _jsonResponse(401, '{"error":"invalid_credentials"}');
    }

    final row = result.first;
    final passwordHash = row[2] as String;
    if (!verifyPassword(password, passwordHash)) {
      return _jsonResponse(401, '{"error":"invalid_credentials"}');
    }

    final id = row[0] as int;
    final token = generateToken(id, email);

    return _jsonResponseBody(200, {
      'token': token,
      'user': {
        'id': id,
        'email': row[1],
        'full_name': row[3],
        'role': row[4],
      },
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _meHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, email, full_name, role FROM users WHERE id = @id',
      substitutionValues: {'id': userId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }
    final row = result.first;
    return _jsonResponseBody(200, {
      'id': row[0],
      'email': row[1],
      'full_name': row[2],
      'role': row[3],
    });
  } finally {
    await connection.close();
  }
}

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;

  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server running on http://localhost:${server.port}');
}