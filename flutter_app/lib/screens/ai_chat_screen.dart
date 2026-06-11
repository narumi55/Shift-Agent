import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';
import '../services/local_chat_store.dart';

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({
    super.key,
    required this.api,
    required this.auth,
    required this.calendarEvents,
    required this.ensureCalendarLoaded,
    required this.refreshCalendar,
  });

  final ApiClient api;
  final GoogleAuthService auth;
  final List<CalendarEventInfo> calendarEvents;
  final Future<List<CalendarEventInfo>> Function() ensureCalendarLoaded;
  final Future<void> Function() refreshCalendar;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final LocalChatStore _chatStore = LocalChatStore();

  List<ChatBubble> _history = [
    ChatBubble(
      role: 'assistant',
      content: '今日の予定やタスクをそのまま文章で送ってください。固定ルールだけを使い、Googleカレンダーも確認しながら行動計画を作ります。追加できる予定があれば、確認後に入力できます。',
    ),
  ];

  List<ScheduledItem> _suggestedEvents = [];
  DateTime? _lastSavedAt;
  bool _sending = false;
  bool _adding = false;
  String? _message;

  String get _saveStatusText {
    if (_lastSavedAt == null) return '会話ログ未保存';
    return '会話ログ保存済み ${DateFormat('HH:mm').format(_lastSavedAt!.toLocal())}';
  }

  @override
  void initState() {
    super.initState();
    _restoreConversationLog();
  }

  Future<void> _restoreConversationLog() async {
    try {
      final stored = await _chatStore.load();
      if (!mounted || stored == null) return;
      setState(() {
        _history = stored.history.isEmpty ? _history : stored.history;
        _suggestedEvents = stored.suggestions;
        _lastSavedAt = stored.updatedAt;
        _message = stored.updatedAt == null
            ? '前回の会話ログを復元しました。'
            : '前回の会話ログを復元しました。最終保存: ${DateFormat('M/d HH:mm').format(stored.updatedAt!.toLocal())}';
      });
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '会話ログ復元エラー: $e');
    }
  }

  Future<void> _saveConversationLog() async {
    try {
      await _chatStore.save(history: _history, suggestions: _suggestedEvents);
      if (!mounted) return;
      setState(() => _lastSavedAt = DateTime.now());
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '会話ログ保存エラー: $e');
    }
  }

  Future<void> _clearConversationLog() async {
    await _chatStore.clear();
    if (!mounted) return;
    setState(() {
      _history = [
        ChatBubble(
          role: 'assistant',
          content: '会話ログを削除しました。今日の予定やタスクを送ってください。',
        ),
      ];
      _suggestedEvents = [];
      _lastSavedAt = null;
      _message = '保存済みの会話ログを削除しました。';
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _sending = true;
      _message = 'Googleカレンダーを確認してから、AIが計画を作成しています。';
      _history.add(ChatBubble(role: 'user', content: text));
      _messageController.clear();
    });
    _scrollToBottomSoon();
    await _saveConversationLog();

    try {
      final visibleEvents = await widget.ensureCalendarLoaded();
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null || header.isEmpty) {
        throw Exception('Google連携が完了していません。先にカレンダーページでGoogle連携してください。');
      }

      final result = await widget.api.assistantChat(
        message: text,
        calendarEvents: visibleEvents,
        rules: AppConfig.agentRules,
        history: _history,
        googleAuthHeader: header,
      );
      if (!mounted) return;

      final hasCandidates = result.suggestedEvents.isNotEmpty;
      final confirmText = hasCandidates
          ? '\n\n---\n\n以下の予定をGoogleカレンダーへ入力できます。内容を確認して、右側の「了解して入力」を押してください。AIだけでは自動追加しません。'
          : '';

      setState(() {
        _history.add(ChatBubble(role: 'assistant', content: result.reply + confirmText));
        _suggestedEvents = result.suggestedEvents;
        final notices = <String>[];
        if (hasCandidates) {
          notices.add('確認：${result.suggestedEvents.length}件の追加候補があります。問題なければ「了解して入力」を押してください。');
        }
        notices.addAll(result.warnings);
        _message = notices.isEmpty ? null : notices.join('\n');
      });
      await _saveConversationLog();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _history.add(ChatBubble(role: 'assistant', content: 'エラーが出ました。Google連携とバックエンド起動を確認してください。\n\n$e'));
        _message = 'AI対話エラー: $e';
      });
      await _saveConversationLog();
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottomSoon();
      }
    }
  }

  Future<void> _addSuggestedEvent(ScheduledItem item) async {
    setState(() {
      _adding = true;
      _message = null;
    });
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
      await widget.api.insertEvent(item: item, googleAuthHeader: header);
      await widget.refreshCalendar();
      if (!mounted) return;
      setState(() {
        _suggestedEvents.removeWhere(
          (e) => e.title == item.title && e.start.isAtSameMomentAs(item.start) && e.end.isAtSameMomentAs(item.end),
        );
        _history.add(ChatBubble(role: 'assistant', content: '了解しました。「${item.title}」をGoogleカレンダーに追加しました。'));
        _message = '「${item.title}」をGoogleカレンダーに追加しました。';
      });
      await _saveConversationLog();
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '追加エラー: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addAllSuggestedEvents() async {
    if (_suggestedEvents.isEmpty) return;
    final items = List<ScheduledItem>.from(_suggestedEvents);

    setState(() {
      _adding = true;
      _message = null;
    });
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
      for (final item in items) {
        await widget.api.insertEvent(item: item, googleAuthHeader: header);
      }
      await widget.refreshCalendar();
      if (!mounted) return;
      setState(() {
        _suggestedEvents = [];
        _history.add(ChatBubble(role: 'assistant', content: '了解しました。${items.length}件をGoogleカレンダーに追加しました。カレンダーページで確認できます。'));
        _message = '${items.length}件をGoogleカレンダーに追加しました。';
      });
      await _saveConversationLog();
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '一括追加エラー: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _clearSuggestions() async {
    setState(() {
      _suggestedEvents = [];
      _message = '追加候補を取り消しました。';
    });
    await _saveConversationLog();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI対話', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      widget.calendarEvents.isEmpty
                          ? '送信時にGoogleカレンダーを取得し、AIに渡します。'
                          : '${widget.calendarEvents.length}件のGoogleカレンダー予定をAIが参照できます。',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Text(_saveStatusText, style: theme.textTheme.bodySmall),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _sending ? null : _clearConversationLog,
                icon: const Icon(Icons.delete_outline),
                label: const Text('ログ削除'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _sending ? null : () async {
                  setState(() => _message = null);
                  try {
                    final events = await widget.ensureCalendarLoaded();
                    if (!mounted) return;
                    setState(() => _message = '${events.length}件のGoogleカレンダー予定をAIに渡せる状態です。');
                  } catch (e) {
                    if (!mounted) return;
                    setState(() => _message = 'カレンダー確認エラー: $e');
                  }
                },
                icon: const Icon(Icons.event_available),
                label: const Text('カレンダー確認'),
              ),
            ],
          ),
        ),
        if (_message != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(_message!),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final bubble = _history[index];
                    return _ChatMessageBubble(bubble: bubble);
                  },
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 420,
                child: _SuggestedEventsPanel(
                  items: _suggestedEvents,
                  adding: _adding,
                  onApproveAll: _addAllSuggestedEvents,
                  onApproveOne: _addSuggestedEvent,
                  onCancel: _clearSuggestions,
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    minLines: 2,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      hintText: '今日の日付、現在時刻、固定予定、変更可能な作業、未確定の予定をまとめて入力してください。AIが行動計画と追加候補を作ります。',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                  label: const Text('送信'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatMessageBubble extends StatelessWidget {
  const _ChatMessageBubble({required this.bubble});

  final ChatBubble bubble;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = bubble.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 820),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isUser ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(bubble.content),
      ),
    );
  }
}

