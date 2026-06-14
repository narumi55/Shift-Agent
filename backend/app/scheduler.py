from __future__ import annotations

from datetime import datetime, timedelta
from math import ceil
from typing import Optional

from .schemas import BusyBlock, ScheduleRequest, ScheduledItem, ScheduleResponse, TaskItem


def _overlap(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return a_start < b_end and b_start < a_end


def _slot_count(start: datetime, end: datetime, slot_minutes: int) -> int:
    return max(0, int((end - start).total_seconds() // 60 // slot_minutes))


def _time_at(start: datetime, index: int, slot_minutes: int) -> datetime:
    return start + timedelta(minutes=index * slot_minutes)


def _ceil_slots(minutes: int, slot_minutes: int) -> int:
    return max(1, ceil(minutes / slot_minutes))


def _floor_slot_index(req: ScheduleRequest, dt: datetime) -> int:
    return max(0, int((dt - req.window_start).total_seconds() // 60 // req.slot_minutes))


def _duration_options(req: ScheduleRequest, task: TaskItem) -> list[int]:
    """Return possible durations in slots.

    v14の方針: Geminiが抽出した「理想時間」と「最低時間」をOR-Toolsに渡し、
    時間が厳しい日は最低時間で入れる余地を残す。これにより、面接準備などを
    完全に落とすより、30分だけでも確保する判断ができる。
    """
    ideal = _ceil_slots(task.duration_minutes, req.slot_minutes)
    min_minutes = task.min_duration_minutes or task.duration_minutes
    min_slots = _ceil_slots(min(min_minutes, task.duration_minutes), req.slot_minutes)
    options = {ideal, min_slots}
    # can_splitのときは中間候補も作る。実際には1ブロック配置だが、短縮幅を増やす。
    if task.can_split and ideal - min_slots >= 2:
        options.add((ideal + min_slots) // 2)
    return sorted(options, reverse=True)


def _before_slots(req: ScheduleRequest, task: TaskItem) -> int:
    return _ceil_slots(task.travel_before_minutes, req.slot_minutes) if task.travel_before_minutes else 0


def _after_slots(req: ScheduleRequest, task: TaskItem) -> int:
    return _ceil_slots(task.travel_after_minutes, req.slot_minutes) if task.travel_after_minutes else 0


def _busy_blocks_with_buffer(req: ScheduleRequest) -> list[BusyBlock]:
    # 固定予定だけをハードbusyにする。soft_busyは目的関数のペナルティで扱う。
    buffered: list[BusyBlock] = []
    delta = timedelta(minutes=req.default_buffer_minutes)
    for b in req.busy:
        buffered.append(
            BusyBlock(
                start=max(req.window_start, b.start - delta),
                end=min(req.window_end, b.end + delta),
                source=b.source,
                title=b.title,
                event_id=b.event_id,
                schedule_type=b.schedule_type,
                movable=b.movable,
                can_cancel=b.can_cancel,
            )
        )
    return buffered


def _candidate_starts(req: ScheduleRequest, task: TaskItem, busy: list[BusyBlock], dur_slots: int) -> list[int]:
    n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
    before = _before_slots(req, task)
    after = _after_slots(req, task)
    candidates: list[int] = []
    for i in range(0, n_slots - dur_slots + 1):
        start = _time_at(req.window_start, i, req.slot_minutes)
        end = _time_at(req.window_start, i + dur_slots, req.slot_minutes)
        occ_start = _time_at(req.window_start, max(0, i - before), req.slot_minutes)
        occ_end = _time_at(req.window_start, min(n_slots, i + dur_slots + after), req.slot_minutes)
        if task.earliest_start and start < task.earliest_start:
            continue
        if task.deadline and end > task.deadline:
            continue
        if task.latest_end and end > task.latest_end:
            continue
        is_heavy = task.energy_required == "high" or task.mental_load == "high"
        if req.avoid_heavy_work_after and is_heavy and end > req.avoid_heavy_work_after:
            continue
        if is_heavy and any(_overlap(occ_start, occ_end, b.start, b.end) for b in req.heavy_avoid_blocks):
            continue
        if any(_overlap(occ_start, occ_end, b.start, b.end) for b in busy):
            continue
        candidates.append(i)
    return candidates


def _keyword_bonus(task: TaskItem) -> int:
    text = f"{task.title} {task.notes or ''} {task.reason or ''}"
    bonus = 0
    if any(k in text for k in ["面接", "就活", "志望理由", "逆質問", "会社概要"]):
        bonus += 1_200_000
    if any(k in text for k in ["課題", "レポート", "提出", "締切", "今日中", "本日中"]):
        bonus += 1_000_000
    if task.category in {"job_hunt", "school"}:
        bonus += 600_000
    if any(k in text for k in ["夕食", "昼食", "食事", "入浴", "寝る準備", "睡眠準備"]):
        bonus -= 180_000
    if any(k in text for k in ["ゲーム", "Discord", "通話", "遊び", "できたら", "任意"]):
        bonus -= 700_000
    return bonus


def _placement_reward(task: TaskItem) -> int:
    reward = task.priority * 2_500_000 + _keyword_bonus(task)
    if task.schedule_type == "uncertain":
        reward -= 900_000
    if task.priority >= 5:
        reward += 3_000_000
    return max(50_000, reward)


def _preferred_time_score(req: ScheduleRequest, task: TaskItem, start_idx: int, dur_slots: int) -> int:
    text = f"{task.title} {task.notes or ''} {task.reason or ''}"
    end_idx = start_idx + dur_slots
    n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
    score = 0

    def idx_for(hour: int, minute: int = 0) -> int:
        target = req.window_start.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if target < req.window_start:
            target = req.window_start
        if target > req.window_end:
            target = req.window_end
        return _floor_slot_index(req, target)

    if any(k in text for k in ["夕食", "食事"]):
        target = max(_floor_slot_index(req, req.window_start), idx_for(19, 15))
        score -= abs(start_idx - target) * 3500
        if start_idx <= idx_for(20, 30):
            score += 18000
    if "昼食" in text:
        score -= abs(start_idx - idx_for(12, 30)) * 2500
    if "入浴" in text or "風呂" in text:
        target_end = max(0, n_slots - _ceil_slots(35, req.slot_minutes))
        score -= abs(end_idx - target_end) * 1800
    if "寝る準備" in text or "睡眠準備" in text:
        score -= abs(end_idx - n_slots) * 3500
        if end_idx == n_slots:
            score += 20000
    if any(k in text for k in ["面接", "就活"]):
        # 就活準備は疲れる前に寄せる。ただし固定予定後でも入るなら許容。
        score -= end_idx * 120
    if any(k in text for k in ["課題", "レポート"]):
        score -= end_idx * 100
    if any(k in text for k in ["休憩", "余白"]):
        target = n_slots // 2
        score -= abs(start_idx - target) * 300
    return score


def _soft_busy_penalty(req: ScheduleRequest, start_idx: int, dur_slots: int) -> int:
    start = _time_at(req.window_start, start_idx, req.slot_minutes)
    end = _time_at(req.window_start, start_idx + dur_slots, req.slot_minutes)
    penalty = 0
    for b in req.soft_busy:
        if _overlap(start, end, b.start, b.end):
            if b.schedule_type == "uncertain" or b.can_cancel:
                penalty += 160_000
            else:
                penalty += 700_000
    return penalty


def _score_choice(req: ScheduleRequest, task: TaskItem, start_idx: int, dur_slots: int) -> int:
    ideal_slots = _ceil_slots(task.duration_minutes, req.slot_minutes)
    score = _placement_reward(task)
    # 長いほうが望ましいが、短縮してでも入る価値がある。
    score += dur_slots * 75_000
    if dur_slots < ideal_slots:
        score -= (ideal_slots - dur_slots) * 120_000
        if task.priority >= 5:
            score -= (ideal_slots - dur_slots) * 40_000
    score += _preferred_time_score(req, task, start_idx, dur_slots)
    score -= _soft_busy_penalty(req, start_idx, dur_slots)
    return score


def _to_item(req: ScheduleRequest, task: TaskItem, start_idx: int, dur_slots: int, reason: str) -> ScheduledItem:
    start = _time_at(req.window_start, start_idx, req.slot_minutes)
    end = _time_at(req.window_start, start_idx + dur_slots, req.slot_minutes)
    actual_minutes = dur_slots * req.slot_minutes
    notes_parts = []
    if task.notes:
        notes_parts.append(task.notes)
    if actual_minutes < task.duration_minutes:
        notes_parts.append(f"時間調整: 理想{task.duration_minutes}分 → 今回{actual_minutes}分")
    if task.travel_before_minutes or task.travel_after_minutes:
        notes_parts.append(f"移動見積: 前{task.travel_before_minutes}分 / 後{task.travel_after_minutes}分")
    return ScheduledItem(
        title=task.title,
        start=start,
        end=end,
        priority=task.priority,
        kind=task.kind,
        notes="\n".join(notes_parts) if notes_parts else task.reason or None,
        reason=task.reason or reason,
        original_duration_minutes=task.duration_minutes,
    )


def _greedy(req: ScheduleRequest) -> ScheduleResponse:
    busy = _busy_blocks_with_buffer(req)
    used: list[tuple[datetime, datetime]] = [(b.start, b.end) for b in busy]
    items: list[ScheduledItem] = []
    unscheduled: list[str] = []
    for task in sorted(req.tasks, key=lambda t: (-t.priority, t.deadline or req.window_end)):
        placed = False
        for dur_slots in _duration_options(req, task):
            before = _before_slots(req, task)
            after = _after_slots(req, task)
            n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
            for i in _candidate_starts(req, task, busy, dur_slots):
                occ_start = _time_at(req.window_start, max(0, i - before), req.slot_minutes)
                occ_end = _time_at(req.window_start, min(n_slots, i + dur_slots + after), req.slot_minutes)
                if any(_overlap(occ_start, occ_end, u0, u1) for u0, u1 in used):
                    continue
                used.append((occ_start, occ_end))
                items.append(_to_item(req, task, i, dur_slots, "優先度・最低時間・締切を考慮して貪欲法で配置"))
                placed = True
                break
            if placed:
                break
        if not placed:
            unscheduled.append(task.title)
    return ScheduleResponse(status="ok" if not unscheduled else "partial", items=sorted(items, key=lambda x: x.start), unscheduled=unscheduled, message="greedy fallback")


def solve_schedule(req: ScheduleRequest) -> ScheduleResponse:
    """Geminiが構造化した予定を、OR-Toolsで厳密に配置する。

    v14設計:
    - Geminiは最終時刻を決めない。
    - OR-Toolsは理想時間/最低時間を選択肢として扱う。
    - fixed busyはハード制約、uncertain/movableはsoft busyとして重なりペナルティにする。
    - 高優先度タスクを完全に落とすより、短縮してでも入れる。
    """
    if not req.tasks:
        return ScheduleResponse(status="ok", items=[], message="配置するタスクがありません。")

    try:
        from ortools.sat.python import cp_model
    except Exception:
        return _greedy(req)

    n_slots = _slot_count(req.window_start, req.window_end, req.slot_minutes)
    if n_slots <= 0:
        return ScheduleResponse(status="infeasible", items=[], unscheduled=[t.title for t in req.tasks], message="配置可能な時間窓がありません。")

    busy = _busy_blocks_with_buffer(req)
    model = cp_model.CpModel()
    choices: dict[tuple[int, int, int], object] = {}
    candidate_map: dict[int, list[tuple[int, int]]] = {}

    for ti, task in enumerate(req.tasks):
        entries: list[tuple[int, int]] = []
        for dur_slots in _duration_options(req, task):
            for start_idx in _candidate_starts(req, task, busy, dur_slots):
                key = (ti, start_idx, dur_slots)
                choices[key] = model.NewBoolVar(f"task_{ti}_start_{start_idx}_dur_{dur_slots}")
                entries.append((start_idx, dur_slots))
        candidate_map[ti] = entries
        if entries:
            model.AddAtMostOne(choices[(ti, s, d)] for s, d in entries)

    for slot in range(n_slots):
        occupants = []
        for ti, entries in candidate_map.items():
            task = req.tasks[ti]
            before = _before_slots(req, task)
            after = _after_slots(req, task)
            for start_idx, dur_slots in entries:
                if start_idx - before <= slot < start_idx + dur_slots + after:
                    occupants.append(choices[(ti, start_idx, dur_slots)])
        if occupants:
            model.AddAtMostOne(occupants)

    terms = []
    for ti, entries in candidate_map.items():
        task = req.tasks[ti]
        for start_idx, dur_slots in entries:
            terms.append(_score_choice(req, task, start_idx, dur_slots) * choices[(ti, start_idx, dur_slots)])
    if terms:
        model.Maximize(sum(terms))

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = 2.0
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return _greedy(req)

    items: list[ScheduledItem] = []
    placed: set[int] = set()
    for ti, entries in candidate_map.items():
        task = req.tasks[ti]
        for start_idx, dur_slots in entries:
            if solver.BooleanValue(choices[(ti, start_idx, dur_slots)]):
                items.append(_to_item(req, task, start_idx, dur_slots, "OR-Toolsが固定予定・最低時間・締切・疲労度・soft busyを考慮して配置"))
                placed.add(ti)
                break
    unscheduled = [task.title for ti, task in enumerate(req.tasks) if ti not in placed]
    return ScheduleResponse(
        status="ok" if not unscheduled else "partial",
        items=sorted(items, key=lambda x: x.start),
        unscheduled=unscheduled,
        message="OR-Tools CP-SATで、理想時間/最低時間、固定予定、soft busy、締切、疲労度を考慮して配置しました。",
    )
