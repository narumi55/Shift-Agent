import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/schedule_models.dart';

class ApiClient {
  ApiClient({this.baseUrl = AppConfig.apiBaseUrl});

  final String baseUrl;

  Future<Map<String, dynamic>> health() async {
    final uri = Uri.parse('$baseUrl/health');
    final res = await http.get(uri);
    if (res.statusCode >= 400) {
      throw Exception('Health error ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<CalendarEventInfo>> calendarEvents({
    required DateTime timeMin,
    required DateTime timeMax,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/events');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'time_min': timeMin.toIso8601String(),
        'time_max': timeMax.toIso8601String(),
        'timezone': timezone,
        'mock': false,
        'include_titles': true,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar read error ${res.statusCode}: ${res.body}');
    }
    return (jsonDecode(res.body) as List<dynamic>)
        .map((e) => CalendarEventInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AssistantChatResult> assistantChat({
    required String message,
    required List<CalendarEventInfo> calendarEvents,
    required List<AssistantRule> rules,
    required List<ChatBubble> history,
    String timezone = AppConfig.timezone,
    String? googleAuthHeader,
  }) async {
    final uri = Uri.parse('$baseUrl/agent/chat');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'timezone': timezone,
        'now': DateTime.now().toIso8601String(),
        'mock': false,
        'google_auth_header': googleAuthHeader,
        'calendar_events': calendarEvents.map((e) => e.toJson()).toList(),
        'rules': rules.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Assistant error ${res.statusCode}: ${res.body}');
    }
    return AssistantChatResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> insertEvent({
    required ScheduledItem item,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/insert');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(item.toInsertJson(
        timezone: timezone,
        mock: false,
        googleAuthHeader: googleAuthHeader,
      )),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar insert error ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> insertManualEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    String? notes,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/insert');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'timezone': timezone,
        'notes': notes,
        'mock': false,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar insert error ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> updateEvent({
    required String eventId,
    String? title,
    DateTime? start,
    DateTime? end,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    String? notes,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/update');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'event_id': eventId,
        'title': title,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'timezone': timezone,
        'notes': notes,
        'mock': false,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar update error ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> deleteEvent({
    required String eventId,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/delete');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'event_id': eventId,
        'timezone': timezone,
        'mock': false,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar delete error ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> applyAction({
    required ProposedAction action,
    required String googleAuthHeader,
    String timezone = AppConfig.timezone,
  }) async {
    if (action.isCreate) {
      final item = action.toScheduledItem();
      if (item == null) throw Exception('追加候補の開始/終了時刻が不足しています。');
      await insertEvent(item: item, googleAuthHeader: googleAuthHeader, timezone: timezone);
      return;
    }
    if (action.isUpdate) {
      final eventId = action.targetEventId;
      if (eventId == null || eventId.isEmpty) throw Exception('変更対象のGoogle予定IDがありません。');
      await updateEvent(
        eventId: eventId,
        title: action.proposedTitle,
        start: action.proposedStart,
        end: action.proposedEnd,
        notes: action.reason,
        googleAuthHeader: googleAuthHeader,
        timezone: timezone,
      );
      return;
    }
    if (action.isDelete) {
      final eventId = action.targetEventId;
      if (eventId == null || eventId.isEmpty) throw Exception('削除対象のGoogle予定IDがありません。');
      await deleteEvent(eventId: eventId, googleAuthHeader: googleAuthHeader, timezone: timezone);
      return;
    }
    throw Exception('未対応の操作です: ${action.actionType}');
  }

  Future<void> recordDecision({
    String? proposalId,
    required String userAction,
    required List<ScheduledItem> acceptedEvents,
    required List<ScheduledItem> rejectedEvents,
    List<ProposedAction> acceptedActions = const [],
    List<ProposedAction> rejectedActions = const [],
    required String googleAuthHeader,
    String? feedback,
  }) async {
    final uri = Uri.parse('$baseUrl/agent/decision');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'proposal_id': proposalId,
        'user_action': userAction,
        'accepted_events': acceptedEvents.map((e) => e.toJson()).toList(),
        'rejected_events': rejectedEvents.map((e) => e.toJson()).toList(),
        'accepted_actions': acceptedActions.map((e) => e.toJson()).toList(),
        'rejected_actions': rejectedActions.map((e) => e.toJson()).toList(),
        'feedback': feedback,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Decision log error ${res.statusCode}: ${res.body}');
    }
  }
}
