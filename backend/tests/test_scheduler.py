from datetime import datetime
from zoneinfo import ZoneInfo

from app.scheduler import solve_schedule
from app.schemas import BusyBlock, ScheduleRequest, TaskItem


def test_solve_schedule_basic():
    tz = ZoneInfo("Asia/Tokyo")
    req = ScheduleRequest(
        window_start=datetime(2026, 6, 12, 9, 0, tzinfo=tz),
        window_end=datetime(2026, 6, 12, 18, 0, tzinfo=tz),
        busy=[BusyBlock(start=datetime(2026, 6, 12, 10, 0, tzinfo=tz), end=datetime(2026, 6, 12, 11, 0, tzinfo=tz))],
        tasks=[TaskItem(title="課題", duration_minutes=120, priority=4)],
    )
    res = solve_schedule(req)
    assert res.items
    assert res.items[0].title == "課題"


def test_high_priority_tasks_not_dropped_by_life_routines():
    tz = ZoneInfo("Asia/Tokyo")
    req = ScheduleRequest(
        window_start=datetime(2026, 6, 13, 16, 30, tzinfo=tz),
        window_end=datetime(2026, 6, 13, 23, 30, tzinfo=tz),
        busy=[BusyBlock(start=datetime(2026, 6, 13, 16, 30, tzinfo=tz), end=datetime(2026, 6, 13, 19, 0, tzinfo=tz), title="アルバイト")],
        tasks=[
            TaskItem(title="夕食", duration_minutes=30, priority=3, category="life", energy_required="low"),
            TaskItem(title="オンライン面接準備", duration_minutes=90, priority=5, category="job_hunt", mental_load="high"),
            TaskItem(title="学校課題", duration_minutes=60, priority=5, category="school", mental_load="high"),
            TaskItem(title="入浴", duration_minutes=25, priority=3, category="life", energy_required="low"),
            TaskItem(title="寝る準備", duration_minutes=20, priority=3, category="life", energy_required="low"),
        ],
        slot_minutes=15,
        default_buffer_minutes=10,
        avoid_heavy_work_after=datetime(2026, 6, 13, 22, 30, tzinfo=tz),
    )
    res = solve_schedule(req)
    titles = [item.title for item in res.items]
    assert "オンライン面接準備" in titles
    assert "学校課題" in titles
    for item in res.items:
        assert not (item.start < datetime(2026, 6, 13, 19, 0, tzinfo=tz) and item.end > datetime(2026, 6, 13, 16, 30, tzinfo=tz))
        if item.title in {"オンライン面接準備", "学校課題"}:
            assert item.end <= datetime(2026, 6, 13, 22, 30, tzinfo=tz)
