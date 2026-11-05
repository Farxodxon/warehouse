import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:test/test.dart';

/// Live smoke test: alohida test backend va haqiqiy DB ga ulanadi.
///
/// Production'ga tasodifan urilmasligi uchun uchta muhit o'zgaruvchisi
/// majburiy. Ular berilmasa test o'tkazib yuboriladi:
///
///   WMS_TEST_BASE_URL=https://<test-backend> \
///   WMS_TEST_EMAIL=<test-email> \
///   WMS_TEST_PASSWORD=<test-password> \
///   dart test test/smoke_test.dart
final _baseUrlRaw = Platform.environment['WMS_TEST_BASE_URL']?.trim() ?? '';
final _email = Platform.environment['WMS_TEST_EMAIL']?.trim() ?? '';
final _password = Platform.environment['WMS_TEST_PASSWORD'] ?? '';

final _configured =
    _baseUrlRaw.isNotEmpty && _email.isNotEmpty && _password.isNotEmpty;
final _host = _baseUrlRaw.endsWith('/')
    ? _baseUrlRaw.substring(0, _baseUrlRaw.length - 1)
    : _baseUrlRaw;

const _skipReason = 'WMS_TEST_BASE_URL, WMS_TEST_EMAIL va WMS_TEST_PASSWORD '
    'berilmagan; live smoke test o\'tkazib yuborildi.';

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
  if (!_configured) {
    test('live smoke test', () {}, skip: _skipReason);
    return;
  }

  setUpAll(() async {
    final h = await get(Uri.parse('$_host/health'));
    expect(h.statusCode, 200,
        reason: 'Test backend javob bermayapti (${h.statusCode}): ${h.body}');
    expect(_decoded(h), {'status': 'ok', 'database': 'connected'});

    final r = await post(Uri.parse('$_host/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _email, 'password': _password}));
    if (r.statusCode != 200) {
      fail('Login muvaffaqiyatsiz (${r.statusCode}). WMS_TEST_EMAIL va '
          'WMS_TEST_PASSWORD qiymatlarini tekshiring. Javob: ${r.body}');
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
