from __future__ import annotations

from datetime import datetime
from typing import Any, Literal, Optional
from pydantic import BaseModel, Field


class BusyBlock(BaseModel):
    start: datetime
    end: datetime
    source: str = "google_calendar"
    title: Optional[str] = None
    event_id: Optional[str] = None
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "fixed"
    movable: bool = False
    can_cancel: bool = False



class CalendarEventInfo(BaseModel):
    id: Optional[str] = None
    calendar_id: str = "primary"
    title: str = "予定あり"
    raw_title: Optional[str] = None
    normalized_title: Optional[str] = None
    start: datetime
    end: datetime
    source: str = "google_calendar"
    location: Optional[str] = None
    html_link: Optional[str] = None
    etag: Optional[str] = None
    is_all_day: bool = False
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "fixed"
    category: Literal["school", "job_hunt", "work", "personal_dev", "life", "social", "other"] = "other"
    movable: bool = False
    can_cancel: bool = False
    can_shorten: bool = False
    travel_before_minutes: int = 0
    travel_after_minutes: int = 0
    confidence: float = 0.7
    inferred_by: str = "calendar_default"


class TaskItem(BaseModel):
    """AI/OR-Tools が扱う予定候補。

    Google Calendar の title/start/end だけでは、優先度・疲労度・移動時間・
    変更可能性を扱えないため、エージェント内部ではこの構造に正規化する。
    """

    title: str
    duration_minutes: int = Field(ge=15, le=720, description="理想の所要時間")
    min_duration_minutes: Optional[int] = Field(default=None, ge=15, le=720, description="最低限確保したい所要時間")
    priority: int = Field(default=3, ge=1, le=5)
    deadline: Optional[datetime] = None
    earliest_start: Optional[datetime] = None
    latest_end: Optional[datetime] = None
    kind: Literal["task", "shift"] = "task"
    category: Literal["school", "job_hunt", "work", "personal_dev", "life", "social", "other"] = "other"
    schedule_type: Literal["fixed", "flexible", "uncertain"] = "flexible"
    energy_required: Literal["low", "medium", "high"] = "medium"
    mental_load: Literal["low", "medium", "high"] = "medium"
    can_split: bool = False
    location: Optional[str] = None
    travel_before_minutes: int = Field(default=0, ge=0, le=240)
    travel_after_minutes: int = Field(default=0, ge=0, le=240)
    notes: Optional[str] = None
    reason: str = ""
    original_duration_minutes: Optional[int] = None


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


class CalendarUpdateRequest(BaseModel):
    google_auth_header: Optional[str] = None
    event_id: str
    title: Optional[str] = None
    start: Optional[datetime] = None
    end: Optional[datetime] = None
    timezone: str = "Asia/Tokyo"
    notes: Optional[str] = None
    mock: bool = True


class CalendarDeleteRequest(BaseModel):
    google_auth_header: Optional[str] = None
    event_id: str
    timezone: str = "Asia/Tokyo"
    mock: bool = True


class ScheduleRequest(BaseModel):
    window_start: datetime
    window_end: datetime
    busy: list[BusyBlock] = []
    soft_busy: list[BusyBlock] = []
    heavy_avoid_blocks: list[BusyBlock] = []
    tasks: list[TaskItem] = []
    slot_minutes: int = Field(default=30, ge=15, le=120)
    timezone: str = "Asia/Tokyo"
    default_buffer_minutes: int = Field(default=10, ge=0, le=60)
    avoid_heavy_work_after: Optional[datetime] = None
    max_continuous_work_minutes: int = Field(default=90, ge=30, le=240)


class ScheduledItem(BaseModel):
    title: str
    start: datetime
    end: datetime
    priority: int
    kind: Literal["task", "shift"] = "task"
    notes: Optional[str] = None
    reason: str = ""
    original_duration_minutes: Optional[int] = None


class ScheduleResponse(BaseModel):
    status: Literal["ok", "partial", "infeasible"]
    items: list[ScheduledItem] = []
    unscheduled: list[str] = []
    message: str = ""


class ProposedAction(BaseModel):
    """ユーザー承認待ちのカレンダー操作。

    create_event: 新規予定追加
    update_event: 既存Googleカレンダー予定の変更
    """

    action_type: Literal["create_event", "update_event", "delete_event"]
    title: str
    reason: str = ""
    risk: Optional[str] = None
    requires_confirmation: bool = True

    # create_event 用
    start: Optional[datetime] = None
    end: Optional[datetime] = None
    priority: int = Field(default=3, ge=1, le=5)
    kind: Literal["task", "shift"] = "task"
    notes: Optional[str] = None

    # update_event 用
    target_event_id: Optional[str] = None
    current_title: Optional[str] = None
    current_start: Optional[datetime] = None
    current_end: Optional[datetime] = None
    proposed_title: Optional[str] = None
    proposed_start: Optional[datetime] = None
    proposed_end: Optional[datetime] = None

    def to_scheduled_item(self) -> Optional[ScheduledItem]:
        if self.action_type != "create_event" or not self.start or not self.end:
            return None
        return ScheduledItem(
            title=self.title,
            start=self.start,
            end=self.end,
            priority=self.priority,
            kind=self.kind,
            notes=self.notes,
            reason=self.reason,
        )


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
    user_id: Optional[str] = None
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
    proposed_actions: list[ProposedAction] = []
    warnings: list[str] = []
    calendar_visible: bool = False
    rules_applied: list[str] = []
    proposal_id: Optional[str] = None
    memory_count: int = 0
    relevant_memory_count: int = 0
    profile_summary: Optional[str] = None


class AgentDecisionRequest(BaseModel):
    google_auth_header: Optional[str] = None
    proposal_id: Optional[str] = None
    user_action: Literal["accepted", "rejected", "partially_accepted"]
    accepted_events: list[ScheduledItem] = []
    rejected_events: list[ScheduledItem] = []
    accepted_actions: list[ProposedAction] = []
    rejected_actions: list[ProposedAction] = []
    feedback: Optional[str] = None


class AgentDecisionResponse(BaseModel):
    ok: bool = True
    message: str = ""


class AgentMemoryResponse(BaseModel):
    user_id: str
    profile: dict[str, Any] = {}
    memories: list[dict[str, Any]] = []
