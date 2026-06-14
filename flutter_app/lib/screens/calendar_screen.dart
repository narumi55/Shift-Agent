import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';
import '../widgets/day_calendar_view.dart';
import '../widgets/month_calendar_view.dart';

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
  bool _loading = false;
  bool _monthLoading = false;
  String? _message;
  bool _monthMode = false;
  DateTime _visibleMonth = DateTime(DateTime.now().year, DateTime.now().month);
  List<CalendarEventInfo> _monthEvents = [];
  final List<String> _unplacedTasks = ['学校課題', '面接準備', '個人開発'];
  final TextEditingController _taskController = TextEditingController();

  DateFormat get _dateTimeFormat => DateFormat('yyyy-MM-dd HH:mm');

  @override
  void didUpdateWidget(covariant CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedDate.year != widget.selectedDate.year || oldWidget.selectedDate.month != widget.selectedDate.month) {
      _visibleMonth = DateTime(widget.selectedDate.year, widget.selectedDate.month);
    }
  }

  @override
  void dispose() {
    _taskController.dispose();
    super.dispose();
  }

  Future<String> _requireHeader() async {
    final header = await widget.auth.calendarAuthorizationHeader();
    if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
    return header;
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
      if (_monthMode) await _loadMonth(_visibleMonth);
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

  Future<void> _loadMonth(DateTime month) async {
    setState(() {
      _monthLoading = true;
      _message = null;
      _visibleMonth = DateTime(month.year, month.month);
    });
    try {
      final header = await _requireHeader();
      final start = DateTime(month.year, month.month, 1);
      final end = DateTime(month.year, month.month + 1, 1);
      final events = await widget.api.calendarEvents(timeMin: start, timeMax: end, googleAuthHeader: header);
      if (!mounted) return;
      setState(() => _monthEvents = events);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '月表示の取得エラー: $e');
    } finally {
      if (mounted) setState(() => _monthLoading = false);
    }
  }

  DateTime _roundToNext15(DateTime value) {
    final minute = ((value.minute + 14) ~/ 15) * 15;
    return DateTime(value.year, value.month, value.day, value.hour).add(Duration(minutes: minute));
  }

  DateTime _parseDateTime(String value) {
    final normalized = value.trim().replaceFirst(' ', 'T');
    final parsed = DateTime.tryParse(normalized);
    if (parsed == null) throw FormatException('日時は yyyy-MM-dd HH:mm の形式で入力してください。');
    return parsed;
  }

  bool _isSameDisplayDate(DateTime date, DateTime target) {
    return date.year == target.year && date.month == target.month && date.day == target.day;
  }

  Future<void> _refreshAfter(DateTime date) async {
    await widget.onLoadDate(date);
    if (_monthMode && _isSameDisplayDate(DateTime(_visibleMonth.year, _visibleMonth.month), DateTime(date.year, date.month))) {
      await _loadMonth(_visibleMonth);
    }
  }

  Future<void> _createEvent({DateTime? start, String? initialTitle}) async {
    final baseStart = start ?? _roundToNext15(DateTime.now());
    final titleController = TextEditingController(text: initialTitle ?? '予定');
    final startController = TextEditingController(text: _dateTimeFormat.format(baseStart));
    final endController = TextEditingController(text: _dateTimeFormat.format(baseStart.add(const Duration(hours: 1))));
    final notesController = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: _EventEditForm(
            title: '予定を追加',
            titleController: titleController,
            startController: startController,
            endController: endController,
            notesController: notesController,
            primaryLabel: '追加',
            onPrimary: () async {
              try {
                final title = titleController.text.trim();
                if (title.isEmpty) throw Exception('タイトルを入力してください。');
                final eventStart = _parseDateTime(startController.text);
                final eventEnd = _parseDateTime(endController.text);
                if (!eventEnd.isAfter(eventStart)) throw Exception('終了時刻は開始時刻より後にしてください。');
                final header = await _requireHeader();
                await widget.api.insertManualEvent(
                  title: title,
                  start: eventStart,
                  end: eventEnd,
                  googleAuthHeader: header,
                  notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
                );
                if (!mounted) return;
                Navigator.pop(context);
                await _refreshAfter(eventStart);
                setState(() => _message = 'Googleカレンダーに追加しました。');
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('追加エラー: $e')));
              }
            },
          ),
        );
      },
    );
  }

  Future<void> _openEventEditor(CalendarEventInfo event) async {
    final titleController = TextEditingController(text: event.title);
    final startController = TextEditingController(text: _dateTimeFormat.format(event.start.toLocal()));
    final endController = TextEditingController(text: _dateTimeFormat.format(event.end.toLocal()));
    final notesController = TextEditingController(text: event.location ?? '');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: _EventEditForm(
            title: '予定を編集',
            titleController: titleController,
            startController: startController,
            endController: endController,
            notesController: notesController,
            primaryLabel: '変更を保存',
            onPrimary: event.id == null
                ? null
                : () async {
                    try {
                      final header = await _requireHeader();
                      final start = _parseDateTime(startController.text);
                      final end = _parseDateTime(endController.text);
                      if (!end.isAfter(start)) throw Exception('終了時刻は開始時刻より後にしてください。');
                      await widget.api.updateEvent(
                        eventId: event.id!,
                        title: titleController.text.trim(),
                        start: start,
                        end: end,
                        notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
                        googleAuthHeader: header,
                      );
                      if (!mounted) return;
                      Navigator.pop(context);
                      await _refreshAfter(start);
                      setState(() => _message = '予定を変更しました。');
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('変更エラー: $e')));
                    }
                  },
            dangerLabel: '削除',
            onDanger: event.id == null
                ? null
                : () async {
                    Navigator.pop(context);
                    await _deleteEvent(event);
                  },
          ),
        );
      },
    );
  }

  Future<void> _moveEvent(CalendarEventInfo event, DateTime newStart) async {
    if (event.id == null) return;
    try {
      final duration = event.end.difference(event.start);
      final header = await _requireHeader();
      await widget.api.updateEvent(
        eventId: event.id!,
        start: newStart,
        end: newStart.add(duration),
        googleAuthHeader: header,
      );
      await _refreshAfter(newStart);
      if (!mounted) return;
      setState(() => _message = '${event.title} を ${DateFormat('HH:mm').format(newStart)} に移動しました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '移動エラー: $e');
    }
  }

  Future<void> _resizeEvent(CalendarEventInfo event, DateTime newEnd) async {
    if (event.id == null) return;
    try {
      final header = await _requireHeader();
      await widget.api.updateEvent(eventId: event.id!, end: newEnd, googleAuthHeader: header);
      await _refreshAfter(event.start);
      if (!mounted) return;
      setState(() => _message = '${event.title} の終了時刻を変更しました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '時間変更エラー: $e');
    }
  }

  Future<void> _deleteEvent(CalendarEventInfo event) async {
    if (event.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('予定を削除しますか？'),
        content: Text('${event.title}\n${_dateTimeFormat.format(event.start.toLocal())}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final header = await _requireHeader();
      await widget.api.deleteEvent(eventId: event.id!, googleAuthHeader: header);
      await _refreshAfter(event.start);
      if (!mounted) return;
      setState(() => _message = '予定を削除しました。');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('予定を削除しました'),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () async {
              try {
                final header = await _requireHeader();
                await widget.api.insertManualEvent(
                  title: event.title,
                  start: event.start,
                  end: event.end,
                  googleAuthHeader: header,
                  notes: event.location,
                );
                await _refreshAfter(event.start);
              } catch (_) {}
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '削除エラー: $e');
    }
  }

  Future<void> _completeEvent(CalendarEventInfo event) async {
    if (event.id == null) return;
    if (event.title.startsWith('✅')) return;
    try {
      final header = await _requireHeader();
      await widget.api.updateEvent(eventId: event.id!, title: '✅ ${event.title}', googleAuthHeader: header);
      await _refreshAfter(event.start);
      if (!mounted) return;
      setState(() => _message = '完了にしました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '完了操作エラー: $e');
    }
  }

  Future<void> _laterEvent(CalendarEventInfo event) async {
    if (event.id == null) return;
    try {
      final header = await _requireHeader();
      await widget.api.updateEvent(
        eventId: event.id!,
        start: event.start.add(const Duration(days: 1)),
        end: event.end.add(const Duration(days: 1)),
        googleAuthHeader: header,
      );
      await _refreshAfter(event.start.add(const Duration(days: 1)));
      if (!mounted) return;
      setState(() => _message = '明日に移動しました。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'あとでやる操作エラー: $e');
    }
  }

  void _addUnplacedTask() {
    final text = _taskController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _unplacedTasks.add(text);
      _taskController.clear();
    });
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
            child: Padding(padding: const EdgeInsets.all(12), child: Text(_message!)),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.view_day), label: Text('日')),
                ButtonSegment(value: true, icon: Icon(Icons.calendar_view_month), label: Text('月')),
              ],
              selected: {_monthMode},
              onSelectionChanged: (values) async {
                final next = values.first;
                setState(() => _monthMode = next);
                if (next && _monthEvents.isEmpty) await _loadMonth(_visibleMonth);
              },
            ),
            const SizedBox(width: 12),
            IconButton.filledTonal(
              onPressed: _loading || _monthLoading
                  ? null
                  : () {
                      if (_monthMode) {
                        _loadMonth(DateTime(_visibleMonth.year, _visibleMonth.month - 1));
                      } else {
                        _load(widget.selectedDate.subtract(const Duration(days: 1)));
                      }
                    },
              icon: const Icon(Icons.chevron_left),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Center(
                child: Text(
                  _monthMode ? DateFormat('yyyy年M月', 'ja_JP').format(_visibleMonth) : dateText,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _loading || _monthLoading
                  ? null
                  : () {
                      if (_monthMode) {
                        _loadMonth(DateTime(_visibleMonth.year, _visibleMonth.month + 1));
                      } else {
                        _load(widget.selectedDate.add(const Duration(days: 1)));
                      }
                    },
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _load(DateTime.now()),
              icon: const Icon(Icons.today),
              label: const Text('今日'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _loading || _monthLoading
                  ? null
                  : () => _monthMode ? _loadMonth(_visibleMonth) : _load(widget.selectedDate),
              icon: (_loading || _monthLoading)
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: const Text('更新'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _UnplacedTaskPanel(
          tasks: _unplacedTasks,
          controller: _taskController,
          onAdd: _addUnplacedTask,
          onRemove: (task) => setState(() => _unplacedTasks.remove(task)),
        ),
        const SizedBox(height: 16),
        if (_monthMode)
          MonthCalendarView(
            month: _visibleMonth,
            selectedDate: widget.selectedDate,
            events: _monthEvents,
            onSelectDate: (date) async {
              setState(() => _monthMode = false);
              await _load(date);
            },
          )
        else
          DayCalendarView(
            date: widget.selectedDate,
            events: widget.events,
            startHour: 6,
            endHour: 29,
            onCreateAt: (start) => _createEvent(start: start),
            onCreateTaskAt: (title, start) {
              setState(() => _unplacedTasks.remove(title));
              _createEvent(start: start, initialTitle: title);
            },
            onTapEvent: _openEventEditor,
            onMoveEvent: _moveEvent,
            onResizeEvent: _resizeEvent,
            onDeleteEvent: _deleteEvent,
            onCompleteEvent: _completeEvent,
            onLaterEvent: _laterEvent,
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('手動操作の使い方', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('空き時間を長押し：予定追加'),
                const Text('予定カードをタップ：下から編集パネル'),
                const Text('予定カードの上半分を上下ドラッグ：時間移動'),
                const Text('予定カードの下半分を上下ドラッグ：15分単位で延長・短縮'),
                const Text('左スワイプ：削除 / 右スワイプ：完了・あとでやる'),
                const Text('未配置タスクをドラッグ：カレンダーへ予定化'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UnplacedTaskPanel extends StatelessWidget {
  const _UnplacedTaskPanel({
    required this.tasks,
    required this.controller,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> tasks;
  final TextEditingController controller;
  final VoidCallback onAdd;
  final void Function(String task) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('未配置タスク', style: theme.textTheme.titleMedium)),
                const Text('ドラッグしてカレンダーに配置'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'タスク名を追加',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => onAdd(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('追加')),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tasks.map((task) {
                return Draggable<String>(
                  data: task,
                  feedback: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Chip(label: Text(task), avatar: const Icon(Icons.drag_indicator, size: 18)),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.35,
                    child: InputChip(
                      avatar: const Icon(Icons.drag_indicator, size: 18),
                      label: Text(task),
                    ),
                  ),
                  child: InputChip(
                    avatar: const Icon(Icons.drag_indicator, size: 18),
                    label: Text(task),
                    onDeleted: () => onRemove(task),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventEditForm extends StatelessWidget {
  const _EventEditForm({
    required this.title,
    required this.titleController,
    required this.startController,
    required this.endController,
    required this.notesController,
    required this.primaryLabel,
    required this.onPrimary,
    this.dangerLabel,
    this.onDanger,
  });

  final String title;
  final TextEditingController titleController;
  final TextEditingController startController;
  final TextEditingController endController;
  final TextEditingController notesController;
  final String primaryLabel;
  final Future<void> Function()? onPrimary;
  final String? dangerLabel;
  final Future<void> Function()? onDanger;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: titleController,
            decoration: const InputDecoration(labelText: 'タイトル', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: startController,
                  decoration: const InputDecoration(labelText: '開始 yyyy-MM-dd HH:mm', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: endController,
                  decoration: const InputDecoration(labelText: '終了 yyyy-MM-dd HH:mm', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notesController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'メモ 任意', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (dangerLabel != null && onDanger != null)
                TextButton.icon(
                  onPressed: onDanger,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(dangerLabel!),
                ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onPrimary,
                icon: const Icon(Icons.save),
                label: Text(primaryLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
