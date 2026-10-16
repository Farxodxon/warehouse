import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:test/test.dart';

/// Live smoke test: ISHLAB TURGAN server va haqiqiy DB ga ulanadi.
///
/// Ishga tushirish:
///   Terminal 1: dart run bin/server.dart
///   Terminal 2: dart test test/smoke_test.dart
const _host = 'http://localhost:8080';

late String _token;

Future<dynamic> _getJson(String path) async {
  final r = await get(Uri.parse('$_host$path'),
      headers: {'Authorization': 'Bearer $_token'});
  expect(r.statusCode, 200, reason: 'GET $path -> ${r.statusCode}: ${r.body}');
  return _decoded(r);
}

dynamic _decoded(Response r) =>
    r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));

void main() {
  setUpAll(() async {
    final h = await get(Uri.parse('$_host/health'));
    expect(h.statusCode, 200,
        reason: 'Server ishlamayapti. Avval `dart run bin/server.dart` '
            'terminalda ishga tushiring. Xato: ${h.body}');
    expect(_decoded(h), {'status': 'ok', 'database': 'connected'});

    final r = await post(Uri.parse('$_host/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': Platform.environment['WMS_TEST_EMAIL'] ?? 'admin@eclair.uz',
          'password': Platform.environment['WMS_TEST_PASSWORD'] ?? 'Test1234!',
        }));
    if (r.statusCode != 200) {
      fail('Login muvaffaqiyatsiz (${r.statusCode}). TEST_LOGIN ni tekshiring '
          'yoki muhit o\'zgaruvchilarini qo\'ying:\n'
          '  \$env:WMS_TEST_EMAIL=...\n'
          '  \$env:WMS_TEST_PASSWORD=...\n'
          'Javob: ${r.body}');
    }
    _token = (_decoded(r) as Map<String, dynamic>)['token'] as String;
  });

  group('health', () {
    test('server va DB ulangan', () async {
      final r = await get(Uri.parse('$_host/health'));
      expect(r.statusCode, 200);
      expect(_decoded(r)['database'], 'connected');
    });
  });

  group('auth', () {
    test('/login noto\'g\'ri parol bilan 401 qaytaradi', () async {
      final r = await post(Uri.parse('$_host/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': 'nobody@eclair.uz', 'password': 'wrong'}));
      expect(r.statusCode, 401);
    });

    test('/me token bilan ishlaydi', () async {
      final r = await get(Uri.parse('$_host/me'),
          headers: {'Authorization': 'Bearer $_token'});
      expect(r.statusCode, 200);
      final me = _decoded(r) as Map<String, dynamic>;
      expect(me['id'], isA<int>());
      expect(me['email'], isA<String>());
    });

    test('/me tokensiz 401 qaytaradi', () async {
      final r = await get(Uri.parse('$_host/me'));
      expect(r.statusCode, 401);
    });
  });

  group('omborlar', () {
    test('GET /warehouses ro\'yxatni qaytaradi', () async {
      final list = await _getJson('/warehouses') as List;
      expect(list, isA<List>());
    });
  });

  test('GET /foobar 404 qaytaradi', () async {
    final r = await get(Uri.parse('$_host/foobar'));
    expect(r.statusCode, 404);
  });
}
