import 'package:shelf/shelf.dart';

import 'package:wms_backend/auth/jwt.dart';

Middleware authMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      final header = request.headers['authorization'];
      if (header == null || !header.startsWith('Bearer ')) {
        return _unauthorized();
      }

      final token = header.substring('Bearer '.length);
      final payload = verifyToken(token);
      if (payload == null) {
        return _unauthorized();
      }

      final userId = (payload['userId'] as num).toInt();
      return innerHandler(request.change(
        context: {'userId': userId},
      ));
    };
  };
}

Response _unauthorized() {
  return Response(401,
      body: '{"error":"unauthorized"}',
      headers: {'content-type': 'application/json; charset=utf-8'});
}