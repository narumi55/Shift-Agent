class ScheduledItem {
  ScheduledItem({
    required this.title,
    required this.start,
    required this.end,
    required this.priority,
    required this.kind,
    required this.reason,
    this.notes,
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final int priority;
  final String kind;
  final String reason;
  final String? notes;

  factory ScheduledItem.fromJson(Map<String, dynamic> json) {
    return ScheduledItem(
      title: json['title'] as String,
      start: DateTime.parse(json['start'] as String),
      end: DateTime.parse(json['end'] as String),
      priority: json['priority'] as int? ?? 3,
      kind: json['kind'] as String? ?? 'task',
      reason: json['reason'] as String? ?? '',
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'priority': priority,
        'kind': kind,
        'reason': reason,
        'notes': notes,
      };

  Map<String, dynamic> toInsertJson({
    required String timezone,
    required bool mock,
    String? googleAuthHeader,
  }) {
    return {
      'google_auth_header': googleAuthHeader,
      'title': title,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'timezone': timezone,
      'notes': notes ?? reason,
      'mock': mock,
    };
  }
}

class CalendarEventInfo {
  CalendarEventInfo({
    this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.source,
  });

  final String? id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String source;

  factory CalendarEventInfo.fromJson(Map<String, dynamic> json) {
    return CalendarEventInfo(
      id: json['id'] as String?,
      title: json['title'] as String? ?? '予定あり',
      start: DateTime.parse(json['start'] as String),
      end: DateTime.parse(json['end'] as String),
      source: json['source'] as String? ?? 'google_calendar',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'source': source,
      };
}

class SchedulePlan {
  SchedulePlan({
    required this.status,
    required this.items,
    required this.unscheduled,
    required this.message,
  });

  final String status;
  final List<ScheduledItem> items;
  final List<String> unscheduled;
  final String message;

  factory SchedulePlan.fromJson(Map<String, dynamic> json) {
    return SchedulePlan(
      status: json['status'] as String,
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => ScheduledItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      unscheduled: (json['unscheduled'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      message: json['message'] as String? ?? '',
    );
  }
}

class AssistantRule {
  AssistantRule({
    required this.id,
    required this.title,
    required this.detail,
    this.enabled = true,
  });

  final String id;
  final String title;
  final String detail;
  final bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'detail': detail,
        'enabled': enabled,
      };
}

class ChatBubble {
  ChatBubble({required this.role, required this.content});

  final String role;
  final String content;

  factory ChatBubble.fromJson(Map<String, dynamic> json) {
    return ChatBubble(
      role: json['role'] as String? ?? 'assistant',
      content: json['content'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
      };
}

class AssistantChatResult {
  AssistantChatResult({
    required this.reply,
    required this.suggestedEvents,
    required this.warnings,
    required this.calendarVisible,
    required this.rulesApplied,
  });

  final String reply;
  final List<ScheduledItem> suggestedEvents;
  final List<String> warnings;
  final bool calendarVisible;
  final List<String> rulesApplied;

  factory AssistantChatResult.fromJson(Map<String, dynamic> json) {
    return AssistantChatResult(
      reply: json['reply'] as String? ?? '',
      suggestedEvents: (json['suggested_events'] as List<dynamic>? ?? [])
          .map((e) => ScheduledItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      warnings: (json['warnings'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      calendarVisible: json['calendar_visible'] as bool? ?? false,
      rulesApplied: (json['rules_applied'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}
