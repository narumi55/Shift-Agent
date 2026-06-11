from __future__ import annotations

import os
from dotenv import load_dotenv
from datetime import datetime
from zoneinfo import ZoneInfo
from typing import Optional

from pydantic import BaseModel, Field

from .schemas import AssistantChatRequest, AssistantChatResponse, ScheduledItem, CalendarEventInfo

# .env の GEMINI_API_KEY を読み込む
load_dotenv()

DAILY_PLAN_RULE_ONLY = """あなたは、私の日常タスクを整理するローカルLLMアシスタントです。以下の長い情報をすべて読んだうえで、今日の行動計画を作ってください。

重要：

タイムゾーンは日本時間,
私は専門学校生です,
今日は学校、課題、就活、アルバイト、個人開発の予定が混ざっています,
23:30には寝たいです,
睡眠不足気味なので、深夜作業は避けたいです,
予定は「固定」「変更可能」「未確定」を分けて扱ってください,
情報が矛盾している場合は、勝手に決めつけず、矛盾として指摘してください,

私の基本情報

私は現在、専門学校に通いながら、個人開発で写真整理アプリのようなものも作っています。
就活も進めていて、明日の午前中にオンライン面接があります。
今日は夕方からアルバイトがあり、これは基本的に動かせません。
移動時間や食事時間を甘く見積もりすぎると破綻しやすいので、なるべく現実的な予定にしてください。

出力してほしい内容

次の形式で答えてください。

今日の最重要事項,
今日絶対に落としてはいけないものを3つ以内で挙げる,
理由も短く書く,
固定予定・変更可能予定・未確定予定の分類,
固定予定,
変更可能予定,
未確定予定,
に分けて整理する

09:10から23:30までの現実的な予定を作る,
移動、食事、休憩、入浴、寝る準備も入れる,
10分程度の余白を適度に入れる,
破綻しそうな予定は入れない,

制約：

勝手に存在しない予定や事実を作らないこと,
今日中の締切を軽視しないこと,
すべてを完璧にやろうとせず、優先順位をつけること,
文章は日本語で、実用的に書くこと"""


class GeminiSuggestedEvent(BaseModel):
    title: str
    start: str
    end: str
    priority: int = Field(default=3, ge=1, le=5)
    kind: str = "task"
    notes: Optional[str] = None
    reason: str = ""


class GeminiChatResult(BaseModel):
    reply: str
    suggested_events: list[GeminiSuggestedEvent] = []
    warnings: list[str] = []
    rules_applied: list[str] = []


def _parse_dt(value: str, timezone: str) -> Optional[datetime]:
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo(timezone))
        return dt
    except Exception:
        return None


def _event(
    title: str,
    start: str,
    end: str,
    priority: int,
    kind: str,
    reason: str,
    timezone: str,
    notes: str = "",
) -> Optional[ScheduledItem]:
    s = _parse_dt(start, timezone)
    e = _parse_dt(end, timezone)
    if not s or not e or e <= s:
        return None
    return ScheduledItem(
        title=title,
        start=s,
        end=e,
        priority=priority,
        kind="shift" if kind == "shift" else "task",
        reason=reason,
        notes=notes or reason,
    )


def _looks_like_duplicate(item: ScheduledItem, events: list[CalendarEventInfo]) -> bool:
    item_title = item.title.strip().lower()
    for ev in events:
        ev_title = ev.title.strip().lower()
        same_title = item_title and ev_title and (item_title == ev_title or item_title in ev_title or ev_title in item_title)
        same_time = abs((item.start - ev.start).total_seconds()) < 300 and abs((item.end - ev.end).total_seconds()) < 300
        overlap = item.start < ev.end and ev.start < item.end
        if same_title and (same_time or overlap):
            return True
    return False


