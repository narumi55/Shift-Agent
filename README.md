# AI Shift Agent v0.4

Flutter Web + FastAPI + Google Calendar + Gemini + OR-Tools の予定管理MVPです。

## v0.4で変えたこと

- API URL はコード固定
  - `flutter_app/lib/config/app_config.dart`
  - `http://127.0.0.1:8000`
- Google Web Client ID はコード固定
  - `flutter_app/lib/config/app_config.dart`
- API URL入力欄、Google Client ID入力欄、AIルール表示UIを削除
- 画面を分離
  - カレンダーページ
  - AI対話ページ
- GoogleカレンダーをFlutter Web上に1日タイムラインとして表示
- 予定の直接追加フォームをカレンダーページに配置
- AIのルールはUIには出さず、AIへの内部ルールとして毎回送信

## 起動方法

### 1. バックエンド

```bash
cd ~/Downloads/shift_agent_app/backend
source .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

`.venv` がない場合:

```bash
cd ~/Downloads/shift_agent_app/backend
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
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

## Google Cloud Consoleで必要な設定

OAuthクライアントIDはコードに固定済みです。
ただし、そのクライアントIDのGoogle Cloud Console側で以下が必要です。

- Google Calendar API を有効化
- OAuth同意画面を作成
- テストユーザーに自分のGoogleアカウントを追加
- OAuthクライアントの種類: ウェブ アプリケーション
- 承認済みJavaScript生成元:

```text
http://localhost:3000
http://127.0.0.1:3000
```

## 使い方

### カレンダーページ

1. `Google連携` を押す
2. Googleアカウントでログイン
3. 今日の予定がブラウザ上にタイムライン表示される
4. 下のフォームから予定を直接追加できる

### AI対話ページ

1. `AI対話` ページを開く
2. 今日の予定やタスクを自然文で入力
3. AIがGoogleカレンダーの予定を参照して返答
4. 追加候補が右側に出る
5. 承認した予定だけGoogleカレンダーへ追加

## Geminiを使う場合

バックエンドの `.env` に以下を入れます。

```env
GEMINI_API_KEY=your_api_key_here
GEMINI_MODEL=gemini-2.5-flash
```

未設定でも、サンプルの内蔵ルールで暫定応答します。


## v0.5 修正内容

- Google Calendar API の `timeMin` / `timeMax` にタイムゾーン付きRFC3339形式を送るよう修正。
- Flutter Webから送られる `2026-06-11T00:00:00.000` のようなタイムゾーンなし日時を、バックエンド側で `Asia/Tokyo` として扱うよう修正。
- 予定追加時の開始/終了日時にもタイムゾーンを付与。
- 終日予定もブラウザ上のカレンダー表示に出せるように改善。
- Google連携後、画面右上のログイン表示が更新されるように修正。

## v0.10: 会話ログ保存・Google自動連携

- AI対話ページの会話履歴と未追加の候補予定をブラウザのローカル保存に保存します。
- 画面をリロードしても、前回の会話ログと追加候補を復元します。
- AI対話ページ右上の「ログ削除」で保存済みログを削除できます。
- 起動時に、前回のGoogleログインとCalendar権限が残っていれば自動でGoogle連携し、今日の予定を取得します。
- 初回ログイン、権限切れ、ブラウザ側で自動ログインが拒否された場合は、従来どおりカレンダーページの「Google連携」を押してください。
