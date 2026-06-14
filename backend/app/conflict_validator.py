from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Iterable

from .schemas import CalendarEventInfo, ProposedAction


def overlaps(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return a_start < b_end and b_start < a_end


@dataclass
class ValidationResult:
    actions: list[ProposedAction]
    warnings: list[str]


def _action_interval(action: ProposedAction) -> tuple[datetime, datetime] | None:
    if action.action_type == "create_event" and action.start and action.end:
        return action.start, action.end
    if action.action_type == "update_event" and action.proposed_start and action.proposed_end:
        return action.proposed_start, action.proposed_end
    return None


def _target_ids(actions: Iterable[ProposedAction], types: set[str] | None = None) -> set[str]:
    out: set[str] = set()
    for action in actions:
        if types and action.action_type not in types:
            continue
        if action.target_event_id:
            out.add(action.target_event_id)
    return out


def validate_proposed_actions(
    actions: list[ProposedAction],
    existing_events: list[CalendarEventInfo],
    *,
    window_end: datetime | None = None,
) -> ValidationResult:
    """Final safety gate before proposals are returned to the UI.

    The agent must never show calendar-write candidates that would create an
    impossible calendar state. This validator simulates accepted actions and
    removes dangerous candidates before the user can press 「了解して実行」.

    Rules:
    - create/update actions must have a valid non-overlapping interval.
    - fixed existing events are never allowed to be overlapped.
    - flexible/uncertain events may be overlapped only when a delete/update
      action for that exact Google event is included in the same proposal set.
    - create/update actions must not overlap each other.
    - actions beyond target sleep/window_end are removed.
    """
    warnings: list[str] = []
    kept: list[ProposedAction] = []

    # Any explicit delete/update action can free its target slot for OR-Tools output.
    # The corresponding delete/update action is still validated before it is returned.
    removable_ids = _target_ids(actions, {"delete_event", "update_event"})

    # Keep valid delete actions first; they define which soft events can be replaced.
    for action in actions:
        if action.action_type == "delete_event":
            if not action.target_event_id:
                warnings.append(f"削除対象IDがないため削除候補を除外しました: {action.title}")
                continue
            kept.append(action)
    existing_by_id = {e.id: e for e in existing_events if e.id}
    occupied: list[tuple[datetime, datetime, str]] = []

    # Existing events that will remain on the final calendar.
    for ev in existing_events:
        if ev.id and ev.id in removable_ids:
            continue
        occupied.append((ev.start, ev.end, ev.title))

    def can_place(action: ProposedAction) -> bool:
        interval = _action_interval(action)
        if interval is None:
            warnings.append(f"開始/終了時刻が不正な候補を除外しました: {action.title}")
            return False
        start, end = interval
        if end <= start:
            warnings.append(f"終了時刻が開始時刻以前の候補を除外しました: {action.title}")
            return False
        if window_end and end > window_end:
            warnings.append(f"就寝/計画終了時刻を超える候補を除外しました: {action.title}")
            return False
        for ev in existing_events:
            if ev.id and ev.id in removable_ids:
                continue
            if not overlaps(start, end, ev.start, ev.end):
                continue
            if ev.schedule_type == "fixed" or (not ev.movable and not ev.can_cancel):
                warnings.append(f"固定予定『{ev.title}』と重なるため候補を除外しました: {action.title}")
                return False
            warnings.append(f"soft予定『{ev.title}』と重なるのに削除/変更候補がないため除外しました: {action.title}")
            return False
        for os, oe, title in occupied:
            if overlaps(start, end, os, oe):
                warnings.append(f"候補同士または既存予定『{title}』と重なるため除外しました: {action.title}")
                return False
        return True

    # Validate updates before creates because updated intervals occupy the final calendar.
    for action in actions:
        if action.action_type != "update_event":
            continue
        if not action.target_event_id or action.target_event_id not in existing_by_id:
            warnings.append(f"変更対象IDが見つからないため変更候補を除外しました: {action.title}")
            continue
        # Updating a fixed event should still be possible only if the agent clearly proposes it,
        # but final overlap rules still apply. The original target was already removed via removable_ids.
        if can_place(action):
            kept.append(action)
            s, e = _action_interval(action)  # type: ignore[misc]
            occupied.append((s, e, action.proposed_title or action.title))
            removable_ids.add(action.target_event_id)

    for action in actions:
        if action.action_type != "create_event":
            continue
        if can_place(action):
            kept.append(action)
            s, e = _action_interval(action)  # type: ignore[misc]
            occupied.append((s, e, action.title))

    # Remove auto/useless deletes that do not actually conflict with any accepted create/update.
    non_delete = [a for a in kept if a.action_type != "delete_event"]
    used_delete_ids: set[str] = set()
    for d in [a for a in kept if a.action_type == "delete_event" and a.target_event_id]:
        ev = existing_by_id.get(d.target_event_id)
        if not ev:
            continue
        for a in non_delete:
            interval = _action_interval(a)
            if interval and overlaps(interval[0], interval[1], ev.start, ev.end):
                used_delete_ids.add(d.target_event_id)
                break
    kept = [
        a for a in kept
        if a.action_type != "delete_event"
        or (a.target_event_id in used_delete_ids)
        or ("高優先度の予定" not in (a.reason or ""))
    ]

    return ValidationResult(actions=kept, warnings=warnings)
