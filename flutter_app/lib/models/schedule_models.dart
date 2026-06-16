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
    this.targetEtag,
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
  final String? targetEtag;
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
      targetEtag: json['target_etag'] as String?,
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
        'target_etag': targetEtag,
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
    this.calendarId = 'primary',
    required this.title,
    this.rawTitle,
    this.normalizedTitle,
    required this.start,
    required this.end,
    required this.source,
    this.location,
    this.htmlLink,
    this.etag,
    this.isAllDay = false,
    this.scheduleType = 'fixed',
    this.category = 'other',
    this.movable = false,
    this.canCancel = false,
    this.canShorten = false,
    this.confidence = 0.7,
    this.inferredBy = 'flutter_cache',
  });

  final String? id;
  final String calendarId;
  final String title;
  final String? rawTitle;
  final String? normalizedTitle;
  final DateTime start;
  final DateTime end;
  final String source;
  final String? location;
  final String? htmlLink;
  final String? etag;
  final bool isAllDay;
  final String scheduleType;
  final String category;
  final bool movable;
  final bool canCancel;
  final bool canShorten;
  final double confidence;
  final String inferredBy;

  factory CalendarEventInfo.fromJson(Map<String, dynamic> json) {
    return CalendarEventInfo(
      id: json['id'] as String?,
      calendarId: json['calendar_id'] as String? ?? 'primary',
      title: json['title'] as String? ?? '予定あり',
      rawTitle: json['raw_title'] as String?,
      normalizedTitle: json['normalized_title'] as String?,
      start: DateTime.parse(json['start'] as String),
      end: DateTime.parse(json['end'] as String),
      source: json['source'] as String? ?? 'google_calendar',
      location: json['location'] as String?,
      htmlLink: json['html_link'] as String?,
      etag: json['etag'] as String?,
      isAllDay: json['is_all_day'] as bool? ?? false,
      scheduleType: json['schedule_type'] as String? ?? 'fixed',
      category: json['category'] as String? ?? 'other',
      movable: json['movable'] as bool? ?? false,
      canCancel: json['can_cancel'] as bool? ?? false,
      canShorten: json['can_shorten'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.7,
      inferredBy: json['inferred_by'] as String? ?? 'flutter_cache',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'calendar_id': calendarId,
        'title': title,
        'raw_title': rawTitle ?? title,
        'normalized_title': normalizedTitle ?? title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'source': source,
        'location': location,
        'html_link': htmlLink,
        'etag': etag,
        'is_all_day': isAllDay,
        'schedule_type': scheduleType,
        'category': category,
        'movable': movable,
        'can_cancel': canCancel,
        'can_shorten': canShorten,
        'confidence': confidence,
        'inferred_by': inferredBy,
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
    this.needsCalendarRefresh = false,
    this.calendarRefreshReason,
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
  final bool needsCalendarRefresh;
  final String? calendarRefreshReason;
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
      needsCalendarRefresh: json['needs_calendar_refresh'] as bool? ?? false,
      calendarRefreshReason: json['calendar_refresh_reason'] as String?,
      memoryCount: json['memory_count'] as int? ?? 0,
      relevantMemoryCount: json['relevant_memory_count'] as int? ?? 0,
      profileSummary: json['profile_summary'] as String?,
    );
  }
}


class CalendarExecuteResult {
  CalendarExecuteResult({
    required this.ok,
    required this.refreshed,
    required this.applied,
    required this.rejected,
    required this.cacheUpserts,
    required this.cacheDeletes,
    required this.warnings,
    this.proposalId,
  });

  final bool ok;
  final bool refreshed;
  final List<Map<String, dynamic>> applied;
  final List<Map<String, dynamic>> rejected;
  final List<CalendarEventInfo> cacheUpserts;
  final List<String> cacheDeletes;
  final List<String> warnings;
  final String? proposalId;

