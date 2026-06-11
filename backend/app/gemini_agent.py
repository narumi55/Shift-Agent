from __future__ import annotations

import os
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from typing import Optional

from pydantic import BaseModel, Field

from .schemas import AgentParseResponse, ShiftRequirement, TaskItem


class GeminiTask(BaseModel):
    title: str
    duration_minutes: int = Field(ge=15, le=720)
    priority: int = Field(ge=1, le=5)
    deadline: Optional[str] = None
    earliest_start: Optional[str] = None
    kind: str = "task"
    notes: Optional[str] = None


class GeminiShift(BaseModel):
    title: str = "仕事シフト"
    start: Optional[str] = None
    end: Optional[str] = None
    duration_minutes: Optional[int] = Field(default=None, ge=30, le=720)
    priority: int = Field(default=5, ge=1, le=5)
    notes: Optional[str] = None


class GeminiParseResult(BaseModel):
    tasks: list[GeminiTask] = []
    shifts: list[GeminiShift] = []
    reply: str


def _parse_dt(value: Optional[str], timezone: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo(timezone))
        return dt
    except Exception:
        return None


def _fallback_parse(text: str, timezone: str) -> AgentParseResponse:
    """Gemini API keyがない時でも画面確認できる簡易パーサー。"""
    now = datetime.now(ZoneInfo(timezone))
    tasks: list[TaskItem] = []
    shifts: list[ShiftRequirement] = []

    # とりあえず入力文を1つのタスクとして扱う。
    duration = 60
    for token in ["30分", "1時間", "2時間", "3時間", "4時間", "5時間", "6時間", "8時間"]:
        if token in text:
            duration = 30 if token == "30分" else int(token.replace("時間", "")) * 60

    if "シフト" in text or "出勤" in text or "バイト" in text or "仕事" in text:
        shifts.append(
            ShiftRequirement(
                title="仕事シフト",
                duration_minutes=duration if duration >= 30 else 180,
                priority=5,
                notes=text,
            )
        )
    else:
        tasks.append(
            TaskItem(
                title=text[:24] or "新しいタスク",
                duration_minutes=duration,
                priority=3,
                deadline=now + timedelta(days=7),
                notes=text,
            )
        )
    return AgentParseResponse(tasks=tasks, shifts=shifts, reply="Gemini未設定のため簡易解析で予定候補を作成しました。")


def parse_with_gemini(text: str, timezone: str = "Asia/Tokyo") -> AgentParseResponse:
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        return _fallback_parse(text, timezone)

    try:
        from google import genai
        from google.genai import types

        client = genai.Client(api_key=api_key)
        prompt = f"""
あなたはシフト管理・タスク管理アプリの予定抽出エージェントです。
ユーザーの自然文から、カレンダーに追加できるタスクまたはシフト候補だけを抽出してください。
現在のタイムゾーンは {timezone} です。
日時はISO 8601形式で返してください。曖昧な場合は null にしてください。

ユーザー入力:
{text}
"""
        result = client.models.generate_content(
            model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=GeminiParseResult,
            ),
        )
        parsed: GeminiParseResult = result.parsed
        tasks = [
            TaskItem(
                title=t.title,
                duration_minutes=t.duration_minutes,
                priority=t.priority,
                deadline=_parse_dt(t.deadline, timezone),
                earliest_start=_parse_dt(t.earliest_start, timezone),
                kind="shift" if t.kind == "shift" else "task",
                notes=t.notes,
            )
            for t in parsed.tasks
        ]
        shifts = [
            ShiftRequirement(
                title=s.title,
                start=_parse_dt(s.start, timezone),
                end=_parse_dt(s.end, timezone),
                duration_minutes=s.duration_minutes,
                priority=s.priority,
                notes=s.notes,
            )
            for s in parsed.shifts
        ]
        return AgentParseResponse(tasks=tasks, shifts=shifts, reply=parsed.reply)
    except Exception as e:
        fallback = _fallback_parse(text, timezone)
        fallback.reply += f" Gemini解析でエラーが出たため簡易解析に切り替えました: {e}"
        return fallback
