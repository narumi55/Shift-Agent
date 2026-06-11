import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';
import '../widgets/day_calendar_view.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    required this.api,
    required this.auth,
    required this.selectedDate,
    required this.events,
    required this.apiOk,
    required this.status,
    required this.onLoadDate,
    required this.onAuthChanged,
  });

  final ApiClient api;
  final GoogleAuthService auth;
  final DateTime selectedDate;
  final List<CalendarEventInfo> events;
  final bool apiOk;
  final String status;
  final Future<List<CalendarEventInfo>> Function(DateTime date) onLoadDate;
  final VoidCallback onAuthChanged;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final TextEditingController _titleController = TextEditingController(text: '予定');
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _endController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  bool _loading = false;
  bool _adding = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _setDefaultTimes();
  }

  @override
  void didUpdateWidget(covariant CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_startController.text.startsWith(DateFormat('yyyy-MM-dd').format(widget.selectedDate))) {
      _setDefaultTimes();
    }
  }

  void _setDefaultTimes() {
    final now = DateTime.now();
    final base = DateTime(widget.selectedDate.year, widget.selectedDate.month, widget.selectedDate.day, now.hour + 1);
    _startController.text = DateFormat('yyyy-MM-dd HH:mm').format(base);
    _endController.text = DateFormat('yyyy-MM-dd HH:mm').format(base.add(const Duration(hours: 1)));
  }

  Future<void> _connectAndLoad() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await widget.auth.signIn();
      widget.onAuthChanged();
      await widget.auth.calendarAuthorizationHeader();
      widget.onAuthChanged();
      await widget.onLoadDate(widget.selectedDate);
      if (!mounted) return;
      setState(() => _message = 'Google連携とカレンダー取得が完了しました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Google連携エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load(DateTime date) async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await widget.onLoadDate(date);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'カレンダー取得エラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime _parseDateTime(String value) {
    final normalized = value.trim().replaceFirst(' ', 'T');
    final parsed = DateTime.tryParse(normalized);
    if (parsed == null) {
      throw FormatException('日時は yyyy-MM-dd HH:mm の形式で入力してください。');
    }
    return parsed;
  }

  Future<void> _addManualEvent() async {
    setState(() {
      _adding = true;
      _message = null;
    });
    try {
      final title = _titleController.text.trim();
      if (title.isEmpty) throw Exception('タイトルを入力してください。');
      final start = _parseDateTime(_startController.text);
      final end = _parseDateTime(_endController.text);
      if (!end.isAfter(start)) throw Exception('終了時刻は開始時刻より後にしてください。');
      final header = await widget.auth.calendarAuthorizationHeader();
      if (header == null) throw Exception('Google連携が必要です。');
      await widget.api.insertManualEvent(
        title: title,
        start: start,
        end: end,
        googleAuthHeader: header,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );
      await widget.onLoadDate(start);
      if (!mounted) return;
      setState(() => _message = 'Googleカレンダーに追加しました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '予定追加エラー: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _startController.dispose();
    _endController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateText = DateFormat('yyyy年M月d日(E)', 'ja_JP').format(widget.selectedDate);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Googleカレンダー', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(widget.status, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: _loading ? null : _connectAndLoad,
              icon: const Icon(Icons.login),
              label: const Text('Google連携'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              avatar: Icon(widget.apiOk ? Icons.check_circle : Icons.error_outline, size: 18),
              label: Text(widget.apiOk ? 'API接続OK' : 'API未接続'),
            ),
            Chip(
              avatar: Icon(widget.auth.email == null ? Icons.account_circle_outlined : Icons.verified_user, size: 18),
              label: Text(widget.auth.email == null ? 'Google未ログイン' : widget.auth.email!),
            ),
            Chip(
              avatar: const Icon(Icons.event_available, size: 18),
              label: Text('${widget.events.length}件表示中'),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_message!),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton.filledTonal(
              onPressed: _loading ? null : () => _load(widget.selectedDate.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left),
              tooltip: '前日',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Center(
                child: Text(dateText, style: theme.textTheme.titleLarge),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _loading ? null : () => _load(widget.selectedDate.add(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_right),
              tooltip: '翌日',
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _load(DateTime.now()),
              icon: const Icon(Icons.today),
              label: const Text('今日'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _load(widget.selectedDate),
              icon: _loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: const Text('更新'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DayCalendarView(date: widget.selectedDate, events: widget.events),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('予定を直接追加', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'タイトル',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _startController,
                        decoration: const InputDecoration(
                          labelText: '開始 yyyy-MM-dd HH:mm',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _endController,
                        decoration: const InputDecoration(
                          labelText: '終了 yyyy-MM-dd HH:mm',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'メモ 任意',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _adding ? null : _addManualEvent,
                    icon: _adding
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add),
                    label: const Text('Googleカレンダーに追加'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
