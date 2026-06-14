from __future__ import annotations

import os
from dotenv import load_dotenv
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo
from typing import Any, Optional, Literal

from pydantic import BaseModel, Field

from .memory_engine import extract_memories_from_text, profile_summary
from .schemas import (
    AssistantChatRequest,
    AssistantChatResponse,
    BusyBlock,
    CalendarEventInfo,
    ProposedAction,
    ScheduleRequest,
    ScheduledItem,
    TaskItem,
)
from .scheduler import solve_schedule
from .conflict_validator import validate_proposed_actions
from .supabase_service import get_supabase_service
from .user_identity import identity_from_google_token

load_dotenv()

DAILY_PLAN_RULE_ONLY = """あなたは、私の日常タスクを整理するローカルLLMアシスタントです。以下の長い情報をすべて読んだうえで、今日の行動計画を作ってください。

重要：
タイムゾーンは日本時間, 私は専門学校生です, 今日は学校、課題、就活、アルバイト、個人開発の予定が混ざっています, 23:30には寝たいです, 睡眠不足気味なので、深夜作業は避けたいです, 予定は「固定」「変更可能」「未確定」を分けて扱ってください, 情報が矛盾している場合は、勝手に決めつけず、矛盾として指摘してください,

私の基本情報
私は現在、専門学校に通いながら、個人開発で写真整理アプリのようなものも作っています。就活も進めていて、明日の午前中にオンライン面接があります。今日は夕方からアルバイトがあり、これは基本的に動かせません。移動時間や食事時間を甘く見積もりすぎると破綻しやすいので、なるべく現実的な予定にしてください。

出力してほしい内容
今日の最重要事項, 今日絶対に落としてはいけないものを3つ以内で挙げる, 理由も短く書く, 固定予定・変更可能予定・未確定予定の分類, 固定予定, 変更可能予定, 未確定予定, に分けて整理する。09:10から23:30までの現実的な予定を作る, 移動、食事、休憩、入浴、寝る準備も入れる, 10分程度の余白を適度に入れる, 破綻しそうな予定は入れない。

制約：
勝手に存在しない予定や事実を作らないこと, 今日中の締切を軽視しないこと, すべてを完璧にやろうとせず、優先順位をつけること, 文章は日本語で、実用的に書くこと"""


class StructuredTask(BaseModel):
    title: str
    category: Literal["school", "job_hunt", "work", "personal_dev", "life", "social", "other"] = "other"
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "flexible"
    duration_minutes: int = Field(default=60, ge=15, le=720, description="理想所要時間")
    min_duration_minutes: int = Field(default=30, ge=15, le=720, description="最低限確保したい時間")
    priority: int = Field(default=3, ge=1, le=5)
    importance_score: int = Field(default=50, ge=0, le=100)
    urgency_score: int = Field(default=50, ge=0, le=100)
    deadline: Optional[str] = None
    earliest_start: Optional[str] = None
    latest_end: Optional[str] = None
    energy_required: Literal["low", "medium", "high"] = "medium"
    mental_load: Literal["low", "medium", "high"] = "medium"
    can_split: bool = False
    travel_before_minutes: int = Field(default=0, ge=0, le=240)
    travel_after_minutes: int = Field(default=0, ge=0, le=240)
    location: Optional[str] = None
    reason: str = ""
    notes: Optional[str] = None


class ExactCreateEvent(BaseModel):
    title: str
    start: str
    end: str
    category: Literal["school", "job_hunt", "work", "personal_dev", "life", "social", "other"] = "other"
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "fixed"
    priority: int = Field(default=3, ge=1, le=5)
    reason: str = ""
    notes: Optional[str] = None


class ExistingEventInterpretation(BaseModel):
    event_id: str
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "fixed"
    movable: bool = False
    can_cancel: bool = False
    category: Literal["school", "job_hunt", "work", "personal_dev", "life", "social", "other"] = "other"
    reason: str = ""


class ExistingEventChange(BaseModel):
    action_type: Literal["update_event", "delete_event"]
    target_event_id: str
    proposed_title: Optional[str] = None
    proposed_start: Optional[str] = None
    proposed_end: Optional[str] = None
    reason: str = ""
    risk: Optional[str] = None


