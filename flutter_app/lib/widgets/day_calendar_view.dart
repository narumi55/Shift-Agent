import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';

class DayCalendarView extends StatelessWidget {
  const DayCalendarView({
    super.key,
    required this.date,
    required this.events,
    this.startHour = 6,
    this.endHour = 29,
    this.onCreateAt,
    this.onCreateTaskAt,
    this.onTapEvent,
    this.onMoveEvent,
    this.onResizeEvent,
    this.onDeleteEvent,
    this.onCompleteEvent,
    this.onLaterEvent,
  });

  final DateTime date;
  final List<CalendarEventInfo> events;
  final int startHour;
  final int endHour;

  /// 空き時間を長押ししたときの新規予定作成。
  final void Function(DateTime start)? onCreateAt;

  /// 未配置タスクをカレンダー上にドロップしたときの予定作成。
  final void Function(String title, DateTime start)? onCreateTaskAt;

  /// 予定カードをタップしたときの編集。
  final void Function(CalendarEventInfo event)? onTapEvent;

  /// 予定カードを長押しドラッグして時間移動。
  final void Function(CalendarEventInfo event, DateTime newStart)? onMoveEvent;

  /// 予定カードの下端ドラッグで終了時刻変更。
  final void Function(CalendarEventInfo event, DateTime newEnd)? onResizeEvent;

  /// 左スワイプで削除。
  final void Function(CalendarEventInfo event)? onDeleteEvent;

  /// 右スワイプで完了。
  final void Function(CalendarEventInfo event)? onCompleteEvent;

  /// 右スワイプであとでやる。
  final void Function(CalendarEventInfo event)? onLaterEvent;

  DateTime get _displayStart => DateTime(date.year, date.month, date.day, startHour);
  DateTime get _displayEnd => DateTime(date.year, date.month, date.day, endHour);

  int _minutesFromStart(DateTime value) {
    return value.difference(_displayStart).inMinutes;
  }

  DateTime _slotTime(int slotIndex) {
    return _displayStart.add(Duration(minutes: slotIndex * 15));
  }

  List<_LayoutItem> _layoutEvents() {
    final displayStart = _displayStart;
    final displayEnd = _displayEnd;
    final totalMinutes = displayEnd.difference(displayStart).inMinutes;

    final visible = <_LayoutItem>[];
    for (final event in events) {
      final start = event.start.toLocal();
      final end = event.end.toLocal();
      if (!start.isBefore(displayEnd) || !end.isAfter(displayStart)) continue;
      final startMin = _minutesFromStart(start).clamp(0, totalMinutes).toInt();
      final endMin = _minutesFromStart(end).clamp(0, totalMinutes).toInt();
      if (endMin <= startMin) continue;
      visible.add(_LayoutItem(event: event, startMin: startMin, endMin: endMin));
    }
    visible.sort((a, b) {
      final byStart = a.startMin.compareTo(b.startMin);
      if (byStart != 0) return byStart;
      return b.endMin.compareTo(a.endMin);
    });

    var i = 0;
    while (i < visible.length) {
      final cluster = <_LayoutItem>[];
      var clusterEnd = visible[i].endMin;
      while (i < visible.length && visible[i].startMin < clusterEnd) {
        cluster.add(visible[i]);
        clusterEnd = math.max(clusterEnd, visible[i].endMin);
        i += 1;
      }

      final laneEnds = <int>[];
      for (final item in cluster) {
        var lane = -1;
        for (var j = 0; j < laneEnds.length; j++) {
          if (laneEnds[j] <= item.startMin) {
            lane = j;
            break;
          }
        }
        if (lane == -1) {
          lane = laneEnds.length;
          laneEnds.add(item.endMin);
        } else {
          laneEnds[lane] = item.endMin;
        }
        item.lane = lane;
      }
      final laneCount = laneEnds.length;
      for (final item in cluster) {
        item.laneCount = laneCount;
      }
    }
    return visible;
  }

