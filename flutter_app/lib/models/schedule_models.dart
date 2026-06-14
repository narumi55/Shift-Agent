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

class ProposedAction {
  ProposedAction({
    required this.actionType,
    required this.title,
    required this.reason,
    this.risk,
    this.requiresConfirmation = true,
    this.start,
    this.end,
    this.priority = 3,
    this.kind = 'task',
    this.notes,
    this.targetEventId,
    this.currentTitle,
    this.currentStart,
    this.currentEnd,
    this.proposedTitle,
    this.proposedStart,
    this.proposedEnd,
  });

  final String actionType;
  final String title;
  final String reason;
  final String? risk;
  final bool requiresConfirmation;

  final DateTime? start;
  final DateTime? end;
  final int priority;
  final String kind;
  final String? notes;

  final String? targetEventId;
  final String? currentTitle;
  final DateTime? currentStart;
  final DateTime? currentEnd;
  final String? proposedTitle;
  final DateTime? proposedStart;
  final DateTime? proposedEnd;

  bool get isCreate => actionType == 'create_event';
  bool get isUpdate => actionType == 'update_event';
  bool get isDelete => actionType == 'delete_event';

  factory ProposedAction.fromJson(Map<String, dynamic> json) {
    DateTime? parseNullable(dynamic v) => v == null ? null : DateTime.parse(v.toString());
    return ProposedAction(
      actionType: json['action_type'] as String? ?? 'create_event',
      title: json['title'] as String? ?? '予定',
      reason: json['reason'] as String? ?? '',
      risk: json['risk'] as String?,
      requiresConfirmation: json['requires_confirmation'] as bool? ?? true,
      start: parseNullable(json['start']),
      end: parseNullable(json['end']),
      priority: json['priority'] as int? ?? 3,
      kind: json['kind'] as String? ?? 'task',
      notes: json['notes'] as String?,
      targetEventId: json['target_event_id'] as String?,
      currentTitle: json['current_title'] as String?,
      currentStart: parseNullable(json['current_start']),
      currentEnd: parseNullable(json['current_end']),
      proposedTitle: json['proposed_title'] as String?,
      proposedStart: parseNullable(json['proposed_start']),
      proposedEnd: parseNullable(json['proposed_end']),
    );
  }

  Map<String, dynamic> toJson() => {
        'action_type': actionType,
        'title': title,
        'reason': reason,
        'risk': risk,
        'requires_confirmation': requiresConfirmation,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'priority': priority,
        'kind': kind,
        'notes': notes,
        'target_event_id': targetEventId,
        'current_title': currentTitle,
        'current_start': currentStart?.toIso8601String(),
        'current_end': currentEnd?.toIso8601String(),
        'proposed_title': proposedTitle,
        'proposed_start': proposedStart?.toIso8601String(),
        'proposed_end': proposedEnd?.toIso8601String(),
      };

  ScheduledItem? toScheduledItem() {
    if (!isCreate || start == null || end == null) return null;
    return ScheduledItem(
      title: title,
      start: start!,
      end: end!,
      priority: priority,
      kind: kind,
      reason: reason,
      notes: notes,
    );
  }
}

class CalendarEventInfo {
  CalendarEventInfo({
    this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.source,
    this.location,
  });

  final String? id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String source;
  final String? location;

  factory CalendarEventInfo.fromJson(Map<String, dynamic> json) {
    return CalendarEventInfo(
      id: json['id'] as String?,
      title: json['title'] as String? ?? '予定あり',
      start: DateTime.parse(json['start'] as String),
      end: DateTime.parse(json['end'] as String),
      source: json['source'] as String? ?? 'google_calendar',
      location: json['location'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'source': source,
        'location': location,
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
    required this.proposedActions,
    required this.warnings,
    required this.calendarVisible,
    required this.rulesApplied,
    this.proposalId,
    this.memoryCount = 0,
    this.relevantMemoryCount = 0,
    this.profileSummary,
  });

  final String reply;
  final List<ScheduledItem> suggestedEvents;
  final List<ProposedAction> proposedActions;
  final List<String> warnings;
  final bool calendarVisible;
  final List<String> rulesApplied;
  final String? proposalId;
  final int memoryCount;
  final int relevantMemoryCount;
  final String? profileSummary;

  factory AssistantChatResult.fromJson(Map<String, dynamic> json) {
    final suggested = (json['suggested_events'] as List<dynamic>? ?? [])
        .map((e) => ScheduledItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final actionsRaw = json['proposed_actions'] as List<dynamic>?;
    final actions = actionsRaw == null
        ? suggested.map((e) => ProposedAction(
              actionType: 'create_event',
              title: e.title,
              start: e.start,
              end: e.end,
              priority: e.priority,
              kind: e.kind,
              notes: e.notes,
              reason: e.reason,
            )).toList()
        : actionsRaw.map((e) => ProposedAction.fromJson(e as Map<String, dynamic>)).toList();
    return AssistantChatResult(
      reply: json['reply'] as String? ?? '',
      suggestedEvents: suggested,
      proposedActions: actions,
      warnings: (json['warnings'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      calendarVisible: json['calendar_visible'] as bool? ?? false,
      rulesApplied: (json['rules_applied'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      proposalId: json['proposal_id'] as String?,
      memoryCount: json['memory_count'] as int? ?? 0,
      relevantMemoryCount: json['relevant_memory_count'] as int? ?? 0,
      profileSummary: json['profile_summary'] as String?,
    );
  }
}
