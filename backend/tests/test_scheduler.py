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
