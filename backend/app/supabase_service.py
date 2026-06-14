from __future__ import annotations

import hashlib
import math
import os
from datetime import datetime
from functools import lru_cache
from typing import Any, Optional

from dotenv import load_dotenv

from .memory_engine import DEFAULT_PROFILE
from .schemas import CalendarEventInfo, ProposedAction, ScheduledItem
from .user_identity import UserIdentity

load_dotenv()

EMBEDDING_DIM = 768


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() if dt else None


def _memory_embedding_text(mem: dict[str, Any]) -> str:
    return " | ".join(
        [
            str(mem.get("type", "")),
            str(mem.get("key", "")),
            str(mem.get("value", "")),
            str(mem.get("evidence", "")),
        ]
    )


def _hash_embedding(text: str, dim: int = EMBEDDING_DIM) -> list[float]:
    """Dependency-free semantic-ish fallback.

    本番では Gemini embedding などに差し替え可能。ローカル開発では無料で
    pgvectorの保存/検索パイプラインを動かすため、単語ハッシュのbag-of-wordsを使う。
    """
    vec = [0.0] * dim
    tokens = [t for t in text.replace("\n", " ").replace("　", " ").split(" ") if t]
    if not tokens:
        tokens = [text[:80] or "empty"]
    for token in tokens:
        h = hashlib.sha256(token.encode("utf-8")).digest()
        idx = int.from_bytes(h[:4], "little") % dim
        sign = 1.0 if h[4] % 2 == 0 else -1.0
        vec[idx] += sign
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [round(v / norm, 6) for v in vec]


