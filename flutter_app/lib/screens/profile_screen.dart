import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    required this.auth,
    required this.calendarEvents,
    required this.calendarCacheSyncedAt,
    required this.ensureCalendarLoaded,
  });

  final ApiClient api;
  final GoogleAuthService auth;
  final List<CalendarEventInfo> calendarEvents;
  final DateTime? calendarCacheSyncedAt;
  final Future<List<CalendarEventInfo>> Function() ensureCalendarLoaded;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ProfileStateResult? _state;
  bool _loading = false;
  bool _analyzing = false;
  String? _message;
  final TextEditingController _analysisFreeTextController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _analysisFreeTextController.dispose();
    super.dispose();
  }

  Future<String> _requireHeader() async {
    final header = await widget.auth.calendarAuthorizationHeader();
    if (header == null || header.isEmpty) throw Exception('Google連携が必要です。');
    return header;
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final header = await widget.auth.calendarAuthorizationHeader();
      final state = await widget.api.profileState(googleAuthHeader: header);
      if (!mounted) return;
      setState(() {
        _state = state;
        _message = 'プロフィールを読み込みました。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'プロフィール読み込みエラー: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openInitialSurvey() async {
    final sleepController = TextEditingController(text: _profileValue('target_sleep_time', fallback: '23:30'));
    final wakeController = TextEditingController(text: _profileValue('target_wake_time', fallback: '08:00'));
    final heavyController = TextEditingController(text: _profileValue('avoid_heavy_work_after', fallback: '22:30'));
    final bufferController = TextEditingController(text: _profileValue('default_buffer_minutes', fallback: '10'));
    final mealController = TextEditingController(text: _profileValue('default_meal_minutes', fallback: '30'));
    final bathController = TextEditingController(text: _profileValue('default_bath_minutes', fallback: '25'));
    final prepController = TextEditingController(text: _profileValue('default_sleep_prep_minutes', fallback: '20'));
    final freeTextController = TextEditingController();
    String afterPolicy = 'light_only';
    String modifyPolicy = 'ask';
    String planningMode = _state?.currentUserState.planningMode ?? 'balance';
    bool uncertainDelete = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('初回アンケート', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('基本プロフィールと初期ルールを作ります。あとからプロフィール画面で変更できます。'),
                  const SizedBox(height: 12),
                  _textField(sleepController, '1. 何時までには寝たいですか？', '23:30'),
                  _textField(wakeController, '2. 何時に起きたいですか？', '08:00'),
                  _textField(heavyController, '3. 何時以降は重い作業を避けたいですか？', '22:30'),
                  _numberField(bufferController, '4. 予定間の余裕は何分ほしいですか？'),
                  _numberField(mealController, '5. 食事の時間は何分で考慮しますか？'),
                  _numberField(bathController, '6. 入浴の時間は何分で考慮しますか？'),
                  _numberField(prepController, '7. 寝る準備は何分で考慮しますか？'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: afterPolicy,
                    decoration: const InputDecoration(labelText: '8. バイトや学校の後に作業を入れても大丈夫ですか？'),
                    items: const [
                      DropdownMenuItem(value: 'ok', child: Text('入れても大丈夫')),
                      DropdownMenuItem(value: 'light_only', child: Text('軽めなら大丈夫')),
                      DropdownMenuItem(value: 'avoid', child: Text('できれば避けたい')),
                    ],
                    onChanged: (v) => setSheetState(() => afterPolicy = v ?? afterPolicy),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: modifyPolicy,
                    decoration: const InputDecoration(labelText: '9. 既存予定をAIが変更してよいですか？'),
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('変更しない')),
                      DropdownMenuItem(value: 'ask', child: Text('候補は出してよいが必ず確認')),
                      DropdownMenuItem(value: 'uncertain_only', child: Text('未確定予定だけ候補にしてよい')),
                    ],
                    onChanged: (v) => setSheetState(() => modifyPolicy = v ?? modifyPolicy),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: planningMode,
                    decoration: const InputDecoration(labelText: '10. 予定提案はどの方針に近いですか？'),
                    items: const [
                      DropdownMenuItem(value: 'balance', child: Text('バランス重視')),
                      DropdownMenuItem(value: 'efficiency', child: Text('効率重視')),
                      DropdownMenuItem(value: 'deadline', child: Text('締切重視')),
                      DropdownMenuItem(value: 'energy_saving', child: Text('無理なさ重視')),
                      DropdownMenuItem(value: 'minimum', child: Text('最低限だけ')),
                    ],
                    onChanged: (v) => setSheetState(() => planningMode = v ?? planningMode),
                  ),
                  CheckboxListTile(
                    value: uncertainDelete,
                    title: const Text('未確定予定は削除候補にしてよい'),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) => setSheetState(() => uncertainDelete = v ?? false),
                  ),
                  TextField(
                    controller: freeTextController,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '自由記入',
                      hintText: '例：面接前日は早めに寝たい、バイト後は休憩したい など',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        final header = await _requireHeader();
                        final state = await widget.api.saveInitialSurvey(
                          googleAuthHeader: header,
                          targetSleepTime: sleepController.text.trim(),
                          targetWakeTime: wakeController.text.trim(),
                          avoidHeavyWorkAfter: heavyController.text.trim(),
                          defaultBufferMinutes: int.tryParse(bufferController.text.trim()) ?? 10,
                          mealDurationMinutes: int.tryParse(mealController.text.trim()) ?? 30,
                          bathDurationMinutes: int.tryParse(bathController.text.trim()) ?? 25,
                          sleepPrepMinutes: int.tryParse(prepController.text.trim()) ?? 20,
                          afterSchoolOrWorkPolicy: afterPolicy,
                          aiCanModifyExistingEvents: modifyPolicy,
                          uncertainEventsCanBeDeleted: uncertainDelete,
                          defaultPlanningMode: planningMode,
                          freeText: freeTextController.text.trim().isEmpty ? null : freeTextController.text.trim(),
                        );
                        if (!mounted) return;
                        Navigator.pop(context);
                        setState(() {
                          _state = state;
                          _message = '初回アンケートを保存し、基本プロフィールと初期ルールを作成しました。';
                        });
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存エラー: $e')));
                      }
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('保存してプロフィール作成'),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Widget _textField(TextEditingController controller, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  Future<void> _analyzeCalendar() async {
    setState(() {
      _analyzing = true;
      _message = 'カレンダー傾向と自由記入からプロフィール見直し項目を作成しています。';
    });
    try {
      final header = await _requireHeader();
      final events = widget.calendarEvents.isEmpty ? await widget.ensureCalendarLoaded() : widget.calendarEvents;
      final result = await widget.api.analyzeProfile(
        googleAuthHeader: header,
        calendarEvents: events,
        calendarCacheSyncedAt: widget.calendarCacheSyncedAt,
        freeText: _analysisFreeTextController.text.trim().isEmpty ? null : _analysisFreeTextController.text.trim(),
      );
      final state = await widget.api.profileState(googleAuthHeader: header);
      if (!mounted) return;
      setState(() {
        _state = state;
        _message = result.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '傾向分析エラー: $e');
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _answer(ProfileReviewItemInfo item, ProfileReviewChoiceInfo choice) async {
    try {
      final header = await _requireHeader();
      final nextState = await widget.api.answerProfileReview(
        googleAuthHeader: header,
        reviewItem: item,
        choiceId: choice.id,
      );
      if (!mounted) return;
      setState(() {
        if (nextState != null) _state = nextState;
        _message = '「${choice.label}」を反映しました。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '回答反映エラー: $e');
    }
  }

  String _profileValue(String key, {String fallback = ''}) {
    final value = _state?.profile[key];
    if (value == null) return fallback;
    final text = value.toString();
    if (text.contains(':') && text.length >= 5) return text.substring(0, 5);
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return RefreshIndicator(
      onRefresh: _loadProfile,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('AIプロフィール', style: Theme.of(context).textTheme.headlineSmall),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _loadProfile,
                icon: const Icon(Icons.refresh),
                label: const Text('再読込'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _openInitialSurvey,
                icon: const Icon(Icons.assignment),
                label: const Text('初回アンケート'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('基本設定・重み付きルール・会話/カレンダー傾向・最近の忙しさをまとめて管理します。'),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(_message!)),
            ),
          ],
          const SizedBox(height: 16),
          _buildAnalysisCard(),
          const SizedBox(height: 16),
          if (_loading && state == null) const Center(child: CircularProgressIndicator()) else ...[
            _buildCoreProfileCard(state),
            const SizedBox(height: 12),
            _buildCurrentStateCard(state),
            const SizedBox(height: 12),
            _buildRulesCard(state),
            const SizedBox(height: 12),
            _buildReviewItemsCard(state),
            const SizedBox(height: 12),
            _buildMemoriesCard(state),
          ],
        ],
      ),
    );
  }

  Widget _buildAnalysisCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('傾向分析', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('現在のFlutterキャッシュ予定を使って、生活傾向・ルール変更候補・最近の忙しさ確認を作成します。'),
            const SizedBox(height: 8),
            TextField(
              controller: _analysisFreeTextController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '自由記入',
                hintText: '例：最近面接が多い、課題を早めに終わらせたい、夜は疲れやすい など',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _analyzing ? null : _analyzeCalendar,
              icon: _analyzing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_graph),
              label: const Text('傾向分析して質問を作成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoreProfileCard(ProfileStateResult? state) {
    final p = state?.profile ?? const <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Core Profile：毎回使う基本設定', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('就寝 ${_shortTime(p['target_sleep_time'] ?? '23:30')}'),
                _chip('起床 ${_shortTime(p['target_wake_time'] ?? '08:00')}'),
                _chip('重い作業回避 ${_shortTime(p['avoid_heavy_work_after'] ?? '22:30')}以降'),
                _chip('バッファ ${p['default_buffer_minutes'] ?? 10}分'),
                _chip('方針 ${p['default_planning_mode'] ?? 'balance'}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStateCard(ProfileStateResult? state) {
    final s = state?.currentUserState ?? CurrentUserStateInfo();
    final updated = s.updatedAt == null ? '未更新' : DateFormat('M/d HH:mm').format(s.updatedAt!.toLocal());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current State：最近の忙しさ・今週のモード', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _chip('忙しさ ${s.loadLevel}/5'),
                _chip('体力 ${s.energyLevel}/5'),
                _chip('モード ${s.planningMode}'),
                _chip('更新 $updated'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRulesCard(ProfileStateResult? state) {
    final rules = state?.rules ?? const <UserProfileRule>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rules：hard / strong / soft / hint', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (rules.isEmpty)
              const Text('まだルールがありません。初回アンケートまたは傾向分析から作成できます。')
            else
              ...rules.map((rule) => ListTile(
                    dense: true,
                    leading: _strengthIcon(rule.strength),
                    title: Text(rule.text),
                    subtitle: Text('${rule.strength} / ${rule.usage} / ${rule.source}'),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewItemsCard(ProfileStateResult? state) {
    final items = state?.reviewItems ?? const <ProfileReviewItemInfo>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Profile Review：AIの仮説・質問・変更候補', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text('未回答の見直し項目はありません。傾向分析ボタンで作成できます。')
            else
              ...items.map((item) => _reviewItemCard(item)),
          ],
        ),
      ),
    );
  }

  Widget _reviewItemCard(ProfileReviewItemInfo item) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title, style: Theme.of(context).textTheme.titleSmall),
            if (item.hypothesis != null) ...[
              const SizedBox(height: 4),
              Text('仮説：${item.hypothesis!}'),
            ],
            const SizedBox(height: 6),
            Text(item.questionText),
            if (item.evidence != null) ...[
              const SizedBox(height: 6),
              Text('根拠：${item.evidence!}', style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: item.choices
                  .map((choice) => OutlinedButton(
                        onPressed: () => _answer(item, choice),
                        child: Text(choice.label),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoriesCard(ProfileStateResult? state) {
    final memories = state?.memories ?? const <Map<String, dynamic>>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Memories：会話・カレンダーから学んだ傾向', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (memories.isEmpty)
              const Text('まだメモリがありません。AI対話や傾向分析から増えていきます。')
            else
              ...memories.take(8).map((memory) {
                final value = memory['value'];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.psychology_alt_outlined),
                  title: Text(memory['key']?.toString() ?? 'memory'),
                  subtitle: Text(value?.toString() ?? ''),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label) => Chip(label: Text(label));

  Icon _strengthIcon(String strength) {
    switch (strength) {
      case 'hard':
        return const Icon(Icons.lock, color: Colors.redAccent);
      case 'strong':
        return const Icon(Icons.priority_high, color: Colors.orangeAccent);
      case 'soft':
        return const Icon(Icons.tune, color: Colors.blueAccent);
      default:
        return const Icon(Icons.lightbulb_outline, color: Colors.grey);
    }
  }

  String _shortTime(dynamic value) {
    final text = value.toString();
    return text.length >= 5 ? text.substring(0, 5) : text;
  }
}