class AgentStructureResult(BaseModel):
    priorities: list[str] = []
    fixed_items: list[str] = []
    flexible_items: list[str] = []
    uncertain_items: list[str] = []
    tasks_to_schedule: list[StructuredTask] = []
    exact_create_events: list[ExactCreateEvent] = []
    existing_event_interpretations: list[ExistingEventInterpretation] = []
    existing_event_changes: list[ExistingEventChange] = []
    missing_info: list[str] = []
    conflicts: list[str] = []
    warnings: list[str] = []
    rules_applied: list[str] = []


class AgentExplanationResult(BaseModel):
    reply: str
    warnings: list[str] = []


def _parse_dt(value: Optional[str], timezone: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo(timezone))
        return dt.astimezone(ZoneInfo(timezone))
    except Exception:
        return None


def _format_time(dt: datetime) -> str:
    return dt.strftime("%H:%M")


def _time_from_profile(value: Any, fallback: time) -> time:
    if isinstance(value, time):
        return value
    if isinstance(value, str):
        try:
            parts = value.split(":")
            return time(hour=int(parts[0]), minute=int(parts[1]) if len(parts) > 1 else 0)
        except Exception:
            return fallback
    return fallback


def _calendar_snapshot(events: list[CalendarEventInfo]) -> list[dict[str, Any]]:
    return [e.model_dump(mode="json") for e in events]


def _relevant_memory_text(memories: list[dict[str, Any]]) -> str:
    if not memories:
        return "- 近い記憶はまだありません。"
    lines = []
    for mem in memories[:12]:
        sim = mem.get("similarity")
        suffix = f" similarity={sim:.3f}" if isinstance(sim, (int, float)) else ""
        lines.append(f"- {mem.get('type')}/{mem.get('key')}: {mem.get('value')} evidence={mem.get('evidence')} confidence={mem.get('confidence')}{suffix}")
    return "\n".join(lines)


def _event_map(events: list[CalendarEventInfo]) -> dict[str, CalendarEventInfo]:
    return {e.id: e for e in events if e.id}


