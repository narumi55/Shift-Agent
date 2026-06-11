from __future__ import annotations

from datetime import datetime, timedelta
from math import ceil

from .schemas import BusyBlock, ScheduleRequest, ScheduledItem, ScheduleResponse, TaskItem


def _overlap(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return a_start < b_end and b_start < a_end


def _slot_count(start: datetime, end: datetime, slot_minutes: int) -> int:
    return max(0, int((end - start).total_seconds() // 60 // slot_minutes))


def _time_at(start: datetime, index: int, slot_minutes: int) -> datetime:
    return start + timedelta(minutes=index * slot_minutes)


def _candidate_starts(req: ScheduleRequest, task: TaskItem) -> list[int]:
    duration_slots = ceil(task.duration_minutes / req.slot_minutes)
    n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
    candidates: list[int] = []
    for i in range(0, n_slots - duration_slots + 1):
        start = _time_at(req.window_start, i, req.slot_minutes)
        end = _time_at(req.window_start, i + duration_slots, req.slot_minutes)
        if task.earliest_start and start < task.earliest_start:
            continue
        if task.deadline and end > task.deadline:
            continue
        if any(_overlap(start, end, b.start, b.end) for b in req.busy):
            continue
        candidates.append(i)
    return candidates


def _greedy(req: ScheduleRequest) -> ScheduleResponse:
    used: list[tuple[datetime, datetime]] = [(b.start, b.end) for b in req.busy]
    items: list[ScheduledItem] = []
    unscheduled: list[str] = []
    for task in sorted(req.tasks, key=lambda t: (-t.priority, t.deadline or req.window_end)):
        placed = False
        duration_slots = ceil(task.duration_minutes / req.slot_minutes)
        n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
        for i in range(0, n_slots - duration_slots + 1):
            start = _time_at(req.window_start, i, req.slot_minutes)
            end = _time_at(req.window_start, i + duration_slots, req.slot_minutes)
            if task.earliest_start and start < task.earliest_start:
                continue
            if task.deadline and end > task.deadline:
                continue
            if any(_overlap(start, end, u0, u1) for u0, u1 in used):
                continue
            used.append((start, end))
            items.append(ScheduledItem(
                title=task.title,
                start=start,
                end=end,
                priority=task.priority,
                kind=task.kind,
                notes=task.notes,
                reason="優先度と空き時間から自動配置",
            ))
            placed = True
            break
        if not placed:
            unscheduled.append(task.title)
    status = "ok" if not unscheduled else "partial"
    return ScheduleResponse(status=status, items=sorted(items, key=lambda x: x.start), unscheduled=unscheduled, message="greedy fallback")


def solve_schedule(req: ScheduleRequest) -> ScheduleResponse:
    """Use OR-Tools CP-SAT when available. Falls back to greedy for easy demos."""
    if not req.tasks:
        return ScheduleResponse(status="ok", items=[], message="配置するタスクがありません。")

    try:
        from ortools.sat.python import cp_model
    except Exception:
        return _greedy(req)

    n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
    model = cp_model.CpModel()

    choices: dict[tuple[int, int], object] = {}
    candidate_map: dict[int, list[int]] = {}

    for ti, task in enumerate(req.tasks):
        cands = _candidate_starts(req, task)
        candidate_map[ti] = cands
        if not cands:
            continue
        vars_for_task = []
        for start_idx in cands:
            v = model.NewBoolVar(f"task_{ti}_start_{start_idx}")
            choices[(ti, start_idx)] = v
            vars_for_task.append(v)
        model.AddExactlyOne(vars_for_task)

    # Tasks with no candidates are unscheduled before solve.
    pre_unscheduled = [req.tasks[ti].title for ti, c in candidate_map.items() if not c]
    schedulable_task_indexes = [ti for ti, c in candidate_map.items() if c]

    # At most one task can occupy a slot.
    for slot in range(n_slots):
        occupants = []
        for ti in schedulable_task_indexes:
            task = req.tasks[ti]
            dur = ceil(task.duration_minutes / req.slot_minutes)
            for start_idx in candidate_map[ti]:
                if start_idx <= slot < start_idx + dur:
                    occupants.append(choices[(ti, start_idx)])
        if occupants:
            model.AddAtMostOne(occupants)

    # Objective: high priority earlier, deadlines earlier. Small app-friendly heuristic.
    terms = []
    for ti in schedulable_task_indexes:
        task = req.tasks[ti]
        dur = ceil(task.duration_minutes / req.slot_minutes)
        for start_idx in candidate_map[ti]:
            end_idx = start_idx + dur
            # Prefer high priority and earlier completion.
            score = task.priority * 1000 - end_idx
            terms.append(score * choices[(ti, start_idx)])
    if terms:
        model.Maximize(sum(terms))

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = 5
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return _greedy(req)

    items: list[ScheduledItem] = []
    for ti in schedulable_task_indexes:
        task = req.tasks[ti]
        dur = ceil(task.duration_minutes / req.slot_minutes)
        for start_idx in candidate_map[ti]:
            if solver.BooleanValue(choices[(ti, start_idx)]):
                start = _time_at(req.window_start, start_idx, req.slot_minutes)
                end = _time_at(req.window_start, start_idx + dur, req.slot_minutes)
                items.append(ScheduledItem(
                    title=task.title,
                    start=start,
                    end=end,
                    priority=task.priority,
                    kind=task.kind,
                    notes=task.notes,
                    reason="OR-Tools CP-SATで既存予定を避けて配置",
                ))
                break

    status_text = "ok" if not pre_unscheduled else "partial"
    return ScheduleResponse(
        status=status_text,
        items=sorted(items, key=lambda x: x.start),
        unscheduled=pre_unscheduled,
        message="OR-Tools CP-SATで配置しました。",
    )
