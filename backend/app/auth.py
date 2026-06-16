from __future__ import annotations

import hmac
import os
import secrets
from dataclasses import dataclass, field

from fastapi import HTTPException, Request, status


def access_mode() -> str:
    mode = os.environ.get("DRIVE_RESEARCH_ACCESS_MODE", "local").strip().lower()
    return "lan" if mode in {"lan", "lanaccess", "network"} else "local"


def auth_required() -> bool:
    return access_mode() == "lan"


def configured_pin() -> str:
    return os.environ.get("DRIVE_RESEARCH_ACCESS_PIN", "").strip()


@dataclass
class SessionStore:
    tokens: set[str] = field(default_factory=set)

    def issue(self) -> str:
        token = secrets.token_urlsafe(32)
        self.tokens.add(token)
        return token

    def valid(self, token: str | None) -> bool:
        if not token:
            return False
        return any(hmac.compare_digest(token, existing) for existing in self.tokens)


sessions = SessionStore()


def verify_pin(pin: str) -> str:
    expected = configured_pin()
    if not auth_required():
        return sessions.issue()
    if not expected:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="PIN is not configured")
    if not hmac.compare_digest(pin.strip(), expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid PIN")
    return sessions.issue()


def token_from_request(request: Request) -> str | None:
    header_token = request.headers.get("X-ShimaiBako-Token")
    if header_token:
        return header_token.strip()
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    query_token = request.query_params.get("token")
    if query_token:
        return query_token.strip()
    return None


async def require_auth(request: Request) -> None:
    if not auth_required():
        return
    if request.method == "OPTIONS":
        return
    token = token_from_request(request)
    if not sessions.valid(token):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="PIN authentication required")
