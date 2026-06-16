from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta
from typing import Any, Optional
from uuid import uuid4

from .schemas import (
    CalendarEventInfo,
    CurrentUserState,
    InitialSurveyRequest,
    ProfileAnalysisRequest,
    ProfileAnalysisResponse,
    ProfileReviewAnswerRequest,
    ProfileReviewAnswerResponse,
    ProfileReviewChoice,
    ProfileReviewItem,
    ProfileRule,
    ProfileStateResponse,
)
from .supabase_service import get_supabase_service
from .user_identity import identity_from_google_token


def _now_iso() -> str:
    return datetime.utcnow().isoformat()


def _model_dump(model) -> dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump(mode="json")
    return model.dict()


def _stable_key(text: str) -> str:
    import hashlib

    value = hashlib.sha1(text.encode("utf-8")).hexdigest()[:12]
    return f"auto_{value}"


def _parse_rule(row: dict[str, Any]) -> Optional[ProfileRule]:
    try:
        return ProfileRule(
            id=str(row.get("id")) if row.get("id") else None,
            key=str(row.get("key") or row.get("rule_key") or "rule"),
            text=str(row.get("text") or row.get("rule_text") or ""),
            category=str(row.get("category") or "general"),
            strength=str(row.get("strength") or "soft"),
            usage=str(row.get("usage") or "always"),
            source=str(row.get("source") or "user"),
            confidence=float(row.get("confidence") or 0.8),
            evidence=row.get("evidence"),
            is_active=bool(row.get("is_active", row.get("active", True))),
        )
    except Exception:
        return None


def _review_item_from_row(row: dict[str, Any]) -> Optional[ProfileReviewItem]:
    try:
        payload = row.get("item_json") or row.get("payload") or {}
        if isinstance(payload, str):
            import json

            payload = json.loads(payload)
        item = ProfileReviewItem(**payload) if payload else ProfileReviewItem(
            id=str(row.get("id")),
            title=str(row.get("title") or "プロフィール確認"),
            hypothesis=row.get("hypothesis"),
            question_text=str(row.get("question_text") or "この傾向を反映しますか？"),
            source=str(row.get("source") or "calendar_analysis"),
            evidence=row.get("evidence"),
            confidence=float(row.get("confidence") or 0.7),
            target_type=str(row.get("target_type") or "rule"),
            target_action=str(row.get("target_action") or "create"),
            status=str(row.get("status") or "pending"),
        )
        item.id = str(row.get("id") or item.id or uuid4())
        item.status = str(row.get("status") or item.status or "pending")
        return item
    except Exception as e:
        print(f"[Profile] failed to parse review item: {e}")
        return None


def _default_profile() -> dict[str, Any]:
    return {
        "timezone": "Asia/Tokyo",
        "target_sleep_time": "23:30",
        "target_wake_time": "08:00",
        "avoid_heavy_work_after": "22:30",
        "default_buffer_minutes": 10,
        "default_meal_minutes": 30,
        "default_bath_minutes": 25,
        "default_sleep_prep_minutes": 20,
        "default_planning_mode": "balance",
        "requires_confirmation_before_changes": True,
    }


def get_profile_state(google_auth_header: Optional[str]) -> ProfileStateResponse:
    identity = identity_from_google_token(google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)
    profile = store.get_profile(identity.user_id)
    profile = {**_default_profile(), **profile}
    return ProfileStateResponse(
        user_id=str(identity.user_id),
        profile=profile,
        rules=_load_rules(identity.user_id),
        memories=store.load_memories(identity.user_id, limit=20),
        current_user_state=_load_current_user_state(identity.user_id),
        review_items=_load_review_items(identity.user_id),
    )