def _overlap(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return a_start < b_end and b_start < a_end


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


def _normalize_task(t: TaskItem) -> TaskItem:
    text = f"{t.title} {t.notes or ''} {t.reason or ''}"
    upd: dict[str, Any] = {}
    if any(k in text for k in ["面接", "就活", "志望理由", "逆質問", "会社概要"]):
        upd.update({"priority": max(t.priority, 5), "category": "job_hunt", "mental_load": "high", "energy_required": "medium" if t.energy_required == "low" else t.energy_required})
        if t.duration_minutes < 45:
            upd["duration_minutes"] = 60
        if not t.min_duration_minutes or t.min_duration_minutes > 45:
            upd["min_duration_minutes"] = 30
    if any(k in text for k in ["課題", "レポート", "提出", "締切", "今日中", "本日中"]):
        upd.update({"priority": max(t.priority, 5), "category": "school" if t.category == "other" else t.category, "mental_load": "high", "energy_required": "high" if t.energy_required != "low" else "medium"})
        if t.duration_minutes < 60:
            upd["duration_minutes"] = 90
        if not t.min_duration_minutes or t.min_duration_minutes > 60:
            upd["min_duration_minutes"] = 60
    if any(k in text for k in ["夕食", "昼食", "食事"]):
        upd.update({"priority": min(t.priority, 3), "category": "life", "energy_required": "low", "mental_load": "low", "duration_minutes": max(20, min(t.duration_minutes, 45)), "min_duration_minutes": max(15, min(t.min_duration_minutes or 20, 30))})
    if "入浴" in text or "風呂" in text:
        upd.update({"priority": min(t.priority, 3), "category": "life", "energy_required": "low", "mental_load": "low", "duration_minutes": max(20, min(t.duration_minutes, 40)), "min_duration_minutes": max(15, min(t.min_duration_minutes or 20, 30))})
    if "寝る準備" in text or "睡眠準備" in text:
        upd.update({"priority": min(t.priority, 3), "category": "life", "energy_required": "low", "mental_load": "low", "duration_minutes": max(15, min(t.duration_minutes, 30)), "min_duration_minutes": max(15, min(t.min_duration_minutes or 15, 20))})
    if any(k in text for k in ["ゲーム", "Discord", "通話", "遊び"]):
        upd.update({"priority": min(t.priority, 1), "category": "social", "schedule_type": "uncertain", "energy_required": "low", "mental_load": "low"})
    return t.model_copy(update=upd)


def _task_from_structured(c: StructuredTask, timezone: str, default_latest_end: Optional[datetime]) -> TaskItem:
    min_duration = min(c.min_duration_minutes, c.duration_minutes)
    return _normalize_task(TaskItem(
        title=c.title,
        duration_minutes=c.duration_minutes,
        min_duration_minutes=min_duration,
        priority=c.priority,
        deadline=_parse_dt(c.deadline, timezone),
        earliest_start=_parse_dt(c.earliest_start, timezone),
        latest_end=_parse_dt(c.latest_end, timezone) or default_latest_end,
        kind="task",
        category=c.category,
        schedule_type=c.schedule_type,
        energy_required=c.energy_required,
        mental_load=c.mental_load,
        can_split=c.can_split,
        location=c.location,
        travel_before_minutes=c.travel_before_minutes,
        travel_after_minutes=c.travel_after_minutes,
        notes=c.notes,
        reason=c.reason,
    ))


def _create_action_from_item(item: ScheduledItem) -> ProposedAction:
    return ProposedAction(
        action_type="create_event",
        title=item.title,
        start=item.start,
        end=item.end,
        priority=item.priority,
        kind=item.kind,
        notes=item.notes,
        reason=item.reason,
        risk=None,
    )


def _create_action_from_exact(c: ExactCreateEvent, timezone: str) -> Optional[ProposedAction]:
    s = _parse_dt(c.start, timezone)
    e = _parse_dt(c.end, timezone)
    if not s or not e or e <= s:
        return None
    return ProposedAction(
        action_type="create_event",
        title=c.title,
        start=s,
        end=e,
        priority=c.priority,
        kind="task",
        notes=c.notes,
        reason=c.reason or "ユーザー入力で時刻が明示された予定のため",
    )


def _event_change_to_action(change: ExistingEventChange, events: list[CalendarEventInfo], timezone: str) -> Optional[ProposedAction]:
    current = _event_map(events).get(change.target_event_id)
    if not current:
        return None
    if change.action_type == "delete_event":
        return ProposedAction(
            action_type="delete_event",
            title=f"削除/キャンセル: {current.title}",
            target_event_id=current.id,
            current_title=current.title,
            current_start=current.start,
            current_end=current.end,
            reason=change.reason,
            risk=change.risk or "既存予定を削除するため、必要なら相手への連絡が必要です。",
        )
    ps = _parse_dt(change.proposed_start, timezone) if change.proposed_start else current.start
    pe = _parse_dt(change.proposed_end, timezone) if change.proposed_end else current.end
    if not ps or not pe or pe <= ps:
        return None
    proposed_title = change.proposed_title or current.title
    return ProposedAction(
        action_type="update_event",
        title=f"{current.title} → {proposed_title}",
        target_event_id=current.id,
        current_title=current.title,
        current_start=current.start,
        current_end=current.end,
        proposed_title=proposed_title,
        proposed_start=ps,
        proposed_end=pe,
        reason=change.reason,
        risk=change.risk,
    )


def _classify_events(events: list[CalendarEventInfo], interpretations: list[ExistingEventInterpretation]) -> list[CalendarEventInfo]:
    by_id = {i.event_id: i for i in interpretations}
    result: list[CalendarEventInfo] = []
    for e in events:
        inter = by_id.get(e.id or "")
        if inter:
            result.append(e.model_copy(update={"schedule_type": inter.schedule_type, "movable": inter.movable, "can_cancel": inter.can_cancel, "category": inter.category, "confidence": 0.9, "inferred_by": "gemini_existing_event_interpretation"}))
        else:
            # タイトルだけでも明らかな未確定/娯楽はsoftにする。安全のため学校/仕事/面接は固定のまま。
            text = e.title
            if any(k in text for k in ["ゲーム", "Discord", "通話", "遊び", "仮", "できたら"]):
                result.append(e.model_copy(update={"schedule_type": "uncertain", "category": "social", "movable": True, "can_cancel": True, "confidence": 0.85, "inferred_by": "title_rule_uncertain"}))
            elif any(k in text for k in ["個人開発", "作業", "自習"]):
                result.append(e.model_copy(update={"schedule_type": "flexible", "category": "personal_dev", "movable": True, "can_cancel": False, "confidence": 0.8, "inferred_by": "title_rule_flexible"}))
            else:
                result.append(e)
    return result


def _memory_constraints(profile: dict[str, Any], memories: list[dict[str, Any]], classified_events: list[CalendarEventInfo], timezone: str) -> dict[str, Any]:
    """Convert Supabase memories into deterministic OR-Tools constraints.

    Memories still help Gemini, but critical lifestyle preferences should also
    become direct solver constraints so they are not lost by LLM wording.
    """
    text = "\n".join(f"{m.get('key')} {m.get('value')} {m.get('evidence')}" for m in memories).lower()
    buffer_minutes = int(profile.get("default_buffer_minutes") or 10)
    if any(k in text for k in ["余裕", "ゆとり", "詰め込み", "移動時間"]):
        buffer_minutes = max(buffer_minutes, 10)

    heavy_avoid_blocks: list[BusyBlock] = []
    avoid_after_work = any(k in text for k in ["バイト後", "仕事後", "アルバイト後", "帰宅後"]) and any(k in text for k in ["重い", "コード", "開発", "疲", "避け"])
    if avoid_after_work:
        for e in classified_events:
            title = e.title.lower()
            is_work = e.category == "work" or any(k in title for k in ["バイト", "アルバイト", "仕事", "勤務", "シフト"])
            if not is_work:
                continue
            heavy_avoid_blocks.append(BusyBlock(start=e.end, end=e.end + timedelta(minutes=60), source="memory_constraint", title="バイト後の高負荷作業回避", event_id=e.id, schedule_type="fixed"))

    return {"default_buffer_minutes": buffer_minutes, "heavy_avoid_blocks": heavy_avoid_blocks}


def _build_schedule_request(req: AssistantChatRequest, profile: dict[str, Any], memories: list[dict[str, Any]], tasks: list[TaskItem], classified_events: list[CalendarEventInfo]) -> ScheduleRequest:
    tz = ZoneInfo(req.timezone)
    now = req.now or datetime.now(tz)
    if now.tzinfo is None:
        now = now.replace(tzinfo=tz)
    now = now.astimezone(tz)
    minute = ((now.minute + 14) // 15) * 15
    window_start = now.replace(second=0, microsecond=0)
    if minute >= 60:
        window_start = window_start.replace(minute=0) + timedelta(hours=1)
    else:
        window_start = window_start.replace(minute=minute)

    sleep_t = _time_from_profile(profile.get("target_sleep_time"), time(23, 30))
    avoid_t = _time_from_profile(profile.get("avoid_heavy_work_after"), time(22, 30))
    window_end = datetime.combine(now.date(), sleep_t, tzinfo=tz)
    if window_end <= window_start:
        window_end = window_start + timedelta(hours=6)
    avoid_after = datetime.combine(now.date(), avoid_t, tzinfo=tz)

    memory_constraints = _memory_constraints(profile, memories, classified_events, req.timezone)

    hard: list[BusyBlock] = []
    soft: list[BusyBlock] = []
    for e in classified_events:
        b = BusyBlock(start=e.start, end=e.end, source=e.source, title=e.title, event_id=e.id, schedule_type=e.schedule_type, movable=e.movable, can_cancel=e.can_cancel)
        if e.schedule_type == "fixed" or (not e.movable and not e.can_cancel):
            hard.append(b)
        else:
            soft.append(b)

    return ScheduleRequest(
        window_start=window_start,
        window_end=window_end,
        busy=hard,
        soft_busy=soft,
        tasks=tasks,
        slot_minutes=15,
        timezone=req.timezone,
        default_buffer_minutes=int(memory_constraints["default_buffer_minutes"]),
        avoid_heavy_work_after=avoid_after,
        heavy_avoid_blocks=memory_constraints["heavy_avoid_blocks"],
        max_continuous_work_minutes=90,
    )


def _make_timeline(events: list[CalendarEventInfo], scheduled: list[ScheduledItem]) -> list[tuple[datetime, datetime, str, str]]:
    rows = [(e.start, e.end, e.title, f"既存/{e.schedule_type}") for e in events]
    rows += [(i.start, i.end, i.title, "AI追加候補") for i in scheduled]
    return sorted(rows, key=lambda r: (r[0], r[1]))


def _auto_soft_event_actions(scheduled: list[ScheduledItem], classified_events: list[CalendarEventInfo]) -> list[ProposedAction]:
    actions: list[ProposedAction] = []
    for ev in classified_events:
        if ev.schedule_type == "fixed" or not ev.id:
            continue
        conflicts = [i for i in scheduled if _overlap(i.start, i.end, ev.start, ev.end)]
        if not conflicts:
            continue
        reason = f"高優先度の予定（{', '.join(i.title for i in conflicts[:2])}）を入れるため、未確定/変更可能な既存予定を調整する必要があります。"
        if ev.can_cancel or ev.schedule_type == "uncertain":
            actions.append(ProposedAction(
                action_type="delete_event",
                title=f"削除/キャンセル: {ev.title}",
                target_event_id=ev.id,
                current_title=ev.title,
                current_start=ev.start,
                current_end=ev.end,
                reason=reason,
                risk="この予定を実行すると既存予定がカレンダーから削除されます。必要なら相手へ連絡してください。",
            ))
        else:
            actions.append(ProposedAction(
                action_type="update_event",
                title=f"調整候補: {ev.title}",
                target_event_id=ev.id,
                current_title=ev.title,
                current_start=ev.start,
                current_end=ev.end,
                proposed_title=f"要調整: {ev.title}",
                proposed_start=ev.start,
                proposed_end=ev.end,
                reason=reason,
                risk="時間変更先が未確定のため、まずタイトルを要調整として残します。",
            ))
    return actions


def _compose_fallback_reply(structured: AgentStructureResult, req: AssistantChatRequest, classified_events: list[CalendarEventInfo], scheduled: list[ScheduledItem], unscheduled: list[str], actions: list[ProposedAction], warnings: list[str]) -> str:
    lines = ["## 今日の最重要事項"]
    if structured.priorities:
        lines += [f"- {p}" for p in structured.priorities[:3]]
    else:
        lines.append("- 入力内容とカレンダー予定から、締切・面接・固定予定を優先して整理しました。")
    lines.append("\n## 固定予定・変更可能予定・未確定予定の分類")
    lines.append("### 固定予定")
    fixed = structured.fixed_items or [f"{_format_time(e.start)}〜{_format_time(e.end)} {e.title}" for e in classified_events if e.schedule_type == "fixed"]
    lines += [f"- {x}" for x in fixed] or ["- なし"]
    lines.append("### 変更可能予定")
    lines += [f"- {x}" for x in (structured.flexible_items or [])] or ["- なし"]
    lines.append("### 未確定予定")
    lines += [f"- {x}" for x in (structured.uncertain_items or [])] or ["- なし"]
    lines.append("\n## OR-Toolsで厳密配置した本日のタイムスケジュール")
    for s, e, title, source in _make_timeline(classified_events, scheduled):
        lines.append(f"- {_format_time(s)}〜{_format_time(e)} {title}（{source}）")
    if unscheduled:
        lines.append("\n## 入れられなかった作業")
        lines += [f"- {u}" for u in unscheduled]
    if actions:
        lines.append("\n## カレンダー操作候補")
        for a in actions:
            if a.action_type == "create_event" and a.start and a.end:
                lines.append(f"- 追加: {_format_time(a.start)}〜{_format_time(a.end)} {a.title} / 理由: {a.reason}")
            elif a.action_type == "delete_event":
                lines.append(f"- 削除: {a.current_title or a.title} / 理由: {a.reason}")
            else:
                lines.append(f"- 変更: {a.title} / 理由: {a.reason}")
    if structured.missing_info or structured.conflicts or warnings:
        lines.append("\n## 不明点・注意")
        for w in structured.missing_info + structured.conflicts + warnings:
            lines.append(f"- {w}")
    lines.append("\n---\n右側の確認欄で『了解して実行』を押すまで、Googleカレンダーには追加・変更・削除しません。")
    return "\n".join(lines)


def _structure_prompt(req: AssistantChatRequest, profile_text: str, relevant_memory_text: str) -> str:
    rule_text = "\n\n".join(r.detail for r in req.rules if r.enabled).strip() or DAILY_PLAN_RULE_ONLY
    cal_text = "\n".join(f"- id={e.id or 'none'} | {e.start.isoformat()}〜{e.end.isoformat()} | {e.title}" for e in req.calendar_events) or "- カレンダー予定は未取得。"
    history_text = "\n".join(f"{m.role}: {m.content}" for m in req.history[-8:]) or "- 会話履歴なし。"
    now_text = req.now.isoformat() if req.now else "未指定"
    return f"""
あなたは予定表を作る係ではなく、予定の意味を高精度に構造化する係です。最終時刻はOR-Toolsが決めます。

固定ルール:
{rule_text}

ユーザー理解:
{profile_text}

今回の相談に近い過去記憶:
{relevant_memory_text}

現在時刻: {now_text}
タイムゾーン: {req.timezone}

Googleカレンダー予定:
{cal_text}

会話履歴:
{history_text}

ユーザーの今回入力:
{req.message}

出力方針:
- 必ずJSONで返す。
- 時間未定の作業は tasks_to_schedule に入れる。ここには理想時間 duration_minutes と最低時間 min_duration_minutes を分けて入れる。
- 時刻が明示された予定は exact_create_events に入れてよいが、最終カレンダー候補には直接使われない。必ずOR-Toolsで重複検証してから配置される。
- Googleカレンダーに存在する予定は再追加しない。
- 既存Googleカレンダー予定を fixed/flexible/uncertain に分類し、existing_event_interpretations に入れる。アルバイト、学校、面接は基本 fixed。ゲーム、仮予定、できたら参加は uncertain。個人開発や自習は movable/flexible になりやすい。
- 既存予定を削除/変更した方がよい場合だけ existing_event_changes に入れる。target_event_idは必ずGoogleカレンダー予定にあるidを使う。
- 面接準備/就活/今日中の課題/締切は priority=5。食事/入浴/寝る準備はpriority=3。任意ゲーム/通話はpriority=1。
- 高負荷タスクは energy_required/high または mental_load/high にする。
- 不明点は missing_info、矛盾は conflicts に入れる。
"""


def _explanation_prompt(req: AssistantChatRequest, structured: AgentStructureResult, classified_events: list[CalendarEventInfo], scheduled: list[ScheduledItem], unscheduled: list[str], actions: list[ProposedAction], warnings: list[str]) -> str:
    return f"""
あなたはユーザーに見せる説明文を作る係です。予定の時刻はすでにOR-Toolsが決めています。勝手に時刻を追加・変更しないでください。

ユーザー入力:
{req.message}

構造化結果:
{structured.model_dump_json(indent=2)}

OR-Toolsで配置された追加候補:
{[i.model_dump(mode='json') for i in scheduled]}

入れられなかった作業:
{unscheduled}

既存Googleカレンダー予定の分類:
{[e.model_dump(mode='json') for e in classified_events]}

カレンダー操作候補:
{[a.model_dump(mode='json') for a in actions]}

注意:
{warnings}

以下の形式で日本語Markdownで出してください。
1. 今日の最重要事項（3つ以内、理由つき）
2. 固定予定・変更可能予定・未確定予定の分類
3. OR-Toolsで厳密配置した本日のタイムスケジュール
4. 入れられなかった作業があれば理由
5. 既存予定の変更/削除提案があれば、変更前・変更後または削除対象・理由・リスク
6. 不明点・確認すべきこと
最後に、右側の確認欄で承認するまでカレンダーは変更されないことを書く。
"""


def _fallback_today_plan(req: AssistantChatRequest, memory_count: int = 0, profile_text: Optional[str] = None, error: Optional[str] = None) -> AssistantChatResponse:
    error_text = f"\n\nエラー詳細: {error}" if error else ""
    reply = f"""## 今日の最重要事項
Gemini APIキーが未設定、またはGemini呼び出しに失敗したため、AIによる詳細な構造化はまだ作成できません。

## 固定予定・変更可能予定・未確定予定の分類
Googleカレンダー予定は{len(req.calendar_events)}件取得済みです。ただしGeminiなしでは入力文から予定を正確に抽出しません。

## 今日のタイムスケジュール
勝手に存在しない予定を作らないため、カレンダー操作候補は作成しません。{error_text}
"""
    warnings = ["Gemini APIキー未設定または応答失敗のため、追加/変更候補なしで返しました。"]
    if error:
        warnings.append(f"Gemini応答に失敗しました: {error}")
    return AssistantChatResponse(reply=reply, proposed_actions=[], warnings=warnings, calendar_visible=bool(req.calendar_events) or not req.mock, rules_applied=["日常タスク整理ルール"], memory_count=memory_count, profile_summary=profile_text)


def chat_with_assistant(req: AssistantChatRequest) -> AssistantChatResponse:
    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)
    store.sync_calendar_events(identity.user_id, req.calendar_events)

    new_memories = extract_memories_from_text(req.message)
    store.upsert_memories(identity.user_id, new_memories)
    profile = store.get_profile(identity.user_id)
    memories = store.load_memories(identity.user_id)
    relevant_memories = store.load_relevant_memories(identity.user_id, req.message, limit=12)
    profile_text = profile_summary(profile, memories)
    relevant_text = _relevant_memory_text(relevant_memories)
    calendar_snapshot = _calendar_snapshot(req.calendar_events)
    store.save_conversation(identity.user_id, "user", req.message, extracted_memories=new_memories, calendar_snapshot=calendar_snapshot)

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        res = _fallback_today_plan(req, memory_count=len(memories), profile_text=profile_text)
        store.save_conversation(identity.user_id, "assistant", res.reply, calendar_snapshot=calendar_snapshot)
        return res

    try:
        from google import genai
        from google.genai import types

        client = genai.Client(api_key=api_key)
        model_name = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

        # 1. Geminiは意味構造化だけを行う。
        structure_result = client.models.generate_content(
            model=model_name,
            contents=_structure_prompt(req, profile_text, relevant_text),
            config=types.GenerateContentConfig(response_mime_type="application/json", response_schema=AgentStructureResult),
        )
        structured: AgentStructureResult = structure_result.parsed
        warnings = list(structured.warnings)

        # 2. 構造化結果で既存予定を fixed/soft に分ける。
        classified_events = _classify_events(req.calendar_events, structured.existing_event_interpretations)

        # 3. OR-Toolsで厳密配置。
        # Geminiの時刻付き候補は直接カレンダー候補にせず、OR-Tools用タスクに変換する。
        # 最終的な create_event は必ずOR-Toolsの出力だけから作る。
        tasks = [_task_from_structured(c, req.timezone, None) for c in structured.tasks_to_schedule]
        for c in structured.exact_create_events:
            s_dt = _parse_dt(c.start, req.timezone)
            e_dt = _parse_dt(c.end, req.timezone)
            if not s_dt or not e_dt or e_dt <= s_dt:
                warnings.append(f"日時形式が不正な時刻付き予定を除外しました: {c.title}")
                continue
            duration = max(15, int((e_dt - s_dt).total_seconds() // 60))
            tasks.append(_normalize_task(TaskItem(
                title=c.title,
                duration_minutes=duration,
                min_duration_minutes=duration,
                priority=c.priority,
                earliest_start=s_dt,
                latest_end=e_dt,
                deadline=e_dt,
                category=c.category,
                schedule_type=c.schedule_type,
                notes=c.notes,
                reason=c.reason or "時刻が明示された予定だが、OR-Toolsで重複検証して配置",
            )))

        schedule_req = _build_schedule_request(req, profile, relevant_memories, tasks, classified_events)
        schedule_result = solve_schedule(schedule_req)

        actions: list[ProposedAction] = []
        for item in schedule_result.items:
            if _looks_like_duplicate(item, req.calendar_events):
                warnings.append(f"既存カレンダー予定と重複しそうな追加候補を除外しました: {item.title}")
                continue
            actions.append(_create_action_from_item(item))

        # 4. soft busyと重なった場合、既存予定の削除/変更候補を生成。
        scheduled_items = [a.to_scheduled_item() for a in actions if a.action_type == "create_event"]
        scheduled_items = [i for i in scheduled_items if i is not None]
        actions.extend(_auto_soft_event_actions(scheduled_items, classified_events))

        # 5. Geminiが明示した既存予定変更/削除候補も追加。
        for ch in structured.existing_event_changes:
            action = _event_change_to_action(ch, req.calendar_events, req.timezone)
            if action is None:
                warnings.append(f"変更/削除対象の予定IDが見つからない候補を除外しました: {ch.target_event_id}")
                continue
            # 重複アクションは避ける。
            if not any(a.action_type == action.action_type and a.target_event_id == action.target_event_id for a in actions):
                actions.append(action)

        # 6. ConflictValidatorで最終安全確認。
        # fixed予定との重複、候補同士の重複、soft_busyと重なるのにdelete/updateがない候補を除外する。
        validation = validate_proposed_actions(actions, classified_events, window_end=schedule_req.window_end)
        actions = validation.actions
        warnings.extend(validation.warnings)
        scheduled_items = [a.to_scheduled_item() for a in actions if a.action_type == "create_event"]
        scheduled_items = [i for i in scheduled_items if i is not None]

        # 7. Geminiは説明文だけを作る。失敗時は deterministic compose。
        try:
            explain_result = client.models.generate_content(
                model=model_name,
                contents=_explanation_prompt(req, structured, classified_events, scheduled_items, schedule_result.unscheduled, actions, warnings),
                config=types.GenerateContentConfig(response_mime_type="application/json", response_schema=AgentExplanationResult),
            )
            explained: AgentExplanationResult = explain_result.parsed
            final_reply = explained.reply.strip()
            warnings.extend(explained.warnings)
        except Exception as exp_e:
            warnings.append(f"説明生成に失敗したため固定テンプレートで返しました: {exp_e}")
            final_reply = _compose_fallback_reply(structured, req, classified_events, scheduled_items, schedule_result.unscheduled, actions, warnings)

        if "右側" not in final_reply:
            final_reply += "\n\n---\n右側の確認欄で『了解して実行』を押すまで、Googleカレンダーには追加・変更・削除しません。"

        rules_applied = structured.rules_applied or ["Gemini構造化", "pgvector類似記憶", "OR-Tools厳密配置", "承認後Calendar操作"]
        proposal_id = store.save_proposal(
            identity.user_id,
            user_message=req.message,
            reply=final_reply,
            proposed_actions=actions,
            warnings=warnings,
            rules_applied=rules_applied,
            calendar_snapshot=[e.model_dump(mode="json") for e in classified_events],
        )
        store.save_conversation(identity.user_id, "assistant", final_reply, calendar_snapshot=calendar_snapshot)
        suggested_events = [a.to_scheduled_item() for a in actions if a.action_type == "create_event"]
        suggested_events = [i for i in suggested_events if i is not None]
        return AssistantChatResponse(
            reply=final_reply,
            suggested_events=suggested_events,
            proposed_actions=actions,
            warnings=warnings,
            calendar_visible=bool(req.calendar_events) or not req.mock,
            rules_applied=rules_applied,
            proposal_id=proposal_id,
            memory_count=len(memories),
            relevant_memory_count=len(relevant_memories),
            profile_summary=profile_text,
        )
    except Exception as e:
        res = _fallback_today_plan(req, memory_count=len(memories), profile_text=profile_text, error=str(e))
        store.save_conversation(identity.user_id, "assistant", res.reply, calendar_snapshot=calendar_snapshot)
        return res