class SupabaseService:
    def __init__(self) -> None:
        self.url = os.getenv("SUPABASE_URL", "").strip()
        self.key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip() or os.getenv("SUPABASE_ANON_KEY", "").strip()
        self.enabled = bool(self.url and self.key)
        self._client = None
        if self.enabled:
            try:
                from supabase import create_client

                self._client = create_client(self.url, self.key)
            except Exception as e:
                print(f"[Supabase] disabled: {e}")
                self.enabled = False

    def status(self) -> dict[str, Any]:
        return {
            "configured": self.enabled,
            "url_set": bool(self.url),
            "key_set": bool(self.key),
            "pgvector_dim": EMBEDDING_DIM,
            "embedding_model": os.getenv("GEMINI_EMBEDDING_MODEL", "hash-fallback"),
        }

    def _table(self, name: str):
        if not self.enabled or self._client is None:
            return None
        return self._client.table(name)

    def _embedding_for_text(self, text: str) -> list[float]:
        model = os.getenv("GEMINI_EMBEDDING_MODEL", "").strip()
        api_key = os.getenv("GEMINI_API_KEY", "").strip()
        if model and api_key:
            try:
                from google import genai
                from google.genai import types

                client = genai.Client(api_key=api_key)
                result = client.models.embed_content(
                    model=model,
                    contents=text,
                    config=types.EmbedContentConfig(output_dimensionality=EMBEDDING_DIM),
                )
                emb = result.embeddings[0].values
                if len(emb) == EMBEDDING_DIM:
                    return [float(v) for v in emb]
            except Exception as e:
                print(f"[Supabase] Gemini embedding fallback to hash: {e}")
        return _hash_embedding(text)

    def ensure_user(self, identity: UserIdentity) -> None:
        table = self._table("app_users")
        if table is None:
            return
        try:
            table.upsert(
                {
                    "id": str(identity.user_id),
                    "google_email": identity.email,
                    "display_name": identity.display_name,
                    "avatar_url": identity.avatar_url,
                    "updated_at": datetime.utcnow().isoformat(),
                },
                on_conflict="id",
            ).execute()
            self._ensure_profile(identity.user_id)
        except Exception as e:
            print(f"[Supabase] ensure_user failed: {e}")

    def _ensure_profile(self, user_id) -> None:
        table = self._table("user_profiles")
        if table is None:
            return
        try:
            row = {"user_id": str(user_id), **DEFAULT_PROFILE, "updated_at": datetime.utcnow().isoformat()}
            table.upsert(row, on_conflict="user_id").execute()
        except Exception as e:
            print(f"[Supabase] ensure_profile failed: {e}")

    def get_profile(self, user_id) -> dict[str, Any]:
        table = self._table("user_profiles")
        if table is None:
            return dict(DEFAULT_PROFILE)
        try:
            res = table.select("*").eq("user_id", str(user_id)).limit(1).execute()
            if res.data:
                return {**DEFAULT_PROFILE, **res.data[0]}
        except Exception as e:
            print(f"[Supabase] get_profile failed: {e}")
        return dict(DEFAULT_PROFILE)

    def load_memories(self, user_id, limit: int = 40) -> list[dict[str, Any]]:
        table = self._table("memories")
        if table is None:
            return []
        try:
            res = (
                table.select("*")
                .eq("user_id", str(user_id))
                .eq("active", True)
                .order("confidence", desc=True)
                .order("updated_at", desc=True)
                .limit(limit)
                .execute()
            )
            return list(res.data or [])
        except Exception as e:
            print(f"[Supabase] load_memories failed: {e}")
            return []

    def load_relevant_memories(self, user_id, query: str, limit: int = 12) -> list[dict[str, Any]]:
        """pgvectorで、今回の会話に近い過去の記憶を検索する。失敗時は通常検索へ戻す。"""
        if not self.enabled or self._client is None:
            return []
        try:
            embedding = self._embedding_for_text(query)
            res = self._client.rpc(
                "match_memories",
                {
                    "p_user_id": str(user_id),
                    "query_embedding": embedding,
                    "match_count": limit,
                },
            ).execute()
            if res.data:
                return list(res.data)
        except Exception as e:
            print(f"[Supabase] load_relevant_memories fallback: {e}")
        return self.load_memories(user_id, limit=limit)

    def upsert_memories(self, user_id, memories: list[dict[str, Any]]) -> None:
        if not memories:
            return
        table = self._table("memories")
        if table is None:
            return
        rows = []
        now = datetime.utcnow().isoformat()
        for mem in memories:
            text = _memory_embedding_text(mem)
            rows.append({"user_id": str(user_id), **mem, "embedding": self._embedding_for_text(text), "updated_at": now})
        try:
            table.upsert(rows, on_conflict="user_id,type,key").execute()
        except Exception as e:
            # 既存DBにembedding列/RPCがまだない場合でも、エージェント本体を止めない。
            print(f"[Supabase] upsert_memories with embedding failed, retry without embedding: {e}")
            try:
                for r in rows:
                    r.pop("embedding", None)
                table.upsert(rows, on_conflict="user_id,type,key").execute()
            except Exception as e2:
                print(f"[Supabase] upsert_memories failed: {e2}")

    def save_conversation(self, user_id, role: str, message: str, extracted_memories: Optional[list[dict[str, Any]]] = None, calendar_snapshot: Optional[list[dict[str, Any]]] = None) -> None:
        table = self._table("conversation_logs")
        if table is None:
            return
        try:
            table.insert(
                {
                    "user_id": str(user_id),
                    "role": role,
                    "message": message,
                    "extracted_memories": extracted_memories or [],
                    "calendar_snapshot": calendar_snapshot or [],
                }
            ).execute()
        except Exception as e:
            print(f"[Supabase] save_conversation failed: {e}")

    def sync_calendar_events(self, user_id, events: list[CalendarEventInfo]) -> None:
        table = self._table("schedule_items")
        if table is None or not events:
            return
        rows = []
        for ev in events:
            rows.append(
                {
                    "user_id": str(user_id),
                    "google_event_id": ev.id,
                    "google_calendar_id": ev.calendar_id,
                    "google_etag": ev.etag,
                    "google_html_link": ev.html_link,
                    "source": ev.source,
                    "title": ev.title,
                    "raw_title": ev.raw_title or ev.title,
                    "normalized_title": ev.normalized_title or ev.title,
                    "description": None,
                    "location": ev.location,
                    "item_type": "event",
                    "schedule_type": ev.schedule_type,
                    "category": ev.category,
                    "start_time": _iso(ev.start),
                    "end_time": _iso(ev.end),
                    "duration_minutes": int((ev.end - ev.start).total_seconds() // 60),
                    "priority": "medium",
                    "movable": ev.movable,
                    "can_cancel": ev.can_cancel,
                    "can_shorten": ev.can_shorten,
                    "travel_before_minutes": ev.travel_before_minutes,
                    "travel_after_minutes": ev.travel_after_minutes,
                    "requires_confirmation": True,
                    "is_all_day": ev.is_all_day,
                    "confidence": ev.confidence,
                    "inferred_by": ev.inferred_by,
                    "last_synced_at": datetime.utcnow().isoformat(),
                    "raw_json": ev.model_dump(mode="json"),
                    "updated_at": datetime.utcnow().isoformat(),
                }
            )
        try:
            table.upsert(rows, on_conflict="user_id,google_event_id").execute()
        except Exception as e:
            # Existing projects may not have v15 columns until 003 migration is run.
            print(f"[Supabase] sync_calendar_events full row failed, retry legacy columns: {e}")
            legacy_keys = {
                "user_id", "google_event_id", "source", "title", "description", "category",
                "item_type", "schedule_type", "start_time", "end_time", "duration_minutes",
                "priority", "movable", "can_cancel", "requires_confirmation", "location",
                "travel_before_minutes", "travel_after_minutes", "raw_json", "updated_at",
            }
            try:
                table.upsert([{k: v for k, v in r.items() if k in legacy_keys} for r in rows], on_conflict="user_id,google_event_id").execute()
            except Exception as e2:
                print(f"[Supabase] sync_calendar_events failed: {e2}")

    def save_proposal(
        self,
        user_id,
        user_message: str,
        reply: str,
        proposed_items: Optional[list[ScheduledItem]] = None,
        proposed_actions: Optional[list[ProposedAction]] = None,
        warnings: Optional[list[str]] = None,
        rules_applied: Optional[list[str]] = None,
        calendar_snapshot: Optional[list[dict[str, Any]]] = None,
    ) -> Optional[str]:
        table = self._table("agent_proposals")
        if table is None:
            return None
        try:
            actions: list[dict[str, Any]] = []
            if proposed_actions is not None:
                actions = [a.model_dump(mode="json") for a in proposed_actions]
            elif proposed_items is not None:
                actions = [
                    {
                        "action_type": "create_event",
                        "title": item.title,
                        "start": item.start.isoformat(),
                        "end": item.end.isoformat(),
                        "priority": item.priority,
                        "kind": item.kind,
                        "notes": item.notes,
                        "reason": item.reason,
                        "requires_confirmation": True,
                    }
                    for item in proposed_items
                ]
            res = table.insert(
                {
                    "user_id": str(user_id),
                    "user_message": user_message,
                    "reply": reply,
                    "proposed_actions": actions,
                    "warnings": warnings or [],
                    "rules_applied": rules_applied or [],
                    "calendar_snapshot": calendar_snapshot or [],
                }
            ).execute()
            if res.data:
                return res.data[0].get("id")
        except Exception as e:
            print(f"[Supabase] save_proposal failed: {e}")
        return None

    def record_decision(
        self,
        user_id,
        proposal_id: Optional[str],
        user_action: str,
        accepted: list[dict[str, Any]],
        rejected: list[dict[str, Any]],
        feedback: Optional[str] = None,
        learned_preferences: Optional[list[dict[str, Any]]] = None,
    ) -> None:
        if not self.enabled or self._client is None:
            return
        try:
            self._client.table("decision_logs").insert(
                {
                    "user_id": str(user_id),
                    "proposal_id": proposal_id,
                    "user_action": user_action,
                    "accepted_json": accepted,
                    "rejected_json": rejected,
                    "user_feedback": feedback,
                    "learned_preferences": learned_preferences or [],
                }
            ).execute()
            if proposal_id:
                status = "accepted" if user_action == "accepted" else "rejected" if user_action == "rejected" else "partially_accepted"
                self._client.table("agent_proposals").update(
                    {"status": status, "decided_at": datetime.utcnow().isoformat()}
                ).eq("id", proposal_id).execute()
        except Exception as e:
            print(f"[Supabase] record_decision failed: {e}")


@lru_cache(maxsize=1)
def get_supabase_service() -> SupabaseService:
    return SupabaseService()
