import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'stock_format.dart';
import 'telegram_client.dart';

/// Telegram webhook sozlamalari (muhit o'zgaruvchilaridan).
///
/// Token/secret qiymatlari hech qayerda loglanmaydi va bu sinf
/// `toString`/`toJson` ga ega emas - ular ataylab chetlab o'tilgan.
class TelegramSettings {
  TelegramSettings({
    required this.token,
    required this.secret,
    required this.chatIds,
    this.publicBaseUrl,
  });

  /// Muhitdan o'qiydi: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`,
  /// `TELEGRAM_CHAT_IDS`, `RENDER_EXTERNAL_URL` yoki `PUBLIC_BASE_URL`.
  factory TelegramSettings.fromEnvironment([Map<String, String>? source]) {
    final env = source ?? const <String, String>{};
    final rawChatIds = env['TELEGRAM_CHAT_IDS'] ?? '';
    final chatIds = <String>{
      for (final part in rawChatIds.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    };
    final baseUrl = (env['RENDER_EXTERNAL_URL'] ?? '').trim().isNotEmpty
        ? (env['RENDER_EXTERNAL_URL'] ?? '').trim()
        : (env['PUBLIC_BASE_URL'] ?? '').trim();
    return TelegramSettings(
      token: (env['TELEGRAM_BOT_TOKEN'] ?? '').trim(),
      secret: (env['TELEGRAM_WEBHOOK_SECRET'] ?? '').trim(),
      chatIds: chatIds,
      publicBaseUrl: baseUrl.isEmpty ? null : baseUrl.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  final String token;
  final String secret;
  final Set<String> chatIds;
  final String? publicBaseUrl;

  /// Token YOKI secret bo'sh bo'lsa butun funksiya o'chiq turadi.
  bool get enabled => token.isNotEmpty && secret.isNotEmpty;

  /// Guruhda qoldiq ko'rsatishga ruxsat etilganmi?
  bool isAllowedChat(String chatId) => chatIds.contains(chatId);

  /// Xato matnidan tokenni olib tashlaydi (logga token'siz yozish uchun).
  String sanitize(String value) =>
      token.isEmpty ? value : value.replaceAll(token, '[token]');
}

/// Doimiy vaqtli taqqoslash (timing attack'ga chidamli).
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Sarlavhani hurmat qilib (katta-kichik harf farqisiz) qidiradi.
String? _headerIgnoreCase(Request request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}

const _helpText = 'Buyruqlar:\n'
    '/qoldiq KOD - mahsulot qoldig\'ini ko\'rish\n'
    '/id - chat ID raqamini olish\n'
    '/yordam - shu yordam';

/// `POST /telegram/webhook` ishlovchisi.
///
/// - [settings] o'chiq bo'lsa (token/secret bo'sh) 404 qaytaradi: butun
///   funksiya o'chiq, server qulamaydi.
/// - Secret to'g'ri bo'lishi shart, aks holda 401 va hech narsa bajarilmaydi.
/// - Faqat `message.text` qayta ishlanadi, boshqalarga 200.
/// - Doim tez 200 (xatolar ushlanib [log]'ga yoziladi, token'siz).
Future<Response> handleTelegramWebhook(
  Request request, {
  required TelegramSettings settings,
  required TelegramSender sender,
  required Future<List<StockMatch>> Function(String query) lookup,
  void Function(String line)? log,
}) async {
  if (!settings.enabled) {
    return Response(404, body: 'not found');
  }
  final providedSecret =
      _headerIgnoreCase(request, 'x-telegram-bot-api-secret-token') ?? '';
  if (!constantTimeEquals(providedSecret, settings.secret)) {
    return Response(401, body: 'unauthorized');
  }

  dynamic update;
  try {
    update = jsonDecode(await request.readAsString());
  } catch (_) {
    return Response.ok('');
  }

  final message = update is Map ? update['message'] : null;
  final chatId =
      message is Map && message['chat'] is Map ? message['chat']['id'] : null;
  final text = message is Map && message['text'] is String
      ? message['text'] as String
      : null;
  if (chatId == null || text == null || text.trim().isEmpty) {
    return Response.ok('');
  }

  final chat = chatId.toString();
  try {
    await _processText(
      text: text,
      chatId: chat,
      settings: settings,
      sender: sender,
      lookup: lookup,
      log: log,
    );
  } catch (e) {
    log?.call('Telegram webhook xatosi: ${settings.sanitize(e.toString())}');
  }
  return Response.ok('');
}

Future<void> _processText({
  required String text,
  required String chatId,
  required TelegramSettings settings,
  required TelegramSender sender,
  required Future<List<StockMatch>> Function(String query) lookup,
  void Function(String line)? log,
}) async {
  final trimmed = text.trim();
  if (!trimmed.startsWith('/')) return;

  final separator = trimmed.indexOf(RegExp(r'\s'));
  final commandPart =
      separator == -1 ? trimmed : trimmed.substring(0, separator);
  final args =
      separator == -1 ? '' : trimmed.substring(separator + 1).trim();

  // /qoldiq@BotNomi ko'rinishidagi qo'shimchani olib tashlash.
  final atIndex = commandPart.indexOf('@');
  final command = (atIndex == -1
          ? commandPart
          : commandPart.substring(0, atIndex))
      .toLowerCase();

  switch (command) {
    case '/id':
      // Istalgan chatda javob beradi (sozlash uchun).
      await sender.sendMessage(chatId, 'Bu chat ID: $chatId');
      return;
    case '/qoldiq':
      if (!settings.isAllowedChat(chatId)) {
        // Bazaga umuman murojaat QILINMAYDI, javob ham YO'Q.
        log?.call('Ruxsatsiz chat: $chatId');
        return;
      }
      if (args.isEmpty) {
        await sender.sendMessage(chatId, 'Ishlatilishi: /qoldiq KOD');
        return;
      }
      final matches = await lookup(args);
      if (matches.isEmpty) {
        await sender.sendMessage(chatId, 'Topilmadi: $args');
        return;
      }
      if (matches.length == 1) {
        final match = matches.first;
        await sender.sendMessage(
          chatId,
          '${stockLine(match.sku, match.unit, match.groups)}\n${match.name}',
        );
        return;
      }
      final lines = [
        for (final match in matches) '${match.sku} - ${match.name}',
      ];
      await sender.sendMessage(chatId, '${lines.join('\n')}\nAniqroq yozing');
      return;
    case '/yordam':
      if (settings.isAllowedChat(chatId)) {
        await sender.sendMessage(chatId, _helpText);
      } else {
        log?.call('Ruxsatsiz chat: $chatId');
      }
      return;
    default:
      if (settings.isAllowedChat(chatId)) {
        await sender.sendMessage(chatId, _helpText);
      } else {
        log?.call('Ruxsatsiz chat: $chatId');
      }
      return;
  }
}
