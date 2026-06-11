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
}
