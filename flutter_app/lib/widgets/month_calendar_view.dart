import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';

class MonthCalendarView extends StatelessWidget {
  const MonthCalendarView({
    super.key,
    required this.month,
    required this.selectedDate,
    required this.events,
    required this.onSelectDate,
  });

  final DateTime month;
  final DateTime selectedDate;
  final List<CalendarEventInfo> events;
  final void Function(DateTime date) onSelectDate;

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  int _eventCount(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return events.where((e) => e.start.isBefore(end) && e.end.isAfter(start)).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month, 1);
    final offset = first.weekday % 7; // Sunday = 0
    final gridStart = first.subtract(Duration(days: offset));
    final days = List.generate(42, (i) => gridStart.add(Duration(days: i)));
    const weekLabels = ['日', '月', '火', '水', '木', '金', '土'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(DateFormat('yyyy年M月', 'ja_JP').format(month), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: weekLabels
                  .map((label) => Expanded(
                        child: Center(child: Text(label, style: theme.textTheme.labelMedium)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: days.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: 88,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemBuilder: (context, index) {
                final day = days[index];
                final inMonth = day.month == month.month;
                final selected = _sameDay(day, selectedDate);
                final count = _eventCount(day);
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelectDate(day),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${day.day}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: inMonth ? null : theme.disabledColor,
                          ),
                        ),
                        const Spacer(),
                        if (count > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text('$count件', style: theme.textTheme.labelSmall),
                          )
                        else
                          Text('予定なし', style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
