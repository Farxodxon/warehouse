import 'dart:convert';
import 'dart:io';

/// Telegram'ga xabar yuborish uchun sof interfeys.
///
/// Sinovlarda bu interfeys soxta (fake) bilan almashtiriladi, shuning uchun
/// webhook va chiqim xabarlari tarmoqsiz tekshiriladi.
abstract class TelegramSender {
  Future<void> sendMessage(String chatId, String text);
}

/// Telegram API xatosi (xabar yuborilmadi). Xato matnida token BO'LMAYDI.
class TelegramSendException implements Exception {
  TelegramSendException(this.message);

  final String message;

  @override
  String toString() => 'TelegramSendException: $message';
}

/// Haqiqiy yuboruvchi: `https://api.telegram.org/bot<TOKEN>/sendMessage`.
///
/// - Oddiy matn yuboriladi (`parse_mode` YO'Q), chunki `210*170kg`
///   dagi `*` belgisi Markdown'ni buzadi.
/// - 5 soniya timeout (ulash va javob olish uchun).
/// - Hech qanday xato matnida token kirmaydi.
class HttpTelegramSender implements TelegramSender {
  HttpTelegramSender({
    required this.token,
    Duration timeout = const Duration(seconds: 5),
    HttpClient? client,
  })  : _timeout = timeout,
        _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
  }

  final String token;
  final Duration _timeout;
  final HttpClient _client;

  @override
  Future<void> sendMessage(String chatId, String text) async {
    final uri = Uri.parse('https://api.telegram.org/bot$token/sendMessage');
    try {
      final request = await _client.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'chat_id': chatId,
        'text': text,
      }));
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TelegramSendException('Telegram HTTP ${response.statusCode}');
      }
    } on TelegramSendException {
      rethrow;
    } catch (e) {
      // HttpClient xatolari URI (token bilan) ichida kelishi mumkin.
      throw TelegramSendException(sanitize(e.toString()));
    }
  }

  /// Tokenni olib tashlaydi: xato logga token'siz tushishi uchun.
  String sanitize(String value) =>
      token.isEmpty ? value : value.replaceAll(token, '[token]');
}