def save_initial_survey(req: InitialSurveyRequest) -> ProfileStateResponse:
    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)

    profile = {
        "user_id": str(identity.user_id),
        "target_sleep_time": req.target_sleep_time,
        "target_wake_time": req.target_wake_time,
        "avoid_heavy_work_after": req.avoid_heavy_work_after,
        "default_buffer_minutes": req.default_buffer_minutes,
        "default_meal_minutes": req.meal_duration_minutes,
        "default_bath_minutes": req.bath_duration_minutes,
        "default_sleep_prep_minutes": req.sleep_prep_minutes,
        "default_planning_mode": req.default_planning_mode,
        "requires_confirmation_before_changes": req.ai_can_modify_existing_events != "never",
        "profile_json": {
            "after_school_or_work_policy": req.after_school_or_work_policy,
            "ai_can_modify_existing_events": req.ai_can_modify_existing_events,
            "uncertain_events_can_be_deleted": req.uncertain_events_can_be_deleted,
            "free_text": req.free_text,
            "timezone": req.timezone,
        },
        "updated_at": _now_iso(),
    }
    table = store._table("user_profiles")
    if table is not None:
        try:
            table.upsert(profile, on_conflict="user_id").execute()
        except Exception as e:
            print(f"[Profile] initial survey profile upsert failed: {e}")

    rules = _rules_from_survey(req)
    _upsert_rules(identity.user_id, rules)

    if req.free_text and req.free_text.strip():
        store.upsert_memories(
            identity.user_id,
            [
                {
                    "type": "profile_free_text",
                    "key": "initial_free_text",
                    "value": {"text": req.free_text.strip()},
                    "confidence": 0.75,
                    "source": "initial_survey",
                    "evidence": "初回アンケートの自由記入欄",
                    "needs_confirmation": False,
                    "active": True,
                }
            ],
        )

    return get_profile_state(req.google_auth_header)


def _rules_from_survey(req: InitialSurveyRequest) -> list[ProfileRule]:
    rules: list[ProfileRule] = []
    if req.target_sleep_time:
        rules.append(
            ProfileRule(
                key="target_sleep_time",
                text=f"{req.target_sleep_time}までには寝る準備に入る",
                category="sleep",
                strength="hard",
                usage="always",
                source="initial_survey",
                confidence=1.0,
                evidence="初回アンケートでユーザーが設定",
            )
        )
    if req.avoid_heavy_work_after:
        rules.append(
            ProfileRule(
                key="avoid_heavy_work_after",
                text=f"{req.avoid_heavy_work_after}以降は重い作業を避ける",
                category="energy",
                strength="strong",
                usage="always",
                source="initial_survey",
                confidence=0.95,
                evidence="初回アンケートでユーザーが設定",
            )
        )
    rules.append(
        ProfileRule(
            key="default_buffer_minutes",
            text=f"予定と予定の間に基本{req.default_buffer_minutes}分の余裕を入れる",
            category="buffer",
            strength="soft",
            usage="always",
            source="initial_survey",
            confidence=0.9,
            evidence="初回アンケートでユーザーが設定",
        )
    )
    if req.after_school_or_work_policy == "avoid":
        text = "学校・バイト・仕事の後は重い作業を避ける"
        strength = "strong"
    elif req.after_school_or_work_policy == "light_only":
        text = "学校・バイト・仕事の後は軽めの作業を優先する"
        strength = "soft"
    else:
        text = "学校・バイト・仕事の後でも作業予定を入れてよい"
        strength = "hint"
    rules.append(
        ProfileRule(
            key="after_school_or_work_policy",
            text=text,
            category="energy",
            strength=strength,
            usage="always",
            source="initial_survey",
            confidence=0.85,
            evidence="初回アンケートでユーザーが設定",
        )
    )
    if req.ai_can_modify_existing_events == "never":
        rules.append(
            ProfileRule(
                key="never_modify_existing_events",
                text="AIは既存予定を変更せず、新規提案だけ行う",
                category="safety",
                strength="hard",
                usage="always",
                source="initial_survey",
                confidence=1.0,
                evidence="初回アンケートでユーザーが設定",
            )
        )
    elif req.ai_can_modify_existing_events == "uncertain_only":
        rules.append(
            ProfileRule(
                key="modify_uncertain_events_only",
                text="AIが変更候補にできるのは未確定予定だけにする",
                category="safety",
                strength="strong",
                usage="always",
                source="initial_survey",
                confidence=0.95,
                evidence="初回アンケートでユーザーが設定",
            )
        )
    return rules