  Future<bool?> _showSwipeActionSheet(BuildContext context, CalendarEventInfo event) {
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(event.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context, false);
                    onCompleteEvent?.call(event);
                  },
                  icon: const Icon(Icons.check_circle),
                  label: const Text('完了にする'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context, false);
                    onLaterEvent?.call(event);
                  },
                  icon: const Icon(Icons.schedule),
                  label: const Text('あとでやる・明日に移動'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMinutes = (endHour - startHour) * 60;
    const pixelsPerMinute = 1.15;
    final height = totalMinutes * pixelsPerMinute;
    final layoutItems = _layoutEvents();
    final slotCount = totalMinutes ~/ 15;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${DateFormat('yyyy年M月d日(E)', 'ja_JP').format(date)}  6:00〜翌5:00',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const Text('長押しで追加 / 予定を長押しドラッグで移動'),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 640,
              child: SingleChildScrollView(
                child: SizedBox(
                  height: height,
                  child: Stack(
                    children: [
                      ...List.generate(endHour - startHour + 1, (index) {
                        final absoluteHour = startHour + index;
                        final hour = absoluteHour % 24;
                        final top = index * 60 * pixelsPerMinute;
                        final isNextDay = absoluteHour >= 24;
                        return Positioned(
                          top: top,
                          left: 0,
                          right: 0,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 58,
                                child: Text(
                                  '${hour.toString().padLeft(2, '0')}:00${isNextDay ? ' 翌' : ''}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: theme.dividerColor.withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      ...List.generate(slotCount, (slot) {
                        final top = slot * 15 * pixelsPerMinute;
                        final start = _slotTime(slot);
                        return Positioned(
                          top: top,
                          left: 64,
                          right: 0,
                          height: 15 * pixelsPerMinute,
                          child: DragTarget<Object>(
                            onWillAccept: (data) => data is CalendarEventInfo || data is String,
                            onAccept: (data) {
                              if (data is CalendarEventInfo) {
                                onMoveEvent?.call(data, start);
                              } else if (data is String) {
                                onCreateTaskAt?.call(data, start);
                              }
                            },
                            builder: (context, candidateData, rejectedData) {
                              final active = candidateData.isNotEmpty;
                              return GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onLongPress: () => onCreateAt?.call(start),
                                child: Container(
                                  color: active ? theme.colorScheme.primary.withOpacity(0.12) : Colors.transparent,
                                ),
                              );
                            },
                          ),
                        );
                      }),
                      if (layoutItems.isEmpty)
                        const Positioned.fill(
                          left: 64,
                          child: Center(child: Text('この時間帯に予定はありません。空き時間を長押しして追加できます。')),
                        ),
                      ...layoutItems.map((item) {
                        final event = item.event;
                        final top = item.startMin * pixelsPerMinute;
                        final eventHeight = ((item.endMin - item.startMin) * pixelsPerMinute).clamp(34, 240).toDouble();
                        final laneSpaceLeft = 68.0;
                        final laneGap = 6.0;
                        final rightPadding = 8.0;
                        return Positioned(
                          top: top,
                          left: laneSpaceLeft,
                          right: rightPadding,
                          height: eventHeight,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final width = (constraints.maxWidth - laneGap * (item.laneCount - 1)) / item.laneCount;
                              final leftOffset = item.lane * (width + laneGap);
                              return Stack(
                                children: [
                                  Positioned(
                                    left: leftOffset,
                                    width: math.max(80, width),
                                    top: 0,
                                    bottom: 0,
                                    child: _DismissibleEventCard(
                                      event: event,
                                      height: eventHeight,
                                      pixelsPerMinute: pixelsPerMinute,
                                      onTap: () => onTapEvent?.call(event),
                                      onDelete: () => onDeleteEvent?.call(event),
                                      onSwipeRight: () => _showSwipeActionSheet(context, event),
                                      onMoveEvent: onMoveEvent,
                                      onResizeEvent: onResizeEvent,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DismissibleEventCard extends StatelessWidget {
  const _DismissibleEventCard({
    required this.event,
    required this.height,
    required this.pixelsPerMinute,
    required this.onTap,
    required this.onDelete,
    required this.onSwipeRight,
    required this.onMoveEvent,
    required this.onResizeEvent,
  });

  final CalendarEventInfo event;
  final double height;
  final double pixelsPerMinute;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Future<bool?> Function() onSwipeRight;
  final void Function(CalendarEventInfo event, DateTime newStart)? onMoveEvent;
  final void Function(CalendarEventInfo event, DateTime newEnd)? onResizeEvent;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('${event.id ?? event.title}-${event.start.toIso8601String()}'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          onDelete();
          return false;
        }
        await onSwipeRight();
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.check_circle),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline),
      ),
      child: _EventCard(
        event: event,
        height: height,
        pixelsPerMinute: pixelsPerMinute,
        faded: false,
        onTap: onTap,
        onMoveEvent: onMoveEvent,
        onResizeEvent: onResizeEvent,
      ),
    );
  }
}

class _EventCard extends StatefulWidget {
  const _EventCard({
    required this.event,
    required this.height,
    required this.pixelsPerMinute,
    required this.faded,
    required this.onTap,
    required this.onMoveEvent,
    required this.onResizeEvent,
  });

  final CalendarEventInfo event;
  final double height;
  final double pixelsPerMinute;
  final bool faded;
  final VoidCallback onTap;
  final void Function(CalendarEventInfo event, DateTime newStart)? onMoveEvent;
  final void Function(CalendarEventInfo event, DateTime newEnd)? onResizeEvent;

  @override
  State<_EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<_EventCard> {
  double _moveDy = 0;
  double _resizeDy = 0;

  int _dyToSlots(double dy) {
    final slotHeight = 15 * widget.pixelsPerMinute;
    if (slotHeight <= 0) return 0;
    return (dy / slotHeight).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localStart = widget.event.start.toLocal();
    final localEnd = widget.event.end.toLocal();
    final timeText = '${DateFormat('HH:mm').format(localStart)}〜${DateFormat('HH:mm').format(localEnd)}';
    final compact = widget.height < 46;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(widget.faded ? 0.5 : 1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            flex: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onVerticalDragStart: (_) => _moveDy = 0,
              onVerticalDragUpdate: (details) => _moveDy += details.delta.dy,
              onVerticalDragEnd: (_) {
                final slots = _dyToSlots(_moveDy);
                _moveDy = 0;
                if (slots == 0 || widget.onMoveEvent == null) return;
                final newStart = widget.event.start.add(Duration(minutes: slots * 15));
                widget.onMoveEvent!(widget.event, newStart);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
                child: compact
                    ? Row(
                        children: [
                          const Icon(Icons.open_with, size: 14),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.event.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(timeText, maxLines: 1, style: theme.textTheme.bodySmall),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.open_with, size: 14),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  widget.event.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(timeText, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                        ],
                      ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onVerticalDragStart: (_) => _resizeDy = 0,
              onVerticalDragUpdate: (details) => _resizeDy += details.delta.dy,
              onVerticalDragEnd: (_) {
                final slots = _dyToSlots(_resizeDy);
                _resizeDy = 0;
                if (slots == 0 || widget.onResizeEvent == null) return;
                final proposedEnd = widget.event.end.add(Duration(minutes: slots * 15));
                if (proposedEnd.isAfter(widget.event.start.add(const Duration(minutes: 15)))) {
                  widget.onResizeEvent!(widget.event, proposedEnd);
                }
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Align(
                  alignment: compact ? Alignment.centerRight : Alignment.bottomCenter,
                  child: Container(
                    height: compact ? 18 : 22,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onPrimaryContainer.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.height, size: 14),
                        if (!compact) ...[
                          const SizedBox(width: 4),
                          Text('下半分：時間調整', style: theme.textTheme.labelSmall),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LayoutItem {
  _LayoutItem({required this.event, required this.startMin, required this.endMin});

  final CalendarEventInfo event;
  final int startMin;
  final int endMin;
  int lane = 0;
  int laneCount = 1;
}
