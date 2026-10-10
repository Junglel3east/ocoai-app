"""Google Play subscription verification — the server is the source of truth for Oracle Pro.

Flow:
  1. App buys / restores → POST /billing/verify with the Play purchase token.
  2. Backend asks Google (purchases.subscriptionsv2) and stores the entitlement per user_id.
  3. Google Real-Time Developer Notifications (Pub/Sub push → POST /billing/rtdn) keep
     renewals, cancellations, refunds and holds in sync without the app being open.
  4. App calls GET /billing/entitlement on launch / sign-in and adopts the server's answer.

Setup (Railway env):
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON  service-account key JSON (raw or base64)
  GOOGLE_PLAY_PACKAGE_NAME          defaults to com.onchainoracleai.app
  BILLING_RTDN_TOKEN                shared secret appended to the Pub/Sub push URL (?token=)

Until the service account is configured every endpoint reports configured=false and the
app keeps its on-device behaviour, so this can ship before the Console setup is done.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Optional

import requests

logger = logging.getLogger("oco.billing")

PACKAGE_NAME = (os.getenv("GOOGLE_PLAY_PACKAGE_NAME") or "com.onchainoracleai.app").strip()
RTDN_TOKEN = (os.getenv("BILLING_RTDN_TOKEN") or "").strip()
_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
_SUBS_V2_URL = (
    "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
    "{package}/purchases/subscriptionsv2/tokens/{token}"
)

PRODUCT_PLANS: dict[str, str] = {
    "oracle_pro_monthly": "Expert",
    "expert_monthly": "Expert",
    "premium_monthly": "Premium",
}

# CANCELED = auto-renew turned off; access continues until expiryTime.
ENTITLED_STATES = {
    "SUBSCRIPTION_STATE_ACTIVE",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    "SUBSCRIPTION_STATE_CANCELED",
}

# Re-ask Google at most this often per user when the app polls entitlement.
_REFRESH_AFTER_SEC = 6 * 60 * 60


class BillingError(Exception):
    def __init__(self, message: str, *, status: Optional[int] = None, invalid_token: bool = False):
        super().__init__(message)
        self.status = status
        self.invalid_token = invalid_token


# ─── Credentials ──────────────────────────────────────────────────────────────

_CRED_LOCK = threading.Lock()
_credentials: Any = None


def _service_account_info() -> Optional[dict[str, Any]]:
    raw = (os.getenv("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON") or "").strip()
    if not raw:
        return None
    if not raw.startswith("{"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except Exception:
            logger.error("billing_service_account_invalid_base64")
            return None
    try:
        info = json.loads(raw)
    except json.JSONDecodeError:
        logger.error("billing_service_account_invalid_json")
        return None
    return info if isinstance(info, dict) and info.get("private_key") else None


def is_configured() -> bool:
    return _service_account_info() is not None


def _access_token() -> str:
    global _credentials
    from google.auth.transport.requests import Request as GoogleAuthRequest
    from google.oauth2 import service_account

    with _CRED_LOCK:
        if _credentials is None:
            info = _service_account_info()
            if info is None:
                raise BillingError("Google Play service account is not configured.")
            _credentials = service_account.Credentials.from_service_account_info(info, scopes=[_SCOPE])
        if not _credentials.valid:
            _credentials.refresh(GoogleAuthRequest())
        return _credentials.token


def fetch_subscription(purchase_token: str) -> dict[str, Any]:
    """purchases.subscriptionsv2.get — raises BillingError on failure."""
    url = _SUBS_V2_URL.format(package=PACKAGE_NAME, token=purchase_token)
    try:
        response = requests.get(
            url,
            headers={"Authorization": f"Bearer {_access_token()}"},
            timeout=15,
        )
    except BillingError:
        raise
    except Exception as exc:
        raise BillingError(f"Google Play request failed: {exc}") from exc
    if response.status_code in (400, 404, 410):
        raise BillingError(
            f"Google Play rejected the purchase token (HTTP {response.status_code}).",
            status=response.status_code,
            invalid_token=True,
        )
    if response.status_code != 200:
        raise BillingError(
            f"Google Play API error HTTP {response.status_code}: {response.text[:300]}",
            status=response.status_code,
        )
    body = response.json()
    if not isinstance(body, dict):
        raise BillingError("Google Play API returned an unexpected body.")
    return body


# ─── Pure entitlement logic (unit-tested) ─────────────────────────────────────


def _iso_to_ms(value: Any) -> Optional[int]:
    if not value:
        return None
    from datetime import datetime

    text = str(value).strip().replace("Z", "+00:00")
    # Google returns nanosecond precision on some fields; trim to microseconds.
    if "." in text:
        head, _, tail = text.partition(".")
        frac = "".join(ch for ch in tail if ch.isdigit())
        tz = tail[len(frac):]
        text = f"{head}.{frac[:6]}{tz}"
    try:
        return int(datetime.fromisoformat(text).timestamp() * 1000)
    except ValueError:
        return None


def entitlement_from_subscription(sub: dict[str, Any], *, now_ms: Optional[int] = None) -> dict[str, Any]:
    """Collapse a subscriptionsv2 resource into {active, plan, product_id, expires_at_ms, state}."""
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    state = str(sub.get("subscriptionState") or "")
    best_plan: Optional[str] = None
    best_product: Optional[str] = None
    best_expiry: Optional[int] = None
    for item in sub.get("lineItems") or []:
        if not isinstance(item, dict):
            continue
        product_id = str(item.get("productId") or "")
        plan = PRODUCT_PLANS.get(product_id)
        if plan is None:
            continue
        expiry = _iso_to_ms(item.get("expiryTime"))
        if best_expiry is None or (expiry or 0) > best_expiry:
            best_plan, best_product, best_expiry = plan, product_id, expiry
    active = (
        state in ENTITLED_STATES
        and best_plan is not None
        and best_expiry is not None
        and best_expiry > now_ms
    )
    return {
        "active": active,
        "plan": best_plan if active else None,
        "product_id": best_product,
        "expires_at_ms": best_expiry,
        "state": state,
        "linked_purchase_token": sub.get("linkedPurchaseToken"),
    }


# ─── Store ───────────────────────────────────────────────────────────────────


def _token_key(purchase_token: str) -> str:
    return hashlib.sha256(purchase_token.encode("utf-8")).hexdigest()


class EntitlementStore:
    """users: user_id → entitlement record; tokens: sha256(token) → user_id (one owner per token)."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()

    def _load(self) -> dict[str, Any]:
        if not self.path.is_file():
            return {"users": {}, "tokens": {}}
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.error("billing_store_read_failed path=%s err=%s", self.path, exc)
            return {"users": {}, "tokens": {}}
        if not isinstance(raw, dict):
            return {"users": {}, "tokens": {}}
        raw.setdefault("users", {})
        raw.setdefault("tokens", {})
        return raw

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(self.path)

    def get(self, user_id: str) -> Optional[dict[str, Any]]:
        with self._lock:
            record = self._load()["users"].get(user_id)
            return dict(record) if isinstance(record, dict) else None

    def owner_of(self, purchase_token: str) -> Optional[str]:
        with self._lock:
            return self._load()["tokens"].get(_token_key(purchase_token))

    def put(self, user_id: str, purchase_token: str, entitlement: dict[str, Any]) -> None:
        """Bind token → user_id. A token moving to a new user revokes it from the previous one."""
        with self._lock:
            data = self._load()
            key = _token_key(purchase_token)
            previous = data["tokens"].get(key)
            if previous and previous != user_id:
                prev_record = data["users"].get(previous)
                if isinstance(prev_record, dict) and prev_record.get("token_key") == key:
                    data["users"].pop(previous, None)
                logger.info("billing_token_rebound from=%s to=%s", previous, user_id)
            linked = entitlement.get("linked_purchase_token")
            if linked:
                data["tokens"].pop(_token_key(str(linked)), None)
            data["tokens"][key] = user_id
            data["users"][user_id] = {
                "purchase_token": purchase_token,
                "token_key": key,
                "active": bool(entitlement.get("active")),
                "plan": entitlement.get("plan"),
                "product_id": entitlement.get("product_id"),
                "expires_at_ms": entitlement.get("expires_at_ms"),
                "state": entitlement.get("state"),
                "checked_at": int(time.time()),
            }
            self._save(data)


