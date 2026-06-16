from __future__ import annotations

import re
from datetime import time
from typing import Any

DEFAULT_PROFILE: dict[str, Any] = {
    "target_sleep_time": "23:30",
    "target_wake_time": "08:00",
    "avoid_heavy_work_after": "22:30",
    "default_buffer_minutes": 10,
    "default_meal_minutes": 30,
    "default_bath_minutes": 25,
    "default_sleep_prep_minutes": 20,
    "avoid_tight_schedule": True,
    "requires_confirmation_before_changes": True,
    "profile_json": {},
}


def _time_value(hour: int, minute: int = 0) -> str:
    hour = max(0, min(23, hour))
    minute = max(0, min(59, minute))
    return f"{hour:02d}:{minute:02d}"


def _memory(type_: str, key: str, value: Any, evidence: str, confidence: float, source: str = "conversation") -> dict[str, Any]:
    return {
        "type": type_,
        "key": key,
        "value": value if isinstance(value, dict) else {"value": value},
        "confidence": confidence,
        "source": source,
        "evidence": evidence[:800],
        "needs_confirmation": confidence < 0.85,
        "active": True,
    }


def extract_memories_from_text(text: str) -> list[dict[str, Any]]:
    """Small, transparent memory extractor.

    Gemini can be added later for richer extraction, but this rule-based version
    is intentionally deterministic. It only extracts scheduling-related facts.
    """
    memories: list[dict[str, Any]] = []
    normalized = text.replace("　", " ")

    # target sleep time: 23:30には寝たい / 23時半に寝たい / 0時には寝たい
    if "寝" in normalized:
        m = re.search(r"(\d{1,2})\s*(?::|：|時)\s*(\d{1,2}|半)?", normalized)
        if m:
            hour = int(m.group(1))
            minute_raw = m.group(2)
            minute = 30 if minute_raw == "半" else int(minute_raw or 0)
            memories.append(_memory("hard_rule", "target_sleep_time", _time_value(hour, minute), text, 0.9))

    # Avoid late heavy/code work.
    if any(w in normalized for w in ["以降", "夜", "深夜"]) and any(w in normalized for w in ["コード", "開発", "重い作業", "集中"]):
        m = re.search(r"(\d{1,2})\s*(?::|：|時)\s*(\d{1,2}|半)?\s*以降", normalized)
        if m:
            hour = int(m.group(1))
            minute_raw = m.group(2)
            minute = 30 if minute_raw == "半" else int(minute_raw or 0)
            key = "avoid_coding_after" if "コード" in normalized or "開発" in normalized else "avoid_heavy_work_after"
            memories.append(_memory("hard_rule", key, _time_value(hour, minute), text, 0.9))

    # Buffer preference.
    if "余白" in normalized or "バッファ" in normalized:
        m = re.search(r"(\d{1,3})\s*分", normalized)
        if m:
            memories.append(_memory("preference", "default_buffer_minutes", int(m.group(1)), text, 0.85))

    # Travel margin preference.
    if "移動" in normalized and any(w in normalized for w in ["多め", "余裕", "甘く", "見積"]):
        memories.append(_memory("preference", "travel_time_margin", {"minutes": 10, "policy": "add_margin"}, text, 0.75))

    # Work fixedness.
    if any(w in normalized for w in ["アルバイト", "バイト", "仕事"]) and any(w in normalized for w in ["動かせない", "固定", "基本的に動かせません"]):
        memories.append(_memory("hard_rule", "part_time_job_fixed", True, text, 0.95))

    return memories


def profile_summary(profile: dict[str, Any], memories: list[dict[str, Any]]) -> str:
    lines = [
        f"- 目標就寝: {profile.get('target_sleep_time', '23:30')}",
        f"- 目標起床: {profile.get('target_wake_time', '08:00')}",
        f"- 重い作業を避ける時刻: {profile.get('avoid_heavy_work_after', '22:30')}",
        f"- 標準余白: {profile.get('default_buffer_minutes', 10)}分",
        f"- 標準食事: {profile.get('default_meal_minutes', 30)}分",
        f"- 入浴: {profile.get('default_bath_minutes', 25)}分 / 寝る準備: {profile.get('default_sleep_prep_minutes', 20)}分",
    ]
    if memories:
        lines.append("- 追加記憶:")
        for mem in memories[:12]:
            lines.append(f"  - {mem.get('type')}/{mem.get('key')}: {mem.get('value')} (confidence={mem.get('confidence')})")
    return "\n".join(lines)
