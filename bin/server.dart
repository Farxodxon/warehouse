import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:wms_backend/db/connection.dart';

final _router = Router()
  ..get('/health', _healthHandler);

Response _jsonResponse(int statusCode, String body) {
  return Response(statusCode,
      body: body,
      headers: {'content-type': 'application/json; charset=utf-8'});
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

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;

  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server running on http://localhost:${server.port}');
}