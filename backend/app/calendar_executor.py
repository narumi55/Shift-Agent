from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from typing import Optional

from fastapi import HTTPException

from .calendar_service import google_event_to_info, insert_event, update_event, delete_event, list_calendar_events
from .conflict_validator import validate_proposed_actions, overlaps
from .schemas import CalendarExecuteRequest, CalendarExecuteResponse, CalendarEventInfo, ProposedAction
from .supabase_service import get_supabase_service
from .user_identity import identity_from_google_token


def _as_action_dict(action: ProposedAction, *, status: str, reason: Optional[str] = None, event_id: Optional[str] = None) -> dict:
    data = action.model_dump(mode="json")
    data["status"] = status
    if reason:
        data["rejection_reason" if status == "rejected" else "message"] = reason
    if event_id:
        data["google_event_id"] = event_id
    return data


def _ensure_tz(dt: datetime, timezone: str) -> datetime:
    tz = ZoneInfo(timezone)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=tz)
    return dt.astimezone(tz)


def _action_datetimes(action: ProposedAction) -> list[datetime]:
    out: list[datetime] = []
    for value in [action.start, action.end, action.current_start, action.current_end, action.proposed_start, action.proposed_end]:
        if value is not None:
            out.append(value)
    return out


def _refresh_range(req: CalendarExecuteRequest) -> tuple[datetime, datetime]:
    tz = ZoneInfo(req.timezone)
    points: list[datetime] = []
    for ev in req.cached_events:
        points.extend([ev.start, ev.end])
    for action in req.actions:
        points.extend(_action_datetimes(action))
    if points:
        start = min(_ensure_tz(p, req.timezone) for p in points) - timedelta(days=1)
        end = max(_ensure_tz(p, req.timezone) for p in points) + timedelta(days=1)
    else:
        now = datetime.now(tz)
        start = now.replace(hour=6, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=14)
    return start, end


def _is_cache_stale(req: CalendarExecuteRequest, *, minutes: int = 60) -> bool:
    if not req.cached_events:
        return True
    if req.calendar_cache_synced_at is None:
        return True
    synced = _ensure_tz(req.calendar_cache_synced_at, req.timezone)
    return datetime.now(ZoneInfo(req.timezone)) - synced > timedelta(minutes=minutes)


def _is_risky(actions: list[ProposedAction]) -> bool:
    return any(a.action_type in {"update_event", "delete_event"} for a in actions)


def _should_refresh(req: CalendarExecuteRequest) -> bool:
    if req.mock:
        return False
    if req.refresh_policy == "always":
        return True
    if req.refresh_policy == "never":
        return False
    if _is_cache_stale(req):
        return True
    if _is_risky(req.actions) and _is_cache_stale(req, minutes=15):
        return True
    return False


def _events_for_validation(events: list[CalendarEventInfo]) -> list[CalendarEventInfo]:
    # Defensive copy is not required; this hook keeps the executor easy to evolve.
    return list(events)


def _event_by_id(events: list[CalendarEventInfo]) -> dict[str, CalendarEventInfo]:
    return {e.id: e for e in events if e.id}


def _looks_duplicate_create(action: ProposedAction, events: list[CalendarEventInfo], timezone: str) -> Optional[str]:
    if action.action_type != "create_event" or not action.start or not action.end:
        return None
    title = action.title.strip().lower()
    action_start = _ensure_tz(action.start, timezone)
    action_end = _ensure_tz(action.end, timezone)
    for ev in events:
        ev_start = _ensure_tz(ev.start, timezone)
        ev_end = _ensure_tz(ev.end, timezone)
        if not overlaps(action_start, action_end, ev_start, ev_end):
            continue
        ev_title = ev.title.strip().lower()
        same_title = title and ev_title and (title == ev_title or title in ev_title or ev_title in title)
        same_start = abs((action_start - ev_start).total_seconds()) < 300
        same_end = abs((action_end - ev_end).total_seconds()) < 300
        if same_title and same_start and same_end:
            return f"同じ時刻に同名のGoogle予定『{ev.title}』が既にあります。"
    return None


def _mock_event_from_action(action: ProposedAction, timezone: str) -> CalendarEventInfo:
    if not action.start or not action.end:
        raise ValueError("mock create_event requires start/end")
    return CalendarEventInfo(
        id=f"mock-{int(datetime.now().timestamp() * 1000)}",
        calendar_id="primary",
        title=action.title,
        raw_title=action.title,
        normalized_title=action.title,
        start=_ensure_tz(action.start, timezone),
        end=_ensure_tz(action.end, timezone),
        source="mock_calendar",
        schedule_type="fixed",
        inferred_by="calendar_executor_mock",
    )


