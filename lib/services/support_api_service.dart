import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_logger.dart';
import 'auth_state.dart';
import 'cabinet_http.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a backend timestamp into epoch seconds.
/// Mobile API ships epoch ints; Cabinet API ships ISO-8601 strings.
int _parseTimestamp(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  if (v is String) {
    final dt = DateTime.tryParse(v);
    if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
  }
  return 0;
}

class SupportTicket {
  final int id;
  final String title;
  final String status;
  final String priority;
  final int createdAt;
  final int updatedAt;

  const SupportTicket({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SupportTicket.fromJson(Map<String, dynamic> j) => SupportTicket(
    id: j['id'] as int,
    title: j['title'] as String? ?? '',
    status: j['status'] as String? ?? 'open',
    priority: j['priority'] as String? ?? 'normal',
    createdAt: _parseTimestamp(j['created_at']),
    updatedAt: _parseTimestamp(j['updated_at']),
  );

  String get statusLabel {
    switch (status) {
      case 'answered': return '🟡 Ответ получен';
      case 'closed':   return '🟢 Закрыт';
      case 'pending':  return '⏳ Ожидает';
      default:         return '🔴 Открыт';
    }
  }
}

class SupportTicketMessage {
  final int id;
  final String messageText;
  final bool isFromAdmin;
  final int createdAt;
  final bool hasMedia;
  final String? mediaType;

  const SupportTicketMessage({
    required this.id,
    required this.messageText,
    required this.isFromAdmin,
    required this.createdAt,
    this.hasMedia = false,
    this.mediaType,
  });

  factory SupportTicketMessage.fromJson(Map<String, dynamic> j) =>
      SupportTicketMessage(
        id: j['id'] as int,
        messageText: j['message_text'] as String? ?? '',
        isFromAdmin: j['is_from_admin'] as bool? ?? false,
        createdAt: _parseTimestamp(j['created_at']),
        hasMedia: j['has_media'] as bool? ?? false,
        mediaType: j['media_type'] as String?,
      );
}

class SupportTicketDetail extends SupportTicket {
  final List<SupportTicketMessage> messages;

  const SupportTicketDetail({
    required super.id,
    required super.title,
    required super.status,
    required super.priority,
    required super.createdAt,
    required super.updatedAt,
    required this.messages,
  });

  factory SupportTicketDetail.fromJson(Map<String, dynamic> j) {
    final base = SupportTicket.fromJson(j);
    final msgs = (j['messages'] as List<dynamic>? ?? [])
        .map((m) => SupportTicketMessage.fromJson(m as Map<String, dynamic>))
        .toList();
    return SupportTicketDetail(
      id: base.id,
      title: base.title,
      status: base.status,
      priority: base.priority,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
      messages: msgs,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Support tickets API.
///
/// Primary path: Cabinet endpoints (`/cabinet/tickets`) with Bearer JWT —
/// works for every auth method (Telegram, email, Google) since all of them
/// now receive a cabinet token pair on login. Legacy sessions without a JWT
/// fall back to the Mobile API (`/mobile/v1/support`, X-Telegram-Id header).
class SupportApiService {
  SupportApiService._();

  static String get _mobileBase => '${AppConfig.backendBaseUrl}/mobile/v1/support';

  static bool get _hasJwt =>
      authStateNotifier.value.cabinetAccessToken?.isNotEmpty ?? false;

  static Map<String, String> _mobileHeaders() {
    final auth = authStateNotifier.value;
    return {
      'Content-Type': 'application/json',
      if (auth.telegramId != null) 'X-Telegram-Id': auth.telegramId.toString(),
    };
  }

  // ── List ──────────────────────────────────────────────────────────────────

  static Future<List<SupportTicket>> getTickets() async {
    try {
      final http.Response? resp;
      if (_hasJwt) {
        resp = await CabinetHttp.get('/cabinet/tickets?page=1&per_page=100');
      } else {
        resp = await http
            .get(Uri.parse('$_mobileBase/tickets'), headers: _mobileHeaders())
            .timeout(const Duration(seconds: 15));
      }
      if (resp == null) return [];
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        // Cabinet wraps the list in `items`, Mobile API in `tickets`.
        final list = (body['items'] ?? body['tickets']) as List<dynamic>? ?? [];
        return list
            .map((t) => SupportTicket.fromJson(t as Map<String, dynamic>))
            .toList();
      }
      appLogger.warning('SupportApi', 'getTickets: HTTP ${resp.statusCode}');
      return [];
    } on Exception catch (e) {
      appLogger.error('SupportApi', 'getTickets: $e');
      return [];
    }
  }

  // ── Create ────────────────────────────────────────────────────────────────

  static Future<SupportTicket?> createTicket({
    required String title,
    required String message,
    String? logs,
  }) async {
    try {
      final http.Response? resp;
      if (_hasJwt) {
        // Cabinet schema has no separate `logs` field — append them to the
        // message body within its 4000-char limit.
        var text = message;
        if (logs != null && logs.isNotEmpty) {
          final budget = 4000 - text.length - 20;
          if (budget > 100) {
            final tail = logs.length > budget
                ? logs.substring(logs.length - budget)
                : logs;
            text = '$text\n\n--- Логи ---\n$tail';
          }
        }
        resp = await CabinetHttp.post('/cabinet/tickets',
            body: {'title': title, 'message': text});
      } else {
        final body = <String, dynamic>{'title': title, 'message': message};
        if (logs != null && logs.isNotEmpty) body['logs'] = logs;
        resp = await http
            .post(Uri.parse('$_mobileBase/tickets'),
                headers: _mobileHeaders(), body: jsonEncode(body))
            .timeout(const Duration(seconds: 15));
      }
      if (resp == null) return null;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return SupportTicket.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      appLogger.warning(
          'SupportApi', 'createTicket: HTTP ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      appLogger.error('SupportApi', 'createTicket: $e');
      return null;
    }
  }

  // ── Detail ────────────────────────────────────────────────────────────────

  static Future<SupportTicketDetail?> getTicket(int ticketId) async {
    try {
      final http.Response? resp;
      if (_hasJwt) {
        resp = await CabinetHttp.get('/cabinet/tickets/$ticketId');
      } else {
        resp = await http
            .get(Uri.parse('$_mobileBase/tickets/$ticketId'),
                headers: _mobileHeaders())
            .timeout(const Duration(seconds: 15));
      }
      if (resp == null) return null;
      if (resp.statusCode == 200) {
        return SupportTicketDetail.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      appLogger.warning('SupportApi', 'getTicket: HTTP ${resp.statusCode}');
      return null;
    } on Exception catch (e) {
      appLogger.error('SupportApi', 'getTicket: $e');
      return null;
    }
  }

  // ── Reply ─────────────────────────────────────────────────────────────────

  static Future<SupportTicketMessage?> replyToTicket({
    required int ticketId,
    required String message,
  }) async {
    try {
      final http.Response? resp;
      if (_hasJwt) {
        resp = await CabinetHttp.post('/cabinet/tickets/$ticketId/messages',
            body: {'message': message});
      } else {
        resp = await http
            .post(Uri.parse('$_mobileBase/tickets/$ticketId/messages'),
                headers: _mobileHeaders(),
                body: jsonEncode({'message': message}))
            .timeout(const Duration(seconds: 15));
      }
      if (resp == null) return null;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return SupportTicketMessage.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      appLogger.warning(
          'SupportApi', 'replyToTicket: HTTP ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      appLogger.error('SupportApi', 'replyToTicket: $e');
      return null;
    }
  }

  // ── Close ─────────────────────────────────────────────────────────────────

  static Future<SupportTicket?> closeTicket(int ticketId) async {
    try {
      final http.Response? resp;
      if (_hasJwt) {
        resp = await CabinetHttp.post('/cabinet/tickets/$ticketId/close');
      } else {
        resp = await http
            .post(Uri.parse('$_mobileBase/tickets/$ticketId/close'),
                headers: _mobileHeaders(), body: '{}')
            .timeout(const Duration(seconds: 15));
      }
      if (resp == null) return null;
      if (resp.statusCode == 200) {
        return SupportTicket.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      appLogger.warning(
          'SupportApi', 'closeTicket: HTTP ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      appLogger.error('SupportApi', 'closeTicket: $e');
      return null;
    }
  }

  /// Decode a backend error response to a user-friendly string.
  static String errorFromResponse(String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      return j['detail'] as String? ?? 'Ошибка сервера';
    } catch (_) {
      return 'Ошибка сервера';
    }
  }
}
