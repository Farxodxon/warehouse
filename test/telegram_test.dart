import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:wms_backend/telegram/stock_format.dart';
import 'package:wms_backend/telegram/telegram_client.dart';
import 'package:wms_backend/telegram/webhook.dart';

/// Soxta yuboruvchi: tarmoqqa chiqmaydi, yuborilganlarni yig'adi.
class FakeSender implements TelegramSender {
  final List<(String, String)> sent = <(String, String)>[];
  bool throwOnSend = false;

  @override
  Future<void> sendMessage(String chatId, String text) async {
    if (throwOnSend) throw TelegramSendException('soxta yuborish xatosi');
    sent.add((chatId, text));
  }
}

TelegramSettings _settings({
  bool enabled = true,
  Set<String> chatIds = const {'-100500'},
}) =>
    TelegramSettings(
      token: enabled ? '000000:TEST-TOKEN' : '',
      secret: enabled ? 'test-secret' : '',
      chatIds: chatIds,
    );

Request _updateRequest({
  required String? secret,
  required int chatId,
  String? text,
}) {
  final headers = <String, String>{'content-type': 'application/json'};
  if (secret != null) headers['x-telegram-bot-api-secret-token'] = secret;
  return Request(
    'POST',
    Uri.parse('http://localhost/telegram/webhook'),
    headers: headers,
    body: jsonEncode({
      'update_id': 1,
      if (text != null)
        'message': {
          'message_id': 1,
          'chat': {'id': chatId, 'type': 'group'},
          'text': text,
        },
    }),
  );
}