def execute_calendar_actions(req: CalendarExecuteRequest) -> CalendarExecuteResponse:
    if not req.actions:
        return CalendarExecuteResponse(ok=True, warnings=["実行するカレンダー操作がありません。"], proposal_id=req.proposal_id)
    if not req.mock and not req.google_auth_header:
        raise HTTPException(status_code=400, detail="google_auth_header is required when mock=false")

    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)

    warnings: list[str] = []
    refreshed = False
    snapshot = list(req.cached_events)

    if _should_refresh(req):
        if not req.google_auth_header:
            raise HTTPException(status_code=400, detail="Googleカレンダー再取得にはgoogle_auth_headerが必要です。")
        try:
            time_min, time_max = _refresh_range(req)
            snapshot = list_calendar_events(req.google_auth_header, time_min, time_max, req.timezone, include_titles=True)
            store.sync_calendar_events(identity.user_id, snapshot)
            refreshed = True
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"Google Calendar refresh failed before execution: {e}")

    # Execution-time validator. This catches stale or unsafe actions before writes.
    validation = validate_proposed_actions(req.actions, _events_for_validation(snapshot))
    valid_actions = validation.actions
    warnings.extend(validation.warnings)

    valid_keys = {(a.action_type, a.target_event_id, a.title, a.start, a.end, a.proposed_start, a.proposed_end, a.proposed_title) for a in valid_actions}
    rejected: list[dict] = []
    for action in req.actions:
        key = (action.action_type, action.target_event_id, action.title, action.start, action.end, action.proposed_start, action.proposed_end, action.proposed_title)
        if key not in valid_keys:
            rejected.append(_as_action_dict(action, status="rejected", reason="ConflictValidatorにより安全でない候補として除外されました。"))

    # Extra duplicate protection for Google execution.
    filtered: list[ProposedAction] = []
    for action in valid_actions:
        dup = _looks_duplicate_create(action, snapshot, req.timezone)
        if dup:
            rejected.append(_as_action_dict(action, status="rejected", reason=dup))
            warnings.append(dup)
        else:
            filtered.append(action)

    # Safety principle: any invalid action rejects the whole batch before Google writes.
    # This prevents a half-applied calendar state when the user pressed one approval button.
    if rejected:
        return CalendarExecuteResponse(
            ok=False,
            refreshed=refreshed,
            applied=[],
            rejected=rejected,
            cache_upserts=[],
            cache_deletes=[],
            warnings=warnings,
            proposal_id=req.proposal_id,
        )

    applied: list[dict] = []
    cache_upserts: list[CalendarEventInfo] = []
    cache_deletes: list[str] = []
    snapshot_by_id = _event_by_id(snapshot)

    for action in filtered:
        try:
            if action.action_type == "create_event":
                if not action.start or not action.end:
                    rejected.append(_as_action_dict(action, status="rejected", reason="開始/終了時刻が不足しています。"))
                    continue
                if req.mock:
                    info = _mock_event_from_action(action, req.timezone)
                else:
                    raw = insert_event(req.google_auth_header or "", action.title, action.start, action.end, req.timezone, action.notes or action.reason)
                    info = google_event_to_info(raw, req.timezone)
                    if info is None:
                        raise RuntimeError("Google Calendar create response could not be converted to CalendarEventInfo")
                cache_upserts.append(info)
                snapshot.append(info)
                if info.id:
                    snapshot_by_id[info.id] = info
                applied.append(_as_action_dict(action, status="applied", event_id=info.id))

            elif action.action_type == "update_event":
                event_id = action.target_event_id
                if not event_id:
                    rejected.append(_as_action_dict(action, status="rejected", reason="変更対象のGoogle予定IDがありません。"))
                    continue
                target = snapshot_by_id.get(event_id)
                if target is None:
                    rejected.append(_as_action_dict(action, status="rejected", reason="変更対象の予定が最新スナップショットに見つかりません。再取得してください。"))
                    continue
                if action.target_etag and target.etag and action.target_etag != target.etag:
                    rejected.append(_as_action_dict(action, status="rejected", reason="Google予定が別端末で変更されています。再取得してください。"))
                    continue
                if req.mock:
                    info = target.model_copy(update={
                        "title": action.proposed_title or target.title,
                        "start": action.proposed_start or target.start,
                        "end": action.proposed_end or target.end,
                        "inferred_by": "calendar_executor_mock_update",
                    })
                else:
                    raw = update_event(
                        req.google_auth_header or "",
                        event_id,
                        action.proposed_title,
                        action.proposed_start,
                        action.proposed_end,
                        req.timezone,
                        action.notes or action.reason,
                    )
                    info = google_event_to_info(raw, req.timezone) if isinstance(raw, dict) else None
                    if info is None:
                        raise RuntimeError("Google Calendar update response could not be converted to CalendarEventInfo")
                cache_upserts.append(info)
                snapshot_by_id[event_id] = info
                snapshot = [info if ev.id == event_id else ev for ev in snapshot]
                applied.append(_as_action_dict(action, status="applied", event_id=event_id))

            elif action.action_type == "delete_event":
                event_id = action.target_event_id
                if not event_id:
                    rejected.append(_as_action_dict(action, status="rejected", reason="削除対象のGoogle予定IDがありません。"))
                    continue
                target = snapshot_by_id.get(event_id)
                if target is None and not req.mock:
                    rejected.append(_as_action_dict(action, status="rejected", reason="削除対象の予定が最新スナップショットに見つかりません。再取得してください。"))
                    continue
                if action.target_etag and target and target.etag and action.target_etag != target.etag:
                    rejected.append(_as_action_dict(action, status="rejected", reason="Google予定が別端末で変更されています。再取得してください。"))
                    continue
                if not req.mock:
                    delete_event(req.google_auth_header or "", event_id, req.timezone)
                cache_deletes.append(event_id)
                snapshot_by_id.pop(event_id, None)
                snapshot = [ev for ev in snapshot if ev.id != event_id]
                store.mark_calendar_event_deleted(identity.user_id, event_id)
                applied.append(_as_action_dict(action, status="applied", event_id=event_id))
        except HTTPException:
            raise
        except Exception as e:
            rejected.append(_as_action_dict(action, status="rejected", reason=str(e)))
            warnings.append(f"{action.title} の実行に失敗しました: {e}")

    if cache_upserts:
        store.sync_calendar_events(identity.user_id, cache_upserts)

    ok = bool(applied)

    return CalendarExecuteResponse(
        ok=ok,
        refreshed=refreshed,
        applied=applied,
        rejected=rejected,
        cache_upserts=cache_upserts,
        cache_deletes=cache_deletes,
        warnings=warnings,
        proposal_id=req.proposal_id,
    )
