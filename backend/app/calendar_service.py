from __future__ import annotations

from datetime import date, datetime, time
from typing import Optional
from zoneinfo import ZoneInfo

import requests
from requests import HTTPError

from .schemas import BusyBlock, CalendarEventInfo

CALENDAR_API_BASE = "https://www.googleapis.com/calendar/v3"


def _raise_for_status(resp: requests.Response) -> None:
    try:
        resp.raise_for_status()
    except HTTPError as e:
        detail = resp.text[:1600] if resp.text else str(e)
        raise RuntimeError(f"HTTP {resp.status_code}: {detail}") from e


def _headers(google_auth_header: str) -> dict[str, str]:
    if not google_auth_header.lower().startswith("bearer "):
        google_auth_header = f"Bearer {google_auth_header}"
    return {"Authorization": google_auth_header, "Accept": "application/json"}


def _ensure_timezone(dt: datetime, timezone: str = "Asia/Tokyo") -> datetime:
    """Google Calendar API requires RFC3339 datetimes with a timezone offset.

    Flutter Web sends local DateTime values like `2026-06-11T00:00:00.000`
    without an offset. FastAPI/Pydantic receives those as naive datetimes.
    Sending naive ISO strings to Google Calendar causes HTTP 400 Bad Request.
    """
    tz = ZoneInfo(timezone)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=tz)
    return dt.astimezone(tz)


def _google_rfc3339(dt: datetime, timezone: str = "Asia/Tokyo") -> str:
    return _ensure_timezone(dt, timezone).isoformat(timespec="seconds")


def _parse_google_datetime(value: Optional[str], timezone: str = "Asia/Tokyo") -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(ZoneInfo(timezone))
    except Exception:
        return None


def _parse_google_all_day(value: Optional[str], timezone: str = "Asia/Tokyo") -> Optional[datetime]:
    if not value:
        return None
    try:
        d = date.fromisoformat(value)
        return datetime.combine(d, time.min, tzinfo=ZoneInfo(timezone))
    except Exception:
        return None


def _event_start_end(ev: dict, timezone: str) -> tuple[Optional[datetime], Optional[datetime]]:
    start_obj = ev.get("start", {}) or {}
    end_obj = ev.get("end", {}) or {}

    # Timed events use dateTime; all-day events use date.
    start = _parse_google_datetime(start_obj.get("dateTime"), timezone)
    end = _parse_google_datetime(end_obj.get("dateTime"), timezone)

    if start is None:
        start = _parse_google_all_day(start_obj.get("date"), timezone)
    if end is None:
        end = _parse_google_all_day(end_obj.get("date"), timezone)

    return start, end


def list_calendar_events(
    google_auth_header: str,
    time_min: datetime,
    time_max: datetime,
    timezone: str = "Asia/Tokyo",
    include_titles: bool = True,
) -> list[CalendarEventInfo]:
    params = {
        # Important: Google Calendar rejects datetimes without timezone offset.
        "timeMin": _google_rfc3339(time_min, timezone),
        "timeMax": _google_rfc3339(time_max, timezone),
        "singleEvents": "true",
        "orderBy": "startTime",
        "timeZone": timezone,
    }
    resp = requests.get(
        f"{CALENDAR_API_BASE}/calendars/primary/events",
        headers=_headers(google_auth_header),
        params=params,
        timeout=20,
    )
    _raise_for_status(resp)
    data = resp.json()
    events: list[CalendarEventInfo] = []
    for ev in data.get("items", []):
        start, end = _event_start_end(ev, timezone)
        if not start or not end:
            continue
        title = ev.get("summary") or "予定あり"
        if not include_titles:
            title = "予定あり"
        events.append(
            CalendarEventInfo(
                id=ev.get("id"),
                title=title,
                start=start,
                end=end,
                source="google_calendar",
            )
        )
    return events


def list_busy_blocks(
    google_auth_header: str,
    time_min: datetime,
    time_max: datetime,
    timezone: str = "Asia/Tokyo",
) -> list[BusyBlock]:
    """Read calendar events and return only busy intervals."""
    return [
        BusyBlock(start=e.start, end=e.end, source=e.source)
        for e in list_calendar_events(google_auth_header, time_min, time_max, timezone, include_titles=False)
    ]


def insert_event(
    google_auth_header: str,
    title: str,
    start: datetime,
    end: datetime,
    timezone: str = "Asia/Tokyo",
    notes: Optional[str] = None,
) -> dict:
    start_with_tz = _ensure_timezone(start, timezone)
    end_with_tz = _ensure_timezone(end, timezone)
    body = {
        "summary": title,
        "description": notes or "AIシフト管理アプリから追加",
        "start": {"dateTime": start_with_tz.isoformat(timespec="seconds"), "timeZone": timezone},
        "end": {"dateTime": end_with_tz.isoformat(timespec="seconds"), "timeZone": timezone},
    }
    resp = requests.post(
        f"{CALENDAR_API_BASE}/calendars/primary/events",
        headers={**_headers(google_auth_header), "Content-Type": "application/json"},
        json=body,
        timeout=20,
    )
    _raise_for_status(resp)
    return resp.json()