# ─── Service facade ──────────────────────────────────────────────────────────


def public_view(record: Optional[dict[str, Any]], *, now_ms: Optional[int] = None) -> dict[str, Any]:
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    if not record:
        return {"active": False, "plan": None, "product_id": None, "expires_at_ms": None, "state": None}
    expires = record.get("expires_at_ms")
    active = bool(record.get("active")) and isinstance(expires, (int, float)) and expires > now_ms
    return {
        "active": active,
        "plan": record.get("plan") if active else None,
        "product_id": record.get("product_id"),
        "expires_at_ms": expires,
        "state": record.get("state"),
    }


def verify_and_store(store: EntitlementStore, user_id: str, purchase_token: str) -> dict[str, Any]:
    sub = fetch_subscription(purchase_token)
    entitlement = entitlement_from_subscription(sub)
    store.put(user_id, purchase_token, entitlement)
    logger.info(
        "billing_verified user_id=%s product=%s active=%s state=%s",
        user_id,
        entitlement.get("product_id"),
        entitlement.get("active"),
        entitlement.get("state"),
    )
    return public_view(store.get(user_id))


def current_entitlement(store: EntitlementStore, user_id: str) -> dict[str, Any]:
    """Stored entitlement, re-checked with Google when stale or past expiry."""
    record = store.get(user_id)
    if record and is_configured():
        stale = int(time.time()) - int(record.get("checked_at") or 0) > _REFRESH_AFTER_SEC
        expired = (record.get("expires_at_ms") or 0) <= int(time.time() * 1000)
        if stale or expired:
            try:
                return verify_and_store(store, user_id, str(record["purchase_token"]))
            except BillingError as exc:
                logger.warning("billing_refresh_failed user_id=%s err=%s", user_id, exc)
                if exc.invalid_token:
                    store.put(user_id, str(record["purchase_token"]), {"active": False, "state": "INVALID"})
                    return public_view(store.get(user_id))
    return public_view(record)


