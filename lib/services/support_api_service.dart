import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'auth_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

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
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
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
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
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

class SupportApiService {
  SupportApiService._();

  static String get _base => '${AppConfig.backendBaseUrl}/mobile/v1/support';

  static Map<String, String> _headers() {
    final auth = authStateNotifier.value;
    return {
      'Content-Type': 'application/json',
      if (auth.telegramId != null) 'X-Telegram-Id': auth.telegramId.toString(),
    };
  }

  /// GET /mobile/v1/support/tickets
  static Future<List<SupportTicket>> getTickets() async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/tickets'), headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = body['tickets'] as List<dynamic>? ?? [];
        return list
            .map((t) => SupportTicket.fromJson(t as Map<String, dynamic>))
            .toList();
      }
      debugPrint('SupportApiService.getTickets: ${resp.statusCode}');
      return [];
    } on Exception catch (e) {
      debugPrint('SupportApiService.getTickets error: $e');
      return [];
    }
  }

  /// POST /mobile/v1/support/tickets
  static Future<SupportTicket?> createTicket({
    required String title,
    required String message,
    String? logs,
  }) async {
    try {
      final body = <String, dynamic>{'title': title, 'message': message};
      if (logs != null && logs.isNotEmpty) body['logs'] = logs;
      final resp = await http
          .post(
        Uri.parse('$_base/tickets'),
        headers: _headers(),
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 201) {
        return SupportTicket.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      debugPrint('SupportApiService.createTicket: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SupportApiService.createTicket error: $e');
      return null;
    }
  }

  /// GET /mobile/v1/support/tickets/{id}
  static Future<SupportTicketDetail?> getTicket(int ticketId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/tickets/$ticketId'), headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        return SupportTicketDetail.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      debugPrint('SupportApiService.getTicket: ${resp.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('SupportApiService.getTicket error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/support/tickets/{id}/messages
  static Future<SupportTicketMessage?> replyToTicket({
    required int ticketId,
    required String message,
  }) async {
    try {
      final resp = await http
          .post(
        Uri.parse('$_base/tickets/$ticketId/messages'),
        headers: _headers(),
        body: jsonEncode({'message': message}),
      )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 201) {
        return SupportTicketMessage.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      debugPrint('SupportApiService.replyToTicket: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SupportApiService.replyToTicket error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/support/tickets/{id}/close
  static Future<SupportTicket?> closeTicket(int ticketId) async {
    try {
      final resp = await http
          .post(
        Uri.parse('$_base/tickets/$ticketId/close'),
        headers: _headers(),
        body: '{}',
      )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        return SupportTicket.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>);
      }
      debugPrint('SupportApiService.closeTicket: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SupportApiService.closeTicket error: $e');
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