from __future__ import annotations

import os
from typing import Optional
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from .assistant_agent import chat_with_assistant
from .calendar_service import insert_event, update_event, delete_event, list_busy_blocks, list_calendar_events
from .gemini_agent import parse_with_gemini
from .scheduler import solve_schedule
from .memory_engine import extract_memories_from_text
from .supabase_service import get_supabase_service
from .user_identity import identity_from_google_token
from .schemas import (
    AgentDecisionRequest,
    AgentDecisionResponse,
    AgentMemoryResponse,
    AgentParseRequest,
    AgentParseResponse,
    AssistantChatRequest,
    AssistantChatResponse,
    BusyBlock,
    CalendarBusyRequest,
    CalendarEventInfo,
    CalendarEventsRequest,
    CalendarInsertRequest,
    CalendarUpdateRequest,
    CalendarDeleteRequest,
    ScheduleRequest,
    ScheduleResponse,
    TaskItem,
)

app = FastAPI(title="AI Shift Agent API", version="0.15.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _mock_events(time_min: datetime, timezone: str) -> list[CalendarEventInfo]:
    # Google未連携時は空の予定として返す。
    return []


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "ai-shift-agent", "version": "0.15.0"}


@app.get("/agent/status")
def agent_status() -> dict:
    supabase = get_supabase_service()
    return {
        "gemini_key_loaded": bool(os.getenv("GEMINI_API_KEY")),
        "gemini_model": os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
        "supabase": supabase.status(),
    }


@app.post("/agent/parse", response_model=AgentParseResponse)
def agent_parse(req: AgentParseRequest) -> AgentParseResponse:
    return parse_with_gemini(req.text, req.timezone)


@app.post("/agent/chat", response_model=AssistantChatResponse)
def agent_chat(req: AssistantChatRequest) -> AssistantChatResponse:
    return chat_with_assistant(req)


@app.get("/agent/memory", response_model=AgentMemoryResponse)
def agent_memory(google_auth_header: Optional[str] = None) -> AgentMemoryResponse:
    identity = identity_from_google_token(google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)
    return AgentMemoryResponse(
        user_id=str(identity.user_id),
        profile=store.get_profile(identity.user_id),
        memories=store.load_memories(identity.user_id),
    )


@app.post("/agent/decision", response_model=AgentDecisionResponse)
def agent_decision(req: AgentDecisionRequest) -> AgentDecisionResponse:
    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    learned = []
    if req.feedback:
        learned = extract_memories_from_text(req.feedback)
        store.upsert_memories(identity.user_id, learned)
    accepted_payload = [a.model_dump(mode="json") for a in req.accepted_actions]
    rejected_payload = [a.model_dump(mode="json") for a in req.rejected_actions]
    # v11互換: Flutter旧版が scheduled_events だけを送ってきた場合も保存する。
    if not accepted_payload and req.accepted_events:
        accepted_payload = [e.model_dump(mode="json") for e in req.accepted_events]
    if not rejected_payload and req.rejected_events:
        rejected_payload = [e.model_dump(mode="json") for e in req.rejected_events]

    store.record_decision(
        identity.user_id,
        proposal_id=req.proposal_id,
        user_action=req.user_action,
        accepted=accepted_payload,
        rejected=rejected_payload,
        feedback=req.feedback,
        learned_preferences=learned,
    )
    return AgentDecisionResponse(ok=True, message="decision recorded")


@app.post("/calendar/events", response_model=list[CalendarEventInfo])
def calendar_events(req: CalendarEventsRequest) -> list[CalendarEventInfo]:
    if req.mock:
        return _mock_events(req.time_min, req.timezone)
    if not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")
    try:
        return list_calendar_events(req.google_auth_header, req.time_min, req.time_max, req.timezone, req.include_titles)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Google Calendar read failed: {e}")


@app.post("/calendar/busy", response_model=list[BusyBlock])
def calendar_busy(req: CalendarBusyRequest) -> list[BusyBlock]:
    if req.mock:
        return [BusyBlock(start=e.start, end=e.end, source=e.source) for e in _mock_events(req.time_min, req.timezone)]
    if not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")
    try:
        return list_busy_blocks(req.google_auth_header, req.time_min, req.time_max, req.timezone)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Google Calendar read failed: {e}")


@app.post("/calendar/insert")
def calendar_insert(req: CalendarInsertRequest) -> dict:
    if req.mock:
        return {
            "mock": True,
            "summary": req.title,
            "start": req.start.isoformat(),
            "end": req.end.isoformat(),
            "message": "mock=true のためGoogleカレンダーには追加していません。",
        }
    if not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")
    try:
        return insert_event(req.google_auth_header, req.title, req.start, req.end, req.timezone, req.notes)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Google Calendar insert failed: {e}")


@app.post("/calendar/update")
def calendar_update(req: CalendarUpdateRequest) -> dict:
    if req.mock:
        return {"mock": True, "event_id": req.event_id, "message": "mock=true のためGoogleカレンダーは変更していません。"}
    if not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")
    try:
        return update_event(req.google_auth_header, req.event_id, req.title, req.start, req.end, req.timezone, req.notes)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Google Calendar update failed: {e}")


@app.post("/calendar/delete")
def calendar_delete(req: CalendarDeleteRequest) -> dict:
    if req.mock:
        return {"mock": True, "deleted": True, "event_id": req.event_id, "message": "mock=true のためGoogleカレンダーからは削除していません。"}
    if not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")
    try:
        return delete_event(req.google_auth_header, req.event_id, req.timezone)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Google Calendar delete failed: {e}")


@app.post("/schedule/solve", response_model=ScheduleResponse)
def schedule_solve(req: ScheduleRequest) -> ScheduleResponse:
    return solve_schedule(req)


@app.post("/demo/plan", response_model=ScheduleResponse)
def demo_plan(req: AgentParseRequest) -> ScheduleResponse:
    """入力文だけで、Gemini解析→mock空き予定→OR-Tools配置まで一気に確認するデモ。"""
    parsed = parse_with_gemini(req.text, req.timezone)
    tz = ZoneInfo(req.timezone)
    now = datetime.now(tz)
    window_start = now.replace(hour=9, minute=0, second=0, microsecond=0)
    if window_start < now:
        window_start += timedelta(days=1)
    window_end = window_start + timedelta(days=7)

    tasks = list(parsed.tasks)
    for s in parsed.shifts:
        if s.start and s.end:
            duration = int((s.end - s.start).total_seconds() // 60)
            tasks.append(
                TaskItem(
                    title=s.title,
                    duration_minutes=max(duration, 30),
                    priority=s.priority,
                    earliest_start=s.start,
                    deadline=s.end,
                    kind="shift",
                    notes=s.notes,
                )
            )
        else:
            tasks.append(
                TaskItem(
                    title=s.title,
                    duration_minutes=s.duration_minutes or 180,
                    priority=s.priority,
                    kind="shift",
                    notes=s.notes,
                )
            )

    busy = [BusyBlock(start=e.start, end=e.end, source=e.source) for e in _mock_events(window_start, req.timezone)]
    return solve_schedule(ScheduleRequest(window_start=window_start, window_end=window_end, busy=busy, tasks=tasks, timezone=req.timezone))
