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
    this.endHour = 24,
  });

  final DateTime date;
  final List<CalendarEventInfo> events;
  final int startHour;
  final int endHour;

  @override
  Widget build(BuildContext context) {
    final dayEvents = events.where((event) {
      final start = event.start.toLocal();
      return start.year == date.year && start.month == date.month && start.day == date.day;
    }).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final theme = Theme.of(context);
    final totalMinutes = (endHour - startHour) * 60;
    const pixelsPerMinute = 1.15;
    final height = totalMinutes * pixelsPerMinute;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat('yyyy年M月d日(E)', 'ja_JP').format(date),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (dayEvents.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('この日に表示できる予定はありません。')),
              )
            else
              SizedBox(
                height: 520,
                child: SingleChildScrollView(
                  child: SizedBox(
                    height: height,
                    child: Stack(
                      children: [
                        ...List.generate(endHour - startHour + 1, (index) {
                          final hour = startHour + index;
                          final top = index * 60 * pixelsPerMinute;
                          return Positioned(
                            top: top,
                            left: 0,
                            right: 0,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 56,
                                  child: Text(
                                    '${hour.toString().padLeft(2, '0')}:00',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                                Expanded(
                                  child: Divider(color: theme.colorScheme.outlineVariant),
                                ),
                              ],
                            ),
                          );
                        }),
                        ...dayEvents.map((event) {
                          final localStart = event.start.toLocal();
                          final localEnd = event.end.toLocal();
                          final startMinutes = ((localStart.hour - startHour) * 60 + localStart.minute).clamp(0, totalMinutes);
                          final rawDuration = localEnd.difference(localStart).inMinutes;
                          final duration = rawDuration <= 0 ? 30 : rawDuration;
                          final rawTop = startMinutes * pixelsPerMinute;
                          final eventHeight = (duration * pixelsPerMinute).clamp(34, 220).toDouble();
                          final maxTop = math.max(0.0, height - eventHeight);
                          final top = math.min(rawTop.toDouble(), maxTop);
                          final timeText = '${DateFormat('HH:mm').format(localStart)}〜${DateFormat('HH:mm').format(localEnd)}';

                          return Positioned(
                            top: top,
                            left: 68,
                            right: 8,
                            height: eventHeight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: theme.colorScheme.primary.withOpacity(0.25)),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final compact = constraints.maxHeight < 46;
                                  if (compact) {
                                    return Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            event.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelMedium,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          timeText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    );
                                  }

                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        event.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelLarge,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        timeText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  );
                                },
                              ),
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