  factory CalendarExecuteResult.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> maps(String key) =>
        (json[key] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return CalendarExecuteResult(
      ok: json['ok'] as bool? ?? false,
      refreshed: json['refreshed'] as bool? ?? false,
      applied: maps('applied'),
      rejected: maps('rejected'),
      cacheUpserts: (json['cache_upserts'] as List<dynamic>? ?? [])
          .map((e) => CalendarEventInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      cacheDeletes: (json['cache_deletes'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      warnings: (json['warnings'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      proposalId: json['proposal_id'] as String?,
    );
  }
}

class UserProfileRule {
  UserProfileRule({
    this.id,
    required this.key,
    required this.text,
    this.category = 'general',
    this.strength = 'soft',
    this.usage = 'always',
    this.source = 'user',
    this.confidence = 0.8,
    this.evidence,
    this.isActive = true,
  });

  final String? id;
  final String key;
  final String text;
  final String category;
  final String strength;
  final String usage;
  final String source;
  final double confidence;
  final String? evidence;
  final bool isActive;

  factory UserProfileRule.fromJson(Map<String, dynamic> json) {
    return UserProfileRule(
      id: json['id'] as String?,
      key: json['key'] as String? ?? 'rule',
      text: json['text'] as String? ?? '',
      category: json['category'] as String? ?? 'general',
      strength: json['strength'] as String? ?? 'soft',
      usage: json['usage'] as String? ?? 'always',
      source: json['source'] as String? ?? 'user',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
      evidence: json['evidence'] as String?,
      isActive: json['is_active'] as bool? ?? true,
    );
  }
}

class CurrentUserStateInfo {
  CurrentUserStateInfo({
    this.loadLevel = 3,
    this.planningMode = 'balance',
    this.energyLevel = 3,
    this.note,
    this.updatedAt,
  });

  final int loadLevel;
  final String planningMode;
  final int energyLevel;
  final String? note;
  final DateTime? updatedAt;

  factory CurrentUserStateInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) => value == null ? null : DateTime.tryParse(value.toString());
    return CurrentUserStateInfo(
      loadLevel: json['load_level'] as int? ?? 3,
      planningMode: json['planning_mode'] as String? ?? 'balance',
      energyLevel: json['energy_level'] as int? ?? 3,
      note: json['note'] as String?,
      updatedAt: parseDate(json['updated_at']),
    );
  }
}

class ProfileReviewChoiceInfo {
  ProfileReviewChoiceInfo({
    required this.id,
    required this.label,
    required this.resultAction,
    this.strength,
    this.usage,
    this.loadLevel,
    this.planningMode,
    this.energyLevel,
  });

  final String id;
  final String label;
  final String resultAction;
  final String? strength;
  final String? usage;
  final int? loadLevel;
  final String? planningMode;
  final int? energyLevel;

  factory ProfileReviewChoiceInfo.fromJson(Map<String, dynamic> json) {
    return ProfileReviewChoiceInfo(
      id: json['id'] as String? ?? 'choice',
      label: json['label'] as String? ?? '選択',
      resultAction: json['result_action'] as String? ?? 'skip',
      strength: json['strength'] as String?,
      usage: json['usage'] as String?,
      loadLevel: json['load_level'] as int?,
      planningMode: json['planning_mode'] as String?,
      energyLevel: json['energy_level'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'result_action': resultAction,
        'strength': strength,
        'usage': usage,
        'load_level': loadLevel,
        'planning_mode': planningMode,
        'energy_level': energyLevel,
      };
}

class ProfileReviewItemInfo {
  ProfileReviewItemInfo({
    this.id,
    required this.title,
    this.hypothesis,
    required this.questionText,
    this.source = 'calendar_analysis',
    this.evidence,
    this.confidence = 0.7,
    this.targetType = 'rule',
    this.targetAction = 'create',
    this.targetRuleId,
    this.suggestedRuleKey,
    this.suggestedRuleText,
    this.suggestedStrength = 'soft',
    this.suggestedUsage = 'always',
    this.choices = const [],
    this.status = 'pending',
  });

  final String? id;
  final String title;
  final String? hypothesis;
  final String questionText;
  final String source;
  final String? evidence;
  final double confidence;
  final String targetType;
  final String targetAction;
  final String? targetRuleId;
  final String? suggestedRuleKey;
  final String? suggestedRuleText;
  final String? suggestedStrength;
  final String? suggestedUsage;
  final List<ProfileReviewChoiceInfo> choices;
  final String status;

  factory ProfileReviewItemInfo.fromJson(Map<String, dynamic> json) {
    return ProfileReviewItemInfo(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'プロフィール確認',
      hypothesis: json['hypothesis'] as String?,
      questionText: json['question_text'] as String? ?? '',
      source: json['source'] as String? ?? 'calendar_analysis',
      evidence: json['evidence'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.7,
      targetType: json['target_type'] as String? ?? 'rule',
      targetAction: json['target_action'] as String? ?? 'create',
      targetRuleId: json['target_rule_id'] as String?,
      suggestedRuleKey: json['suggested_rule_key'] as String?,
      suggestedRuleText: json['suggested_rule_text'] as String?,
      suggestedStrength: json['suggested_strength'] as String?,
      suggestedUsage: json['suggested_usage'] as String?,
      choices: (json['choices'] as List<dynamic>? ?? [])
          .map((e) => ProfileReviewChoiceInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      status: json['status'] as String? ?? 'pending',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'hypothesis': hypothesis,
        'question_text': questionText,
        'source': source,
        'evidence': evidence,
        'confidence': confidence,
        'target_type': targetType,
        'target_action': targetAction,
        'target_rule_id': targetRuleId,
        'suggested_rule_key': suggestedRuleKey,
        'suggested_rule_text': suggestedRuleText,
        'suggested_strength': suggestedStrength,
        'suggested_usage': suggestedUsage,
        'choices': choices.map((e) => e.toJson()).toList(),
        'status': status,
      };
}

class ProfileStateResult {
  ProfileStateResult({
    required this.userId,
    required this.profile,
    required this.rules,
    required this.memories,
    required this.currentUserState,
    required this.reviewItems,
  });

  final String userId;
  final Map<String, dynamic> profile;
  final List<UserProfileRule> rules;
  final List<Map<String, dynamic>> memories;
  final CurrentUserStateInfo currentUserState;
  final List<ProfileReviewItemInfo> reviewItems;

  factory ProfileStateResult.fromJson(Map<String, dynamic> json) {
    return ProfileStateResult(
      userId: json['user_id'] as String? ?? '',
      profile: Map<String, dynamic>.from(json['profile'] as Map? ?? const {}),
      rules: (json['rules'] as List<dynamic>? ?? [])
          .map((e) => UserProfileRule.fromJson(e as Map<String, dynamic>))
          .toList(),
      memories: (json['memories'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      currentUserState: CurrentUserStateInfo.fromJson(
        Map<String, dynamic>.from(json['current_user_state'] as Map? ?? const {}),
      ),
      reviewItems: (json['review_items'] as List<dynamic>? ?? [])
          .map((e) => ProfileReviewItemInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ProfileAnalysisResult {
  ProfileAnalysisResult({required this.ok, required this.message, required this.reviewItems});

  final bool ok;
  final String message;
  final List<ProfileReviewItemInfo> reviewItems;

  factory ProfileAnalysisResult.fromJson(Map<String, dynamic> json) {
    return ProfileAnalysisResult(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      reviewItems: (json['review_items'] as List<dynamic>? ?? [])
          .map((e) => ProfileReviewItemInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