def _fallback_today_plan(req: AssistantChatRequest) -> AssistantChatResponse:
    """Gemini未設定時の安全な応答。

    ユーザー入力とGoogleカレンダーだけを使う方針を明示する。
    """
    calendar_note = (
        f"Googleカレンダー予定は{len(req.calendar_events)}件取得済みです。"
        if req.calendar_events
        else "Googleカレンダー予定はまだ取得できていません。"
    )

    reply = f"""## 今日の最重要事項
Gemini APIキーが未設定、またはGemini呼び出しに失敗したため、AIによる詳細な行動計画はまだ作成できません。

## 固定予定・変更可能予定・未確定予定の分類
{calendar_note} ただし、Geminiが使えない状態では、入力文から固定予定・変更可能予定・未確定予定を正確に抽出しません。

## 今日のタイムスケジュール
現時点では、勝手に存在しない予定を作らないため、カレンダー入力候補は作成しません。

## 不明点・確認すべきこと
バックエンドの `.env` に `GEMINI_API_KEY` を設定すると、入力文とGoogleカレンダー予定をもとに行動計画とカレンダー追加候補を作成できます。
"""
    return AssistantChatResponse(
        reply=reply,
        suggested_events=[],
        warnings=["Gemini APIキー未設定または応答失敗のため、追加候補なしで返しました。"],
        calendar_visible=bool(req.calendar_events) or not req.mock,
        rules_applied=["日常タスク整理ルール"],
    )


def _system_prompt(req: AssistantChatRequest) -> str:
    # ルールはフロントから渡された1件のみを優先。無ければ同じ内容の定数を使う。
    rule_text = "\n\n".join(r.detail for r in req.rules if r.enabled).strip() or DAILY_PLAN_RULE_ONLY
    cal_text = "\n".join(
        f"- {e.start.isoformat()}〜{e.end.isoformat()} {e.title}" for e in req.calendar_events
    ) or "- カレンダー予定は未取得。"
    history_text = "\n".join(
        f"{m.role}: {m.content}" for m in req.history[-8:]
    ) or "- 会話履歴なし。"
    now_text = req.now.isoformat() if req.now else "未指定"
    return f"""
あなたはユーザーの予定整理を支援するアシスタントです。
次の「固定ルール」だけを守ってください。

固定ルール:
{rule_text}

現在時刻: {now_text}
タイムゾーン: {req.timezone}

AIが現在見えているGoogleカレンダー予定:
{cal_text}

直近の会話履歴:
{history_text}

ユーザーの入力文とGoogleカレンダー予定を読み、固定ルールの形式に沿って日本語Markdownで返答してください。

カレンダー追加候補についての処理仕様:
- 予定としてGoogleカレンダーに入れた方がよいものがある場合だけ suggested_events に入れてください。
- 既にGoogleカレンダーにある予定と同じ予定は suggested_events に入れないでください。
- suggested_events の日時は必ずISO 8601形式で返し、タイムゾーンは {req.timezone} にしてください。
- AI自身が予定を追加したとは書かないでください。画面でユーザーが了解した場合のみアプリが追加します。
- 候補がない場合は suggested_events を空配列にしてください。
"""


def chat_with_assistant(req: AssistantChatRequest) -> AssistantChatResponse:
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        return _fallback_today_plan(req)

    try:
        from google import genai
        from google.genai import types

        client = genai.Client(api_key=api_key)
        contents = _system_prompt(req) + "\n\nユーザー入力:\n" + req.message
        result = client.models.generate_content(
            model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
            contents=contents,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=GeminiChatResult,
            ),
        )
        parsed: GeminiChatResult = result.parsed
        items: list[ScheduledItem] = []
        warnings = list(parsed.warnings)
        for ev in parsed.suggested_events:
            item = _event(ev.title, ev.start, ev.end, ev.priority, ev.kind, ev.reason, req.timezone, ev.notes or "")
            if not item:
                warnings.append(f"日時形式が不正な候補を除外しました: {ev.title}")
                continue
            if _looks_like_duplicate(item, req.calendar_events):
                warnings.append(f"既存カレンダー予定と重複しそうな候補を除外しました: {item.title}")
                continue
            items.append(item)
        return AssistantChatResponse(
            reply=parsed.reply,
            suggested_events=items,
            warnings=warnings,
            calendar_visible=bool(req.calendar_events) or not req.mock,
            rules_applied=["日常タスク整理ルール"],
        )
    except Exception as e:
        res = _fallback_today_plan(req)
        res.warnings.append(f"Gemini応答に失敗しました: {e}")
        return res