def _load_rules(user_id) -> list[ProfileRule]:
    store = get_supabase_service()
    table = store._table("user_rules")
    if table is None:
        return []
    try:
        res = (
            table.select("*")
            .eq("user_id", str(user_id))
            .eq("is_active", True)
            .order("strength")
            .order("updated_at", desc=True)
            .limit(80)
            .execute()
        )
        return [r for r in (_parse_rule(row) for row in (res.data or [])) if r is not None]
    except Exception as e:
        print(f"[Profile] load rules failed: {e}")
        return []


def _upsert_rules(user_id, rules: list[ProfileRule]) -> None:
    store = get_supabase_service()
    table = store._table("user_rules")
    if table is None or not rules:
        return
    rows = []
    now = _now_iso()
    for rule in rules:
        payload = _model_dump(rule)
        payload.pop("id", None)
        rows.append({"user_id": str(user_id), **payload, "updated_at": now})
    try:
        table.upsert(rows, on_conflict="user_id,key").execute()
    except Exception as e:
        print(f"[Profile] upsert rules failed: {e}")


def _load_current_user_state(user_id) -> CurrentUserState:
    store = get_supabase_service()
    table = store._table("current_user_state")
    if table is None:
        return CurrentUserState()
    try:
        res = table.select("*").eq("user_id", str(user_id)).limit(1).execute()
        if res.data:
            row = res.data[0]
            return CurrentUserState(
                load_level=int(row.get("load_level") or 3),
                planning_mode=str(row.get("planning_mode") or "balance"),
                energy_level=int(row.get("energy_level") or 3),
                note=row.get("note"),
                updated_at=datetime.fromisoformat(str(row["updated_at"]).replace("Z", "+00:00")) if row.get("updated_at") else None,
            )
    except Exception as e:
        print(f"[Profile] load current state failed: {e}")
    return CurrentUserState()


def _update_current_user_state(user_id, choice: ProfileReviewChoice, note: Optional[str] = None) -> None:
    store = get_supabase_service()
    table = store._table("current_user_state")
    if table is None:
        return
    row = {
        "user_id": str(user_id),
        "load_level": choice.load_level or 3,
        "planning_mode": choice.planning_mode or "balance",
        "energy_level": choice.energy_level or 3,
        "note": note,
        "updated_at": _now_iso(),
    }
    try:
        table.upsert(row, on_conflict="user_id").execute()
    except Exception as e:
        print(f"[Profile] update current state failed: {e}")


def _load_review_items(user_id) -> list[ProfileReviewItem]:
    store = get_supabase_service()
    table = store._table("profile_review_items")
    if table is None:
        return []
    try:
        res = (
            table.select("*")
            .eq("user_id", str(user_id))
            .eq("status", "pending")
            .order("created_at", desc=True)
            .limit(20)
            .execute()
        )
        return [i for i in (_review_item_from_row(row) for row in (res.data or [])) if i is not None]
    except Exception as e:
        print(f"[Profile] load review items failed: {e}")
        return []


def _store_review_items(user_id, items: list[ProfileReviewItem]) -> list[ProfileReviewItem]:
    if not items:
        return []
    store = get_supabase_service()
    table = store._table("profile_review_items")
    now = _now_iso()
    for item in items:
        item.id = item.id or str(uuid4())
        item.created_at = item.created_at or datetime.utcnow()
    if table is None:
        return items
    rows = []
    for item in items:
        rows.append(
            {
                "id": item.id,
                "user_id": str(user_id),
                "title": item.title,
                "hypothesis": item.hypothesis,
                "question_text": item.question_text,
                "source": item.source,
                "evidence": item.evidence,
                "confidence": item.confidence,
                "target_type": item.target_type,
                "target_action": item.target_action,
                "status": item.status,
                "item_json": _model_dump(item),
                "created_at": now,
                "updated_at": now,
            }
        )
    try:
        table.upsert(rows, on_conflict="id").execute()
    except Exception as e:
        print(f"[Profile] store review items failed: {e}")
    return items


