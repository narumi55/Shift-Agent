from __future__ import annotations

from dataclasses import dataclass
from typing import Optional
from uuid import UUID, uuid5, NAMESPACE_URL

import requests


@dataclass(frozen=True)
class UserIdentity:
    user_id: UUID
    email: Optional[str] = None
    display_name: Optional[str] = None
    avatar_url: Optional[str] = None
    source: str = "local"


LOCAL_USER_ID = uuid5(NAMESPACE_URL, "shift-agent-local-user")


def _auth_headers(google_auth_header: str) -> dict[str, str]:
    if not google_auth_header.lower().startswith("bearer "):
        google_auth_header = f"Bearer {google_auth_header}"
    return {"Authorization": google_auth_header, "Accept": "application/json"}


def identity_from_google_token(google_auth_header: Optional[str]) -> UserIdentity:
    """Resolve a stable app user id from the Google access token.

    The Flutter app already obtains Google scopes including email/profile.
    When resolving fails, we fall back to a deterministic local user so the app
    keeps working during development.
    """
    if not google_auth_header:
        return UserIdentity(user_id=LOCAL_USER_ID)
    try:
        resp = requests.get(
            "https://www.googleapis.com/oauth2/v3/userinfo",
            headers=_auth_headers(google_auth_header),
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        email = data.get("email")
        subject = data.get("sub") or email or "unknown"
        return UserIdentity(
            user_id=uuid5(NAMESPACE_URL, f"google:{subject}"),
            email=email,
            display_name=data.get("name"),
            avatar_url=data.get("picture"),
            source="google",
        )
    except Exception:
        return UserIdentity(user_id=LOCAL_USER_ID)
