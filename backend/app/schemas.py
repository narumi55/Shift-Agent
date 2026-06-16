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
    target_etag: Optional[str] = None
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


class CalendarExecuteRequest(BaseModel):
    google_auth_header: Optional[str] = None
    timezone: str = "Asia/Tokyo"
    actions: list[ProposedAction] = []
    cached_events: list[CalendarEventInfo] = []
    calendar_cache_synced_at: Optional[datetime] = None
    refresh_policy: Literal["never", "always", "if_stale_or_risky"] = "if_stale_or_risky"
    proposal_id: Optional[str] = None
    source: Literal["ai", "manual", "drag_move", "drag_resize", "swipe_delete", "swipe_complete", "postpone", "task_drag"] = "ai"
    mock: bool = False


class CalendarExecuteResponse(BaseModel):
    ok: bool = True
    refreshed: bool = False
    applied: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    cache_upserts: list[CalendarEventInfo] = []
    cache_deletes: list[str] = []
    warnings: list[str] = []
    proposal_id: Optional[str] = None



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
    calendar_cache_synced_at: Optional[datetime] = None
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
    needs_calendar_refresh: bool = False
    calendar_refresh_reason: Optional[str] = None
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


class InitialSurveyRequest(BaseModel):
    google_auth_header: Optional[str] = None
    timezone: str = "Asia/Tokyo"
    target_sleep_time: Optional[str] = Field(default="23:30", description="HH:MM")
    target_wake_time: Optional[str] = Field(default="08:00", description="HH:MM")
    avoid_heavy_work_after: Optional[str] = Field(default="22:30", description="HH:MM")
    default_buffer_minutes: int = Field(default=10, ge=0, le=90)
    meal_duration_minutes: int = Field(default=30, ge=0, le=180)
    bath_duration_minutes: int = Field(default=25, ge=0, le=180)
    sleep_prep_minutes: int = Field(default=20, ge=0, le=180)
    after_school_or_work_policy: Literal["ok", "light_only", "avoid"] = "light_only"
    ai_can_modify_existing_events: Literal["never", "ask", "uncertain_only"] = "ask"
    uncertain_events_can_be_deleted: bool = False
    default_planning_mode: Literal["balance", "efficiency", "deadline", "energy_saving", "minimum"] = "balance"
    free_text: Optional[str] = None


class ProfileRule(BaseModel):
    id: Optional[str] = None
    key: str
    text: str
    category: str = "general"
    strength: Literal["hard", "strong", "soft", "hint"] = "soft"
    usage: Literal["always", "on_demand", "archived"] = "always"
    source: str = "user"
    confidence: float = 0.8
    evidence: Optional[str] = None
    is_active: bool = True


class CurrentUserState(BaseModel):
    load_level: int = Field(default=3, ge=1, le=5)
    planning_mode: Literal["balance", "efficiency", "deadline", "energy_saving", "minimum"] = "balance"
    energy_level: int = Field(default=3, ge=1, le=5)
    note: Optional[str] = None
    updated_at: Optional[datetime] = None


class ProfileReviewChoice(BaseModel):
    id: str
    label: str
    result_action: Literal[
        "create_rule",
        "update_rule",
        "delete_rule",
        "create_memory",
        "update_current_state",
        "reject",
        "skip",
    ]
    strength: Optional[Literal["hard", "strong", "soft", "hint"]] = None
    usage: Optional[Literal["always", "on_demand", "archived"]] = None
    load_level: Optional[int] = Field(default=None, ge=1, le=5)
    planning_mode: Optional[Literal["balance", "efficiency", "deadline", "energy_saving", "minimum"]] = None
    energy_level: Optional[int] = Field(default=None, ge=1, le=5)


class ProfileReviewItem(BaseModel):
    id: Optional[str] = None
    title: str
    hypothesis: Optional[str] = None
    question_text: str
    source: Literal["initial_survey", "calendar_analysis", "chat", "user_checkin", "rule_review", "manual"] = "calendar_analysis"
    evidence: Optional[str] = None
    confidence: float = 0.7
    target_type: Literal["profile", "rule", "memory", "current_user_state"] = "rule"
    target_action: Literal["create", "update", "delete", "check"] = "create"
    target_rule_id: Optional[str] = None
    suggested_rule_key: Optional[str] = None
    suggested_rule_text: Optional[str] = None
    suggested_strength: Optional[Literal["hard", "strong", "soft", "hint"]] = "soft"
    suggested_usage: Optional[Literal["always", "on_demand", "archived"]] = "always"
    choices: list[ProfileReviewChoice] = []
    status: Literal["pending", "accepted", "rejected", "skipped", "applied"] = "pending"
    created_at: Optional[datetime] = None


class ProfileStateResponse(BaseModel):
    user_id: str
    profile: dict[str, Any] = {}
    rules: list[ProfileRule] = []
    memories: list[dict[str, Any]] = []
    current_user_state: CurrentUserState = Field(default_factory=CurrentUserState)
    review_items: list[ProfileReviewItem] = []


class ProfileAnalysisRequest(BaseModel):
    google_auth_header: Optional[str] = None
    timezone: str = "Asia/Tokyo"
    calendar_events: list[CalendarEventInfo] = []
    calendar_cache_synced_at: Optional[datetime] = None
    free_text: Optional[str] = None


class ProfileAnalysisResponse(BaseModel):
    ok: bool = True
    message: str = ""
    review_items: list[ProfileReviewItem] = []


class ProfileReviewAnswerRequest(BaseModel):
    google_auth_header: Optional[str] = None
    review_item: ProfileReviewItem
    choice_id: str
    free_text: Optional[str] = None


class ProfileReviewAnswerResponse(BaseModel):
    ok: bool = True
    message: str = ""
    profile_state: Optional[ProfileStateResponse] = None
