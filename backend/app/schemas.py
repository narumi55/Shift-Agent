from __future__ import annotations

from datetime import datetime
from typing import Literal, Optional
from pydantic import BaseModel, Field


class BusyBlock(BaseModel):
    start: datetime
    end: datetime
    source: str = "google_calendar"


class CalendarEventInfo(BaseModel):
    id: Optional[str] = None
    title: str = "予定あり"
    start: datetime
    end: datetime
    source: str = "google_calendar"


class TaskItem(BaseModel):
    title: str
    duration_minutes: int = Field(ge=15, le=720)
    priority: int = Field(default=3, ge=1, le=5)
    deadline: Optional[datetime] = None
    earliest_start: Optional[datetime] = None
    kind: Literal["task", "shift"] = "task"
    notes: Optional[str] = None


class ShiftRequirement(BaseModel):
    title: str = "仕事シフト"
    date: Optional[str] = Field(default=None, description="YYYY-MM-DD")
    start: Optional[datetime] = None
    end: Optional[datetime] = None
    duration_minutes: Optional[int] = Field(default=None, ge=30, le=720)
    priority: int = Field(default=5, ge=1, le=5)
    notes: Optional[str] = None


class AgentParseRequest(BaseModel):
    text: str
    timezone: str = "Asia/Tokyo"


class AgentParseResponse(BaseModel):
    tasks: list[TaskItem] = []
    shifts: list[ShiftRequirement] = []
    reply: str = ""


class CalendarBusyRequest(BaseModel):
    google_auth_header: Optional[str] = Field(
        default=None,
        description="Bearer token header from Flutter google_sign_in authorizationHeaders. Required when mock=false.",
    )
    time_min: datetime
    time_max: datetime
    timezone: str = "Asia/Tokyo"
    mock: bool = True


class CalendarEventsRequest(BaseModel):
    google_auth_header: Optional[str] = None
    time_min: datetime
    time_max: datetime
    timezone: str = "Asia/Tokyo"
    mock: bool = True
    include_titles: bool = True


class CalendarInsertRequest(BaseModel):
    google_auth_header: Optional[str] = None
    title: str
    start: datetime
    end: datetime
    timezone: str = "Asia/Tokyo"
    notes: Optional[str] = None
    mock: bool = True


class ScheduleRequest(BaseModel):
    window_start: datetime
    window_end: datetime
    busy: list[BusyBlock] = []
    tasks: list[TaskItem] = []
    slot_minutes: int = Field(default=30, ge=15, le=120)
    timezone: str = "Asia/Tokyo"


class ScheduledItem(BaseModel):
    title: str
    start: datetime
    end: datetime
    priority: int
    kind: Literal["task", "shift"] = "task"
    notes: Optional[str] = None
    reason: str = ""


class ScheduleResponse(BaseModel):
    status: Literal["ok", "partial", "infeasible"]
    items: list[ScheduledItem] = []
    unscheduled: list[str] = []
    message: str = ""


class AssistantRule(BaseModel):
    id: str
    title: str
    detail: str
    enabled: bool = True


class ChatMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: str


class AssistantChatRequest(BaseModel):
    message: str
    timezone: str = "Asia/Tokyo"
    now: Optional[datetime] = None
    mock: bool = True
    google_auth_header: Optional[str] = None
    calendar_events: list[CalendarEventInfo] = []
    rules: list[AssistantRule] = []
    history: list[ChatMessage] = []


class AssistantChatResponse(BaseModel):
    reply: str
    suggested_events: list[ScheduledItem] = []
    warnings: list[str] = []
    calendar_visible: bool = False
    rules_applied: list[str] = []
