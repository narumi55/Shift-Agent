# Shift Agent v0.14 Core Agent Pipeline

v0.14では、AIが直接予定表を作る方式をやめ、以下の3段階に分離しています。

## 1. Gemini Structurer
Geminiはユーザー入力、Googleカレンダー、Supabaseメモリ、pgvector類似記憶を読み、最終時刻ではなく以下をJSON化します。

- 今日の最重要事項
- 固定予定 / 変更可能予定 / 未確定予定
- 時間未定タスク
- 理想所要時間 `duration_minutes`
- 最低所要時間 `min_duration_minutes`
- 締切、疲労度、分割可否、移動時間
- 既存Google予定の fixed / flexible / uncertain 分類
- 既存予定の変更/削除候補
- 不明点・矛盾

## 2. OR-Tools Scheduler
OR-ToolsはGeminiが構造化したタスクだけを入力として、実際の時刻を決めます。

- fixed予定はハード制約
- flexible / uncertain予定はsoft busyとして扱う
- タスクは optional interval として扱う
- 理想時間と最低時間を候補化
- 高優先度タスクは短縮してでも入れる
- 締切、就寝時刻、夜の高負荷作業回避を考慮
- soft busyと重なる場合は既存予定の削除/変更候補を出す

## 3. Gemini Explainer
最後にGeminiは、OR-Toolsが決めた結果だけを説明文にします。
この段階では新しい時刻を勝手に作りません。

## Calendar Execution
Googleカレンダーの追加・変更・削除は、Flutter UIでユーザーが「了解して実行」を押した後だけ実行します。

対応操作:

- `create_event`
- `update_event`
- `delete_event`

## Safety
- 既存予定は自動変更しない
- 固定予定は原則変更提案しない
- 削除は必ず確認UI経由
- Geminiが作った時刻ではなくOR-Toolsの時刻を採用する
