import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../models/schedule_models.dart';
import '../services/api_client.dart';
import '../services/google_auth_service.dart';

const _samplePrompt = '''あなたは、私の日常タスクを整理するローカルLLMアシスタントです。
今日の日付は 2026年6月8日（月）、現在時刻は 09:10、タイムゾーンは日本時間です。
私は専門学校生で、今日は学校、課題、就活、アルバイト、個人開発が混ざっています。
23:30には寝たいです。睡眠不足気味なので、深夜作業は避けたいです。

固定予定：
オンライン授業 10:30〜11:20 自宅。人工知能に関する授業。出席必要。
キャリア面談 14:00〜14:40 オンライン。明日の面接に向けた確認。固定。
アルバイト 16:00〜20:00 店舗。自宅から店舗まで35分。15:20には家を出る必要あり。着替えや準備10分。
Discord作業通話 20:45〜21:30 未確定。課題が終わっていない場合は断ってよい。

今日中の作業：
AIレポート：締切今日23:59。800〜1000字。テーマ「人工知能と自分がやりたいこと」。60〜90分。優先度かなり高い。
明日の面接準備：明日10:00オンライン。会社概要、志望理由、逆質問2つ、1分自己紹介。最低30分、できれば60分。
個人開発：写真が一部取り込まれない問題。友人に今日の夜軽く見ておくと言った。30分だけでよい。22:30以降はコード作業しない。
先生へのメール：前回授業欠席理由。今日中。10分。
洗剤の買い物：母から依頼。スーパー9:00〜22:00。徒歩7分、買い物15分。

メッセージ：母、田中、個人開発の友人、先生、チームメンバーに返信したい。

出してほしい内容：
今日の最重要事項、固定・変更可能・未確定の分類、09:10〜23:30の現実的な予定、返信文、AIレポート構成案、明日の面接準備、今日やらない方がいいこと、不明点・矛盾。
''';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _baseUrlController = TextEditingController(text: 'http://127.0.0.1:8000');
  final _googleClientIdController = TextEditingController();
  final _messageController = TextEditingController(text: _samplePrompt);
  final _manualTitleController = TextEditingController(text: 'AIレポート作成');
  final _manualStartController = TextEditingController(text: '2026-06-08 11:30');
  final _manualEndController = TextEditingController(text: '2026-06-08 12:50');
  final _manualMemoController = TextEditingController(text: 'AIシフトエージェントから追加');

  final _auth = GoogleAuthService();
  final List<CalendarEventInfo> _calendarEvents = [];
  final List<ChatBubble> _messages = [
    ChatBubble(
      role: 'assistant',
      content: 'こんにちは。Googleカレンダーを確認して、固定予定を守りながら今日の計画を作れます。まずはmockモードで試すか、Google連携してください。',
    ),
  ];
  final List<ScheduledItem> _suggestedEvents = [];

  String? _googleAuthHeader;
  String? _googleEmail;
  bool _loading = false;
  bool _mockCalendar = true;
  bool _apiOk = false;
  String _status = '未接続';

  final List<AssistantRule> _rules = [
    AssistantRule(id: 'fixed', title: '固定予定は動かさない', detail: '学校、面談、アルバイト、移動時間は優先して守る。'),
    AssistantRule(id: 'deadline', title: '今日中の締切を最優先', detail: 'AIレポート、先生へのメール、明日の面接準備を軽視しない。'),
    AssistantRule(id: 'sleep', title: '23:30就寝を守る', detail: '22:30以降はコード作業や重い作業を避ける。'),
    AssistantRule(id: 'buffer', title: '余白を入れる', detail: '移動、食事、入浴、寝る準備、10分程度の余白を予定に入れる。'),
    AssistantRule(id: 'conflict', title: '矛盾は指摘する', detail: 'Discordとゲームなど、重なる予定は勝手に両方入れない。'),
    AssistantRule(id: 'approval', title: '追加前に承認する', detail: 'AIが勝手にカレンダーへ書き込まず、ユーザーがボタンで追加する。'),
  ];

  ApiClient get _api => ApiClient(baseUrl: _baseUrlController.text.trim());
  final _df = DateFormat('M/d(E) HH:mm', 'ja_JP');

  @override
  void initState() {
    super.initState();
    _checkApi();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _googleClientIdController.dispose();
    _messageController.dispose();
    _manualTitleController.dispose();
    _manualStartController.dispose();
    _manualEndController.dispose();
    _manualMemoController.dispose();
    _auth.dispose();
    super.dispose();
  }

  DateTime _sampleDayStart() => DateTime.parse('2026-06-08T09:10:00+09:00');
  DateTime _sampleDayEnd() => DateTime.parse('2026-06-08T23:30:00+09:00');

  Future<void> _checkApi() async {
    setState(() {
      _loading = true;
      _status = 'API接続を確認中...';
    });
    try {
      await _api.health();
      setState(() {
        _apiOk = true;
        _status = 'API接続OK';
      });
    } catch (e) {
      setState(() {
        _apiOk = false;
        _status = 'API接続エラー: $e';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _connectGoogle() async {
    final clientId = _googleClientIdController.text.trim();
    if (kIsWeb && clientId.isEmpty) {
      setState(() {
        _status = 'Google Web Client IDが未入力です。Google Cloud Consoleで作成した「ウェブアプリケーション」のクライアントIDを貼ってください。';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Googleカレンダー権限を確認中...';
    });
    try {
      await _auth.init(clientId: clientId.isEmpty ? null : clientId);
      final header = await _auth.calendarAuthorizationHeader();
      setState(() {
        _googleAuthHeader = header;
        _googleEmail = _auth.email;
        if (header != null) {
          _mockCalendar = false;
          _status = 'Google連携OK${_googleEmail == null ? '' : '（$_googleEmail）'}。次に「カレンダー確認」を押してください。';
        } else {
          _status = 'Google認証に失敗しました。Google Cloud Consoleの承認済みJavaScript生成元とスコープを確認してください。';
        }
      });
    } catch (e) {
      setState(() => _status = 'Google認証エラー: $e\n\nよくある原因: Web Client ID未入力、承認済みJavaScript生成元に http://localhost:3000 がない、OAuth同意画面のテストユーザーに自分のGoogleアカウントを追加していない。');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _readCalendar() async {
    setState(() {
      _loading = true;
      _status = _mockCalendar ? 'mockカレンダーを確認中...' : 'Googleカレンダーを確認中...';
    });
    try {
      final events = await _api.calendarEvents(
        timeMin: _sampleDayStart(),
        timeMax: _sampleDayEnd(),
        mock: _mockCalendar,
        googleAuthHeader: _googleAuthHeader,
      );
      setState(() {
        _calendarEvents
          ..clear()
          ..addAll(events);
        _status = '${events.length}件の予定を取得しました。AIはこの予定を見て計画できます。';
      });
    } catch (e) {
      setState(() => _status = 'カレンダー確認エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _sendToAssistant() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _loading = true;
      _status = 'AIがルールとカレンダーを見ながら計画中...';
      _messages.add(ChatBubble(role: 'user', content: text));
    });
    try {
      final result = await _api.assistantChat(
        message: text,
        mock: _mockCalendar,
        googleAuthHeader: _googleAuthHeader,
        calendarEvents: _calendarEvents,
        rules: _rules,
        history: _messages,
      );
      setState(() {
        _messages.add(ChatBubble(role: 'assistant', content: result.reply));
        _suggestedEvents
          ..clear()
          ..addAll(result.suggestedEvents);
        _status = result.calendarVisible
            ? 'AI応答完了。AIはカレンダー取得済み予定を見ています。'
            : 'AI応答完了。ただし実カレンダーはまだ見えていません。';
        if (result.warnings.isNotEmpty) {
          _messages.add(ChatBubble(role: 'assistant', content: '注意:\n${result.warnings.map((e) => '・$e').join('\n')}'));
        }
      });
    } catch (e) {
      setState(() => _status = 'AI応答エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  DateTime? _parseInputDateTime(String value) {
    final v = value.trim().replaceAll('/', '-');
    final normalized = v.contains('T') ? v : v.replaceFirst(' ', 'T');
    try {
      if (normalized.length == 16) {
        return DateTime.parse('$normalized:00+09:00');
      }
      if (normalized.length == 19) {
        return DateTime.parse('$normalized+09:00');
      }
      return DateTime.parse(normalized);
    } catch (_) {
      return null;
    }
  }

  Future<void> _insertManual() async {
    final title = _manualTitleController.text.trim();
    final start = _parseInputDateTime(_manualStartController.text);
    final end = _parseInputDateTime(_manualEndController.text);
    if (title.isEmpty || start == null || end == null || !end.isAfter(start)) {
      setState(() => _status = '手動追加エラー: タイトル、開始、終了を確認してください。例 2026-06-08 11:30');
      return;
    }
    setState(() {
      _loading = true;
      _status = _mockCalendar ? 'mock予定を追加中...' : 'Googleカレンダーへ予定を追加中...';
    });
    try {
      await _api.insertManualEvent(
        title: title,
        start: start,
        end: end,
        timezone: 'Asia/Tokyo',
        mock: _mockCalendar,
        googleAuthHeader: _googleAuthHeader,
        notes: _manualMemoController.text.trim(),
      );
      setState(() => _status = _mockCalendar ? 'mock追加完了。Googleには書き込んでいません。' : 'Googleカレンダーへ追加しました。');
      await _readCalendar();
    } catch (e) {
      setState(() => _status = '予定追加エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _insertSuggested(ScheduledItem item) async {
    setState(() {
      _loading = true;
      _status = _mockCalendar ? 'mock追加中...' : 'Googleカレンダーへ追加中...';
    });
    try {
      await _api.insertEvent(
        item: item,
        timezone: 'Asia/Tokyo',
        mock: _mockCalendar,
        googleAuthHeader: _googleAuthHeader,
      );
      setState(() => _status = _mockCalendar ? 'mock追加完了。Googleには書き込んでいません。' : 'Googleカレンダーへ追加しました。');
    } catch (e) {
      setState(() => _status = '追加エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _insertAllSuggested() async {
    if (_suggestedEvents.isEmpty) return;
    setState(() {
      _loading = true;
      _status = _mockCalendar ? '予定案をmock追加中...' : '予定案をGoogleカレンダーへ追加中...';
    });
    try {
      for (final item in _suggestedEvents) {
        await _api.insertEvent(
          item: item,
          timezone: 'Asia/Tokyo',
          mock: _mockCalendar,
          googleAuthHeader: _googleAuthHeader,
        );
      }
      setState(() => _status = _mockCalendar ? '予定案をmock追加しました。' : '予定案をGoogleカレンダーへ追加しました。');
    } catch (e) {
      setState(() => _status = '一括追加エラー: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _statusChip({required IconData icon, required String label, required bool ok}) {
    return Chip(
      avatar: Icon(icon, size: 18, color: ok ? Colors.green : Colors.orange),
      label: Text(label),
    );
  }

  Widget _sectionTitle(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 8),
          Text(text, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    );
  }

  Widget _buildRuleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AIに守らせるルール', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final rule in _rules)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${rule.title}：${rule.detail}')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('AIが見えるカレンダー予定', style: Theme.of(context).textTheme.titleMedium)),
                Text('${_calendarEvents.length}件'),
              ],
            ),
            const SizedBox(height: 8),
            if (_calendarEvents.isEmpty)
              const Text('まだ取得していません。「カレンダー確認」を押すと、AIが見られる予定がここに出ます。'),
            for (final e in _calendarEvents)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(e.source == 'mock' ? Icons.science : Icons.event),
                title: Text(e.title),
                subtitle: Text('${_df.format(e.start)} 〜 ${_df.format(e.end)} / ${e.source}'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AIと対話する', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final msg in _messages.take(8))
              Align(
                alignment: msg.role == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 900),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: msg.role == 'user' ? Colors.indigo.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(msg.content),
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'AIに相談する内容',
                hintText: '今日の予定、課題、返信文、追加したいシフトなどを入力',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _sendToAssistant,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('AIに計画を作らせる'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _messageController.text = _samplePrompt),
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('今日のサンプルを入れる'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestedCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('AIが提案した追加予定', style: Theme.of(context).textTheme.titleMedium)),
                OutlinedButton.icon(
                  onPressed: _loading || _suggestedEvents.isEmpty ? null : _insertAllSuggested,
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text(_mockCalendar ? '全件mock追加' : '全件カレンダー追加'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_suggestedEvents.isEmpty)
              const Text('AIに計画を作らせると、ここにカレンダー追加候補が表示されます。勝手には追加しません。'),
            for (final item in _suggestedEvents)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(item.kind == 'shift' ? Icons.work_outline : Icons.task_alt),
                  title: Text(item.title),
                  subtitle: Text('${_df.format(item.start)} 〜 ${_df.format(item.end)}\n${item.reason}'),
                  trailing: OutlinedButton(
                    onPressed: _loading ? null : () => _insertSuggested(item),
                    child: Text(_mockCalendar ? 'mock追加' : '追加'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualAddCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('カレンダーへ直接予定を入力', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _manualTitleController,
              decoration: const InputDecoration(labelText: '予定タイトル', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualStartController,
                    decoration: const InputDecoration(labelText: '開始 例 2026-06-08 11:30', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _manualEndController,
                    decoration: const InputDecoration(labelText: '終了 例 2026-06-08 12:50', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _manualMemoController,
              decoration: const InputDecoration(labelText: 'メモ', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _loading ? null : _insertManual,
              icon: const Icon(Icons.event_available),
              label: Text(_mockCalendar ? 'mockで直接追加' : 'Googleカレンダーへ直接追加'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final calendarReady = _mockCalendar || _googleAuthHeader != null;
    final aiCanSeeCalendar = _calendarEvents.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Shift Agent'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'API URL',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _checkApi(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _googleClientIdController,
              decoration: const InputDecoration(
                labelText: 'Google Web Client ID（Chrome実行時に必須）',
                hintText: 'xxxxx.apps.googleusercontent.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statusChip(icon: Icons.api, label: _apiOk ? 'API接続OK' : 'API未確認', ok: _apiOk),
                _statusChip(icon: Icons.calendar_month, label: _mockCalendar ? 'mockカレンダー' : 'Google連携', ok: calendarReady),
                _statusChip(icon: Icons.visibility, label: aiCanSeeCalendar ? 'AIが予定を見ています' : 'AIはまだ予定未取得', ok: aiCanSeeCalendar),
                if (_googleEmail != null)
                  _statusChip(icon: Icons.account_circle, label: _googleEmail!, ok: true),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _mockCalendar,
              onChanged: (v) => setState(() => _mockCalendar = v),
              title: const Text('mockモード'),
              subtitle: const Text('ONならGoogleに書き込まず練習。OFFはGoogle連携後に使用。'),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _loading ? null : _checkApi,
                  icon: const Icon(Icons.refresh),
                  label: const Text('API確認'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _connectGoogle,
                  icon: const Icon(Icons.login),
                  label: const Text('Google連携'),
                ),
                FilledButton.icon(
                  onPressed: _loading ? null : _readCalendar,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('カレンダー確認'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status),
              ),
            ),
            _sectionTitle('ルール付け', Icons.rule),
            _buildRuleCard(),
            _sectionTitle('カレンダー確認', Icons.calendar_month),
            _buildCalendarCard(),
            _sectionTitle('対話', Icons.chat_bubble_outline),
            _buildChatCard(),
            _sectionTitle('予定案の承認', Icons.fact_check_outlined),
            _buildSuggestedCard(),
            _sectionTitle('手動追加', Icons.add_circle_outline),
            _buildManualAddCard(),
          ],
        ),
      ),
    );
  }
}