def handle_rtdn(store: EntitlementStore, envelope: dict[str, Any]) -> dict[str, Any]:
    """Pub/Sub push body → re-verify the token for whichever user owns it."""
    message = envelope.get("message") if isinstance(envelope, dict) else None
    data_b64 = (message or {}).get("data") if isinstance(message, dict) else None
    if not data_b64:
        return {"handled": False, "reason": "no_data"}
    try:
        payload = json.loads(base64.b64decode(data_b64).decode("utf-8"))
    except Exception:
        return {"handled": False, "reason": "bad_payload"}
    if payload.get("testNotification"):
        logger.info("billing_rtdn_test_notification")
        return {"handled": True, "test": True}
    note = payload.get("subscriptionNotification")
    if not isinstance(note, dict):
        return {"handled": False, "reason": "not_subscription"}
    token = str(note.get("purchaseToken") or "")
    owner = store.owner_of(token) if token else None
    if not owner:
        # Purchase not yet verified by the app — it will be when the app reports it.
        logger.info("billing_rtdn_unknown_token type=%s", note.get("notificationType"))
        return {"handled": False, "reason": "unknown_token"}
    view = verify_and_store(store, owner, token)
    logger.info(
        "billing_rtdn_applied user_id=%s type=%s active=%s",
        owner,
        note.get("notificationType"),
        view.get("active"),
    )
    return {"handled": True, "user_id": owner, "active": view.get("active")}
