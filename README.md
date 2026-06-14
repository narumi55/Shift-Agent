# AI Shift Agent v0.12

Flutter Web + FastAPI + Google Calendar + Gemini + OR-Tools + Supabase の予定管理エージェントMVPです。

## v0.12の主な変更

今回の版では、肝心なエージェント部分を強化しました。

- OR-Tools CP-SATで予定配置を厳密化
- 固定予定、移動時間、余白、締切、睡眠時刻、夜の高負荷作業制限を考慮
- 既存Googleカレンダー予定の変更候補UIを追加
- 変更前/変更後/理由/リスクを表示して、承認後だけGoogle Calendarをpatch
- pgvectorで過去の似た記憶検索を追加
- Supabase memories.embedding と `match_memories` RPCを使用
- AI対話で「追加候補」と「変更候補」を分けて確認可能

## 起動方法

### 1. バックエンド

```bash
cd ~/Downloads/shift_agent_app/backend
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt
cp .env.example .env
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

既に `.venv` がある場合:

```bash
cd ~/Downloads/shift_agent_app/backend
source .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### 2. Flutter Web

Google OAuthの承認済みJavaScript生成元と合わせるため、必ず3000番固定で起動します。

```bash
cd ~/Downloads/shift_agent_app/flutter_app
flutter pub get
flutter run -d chrome --web-port 3000
```

ブラウザURL:

```text
http://localhost:3000
```

## `.env` 設定

```env
GEMINI_API_KEY=your_gemini_key
GEMINI_MODEL=gemini-2.5-flash

# 任意。設定するとpgvector用メモリ埋め込みをGeminiで作る。
# 未設定なら無料のhash-fallbackで動く。
GEMINI_EMBEDDING_MODEL=

SUPABASE_URL=https://xxxxxxxx.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
```

`SUPABASE_SERVICE_ROLE_KEY` は絶対にFlutter側やGitHubに置かないでください。バックエンド専用です。

## Supabase設定

1. SupabaseでProjectを作成
2. SQL Editorを開く
3. 初回なら `supabase/migrations/001_agent_schema.sql` をコピーして実行
4. v11から更新する場合は `supabase/migrations/002_pgvector_memory_search.sql` も実行
5. `backend/.env` に `SUPABASE_URL` と `SUPABASE_SERVICE_ROLE_KEY` を設定
6. バックエンド再起動

確認:

```bash
curl http://127.0.0.1:8000/agent/status
```

成功すると、以下のように返ります。

```json
{
  "gemini_key_loaded": true,
  "gemini_model": "gemini-2.5-flash",
  "supabase": {
    "configured": true,
    "url_set": true,
    "key_set": true,
    "pgvector_dim": 768,
    "embedding_model": "hash-fallback"
  }
}
```

## エージェントの内部処理

```text
AI対話で入力
↓
Googleユーザーを識別
↓
Supabaseからprofile/memories取得
↓
pgvectorで今回の相談に似た記憶を検索
↓
Googleカレンダー予定をschedule_itemsへ保存
↓
会話から新しいmemoryを抽出
↓
Geminiがタスク・固定予定・変更候補をJSON抽出
↓
OR-Toolsが柔軟タスクを厳密配置
↓
agent_proposalsに追加/変更候補を保存
↓
ユーザーが了解
↓
Googleカレンダーへinsert/update
↓
decision_logsへ承認履歴を保存
```

## Google Cloud Consoleで必要な設定

- Google Calendar API を有効化
- OAuth同意画面を作成
- テストユーザーに自分のGoogleアカウントを追加
- OAuthクライアントの種類: ウェブ アプリケーション
- 承認済みJavaScript生成元:

```text
http://localhost:3000
http://127.0.0.1:3000
```

## 設計ドキュメント

詳しい設計は `docs/AGENT_ARCHITECTURE.md` を見てください。


## v0.14 Core Agent

Gemini構造化 → OR-Tools最適配置 → Gemini説明生成の3段階に分離しました。既存Googleカレンダー予定の削除候補にも対応しています。詳細は `docs/AGENT_PIPELINE_V14.md` を参照してください。

## v0.15 Safety-first agent pipeline

今回の修正では、カレンダー候補の最終決定をOR-Toolsに寄せ、最後にConflictValidatorで安全確認する構成にしました。

- Geminiは予定の意味を構造化するだけで、時刻つき候補を直接Googleカレンダー候補にしません。
- 時刻が明示された予定も、OR-Tools用タスクに変換してから重複検証します。
- OR-Tools出力だけをcreate_event候補にします。
- fixed予定と重なる候補は候補生成時点で除外されます。
- soft_busyと重なる場合は、delete_event / update_eventが同じ提案セットにある場合だけ許可されます。
- ConflictValidatorが追加・変更・削除後の仮カレンダーを検証し、重複候補を除外します。
- Googleカレンダー予定の保存構造に google_calendar_id / etag / html_link / inferred_by / confidence / last_synced_at などを追加しました。
- Supabase memoriesを、GeminiだけでなくOR-Tools制約にも変換します。

既存DBを使っている場合は、Supabase SQL Editorで以下を実行してください。

```bash
pbcopy < ~/Downloads/shift_agent_app/supabase/migrations/003_calendar_structure_and_validator.sql
```