def analyze_profile(req: ProfileAnalysisRequest) -> ProfileAnalysisResponse:
    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)
    items = _generate_review_items(req.calendar_events, req.free_text)
    items = _store_review_items(identity.user_id, items)
    return ProfileAnalysisResponse(ok=True, message=f"{len(items)}件のプロフィール見直し項目を作成しました。", review_items=items)


def _generate_review_items(events: list[CalendarEventInfo], free_text: Optional[str] = None) -> list[ProfileReviewItem]:
    items: list[ProfileReviewItem] = []
    items.append(_busy_check_item())
    if free_text and free_text.strip():
        text = free_text.strip()
        items.append(
            ProfileReviewItem(
                title="自由記入の反映",
                hypothesis="ユーザーが自由記入で伝えた生活方針をプロフィールに反映できそうです。",
                question_text=f"次の内容を今後の予定提案に反映しますか？\n「{text}」",
                source="manual",
                evidence="傾向分析画面の自由記入欄",
                confidence=0.9,
                target_type="memory",
                target_action="create",
                suggested_rule_key=_stable_key(text),
                suggested_rule_text=text,
                suggested_strength="hint",
                suggested_usage="on_demand",
                choices=[
                    ProfileReviewChoice(id="save_rule_soft", label="ルールとして反映", result_action="create_rule", strength="soft", usage="always"),
                    ProfileReviewChoice(id="save_memory", label="傾向として保存", result_action="create_memory", strength="hint", usage="on_demand"),
                    ProfileReviewChoice(id="reject", label="保存しない", result_action="reject"),
                ],
            )
        )
    if not events:
        return items

    sorted_events = sorted(events, key=lambda e: e.start)
    total_minutes = sum(max(0, int((e.end - e.start).total_seconds() // 60)) for e in sorted_events)
    busy_hours = round(total_minutes / 60, 1)
    day_count = max(1, len({e.start.date() for e in sorted_events}))
    avg_events_per_day = len(sorted_events) / day_count
    if len(sorted_events) >= 5 or busy_hours >= 6 or avg_events_per_day >= 4:
        items.append(
            ProfileReviewItem(
                title="予定量が多い日の扱い",
                hypothesis="予定が多い日は、低優先度のタスクを減らした方がよさそうです。",
                question_text="カレンダー上の予定量が多めです。忙しい日は休憩多め・最低限の予定を優先する設定にしますか？",
                source="calendar_analysis",
                evidence=f"分析対象に{len(sorted_events)}件、合計約{busy_hours}時間の予定があります。",
                confidence=0.75,
                target_type="rule",
                target_action="create",
                suggested_rule_key="busy_day_reduce_low_priority",
                suggested_rule_text="予定が多い日は低優先度のタスクを減らし、休憩を多めにする",
                suggested_strength="soft",
                suggested_usage="always",
                choices=[
                    ProfileReviewChoice(id="strong", label="強めに反映", result_action="create_rule", strength="strong", usage="always"),
                    ProfileReviewChoice(id="soft", label="できれば反映", result_action="create_rule", strength="soft", usage="always"),
                    ProfileReviewChoice(id="memory", label="参考程度にする", result_action="create_memory", strength="hint", usage="on_demand"),
                    ProfileReviewChoice(id="reject", label="これは違う", result_action="reject"),
                ],
            )
        )

    work_keywords = ("バイト", "仕事", "シフト", "勤務", "work", "part-time")
    work_events = [e for e in sorted_events if any(k.lower() in e.title.lower() for k in work_keywords)]
    if work_events:
        after_work_with_events = 0
        for w in work_events:
            window_end = w.end + timedelta(hours=2)
            if any(e.start >= w.end and e.start < window_end and e.id != w.id for e in sorted_events):
                after_work_with_events += 1
        if after_work_with_events <= max(0, len(work_events) // 3):
            items.append(
                ProfileReviewItem(
                    title="バイト・仕事後の作業",
                    hypothesis="バイトや仕事の後は、重い作業を避けた方がよさそうです。",
                    question_text="バイト・仕事の後に作業予定が少ない傾向があります。今後もバイト後は軽めの予定を優先しますか？",
                    source="calendar_analysis",
                    evidence=f"分析対象にバイト・仕事系予定が{len(work_events)}件あり、直後2時間の予定が少なめでした。",
                    confidence=0.72,
                    target_type="rule",
                    target_action="create",
                    suggested_rule_key="after_work_light_only",
                    suggested_rule_text="バイト・仕事の後は重い作業を避け、軽めの予定を優先する",
                    suggested_strength="soft",
                    suggested_usage="always",
                    choices=[
                        ProfileReviewChoice(id="strong", label="強めに反映", result_action="create_rule", strength="strong", usage="always"),
                        ProfileReviewChoice(id="soft", label="できれば反映", result_action="create_rule", strength="soft", usage="always"),
                        ProfileReviewChoice(id="hint", label="参考程度", result_action="create_memory", strength="hint", usage="on_demand"),
                        ProfileReviewChoice(id="reject", label="関係ない", result_action="reject"),
                    ],
                )
            )

    late_events = [e for e in sorted_events if e.start.hour >= 22 or e.end.hour >= 23]
    if late_events:
        items.append(
            ProfileReviewItem(
                title="夜遅い予定の扱い",
                hypothesis="夜遅い予定がある日は、翌朝や深夜の重い作業を避けた方がよさそうです。",
                question_text="22時以降に予定が入る日があります。夜遅い日は重い作業を避けるルールを強めますか？",
                source="calendar_analysis",
                evidence=f"22時以降に関係する予定が{len(late_events)}件ありました。",
                confidence=0.68,
                target_type="rule",
                target_action="create",
                suggested_rule_key="late_day_avoid_heavy_work",
                suggested_rule_text="夜遅い予定がある日は、その後の重い作業と翌朝早い予定を避ける",
                suggested_strength="soft",
                suggested_usage="always",
                choices=[
                    ProfileReviewChoice(id="strong", label="強める", result_action="create_rule", strength="strong", usage="always"),
                    ProfileReviewChoice(id="soft", label="弱めに反映", result_action="create_rule", strength="soft", usage="always"),
                    ProfileReviewChoice(id="skip", label="今回はスキップ", result_action="skip"),
                    ProfileReviewChoice(id="reject", label="違う", result_action="reject"),
                ],
            )
        )

    tight_gaps = 0
    for a, b in zip(sorted_events, sorted_events[1:]):
        gap = (b.start - a.end).total_seconds() / 60
        if 0 <= gap < 15:
            tight_gaps += 1
    if tight_gaps:
        items.append(
            ProfileReviewItem(
                title="予定間の余裕",
                hypothesis="予定と予定の間の余裕が少ない日がありそうです。",
                question_text="予定同士の間隔が短い箇所があります。今後は予定間のバッファを強めに取りますか？",
                source="calendar_analysis",
                evidence=f"15分未満の予定間隔が{tight_gaps}箇所ありました。",
                confidence=0.7,
                target_type="rule",
                target_action="create",
                suggested_rule_key="avoid_tight_event_gaps",
                suggested_rule_text="予定と予定の間に余裕を取り、連続しすぎる配置を避ける",
                suggested_strength="soft",
                suggested_usage="always",
                choices=[
                    ProfileReviewChoice(id="strong", label="強めに反映", result_action="create_rule", strength="strong", usage="always"),
                    ProfileReviewChoice(id="soft", label="できれば反映", result_action="create_rule", strength="soft", usage="always"),
                    ProfileReviewChoice(id="reject", label="気にしない", result_action="reject"),
                ],
            )
        )
    return items


def _busy_check_item() -> ProfileReviewItem:
    return ProfileReviewItem(
        title="最近の忙しさ",
        hypothesis=None,
        question_text="最近の忙しさはどうですか？今週の予定提案に反映します。",
        source="user_checkin",
        evidence="ユーザー状態の定期確認",
        confidence=1.0,
        target_type="current_user_state",
        target_action="update",
        choices=[
            ProfileReviewChoice(id="load_1", label="余裕あり", result_action="update_current_state", load_level=1, planning_mode="balance", energy_level=4),
            ProfileReviewChoice(id="load_3", label="普通", result_action="update_current_state", load_level=3, planning_mode="balance", energy_level=3),
            ProfileReviewChoice(id="load_4", label="かなり忙しい", result_action="update_current_state", load_level=4, planning_mode="energy_saving", energy_level=2),
            ProfileReviewChoice(id="load_5", label="予定を減らしたい", result_action="update_current_state", load_level=5, planning_mode="minimum", energy_level=2),
        ],
    )


def answer_profile_review(req: ProfileReviewAnswerRequest) -> ProfileReviewAnswerResponse:
    identity = identity_from_google_token(req.google_auth_header)
    store = get_supabase_service()
    store.ensure_user(identity)
    item = req.review_item
    choice = next((c for c in item.choices if c.id == req.choice_id), None)
    if choice is None:
        return ProfileReviewAnswerResponse(ok=False, message="選択肢が見つかりません。")

    if choice.result_action in ("create_rule", "update_rule"):
        rule = ProfileRule(
            id=item.target_rule_id,
            key=item.suggested_rule_key or _stable_key(item.suggested_rule_text or item.title),
            text=item.suggested_rule_text or item.hypothesis or item.title,
            category=item.target_type,
            strength=choice.strength or item.suggested_strength or "soft",
            usage=choice.usage or item.suggested_usage or "always",
            source=f"user_confirmed_{item.source}",
            confidence=max(item.confidence, 0.85),
            evidence=item.evidence,
            is_active=True,
        )
        _upsert_rules(identity.user_id, [rule])
        _mark_review_item(identity.user_id, item, "applied")
        message = "ルールに反映しました。"
    elif choice.result_action == "delete_rule":
        _deactivate_rule(identity.user_id, item.target_rule_id, item.suggested_rule_key)
        _mark_review_item(identity.user_id, item, "applied")
        message = "ルールを削除しました。"
    elif choice.result_action == "create_memory":
        text = item.suggested_rule_text or item.hypothesis or item.question_text
        store.upsert_memories(
            identity.user_id,
            [
                {
                    "type": "pattern",
                    "key": item.suggested_rule_key or _stable_key(text),
                    "value": {"text": text, "strength": choice.strength or "hint", "usage": choice.usage or "on_demand"},
                    "confidence": item.confidence,
                    "source": f"user_confirmed_{item.source}",
                    "evidence": item.evidence,
                    "needs_confirmation": False,
                    "active": True,
                }
            ],
        )
        _mark_review_item(identity.user_id, item, "applied")
        message = "傾向として保存しました。"
    elif choice.result_action == "update_current_state":
        _update_current_user_state(identity.user_id, choice, note=req.free_text)
        _mark_review_item(identity.user_id, item, "applied")
        message = "最近の忙しさ・今週のモードを更新しました。"
    elif choice.result_action == "reject":
        _mark_review_item(identity.user_id, item, "rejected")
        message = "この仮説は反映しません。"
    else:
        _mark_review_item(identity.user_id, item, "skipped")
        message = "今回はスキップしました。"

    return ProfileReviewAnswerResponse(ok=True, message=message, profile_state=get_profile_state(req.google_auth_header))


def _deactivate_rule(user_id, rule_id: Optional[str], key: Optional[str]) -> None:
    store = get_supabase_service()
    table = store._table("user_rules")
    if table is None:
        return
    try:
        q = table.update({"is_active": False, "updated_at": _now_iso()}).eq("user_id", str(user_id))
        if rule_id:
            q = q.eq("id", rule_id)
        elif key:
            q = q.eq("key", key)
        else:
            return
        q.execute()
    except Exception as e:
        print(f"[Profile] deactivate rule failed: {e}")


def _mark_review_item(user_id, item: ProfileReviewItem, status: str) -> None:
    if not item.id:
        return
    store = get_supabase_service()
    table = store._table("profile_review_items")
    if table is None:
        return
    try:
        table.update({"status": status, "updated_at": _now_iso()}).eq("id", item.id).eq("user_id", str(user_id)).execute()
    except Exception as e:
        print(f"[Profile] mark review item failed: {e}")
