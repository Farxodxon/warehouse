import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dotenv/dotenv.dart';

String _secretKey() {
  final env = DotEnv()..load();
  return env['JWT_SECRET'] ?? 'insecure-dev-secret';
}

String generateToken(int userId, String email) {
  final jwt = JWT(
    {
      'userId': userId,
      'email': email,
    },
  );
  return jwt.sign(SecretKey(_secretKey()), expiresIn: Duration(days: 7));
}

Map<String, dynamic>? verifyToken(String token) {
  try {
    final jwt = JWT.verify(token, SecretKey(_secretKey()));
    return Map<String, dynamic>.from(jwt.payload as Map);
  } catch (_) {
    return null;
  }
}