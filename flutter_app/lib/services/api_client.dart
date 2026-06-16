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
    DateTime? calendarCacheSyncedAt,
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
        'calendar_cache_synced_at': calendarCacheSyncedAt?.toIso8601String(),
        'rules': rules.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Assistant error ${res.statusCode}: ${res.body}');
    }
    return AssistantChatResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<CalendarExecuteResult> executeCalendarActions({
    required List<ProposedAction> actions,
    required String googleAuthHeader,
    required List<CalendarEventInfo> cachedEvents,
    DateTime? calendarCacheSyncedAt,
    String timezone = AppConfig.timezone,
    String refreshPolicy = 'if_stale_or_risky',
    String source = 'ai',
    String? proposalId,
  }) async {
    final uri = Uri.parse('$baseUrl/calendar/execute');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'timezone': timezone,
        'actions': actions.map((e) => e.toJson()).toList(),
        'cached_events': cachedEvents.map((e) => e.toJson()).toList(),
        'calendar_cache_synced_at': calendarCacheSyncedAt?.toIso8601String(),
        'refresh_policy': refreshPolicy,
        'proposal_id': proposalId,
        'source': source,
        'mock': false,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Calendar execute error ${res.statusCode}: ${res.body}');
    }
    return CalendarExecuteResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void _throwIfExecutionRejected(CalendarExecuteResult result) {
    if (!result.ok || result.rejected.isNotEmpty) {
      final rejected = result.rejected.map((e) => e['rejection_reason'] ?? e['title'] ?? e.toString()).join('\n');
      final warnings = result.warnings.join('\n');
      throw Exception([rejected, warnings].where((e) => e.trim().isNotEmpty).join('\n'));
    }
  }

  Future<CalendarEventInfo?> insertEvent({
    required ScheduledItem item,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    List<CalendarEventInfo> cachedEvents = const [],
    DateTime? calendarCacheSyncedAt,
  }) async {
    final action = ProposedAction(
      actionType: 'create_event',
      title: item.title,
      start: item.start,
      end: item.end,
      priority: item.priority,
      kind: item.kind,
      notes: item.notes,
      reason: item.reason,
    );
    final result = await executeCalendarActions(
      actions: [action],
      googleAuthHeader: googleAuthHeader,
      cachedEvents: cachedEvents,
      calendarCacheSyncedAt: calendarCacheSyncedAt,
      timezone: timezone,
      source: 'ai',
    );
    _throwIfExecutionRejected(result);
    return result.cacheUpserts.isEmpty ? null : result.cacheUpserts.first;
  }

  Future<CalendarEventInfo?> insertManualEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    String? notes,
    List<CalendarEventInfo> cachedEvents = const [],
    DateTime? calendarCacheSyncedAt,
    String source = 'manual',
  }) async {
    final result = await executeCalendarActions(
      actions: [
        ProposedAction(
          actionType: 'create_event',
          title: title,
          start: start,
          end: end,
          notes: notes,
          reason: '手動操作で追加',
        )
      ],
      googleAuthHeader: googleAuthHeader,
      cachedEvents: cachedEvents,
      calendarCacheSyncedAt: calendarCacheSyncedAt,
      timezone: timezone,
      source: source,
    );
    _throwIfExecutionRejected(result);
    return result.cacheUpserts.isEmpty ? null : result.cacheUpserts.first;
  }

  Future<CalendarEventInfo?> updateEvent({
    required String eventId,
    String? title,
    DateTime? start,
    DateTime? end,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    String? notes,
    List<CalendarEventInfo> cachedEvents = const [],
    DateTime? calendarCacheSyncedAt,
    String source = 'manual',
    String? targetEtag,
  }) async {
    final result = await executeCalendarActions(
      actions: [
        ProposedAction(
          actionType: 'update_event',
          title: title ?? '予定変更',
          targetEventId: eventId,
          targetEtag: targetEtag,
          proposedTitle: title,
          proposedStart: start,
          proposedEnd: end,
          notes: notes,
          reason: '手動操作で変更',
        )
      ],
      googleAuthHeader: googleAuthHeader,
      cachedEvents: cachedEvents,
      calendarCacheSyncedAt: calendarCacheSyncedAt,
      timezone: timezone,
      source: source,
    );
    _throwIfExecutionRejected(result);
    return result.cacheUpserts.isEmpty ? null : result.cacheUpserts.first;
  }

  Future<void> deleteEvent({
    required String eventId,
    String timezone = AppConfig.timezone,
    required String googleAuthHeader,
    List<CalendarEventInfo> cachedEvents = const [],
    DateTime? calendarCacheSyncedAt,
    String source = 'swipe_delete',
    String? targetEtag,
  }) async {
    final result = await executeCalendarActions(
      actions: [
        ProposedAction(
          actionType: 'delete_event',
          title: '予定削除',
          targetEventId: eventId,
          targetEtag: targetEtag,
          reason: '手動操作で削除',
        )
      ],
      googleAuthHeader: googleAuthHeader,
      cachedEvents: cachedEvents,
      calendarCacheSyncedAt: calendarCacheSyncedAt,
      timezone: timezone,
      source: source,
    );
    _throwIfExecutionRejected(result);
  }

  Future<CalendarEventInfo?> applyAction({
    required ProposedAction action,
    required String googleAuthHeader,
    String timezone = AppConfig.timezone,
    List<CalendarEventInfo> cachedEvents = const [],
    DateTime? calendarCacheSyncedAt,
    String? proposalId,
  }) async {
    final result = await executeCalendarActions(
      actions: [action],
      googleAuthHeader: googleAuthHeader,
      cachedEvents: cachedEvents,
      calendarCacheSyncedAt: calendarCacheSyncedAt,
      timezone: timezone,
      source: 'ai',
      proposalId: proposalId,
    );
    _throwIfExecutionRejected(result);
    return result.cacheUpserts.isEmpty ? null : result.cacheUpserts.first;
  }



  Future<ProfileStateResult> profileState({String? googleAuthHeader}) async {
    final uri = Uri.parse('$baseUrl/profile/state').replace(
      queryParameters: googleAuthHeader == null || googleAuthHeader.isEmpty
          ? null
          : {'google_auth_header': googleAuthHeader},
    );
    final res = await http.get(uri);
    if (res.statusCode >= 400) {
      throw Exception('Profile state error ${res.statusCode}: ${res.body}');
    }
    return ProfileStateResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ProfileStateResult> saveInitialSurvey({
    required String googleAuthHeader,
    required String targetSleepTime,
    required String targetWakeTime,
    required String avoidHeavyWorkAfter,
    required int defaultBufferMinutes,
    required int mealDurationMinutes,
    required int bathDurationMinutes,
    required int sleepPrepMinutes,
    required String afterSchoolOrWorkPolicy,
    required String aiCanModifyExistingEvents,
    required bool uncertainEventsCanBeDeleted,
    required String defaultPlanningMode,
    String? freeText,
    String timezone = AppConfig.timezone,
  }) async {
    final uri = Uri.parse('$baseUrl/profile/initial-survey');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'timezone': timezone,
        'target_sleep_time': targetSleepTime,
        'target_wake_time': targetWakeTime,
        'avoid_heavy_work_after': avoidHeavyWorkAfter,
        'default_buffer_minutes': defaultBufferMinutes,
        'meal_duration_minutes': mealDurationMinutes,
        'bath_duration_minutes': bathDurationMinutes,
        'sleep_prep_minutes': sleepPrepMinutes,
        'after_school_or_work_policy': afterSchoolOrWorkPolicy,
        'ai_can_modify_existing_events': aiCanModifyExistingEvents,
        'uncertain_events_can_be_deleted': uncertainEventsCanBeDeleted,
        'default_planning_mode': defaultPlanningMode,
        'free_text': freeText,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Initial survey error ${res.statusCode}: ${res.body}');
    }
    return ProfileStateResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ProfileAnalysisResult> analyzeProfile({
    required String googleAuthHeader,
    required List<CalendarEventInfo> calendarEvents,
    DateTime? calendarCacheSyncedAt,
    String? freeText,
    String timezone = AppConfig.timezone,
  }) async {
    final uri = Uri.parse('$baseUrl/profile/analyze');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'timezone': timezone,
        'calendar_events': calendarEvents.map((e) => e.toJson()).toList(),
        'calendar_cache_synced_at': calendarCacheSyncedAt?.toIso8601String(),
        'free_text': freeText,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Profile analysis error ${res.statusCode}: ${res.body}');
    }
    return ProfileAnalysisResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ProfileStateResult?> answerProfileReview({
    required String googleAuthHeader,
    required ProfileReviewItemInfo reviewItem,
    required String choiceId,
    String? freeText,
  }) async {
    final uri = Uri.parse('$baseUrl/profile/review/answer');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'google_auth_header': googleAuthHeader,
        'review_item': reviewItem.toJson(),
        'choice_id': choiceId,
        'free_text': freeText,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Profile review answer error ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final state = decoded['profile_state'];
    return state == null ? null : ProfileStateResult.fromJson(state as Map<String, dynamic>);
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