class _SuggestedEventsPanel extends StatelessWidget {
  const _SuggestedEventsPanel({
    required this.items,
    required this.adding,
    required this.onApproveAll,
    required this.onApproveOne,
    required this.onCancel,
  });

  final List<ScheduledItem> items;
  final bool adding;
  final Future<void> Function() onApproveAll;
  final Future<void> Function(ScheduledItem item) onApproveOne;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('カレンダー入力の確認', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'AIが作った予定候補は、ここで確認してからGoogleカレンダーへ入力します。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (items.isNotEmpty)
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('確認メッセージ', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text('以下の${items.length}件をGoogleカレンダーに入力します。問題なければ「了解して入力」を押してください。'),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: adding ? null : onApproveAll,
                        icon: adding
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check_circle),
                        label: const Text('了解して入力'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: adding ? null : onCancel,
                        icon: const Icon(Icons.close),
                        label: const Text('今回は入力しない'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('まだ入力候補はありません。\nAIに予定を送ると、ここに確認が出ます。', textAlign: TextAlign.center))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(item.kind == 'shift' ? Icons.work_outline : Icons.task_alt, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(item.title, style: theme.textTheme.titleSmall)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${DateFormat('M/d HH:mm').format(item.start.toLocal())}〜${DateFormat('HH:mm').format(item.end.toLocal())}',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (item.reason.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(item.reason, style: theme.textTheme.bodySmall),
                              ],
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: OutlinedButton.icon(
                                  onPressed: adding ? null : () => onApproveOne(item),
                                  icon: const Icon(Icons.check),
                                  label: const Text('この予定だけ了解'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
