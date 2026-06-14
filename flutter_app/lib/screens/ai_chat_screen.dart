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
      content: '今日の予定やタスクを文章で送ってください。AIがGoogleカレンダー、Supabaseの記憶、OR-Toolsを使って、追加候補と既存予定の変更候補を作ります。実行前には必ず右側で確認できます。',
    ),
  ];

  List<ProposedAction> _proposedActions = [];
  DateTime? _lastSavedAt;
  bool _sending = false;
  bool _applying = false;
  String? _message;
  String? _currentProposalId;

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
        _proposedActions = stored.actions;
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
      await _chatStore.save(history: _history, actions: _proposedActions);
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
        ChatBubble(role: 'assistant', content: '会話ログを削除しました。今日の予定やタスクを送ってください。'),
      ];
      _proposedActions = [];
      _lastSavedAt = null;
      _message = '保存済みの会話ログを削除しました。';
      _currentProposalId = null;
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _sending = true;
      _message = 'Googleカレンダーと過去記憶を確認し、OR-Toolsで予定配置を計算しています。';
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

      final hasCandidates = result.proposedActions.isNotEmpty;
      final confirmText = hasCandidates
          ? '\n\n---\n\n右側に「新規追加」または「既存予定変更」の確認が出ています。問題なければ「了解して実行」を押してください。AIだけでは自動でカレンダーを変更しません。'
          : '';

      setState(() {
        _history.add(ChatBubble(role: 'assistant', content: result.reply + confirmText));
        _proposedActions = result.proposedActions;
        _currentProposalId = result.proposalId;
        final notices = <String>[];
        if (result.memoryCount > 0) notices.add('ユーザー理解メモリ: ${result.memoryCount}件を参照しました。');
        if (result.relevantMemoryCount > 0) notices.add('pgvector類似記憶: ${result.relevantMemoryCount}件を参照しました。');
        if (hasCandidates) {
          final creates = result.proposedActions.where((a) => a.isCreate).length;
          final updates = result.proposedActions.where((a) => a.isUpdate).length;
          final deletes = result.proposedActions.where((a) => a.isDelete).length;
          notices.add('確認：新規追加 $creates件 / 既存予定変更 $updates件 / 削除 $deletes件 の候補があります。');
        }
        notices.addAll(result.warnings);
        _message = notices.isEmpty ? null : notices.join('\n');
      });
      await _saveConversationLog();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _history.add(ChatBubble(role: 'assistant', content: 'エラーが出ました。Google連携、Supabase設定、バックエンド起動を確認してください。\n\n$e'));
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

  Future<void> _applyOneAction(ProposedAction action) async {
    setState(() {
      _applying = true;
      _message = null;
    });
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
      await widget.api.applyAction(action: action, googleAuthHeader: header);

      final rejected = _proposedActions.where((a) => a != action).toList();
      await widget.api.recordDecision(
        proposalId: _currentProposalId,
        userAction: rejected.isEmpty ? 'accepted' : 'partially_accepted',
        acceptedEvents: const [],
        rejectedEvents: const [],
        acceptedActions: [action],
        rejectedActions: rejected,
        googleAuthHeader: header,
      );
      await widget.refreshCalendar();
      if (!mounted) return;
      setState(() {
        _proposedActions.remove(action);
        final actionLabel = action.isDelete ? '削除' : action.isUpdate ? '変更' : '追加';
        _history.add(ChatBubble(role: 'assistant', content: '了解しました。「${action.title}」をGoogleカレンダーに$actionLabelしました。'));
        _message = '「${action.title}」をGoogleカレンダーに$actionLabelしました。';
      });
      await _saveConversationLog();
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '実行エラー: $e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _applyAllActions() async {
    if (_proposedActions.isEmpty) return;
    final actions = List<ProposedAction>.from(_proposedActions);
    setState(() {
      _applying = true;
      _message = null;
    });
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
      for (final action in actions) {
        await widget.api.applyAction(action: action, googleAuthHeader: header);
      }
      await widget.api.recordDecision(
        proposalId: _currentProposalId,
        userAction: 'accepted',
        acceptedEvents: const [],
        rejectedEvents: const [],
        acceptedActions: actions,
        rejectedActions: const [],
        googleAuthHeader: header,
      );
      await widget.refreshCalendar();
      if (!mounted) return;
      setState(() {
        _proposedActions = [];
        _currentProposalId = null;
        _history.add(ChatBubble(role: 'assistant', content: '了解しました。${actions.length}件のカレンダー操作を実行しました。カレンダーページで確認できます。'));
        _message = '${actions.length}件のカレンダー操作を実行しました。';
      });
      await _saveConversationLog();
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '一括実行エラー: $e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _clearSuggestions() async {
    final rejected = List<ProposedAction>.from(_proposedActions);
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header != null && header.isNotEmpty && rejected.isNotEmpty) {
        await widget.api.recordDecision(
          proposalId: _currentProposalId,
          userAction: 'rejected',
          acceptedEvents: const [],
          rejectedEvents: const [],
          acceptedActions: const [],
          rejectedActions: rejected,
          googleAuthHeader: header,
          feedback: '今回は実行しない',
        );
      }
    } catch (_) {}
    setState(() {
      _proposedActions = [];
      _currentProposalId = null;
      _message = '候補を取り消しました。';
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
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
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
                onPressed: _sending
                    ? null
                    : () async {
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
                  itemBuilder: (context, index) => _ChatMessageBubble(bubble: _history[index]),
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 460,
                child: _ProposedActionsPanel(
                  actions: _proposedActions,
                  applying: _applying,
                  onApproveAll: _applyAllActions,
                  onApproveOne: _applyOneAction,
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
                      hintText: '今日の日付、現在時刻、固定予定、変更可能な作業、未確定の予定をまとめて入力してください。AIが追加/変更候補を作ります。',
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

class _ProposedActionsPanel extends StatelessWidget {
  const _ProposedActionsPanel({
    required this.actions,
    required this.applying,
    required this.onApproveAll,
    required this.onApproveOne,
    required this.onCancel,
  });

  final List<ProposedAction> actions;
  final bool applying;
  final Future<void> Function() onApproveAll;
  final Future<void> Function(ProposedAction action) onApproveOne;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final createCount = actions.where((a) => a.isCreate).length;
    final updateCount = actions.where((a) => a.isUpdate).length;
    final deleteCount = actions.where((a) => a.isDelete).length;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('カレンダー操作の確認', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'AIが作った新規追加・既存予定変更・削除は、ここで確認してから実行します。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (actions.isNotEmpty)
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('確認メッセージ', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text('新規追加 $createCount件、既存予定変更 $updateCount件、削除 $deleteCount件を実行できます。問題なければ「了解して実行」を押してください。'),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: applying ? null : onApproveAll,
                        icon: applying
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check_circle),
                        label: const Text('了解して実行'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: applying ? null : onCancel,
                        icon: const Icon(Icons.close),
                        label: const Text('今回は実行しない'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: actions.isEmpty
                ? const Center(child: Text('まだ操作候補はありません。\nAIに予定を送ると、ここに確認が出ます。', textAlign: TextAlign.center))
                : ListView.separated(
                    itemCount: actions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _ActionCard(
                      action: actions[index],
                      applying: applying,
                      onApprove: onApproveOne,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action, required this.applying, required this.onApprove});

  final ProposedAction action;
  final bool applying;
  final Future<void> Function(ProposedAction action) onApprove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('M/d HH:mm');
    final tf = DateFormat('HH:mm');
    final icon = action.isDelete ? Icons.delete_outline : action.isUpdate ? Icons.edit_calendar : Icons.add_circle_outline;
    final label = action.isDelete ? '既存予定削除' : action.isUpdate ? '既存予定変更' : '新規追加';

    Widget timeBlock() {
      if (action.isCreate && action.start != null && action.end != null) {
        return Text('${df.format(action.start!.toLocal())}〜${tf.format(action.end!.toLocal())}', style: theme.textTheme.bodySmall);
      }
      if (action.isUpdate) {
        final before = action.currentStart != null && action.currentEnd != null
            ? '${df.format(action.currentStart!.toLocal())}〜${tf.format(action.currentEnd!.toLocal())} ${action.currentTitle ?? ''}'
            : action.currentTitle ?? '変更前不明';
        final after = action.proposedStart != null && action.proposedEnd != null
            ? '${df.format(action.proposedStart!.toLocal())}〜${tf.format(action.proposedEnd!.toLocal())} ${action.proposedTitle ?? ''}'
            : action.proposedTitle ?? '変更後不明';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('変更前: $before', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('変更後: $after', style: theme.textTheme.bodySmall),
          ],
        );
      }
      if (action.isDelete) {
        final target = action.currentStart != null && action.currentEnd != null
            ? '${df.format(action.currentStart!.toLocal())}〜${tf.format(action.currentEnd!.toLocal())} ${action.currentTitle ?? action.title}'
            : action.currentTitle ?? action.title;
        return Text('削除対象: $target', style: theme.textTheme.bodySmall);
      }
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.labelMedium),
                const SizedBox(width: 8),
                Expanded(child: Text(action.title, style: theme.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 8),
            timeBlock(),
            if (action.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('理由: ${action.reason}', style: theme.textTheme.bodySmall),
            ],
            if (action.risk != null && action.risk!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('リスク: ${action.risk}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: applying ? null : () => onApprove(action),
                icon: const Icon(Icons.check),
                label: Text(action.isDelete ? 'この削除だけ了解' : action.isUpdate ? 'この変更だけ了解' : 'この追加だけ了解'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
