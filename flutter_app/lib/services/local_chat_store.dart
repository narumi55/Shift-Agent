import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/schedule_models.dart';

class LocalChatStore {
  static const String _historyKey = 'ai_chat_history_v1';
  static const String _suggestionsKey = 'ai_chat_suggestions_v1';
  static const String _updatedAtKey = 'ai_chat_updated_at_v1';

  Future<void> save({
    required List<ChatBubble> history,
    required List<ScheduledItem> suggestions,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(
      _suggestionsKey,
      jsonEncode(suggestions.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(_updatedAtKey, DateTime.now().toIso8601String());
  }

  Future<StoredChatLog?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final historyRaw = prefs.getString(_historyKey);
    if (historyRaw == null || historyRaw.isEmpty) return null;

    final historyJson = jsonDecode(historyRaw) as List<dynamic>;
    final history = historyJson
        .map((e) => ChatBubble.fromJson(e as Map<String, dynamic>))
        .toList();

    final suggestionsRaw = prefs.getString(_suggestionsKey);
    final suggestions = suggestionsRaw == null || suggestionsRaw.isEmpty
        ? <ScheduledItem>[]
        : (jsonDecode(suggestionsRaw) as List<dynamic>)
            .map((e) => ScheduledItem.fromJson(e as Map<String, dynamic>))
            .toList();

    final updatedAtRaw = prefs.getString(_updatedAtKey);
    final updatedAt = updatedAtRaw == null ? null : DateTime.tryParse(updatedAtRaw);

    return StoredChatLog(
      history: history,
      suggestions: suggestions,
      updatedAt: updatedAt,
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    await prefs.remove(_suggestionsKey);
    await prefs.remove(_updatedAtKey);
  }
}

class StoredChatLog {
  StoredChatLog({
    required this.history,
    required this.suggestions,
    required this.updatedAt,
  });

  final List<ChatBubble> history;
  final List<ScheduledItem> suggestions;
  final DateTime? updatedAt;
}
