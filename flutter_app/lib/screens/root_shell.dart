import 'package:flutter/material.dart';

import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';
import 'ai_chat_screen.dart';
import 'calendar_screen.dart';
import 'profile_screen.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final ApiClient _api = ApiClient();
  final GoogleAuthService _auth = GoogleAuthService();

  int _selectedIndex = 0;
  DateTime _calendarDate = DateTime.now();
  List<CalendarEventInfo> _calendarEvents = [];
  DateTime? _calendarSyncedAt;
  String _status = '起動中...';
  bool _apiOk = false;
  bool _calendarLoaded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _auth.init();
      await _api.health();
      if (!mounted) return;
      setState(() {
        _apiOk = true;
        _status = 'API接続OK。Googleアカウントの自動連携を確認しています。';
      });

      final autoConnected = await _auth.tryAutoConnectCalendar();
      if (!mounted) return;
      if (autoConnected) {
        setState(() => _status = 'Google自動連携OK。今日のカレンダーを取得しています。');
        await loadCalendarForDate(DateTime.now());
      } else {
        setState(() {
          _status = 'API接続OK。初回または権限切れのため、カレンダーページでGoogle連携を押してください。';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '初期化エラー: $e';
      });
    }
  }

  Future<String> _requireGoogleHeader() async {
    final header = await _auth.calendarAuthorizationHeader();
    if (header == null || header.isEmpty) {
      throw Exception('Google連携が完了していません。');
    }
    return header;
  }

  Future<List<CalendarEventInfo>> loadCalendarForDate(DateTime date) async {
    final target = DateTime(date.year, date.month, date.day);
    final displayStart = DateTime(target.year, target.month, target.day, 6);
    final displayEnd = displayStart.add(const Duration(hours: 23));
    final header = await _requireGoogleHeader();
    final events = await _api.calendarEvents(
      timeMin: displayStart,
      timeMax: displayEnd,
      googleAuthHeader: header,
    );
    if (!mounted) return events;
    setState(() {
      _calendarDate = target;
      _calendarEvents = events;
      _calendarLoaded = true;
      _calendarSyncedAt = DateTime.now();
      _status = '${events.length}件のGoogleカレンダー予定を取得し、FlutterキャッシュとSupabaseに同期しました。';
    });
    return events;
  }

  Future<List<CalendarEventInfo>> ensureCalendarLoaded() async {
    if (_calendarLoaded) return _calendarEvents;
    return loadCalendarForDate(_calendarDate);
  }

  Future<void> refreshCalendar() async {
    await loadCalendarForDate(_calendarDate);
  }

  void upsertCachedEvent(CalendarEventInfo event) {
    setState(() {
      final id = event.id;
      final index = id == null ? -1 : _calendarEvents.indexWhere((e) => e.id == id);
      if (index >= 0) {
        _calendarEvents[index] = event;
      } else {
        _calendarEvents.add(event);
      }
      _calendarEvents.sort((a, b) => a.start.compareTo(b.start));
      _calendarLoaded = true;
      _calendarSyncedAt = DateTime.now();
      _status = 'Google反映後、FlutterキャッシュとSupabaseを同時更新しました。';
    });
  }

  void removeCachedEvent(String eventId) {
    setState(() {
      _calendarEvents.removeWhere((e) => e.id == eventId);
      _calendarLoaded = true;
      _calendarSyncedAt = DateTime.now();
      _status = 'Google削除後、FlutterキャッシュとSupabaseを同時更新しました。';
    });
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      CalendarScreen(
        api: _api,
        auth: _auth,
        selectedDate: _calendarDate,
        events: _calendarEvents,
        apiOk: _apiOk,
        status: _status,
        calendarSyncedAt: _calendarSyncedAt,
        onLoadDate: loadCalendarForDate,
        onUpsertCachedEvent: upsertCachedEvent,
        onRemoveCachedEvent: removeCachedEvent,
        onAuthChanged: () => setState(() {}),
      ),
      AiChatScreen(
        api: _api,
        auth: _auth,
        calendarEvents: _calendarEvents,
        calendarCacheSyncedAt: _calendarSyncedAt,
        ensureCalendarLoaded: ensureCalendarLoaded,
        refreshCalendar: refreshCalendar,
        onUpsertCachedEvent: upsertCachedEvent,
        onRemoveCachedEvent: removeCachedEvent,
      ),
      ProfileScreen(
        api: _api,
        auth: _auth,
        calendarEvents: _calendarEvents,
        calendarCacheSyncedAt: _calendarSyncedAt,
        ensureCalendarLoaded: ensureCalendarLoaded,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Shift Agent'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                _auth.email == null ? '未ログイン' : _auth.email!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) => setState(() => _selectedIndex = index),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: Text('カレンダー'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.smart_toy_outlined),
                selectedIcon: Icon(Icons.smart_toy),
                label: Text('AI対話'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.person_search_outlined),
                selectedIcon: Icon(Icons.person_search),
                label: Text('プロフィール'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_selectedIndex]),
        ],
      ),
    );
  }
}