void main() {
  group('formatQty', () {
    test('butun son kasrsiz chiqadi', () {
      expect(formatQty(170), '170');
      expect(formatQty(35700), '35700');
      expect(formatQty(0), '0');
    });

    test('kasr 2 xonagacha, ortiqcha nolsiz', () {
      expect(formatQty(93.5), '93.5');
      expect(formatQty(93.456), '93.46');
      expect(formatQty(170.25), '170.25');
    });
  });

  group('normalizeCode', () {
    test("normalizeCode('L 001/2') == normalizeCode('l001/2')", () {
      expect(normalizeCode('L 001/2'), normalizeCode('l001/2'));
      expect(normalizeCode('L 001/2'), 'L001/2');
      expect(normalizeCode('  l001 / 2 '), 'L001/2');
    });
  });

  group('stockLine', () {
    test('bitta guruh (aniq matn)', () {
      expect(
        stockLine('L 001/2', 'kg', [(170, 210)]),
        'L 001/2 - 210*170kg=35700kg qoldi',
      );
    });

    test('aralash guruhlar (aniq matn)', () {
      expect(
        stockLine('L 001/2', 'kg', [(170, 209), (93, 1)]),
        'L 001/2 - 209*170kg + 1*93kg = 35623kg qoldi',
      );
    });

    test('nol qoldiq matni', () {
      expect(
        stockLine('L 001/2', 'kg', []),
        "L 001/2 - qoldiq yo'q (0kg)",
      );
    });

    test('6 tadan ko\'p guruh qisqartiriladi', () {
      final groups = <(num, int)>[
        (10, 7),
        (20, 6),
        (30, 5),
        (40, 4),
        (50, 3),
        (60, 2),
        (70, 1),
      ];
      final line = stockLine('KOD', 'kg', groups);
      expect(line, startsWith('KOD - 7*10kg + 6*20kg'));
      expect(line, contains(' + yana 1 ta konteyner'));
      expect(line, endsWith(' = 840kg qoldi'));
    });
  });

  group('buildOutMessage (chiqim shabloni)', () {
    test('bitta konteyner - aniq shablonga mos', () {
      final message = buildOutMessage(
        sku: 'L 001/2',
        productName: 'Sodium laureth sulfate',
        unit: 'kg',
        items: const [
          OutItem(
            containerBarcode: 'L0012-B3',
            lotNumber: 'LOT-2026-001',
            quantity: 170,
          ),
        ],
        remainingGroups: [(170, 209)],
        performer: 'Otabek Karimov',
        time: DateTime.utc(2026, 10, 16, 12, 5),
      );
      expect(
        message,
        '📤 CHIQIM\n'
        'L 001/2 - Sodium laureth sulfate\n'
        'Chiqdi: 170kg (konteyner L0012-B3, lot LOT-2026-001)\n'
        'Qoldiq: 209*170kg=35530kg\n'
        'Kim: Otabek Karimov | 16.10.2026 17:05',
      );
    });

    test('FEFO: har konteyner alohida qatorda, Qoldiq bitta', () {
      final message = buildOutMessage(
        sku: 'L 001/2',
        productName: 'Sodium laureth sulfate',
        unit: 'kg',
        items: const [
          OutItem(
            containerBarcode: 'L0012-B3',
            lotNumber: 'LOT-2026-001',
            quantity: 170,
          ),
          OutItem(
            containerBarcode: 'L0012-B4',
            lotNumber: 'LOT-2026-001',
            quantity: 93.5,
          ),
        ],
        remainingGroups: [(170, 208)],
        performer: 'Otabek Karimov',
        time: DateTime.utc(2026, 10, 16, 12, 5),
      );
      final lines = message.split('\n');
      expect(lines[0], '📤 CHIQIM');
      expect(lines[2], 'Chiqdi: 170kg (konteyner L0012-B3, lot LOT-2026-001)');
      expect(lines[3], 'Chiqdi: 93.5kg (konteyner L0012-B4, lot LOT-2026-001)');
      expect(
        lines.where((line) => line.startsWith('Qoldiq:')).single,
        'Qoldiq: 208*170kg=35360kg',
      );
    });

    test('vaqt Toshkent (UTC+5)', () {
      expect(tashkentTime(DateTime.utc(2026, 10, 16, 12, 5)),
          '16.10.2026 17:05');
      expect(
          tashkentTime(DateTime.utc(2026, 1, 1, 19, 30)), '02.01.2026 00:30');
    });
  });

  group('webhook ishlovchisi', () {
    late FakeSender sender;
    late List<String> logs;

    setUp(() {
      sender = FakeSender();
      logs = <String>[];
    });

    Future<Response> post({
      required String? secret,
      required int chatId,
      String? text,
      required Future<List<StockMatch>> Function(String query) lookup,
    }) =>
        handleTelegramWebhook(
          _updateRequest(secret: secret, chatId: chatId, text: text),
          settings: _settings(),
          sender: sender,
          lookup: lookup,
          log: logs.add,
        );

    test("noto'g'ri secret -> 401 va hech narsa yuborilmaydi", () async {
      final response = await post(
        secret: 'wrong-secret',
        chatId: -100500,
        text: '/id',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 401);
      expect(sender.sent, isEmpty);
    });

    test("yo'q secret (sarlavhasiz) -> 401", () async {
      final response = await post(
        secret: null,
        chatId: -100500,
        text: '/id',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 401);
      expect(sender.sent, isEmpty);
    });

    test("env bo'sh (token/secret yo'q) -> 404", () async {
      final response = await handleTelegramWebhook(
        _updateRequest(secret: 'test-secret', chatId: -100500, text: '/id'),
        settings: _settings(enabled: false),
        sender: sender,
        lookup: (q) async => [],
        log: logs.add,
      );
      expect(response.statusCode, 404);
      expect(sender.sent, isEmpty);
    });

    test("to'g'ri secret + noma'lum chatdan /id -> chat ID yuboriladi",
        () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -777,
        text: '/id',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$1, '-777');
      expect(sender.sent.single.$2, 'Bu chat ID: -777');
    });

    test("noma'lum chatdan /qoldiq -> javob YO'Q va bazaga so'rov KETMAYDI",
        () async {
      var lookupCalled = false;
      final response = await post(
        secret: 'test-secret',
        chatId: -777,
        text: '/qoldiq X',
        lookup: (q) async {
          lookupCalled = true;
          return [];
        },
      );
      expect(response.statusCode, 200);
      expect(sender.sent, isEmpty);
      expect(lookupCalled, isFalse);
      expect(logs, contains('Ruxsatsiz chat: -777'));
    });

    test("ruxsatli chatdan /qoldiq -> qoldiq va nom bilan javob", () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/qoldiq L001/2',
        lookup: (q) async => [
          StockMatch(
            sku: 'L 001/2',
            name: 'Sodium laureth sulfate',
            unit: 'kg',
            groups: [(170, 3)],
          ),
        ],
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$1, '-100500');
      expect(
        sender.sent.single.$2,
        'L 001/2 - 3*170kg=510kg qoldi\nSodium laureth sulfate',
      );
    });

    test('/qoldiq@BotNomi nomi olib tashlanadi', () async {
      final calls = <String>[];
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/qoldiq@TestBot L 001/2',
        lookup: (q) async {
          calls.add(q);
          return [
            StockMatch(sku: 'L 001/2', name: 'SLS', unit: 'kg', groups: []),
          ];
        },
      );
      expect(response.statusCode, 200);
      expect(calls, ['L 001/2']);
      expect(sender.sent.single.$2, contains('qoldiq yo\'q'));
    });

    test("argumentsiz /qoldiq -> ishlatish yordami, bazaga so'rov yo'q",
        () async {
      var lookupCalled = false;
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/qoldiq',
        lookup: (q) async {
          lookupCalled = true;
          return [];
        },
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$2, 'Ishlatilishi: /qoldiq KOD');
      expect(lookupCalled, isFalse);
    });

    test("topilmadi -> Topilmadi: <so'rov>", () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/qoldiq YOQ-KOD',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$2, "Topilmadi: YOQ-KOD");
    });

    test("bir nechta moslik -> ro'yxat va Aniqroq yozing", () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/qoldiq L00',
        lookup: (q) async => [
          StockMatch(sku: 'L001', name: 'Birinchi', unit: 'kg', groups: []),
          StockMatch(sku: 'L002', name: 'Ikkinchi', unit: 'kg', groups: []),
        ],
      );
      expect(response.statusCode, 200);
      expect(
        sender.sent.single.$2,
        'L001 - Birinchi\nL002 - Ikkinchi\nAniqroq yozing',
      );
    });

    test('yuborish xatosi -> ishlovchi qulamaydi (200)', () async {
      sender.throwOnSend = true;
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/id',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 200);
      expect(logs.join('\n'), contains('Telegram webhook xatosi'));
    });

    test("message.text yo'q -> 200 va hech narsa yuborilmaydi", () async {
      final response = await handleTelegramWebhook(
        Request(
          'POST',
          Uri.parse('http://localhost/telegram/webhook'),
          headers: {
            'content-type': 'application/json',
            'x-telegram-bot-api-secret-token': 'test-secret',
          },
          body: jsonEncode({
            'update_id': 2,
            'message': {
              'message_id': 2,
              'chat': {'id': -100500, 'type': 'group'},
              'photo': [],
            },
          }),
        ),
        settings: _settings(),
        sender: sender,
        lookup: (q) async => [],
        log: logs.add,
      );
      expect(response.statusCode, 200);
      expect(sender.sent, isEmpty);
    });

    test('/yordam ruxsatli chatda -> yordam matni', () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/yordam',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$2, contains('/qoldiq KOD'));
    });

    test("noma'lum buyruq ruxsatli chatda -> yordam matni", () async {
      final response = await post(
        secret: 'test-secret',
        chatId: -100500,
        text: '/nomalum',
        lookup: (q) async => [],
      );
      expect(response.statusCode, 200);
      expect(sender.sent.single.$2, contains('/yordam'));
    });
  });
}
