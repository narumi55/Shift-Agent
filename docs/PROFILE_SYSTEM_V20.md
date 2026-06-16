# Shift Agent v20 Profile System

v20では、ユーザー理解を次の5つに分けて管理する。

```text
user_profiles
→ 基本設定。就寝時間、起床時間、バッファ、確認必須など

user_rules
→ hard / strong / soft / hint の重み付きルール

memories
→ 会話・カレンダー分析から学んだ傾向

current_user_state
→ 最近忙しいか、今週のモード、今の体力感

profile_review_items
→ AIが見つけた仮説・質問・ルール変更候補をまとめて保存
```

## 追加画面

Flutterに「プロフィール」タブを追加した。

できること:

- 初回アンケートの作成
- 自由記入欄からプロフィール/メモリ候補を作成
- 傾向分析ボタンでカレンダーから生活傾向を抽出
- 最近忙しいかどうかの確認
- AIの仮説をルール化 / メモリ化 / 却下
- 作成済みルールの一覧確認

## 追加API

```text
GET  /profile/state
POST /profile/initial-survey
POST /profile/analyze
POST /profile/review/answer
```

## 追加SQL

```text
supabase/migrations/006_profile_system.sql
```

既存Supabaseを使っている場合はSQL Editorで実行する。

## AIへの反映

`assistant_agent.py` は毎回以下を読み込む。

- `user_profiles`
- `usage = always` の `user_rules`
- `current_user_state`

`memories` はGemini Routerが必要と判断した時だけpgvector検索する。

## ルールの強さ

```text
hard
→ 絶対守る。破るなら提案を出さない

strong
→ かなり重視。基本は守る

soft
→ できれば守る。必要なら破れる

hint
→ 参考情報
```

## 傾向分析の流れ

```text
プロフィールタブで「傾向分析して質問を作成」
↓
Flutterキャッシュ済みカレンダー予定をFastAPIへ送信
↓
FastAPIが予定量、バイト後、夜遅い予定、予定間隔を分析
↓
profile_review_items を作成
↓
ユーザーが選択肢を押す
↓
user_rules / memories / current_user_state に反映
```
