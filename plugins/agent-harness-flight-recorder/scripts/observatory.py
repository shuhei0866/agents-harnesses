#!/usr/bin/env python3
"""Read-only, loopback-only Flight Recorder observatory."""

from __future__ import annotations

import json
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Callable

from chunk_rotation import canonical_json
from evidence_index import read_sealed_query_locked
from index_freshness import status as index_freshness_status
from index_storage import index_storage_snapshot as _index_storage_snapshot
from receipt_automation import status as receipt_automation_status
from reporting import DEFAULT_POLICY_VERSION, _episode_card, _inbox_count
from retention_state import load_forgotten
from semantic_receipts import _stored_receipts
from value_compiler import (
    _stored_records as _stored_value_records,
    authenticate_value_primitive_cards,
)
from vault import VaultError, vault_lock


HOST = "127.0.0.1"
MAX_RESPONSE_BYTES = 64 * 1024
MAX_INDEX_EVENTS = 1_000_000
MAX_INDEX_EPISODES = 500_000
MAX_EVIDENCE_BINDINGS = 2_000_000
MAX_LOCAL_RECORDS = 10_000
MAX_LOCAL_RECORD_BYTES = 256 * 1024 * 1024
MAX_INBOX_BYTES = 256 * 1024 * 1024
MAX_CURRENT_VALUE_EPISODES = 100
QUERY_DEADLINE_SECONDS = 2
AUTOMATION_FIELDS = (
    "schema_version",
    "state",
    "enabled",
    "discovered",
    "matched",
    "ambiguous",
    "missing",
    "active",
    "queued",
    "generated",
    "failed",
    "measured_cost_microusd",
    "diagnostic_code",
    "attempt_count",
)


def _basis_points(numerator: int, denominator: int) -> int:
    return numerator * 10_000 // denominator if denominator else 0


def _bounded_local_records(
    root: Path,
    directory_name: str,
    reader: Callable[[Path], list[tuple[Path, bytes, dict[str, Any]]]],
    label: str,
) -> list[tuple[Path, bytes, dict[str, Any]]]:
    """Preflight owner-local stores before invoking their strict readers."""
    directory = root / directory_name
    if directory.exists() and not directory.is_symlink() and directory.is_dir():
        count = 0
        total_bytes = 0
        try:
            for path in directory.iterdir():
                count += 1
                if count > MAX_LOCAL_RECORDS:
                    raise VaultError(f"{label} storage exceeds observatory limits")
                total_bytes += path.lstat().st_size
                if total_bytes > MAX_LOCAL_RECORD_BYTES:
                    raise VaultError(f"{label} storage exceeds observatory limits")
        except VaultError:
            raise
        except OSError as error:
            raise VaultError(f"{label} storage is unsafe") from error
    return reader(root)


def _bounded_inbox_count(root: Path) -> int:
    path = root / "inbox/events.jsonl"
    try:
        if path.exists() and not path.is_symlink():
            if path.lstat().st_size > MAX_INBOX_BYTES:
                raise VaultError("event inbox exceeds observatory limits")
    except VaultError:
        raise
    except OSError as error:
        raise VaultError("event inbox is unsafe") from error
    return _inbox_count(root)


def _bound_record_count(
    records: list[tuple[Path, bytes, dict[str, Any]]],
    bindings: dict[str, dict[str, Any]] | None,
    *,
    require_evidence: bool,
) -> int:
    # Fixtures for the projection-only schema have no binding tables. A real
    # Evidence Index v4 always has them and therefore takes the authenticated
    # branch below.
    if bindings is None:
        return len(records)
    count = 0
    for _path, _raw, record in records:
        provenance = record.get("provenance")
        binding = bindings.get(record.get("episode_id"))
        if (
            not isinstance(provenance, dict)
            or binding is None
            or provenance.get("policy_version") != DEFAULT_POLICY_VERSION
            or provenance.get("source_event_ids")
            != binding["source_event_ids"]
        ):
            continue
        if require_evidence and not set(provenance.get("evidence_ids", [])).issubset(
            binding["evidence_ids"]
        ):
            continue
        count += 1
    return count


def _current_value_card_count(
    root: Path,
    records: list[tuple[Path, bytes, dict[str, Any]]],
    current_cards: dict[str, dict[str, Any]] | None,
) -> int:
    if current_cards is None:
        return len(records)
    count = 0
    for episode_id, card in current_cards.items():
        count += len(
            authenticate_value_primitive_cards(
                root,
                DEFAULT_POLICY_VERSION,
                episode_id,
                card,
                records,
            )
        )
    return count


def overview(root: Path) -> dict[str, Any]:
    """Return the fixed, privacy-safe observatory projection."""
    root = Path(root)
    pending_events = _bounded_inbox_count(root)
    refresh = index_freshness_status(root)
    automation_source = receipt_automation_status(root)
    automation = {
        field: automation_source[field] for field in AUTOMATION_FIELDS
    }
    if refresh["state"] != "ready":
        return {
            "schema_version": 2,
            "command": "observatory.overview",
            "index_refresh": refresh,
            "recording": {
                "state": refresh["state"],
                "index_schema_version": None,
                "events": None,
                "pending_events": pending_events,
            },
            "episode_formation": {
                "episodes": None,
                "singleton_episodes": None,
                "singleton_basis_points": None,
            },
            "comparison_readiness": {
                "comparable_episodes": None,
                "comparable_basis_points": None,
            },
            "semantic_coverage": {
                "semantic_receipts": None,
                "value_cards": None,
            },
            "index_storage": None,
            "receipt_automation": automation,
        }
    receipts = _bounded_local_records(
        root,
        "semantic-receipts",
        _stored_receipts,
        "Semantic Receipt",
    )
    values = _bounded_local_records(
        root,
        "value-primitive-cards",
        _stored_value_records,
        "Value Primitive Card",
    )
    value_episode_ids = sorted(
        {
            value["episode_id"]
            for _path, _raw, value in values
            if value["provenance"]["policy_version"]
            == DEFAULT_POLICY_VERSION
        }
    )
    if len(value_episode_ids) > MAX_CURRENT_VALUE_EPISODES:
        raise VaultError("Value Card coverage exceeds observatory limits")
    with vault_lock(root):
        forgotten = sorted(
            episode_id
            for policy_version, episode_id in load_forgotten(root)
            if policy_version == DEFAULT_POLICY_VERSION
        )
        forgotten_json = json.dumps(
            forgotten, ensure_ascii=False, separators=(",", ":")
        )

        def query(connection: Any, _policy: dict[str, Any]) -> dict[str, Any]:
            deadline = time.monotonic() + QUERY_DEADLINE_SECONDS
            connection.set_progress_handler(
                lambda: int(time.monotonic() >= deadline), 10_000
            )
            try:
                index_schema_version = int(
                    connection.execute("PRAGMA user_version").fetchone()[0]
                )
                row = connection.execute(
                    """
                    WITH visible AS (
                        SELECT episode_id, member_count
                        FROM episodes
                        WHERE policy_version = ?
                          AND episode_id NOT IN (
                              SELECT value FROM json_each(?)
                          )
                    )
                    SELECT
                        (SELECT COUNT(*) FROM source_events),
                        (SELECT COUNT(*) FROM visible),
                        (SELECT COUNT(*) FROM visible WHERE member_count = 1),
                        (
                            SELECT COUNT(*)
                            FROM visible AS v
                            JOIN session_atlas_facets AS f
                              ON f.policy_version = ?
                             AND f.episode_id = v.episode_id
                            WHERE f.event_lifecycle_state != 'unknown'
                              AND f.operation_state != 'unknown'
                              AND f.artifact_change_state != 'unknown'
                        )
                    """,
                    (
                        DEFAULT_POLICY_VERSION,
                        forgotten_json,
                        DEFAULT_POLICY_VERSION,
                    ),
                ).fetchone()
                if row is None:
                    raise VaultError("observatory projection is unavailable")
                events, episodes, singleton_episodes, comparable_episodes = (
                    int(value) for value in row
                )
                if events > MAX_INDEX_EVENTS or episodes > MAX_INDEX_EPISODES:
                    raise VaultError("observatory index exceeds read limits")
                try:
                    storage = _index_storage_snapshot(connection)
                except VaultError:
                    if index_schema_version >= 5:
                        raise
                    storage = None

                tables = {
                    item[0]
                    for item in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table' "
                        "AND name IN ('episode_members','deterministic_evidence')"
                    )
                }
                bindings: dict[str, dict[str, Any]] | None = None
                current_value_cards: dict[str, dict[str, Any]] | None = None
                if tables == {"episode_members", "deterministic_evidence"}:
                    member_rows = list(
                        connection.execute(
                            """
                            SELECT em.episode_id, em.event_id
                            FROM episode_members AS em
                            JOIN episodes AS ep
                              ON ep.policy_version = em.policy_version
                             AND ep.episode_id = em.episode_id
                            WHERE em.policy_version = ?
                              AND em.episode_id NOT IN (
                                  SELECT value FROM json_each(?)
                              )
                            ORDER BY em.episode_id, em.ordinal
                            LIMIT ?
                            """,
                            (
                                DEFAULT_POLICY_VERSION,
                                forgotten_json,
                                MAX_INDEX_EVENTS + 1,
                            ),
                        )
                    )
                    if len(member_rows) > MAX_INDEX_EVENTS:
                        raise VaultError("observatory bindings exceed read limits")
                    bindings = {}
                    for episode_id, event_id in member_rows:
                        binding = bindings.setdefault(
                            episode_id,
                            {"source_event_ids": [], "evidence_ids": set()},
                        )
                        binding["source_event_ids"].append(event_id)
                    evidence_rows = list(
                        connection.execute(
                            """
                            SELECT em.episode_id, de.evidence_id
                            FROM episode_members AS em
                            JOIN episodes AS ep
                              ON ep.policy_version = em.policy_version
                             AND ep.episode_id = em.episode_id
                            JOIN deterministic_evidence AS de
                              ON de.source_event_id = em.event_id
                            WHERE em.policy_version = ?
                              AND em.episode_id NOT IN (
                                  SELECT value FROM json_each(?)
                              )
                            ORDER BY em.episode_id, de.evidence_id
                            LIMIT ?
                            """,
                            (
                                DEFAULT_POLICY_VERSION,
                                forgotten_json,
                                MAX_EVIDENCE_BINDINGS + 1,
                            ),
                        )
                    )
                    if len(evidence_rows) > MAX_EVIDENCE_BINDINGS:
                        raise VaultError("observatory evidence exceeds read limits")
                    for episode_id, evidence_id in evidence_rows:
                        binding = bindings.get(episode_id)
                        if binding is not None:
                            binding["evidence_ids"].add(evidence_id)
                    current_value_cards = {}
                    for episode_id in value_episode_ids:
                        if episode_id not in bindings:
                            continue
                        card, _edges = _episode_card(
                            root,
                            connection,
                            _policy,
                            episode_id,
                            {},
                            include_model_evaluations=False,
                        )
                        current_value_cards[episode_id] = card
                return {
                    "index_schema_version": index_schema_version,
                    "events": events,
                    "episodes": episodes,
                    "singleton_episodes": singleton_episodes,
                    "comparable_episodes": comparable_episodes,
                    "bindings": bindings,
                    "current_value_cards": current_value_cards,
                    "index_storage": storage,
                }
            except sqlite3.Error as error:
                raise VaultError("observatory sealed query failed") from error
            finally:
                connection.set_progress_handler(None, 0)

        projection = read_sealed_query_locked(
            root, DEFAULT_POLICY_VERSION, query
        )

    index_schema_version = projection["index_schema_version"]
    events = projection["events"]
    episodes = projection["episodes"]
    singleton_episodes = projection["singleton_episodes"]
    comparable_episodes = projection["comparable_episodes"]
    bindings = projection["bindings"]
    semantic_receipts = _bound_record_count(
        receipts, bindings, require_evidence=True
    )
    value_cards = _current_value_card_count(
        root, values, projection["current_value_cards"]
    )

    return {
        "schema_version": 2,
        "command": "observatory.overview",
        "index_refresh": refresh,
        "recording": {
            "state": "ready",
            "index_schema_version": index_schema_version,
            "events": events,
            "pending_events": pending_events,
        },
        "episode_formation": {
            "episodes": episodes,
            "singleton_episodes": singleton_episodes,
            "singleton_basis_points": _basis_points(
                singleton_episodes, episodes
            ),
        },
        "comparison_readiness": {
            "comparable_episodes": comparable_episodes,
            "comparable_basis_points": _basis_points(
                comparable_episodes, episodes
            ),
        },
        "semantic_coverage": {
            "semantic_receipts": semantic_receipts,
            "value_cards": value_cards,
        },
        "index_storage": projection["index_storage"],
        "receipt_automation": automation,
    }


def _integer(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise VaultError("observatory overview is invalid")
    return value


def _number(value: Any) -> str:
    return f"{_integer(value):,}"


def _percent(basis_points: Any) -> str:
    return f"{_integer(basis_points) / 100:.2f}%"


def render_overview_html(value: dict[str, Any]) -> str:
    """Compress the fixed overview into the three owner-facing questions."""
    recording_value = value.get("recording")
    if isinstance(recording_value, dict) and recording_value.get("events") is None:
        state = recording_value.get("state")
        if state not in {"refresh_required", "refreshing", "error"}:
            raise VaultError("observatory overview is invalid")
        pending = _number(recording_value.get("pending_events"))
        return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Flight Recorder Observatory</title><style>:root{{color-scheme:dark;font-family:system-ui,sans-serif;background:#08111f;color:#edf4ff}}main{{max-width:760px;margin:12vh auto;padding:32px}}section{{padding:28px;border:1px solid #29415f;border-radius:20px;background:#12233a}}p{{color:#a9bad0;line-height:1.7}}</style></head><body><main><section><h1>Index refresh: {state}</h1><p>認証済みの更新が完了するまで、古い集計値は表示しません。次の更新を待つイベントは {pending} 件です。</p></section></main></body></html>"""
    try:
        recording = value["recording"]
        formation = value["episode_formation"]
        comparison = value["comparison_readiness"]
        semantic = value["semantic_coverage"]
        events = _number(recording["events"])
        pending = _number(recording["pending_events"])
        episodes = _number(formation["episodes"])
        singletons = _number(formation["singleton_episodes"])
        singleton_rate = _percent(formation["singleton_basis_points"])
        comparable = _number(comparison["comparable_episodes"])
        comparable_rate = _percent(comparison["comparable_basis_points"])
        receipts = _number(semantic["semantic_receipts"])
        cards = _number(semantic["value_cards"])
        storage = value.get("index_storage")
        storage_html = ""
        if storage is not None:
            storage_state = storage["state"]
            if storage_state not in {"ready", "attention", "critical"}:
                raise VaultError("observatory overview is invalid")
            total_gib = _integer(storage["total_bytes"]) / 1024**3
            relationship_gib = _integer(
                storage["components"]["relationship_bytes"]
            ) / 1024**3
            other_bytes = _integer(storage["components"]["other_bytes"])
            component_bytes = sum(
                _integer(storage["components"][name])
                for name in (
                    "source_bytes", "relationship_bytes", "projection_bytes"
                )
            )
            if component_bytes == 0 and other_bytes == _integer(
                storage["total_bytes"]
            ):
                breakdown_html = "Breakdown unavailable"
            else:
                breakdown_html = (
                    "Relationship "
                    f"<strong>{relationship_gib:.2f} GiB</strong>"
                )
            storage_html = (
                f'<aside class="storage {storage_state}">Index storage '
                f'<strong>{total_gib:.2f} GiB</strong> · {breakdown_html} · '
                f'{storage_state}</aside>'
            )
    except (KeyError, TypeError) as error:
        raise VaultError("observatory overview is invalid") from error

    # Values above are rendered only after strict integer validation. The
    # renderer deliberately ignores every unknown field in its input.
    document = f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Flight Recorder Observatory</title>
<style>
:root {{ color-scheme: dark; font-family: ui-sans-serif, system-ui, sans-serif; background: #08111f; color: #edf4ff; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; min-height: 100vh; background: radial-gradient(circle at 20% 0%, #153052 0, #08111f 42%); }}
main {{ width: min(1120px, calc(100% - 32px)); margin: 0 auto; padding: 56px 0 72px; }}
.eyebrow {{ color: #79d6c7; font-size: 12px; font-weight: 800; letter-spacing: .18em; text-transform: uppercase; }}
h1 {{ margin: 10px 0 8px; font-size: clamp(32px, 5vw, 58px); letter-spacing: -.04em; }}
.lead {{ margin: 0; max-width: 720px; color: #9eb1ca; line-height: 1.7; }}
.flow {{ display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; margin: 40px 0; }}
.step {{ min-width: 0; padding: 16px; border: 1px solid #29415f; border-radius: 14px; background: #0e1b2dcc; }}
.step strong {{ display: block; font-size: clamp(19px, 2.5vw, 28px); }}
.step span {{ color: #91a6c0; font-size: 12px; }}
.questions {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }}
.card {{ min-height: 250px; padding: 24px; border: 1px solid #29415f; border-radius: 20px; background: linear-gradient(145deg, #12233a, #0b1728); box-shadow: 0 18px 50px #0005; }}
.card h2 {{ margin: 0 0 24px; font-size: 18px; }}
.metric {{ margin: 0 0 4px; font-size: clamp(34px, 4vw, 48px); font-weight: 850; letter-spacing: -.04em; }}
.caption {{ color: #9eb1ca; font-size: 13px; line-height: 1.6; }}
.warning {{ color: #ffbd70; }}
.good {{ color: #79d6c7; }}
.detail {{ margin-top: 24px; padding-top: 18px; border-top: 1px solid #29415f; color: #c7d4e6; font-size: 14px; line-height: 1.7; }}
.storage {{ margin: 0 0 24px; padding: 14px 18px; border: 1px solid #29415f; border-radius: 12px; color: #c7d4e6; }}
.storage.attention, .storage.critical {{ border-color: #ffbd70; color: #ffcf96; }}
footer {{ margin-top: 28px; color: #6f86a3; font-size: 12px; }}
@media (max-width: 780px) {{ .flow {{ grid-template-columns: 1fr 1fr; }} .questions {{ grid-template-columns: 1fr; }} }}
</style>
</head>
<body>
<main>
  <div class="eyebrow">Flight Recorder Observatory</div>
  <h1>仕事の記録は、価値まで届いているか。</h1>
  <p class="lead">大量のログを読む代わりに、今のデータがどこまで意味のある仕事単位と比較材料になったかを3つの問いで観測します。</p>
  <section class="flow" aria-label="データの流れ">
    <div class="step"><strong>{events}</strong><span>Events</span></div>
    <div class="step"><strong>{episodes}</strong><span>Episodes</span></div>
    <div class="step"><strong>{comparable}</strong><span>Comparable</span></div>
    <div class="step"><strong>{receipts}</strong><span>Semantic Receipts</span></div>
    <div class="step"><strong>{cards}</strong><span>Value Cards</span></div>
  </section>
  {storage_html}
  <section class="questions">
    <article class="card">
      <h2>1. 記録できているか</h2>
      <p class="metric good">{events}</p>
      <p class="caption">sealed index に入ったイベント</p>
      <p class="detail">次の反映を待つイベントは <strong>{pending}</strong> 件です。</p>
    </article>
    <article class="card">
      <h2>2. 仕事単位になっているか</h2>
      <p class="metric warning">{singleton_rate}</p>
      <p class="caption">1イベントだけで終わっている Episode の割合</p>
      <p class="detail"><strong>{singletons}</strong> / {episodes} Episodes。ここが高いほど、仕事のまとまりを復元する余地があります。</p>
    </article>
    <article class="card">
      <h2>3. 価値比較できるか</h2>
      <p class="metric">{comparable_rate}</p>
      <p class="caption">構造的な比較条件が揃った Episode の割合</p>
      <p class="detail"><strong>{comparable}</strong> Episodes、Semantic Receipt <strong>{receipts}</strong> 件、Value Card <strong>{cards}</strong> 件です。</p>
    </article>
  </section>
  <footer>Local only · Read only · Raw session content is never served</footer>
</main>
</body>
</html>"""
    if len(document.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise VaultError("observatory HTML exceeds its size limit")
    return document


def _json_body(value: Any) -> bytes:
    body = canonical_json(value) + b"\n"
    if len(body) > MAX_RESPONSE_BYTES:
        raise VaultError("observatory JSON exceeds its size limit")
    return body


class _ObservatoryServer(HTTPServer):
    allow_reuse_address = False

    def get_request(self) -> tuple[Any, Any]:
        request, address = super().get_request()
        request.settimeout(3)
        return request, address


def create_server(
    root: Path,
    port: int,
    overview_loader: Callable[[Path], dict[str, Any]] = overview,
) -> HTTPServer:
    """Create a single-threaded HTTP server bound to IPv4 loopback."""
    if isinstance(port, bool) or not isinstance(port, int):
        raise TypeError("observatory port must be an integer")
    if not 0 <= port <= 65535:
        raise ValueError("observatory port must be between 0 and 65535")
    root = Path(root)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "FlightRecorderObservatory/1"
        sys_version = ""

        def log_message(self, _format: str, *args: Any) -> None:
            return

        def _host_is_allowed(self) -> bool:
            values = self.headers.get_all("Host", failobj=[])
            if len(values) != 1:
                return False
            host = values[0].strip().lower()
            current_port = self.server.server_port
            return host in {
                HOST,
                "localhost",
                f"{HOST}:{current_port}",
                f"localhost:{current_port}",
            }

        def _browser_request_is_allowed(self) -> bool:
            values = self.headers.get_all("Sec-Fetch-Site", failobj=[])
            if not values:
                return True
            return len(values) == 1 and values[0].strip().lower() in {
                "none",
                "same-origin",
            }

        def _respond(
            self,
            status: int,
            body: bytes,
            content_type: str,
            *,
            allow: str | None = None,
        ) -> None:
            self.close_connection = True
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; style-src 'unsafe-inline'; "
                "frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
            )
            self.send_header("Connection", "close")
            if allow is not None:
                self.send_header("Allow", allow)
            self.end_headers()
            if getattr(self, "command", None) != "HEAD":
                self.wfile.write(body)

        def send_error(
            self,
            code: int,
            message: str | None = None,
            explain: str | None = None,
        ) -> None:
            del message, explain
            # Parser failures can occur before BaseHTTPRequestHandler records
            # the request version. Always emit the fixed HTTP/1.1 envelope.
            self.request_version = "HTTP/1.1"
            if code == 501:
                self._method_not_allowed()
            elif 400 <= code < 500:
                self._respond(
                    400,
                    b"Bad Request\n",
                    "text/plain; charset=utf-8",
                )
            else:
                self._respond(
                    500,
                    b"Observatory unavailable\n",
                    "text/plain; charset=utf-8",
                )

        def _route(self) -> None:
            if not self.path.startswith("/"):
                self._respond(400, b"Bad Request\n", "text/plain; charset=utf-8")
                return
            if not self._host_is_allowed():
                self._respond(421, b"Misdirected Request\n", "text/plain; charset=utf-8")
                return
            if not self._browser_request_is_allowed():
                self._respond(403, b"Forbidden\n", "text/plain; charset=utf-8")
                return
            if self.path == "/healthz":
                self._respond(
                    200,
                    _json_body({"status": "ok"}),
                    "application/json; charset=utf-8",
                )
                return
            if self.path not in {"/", "/api/v1/overview"}:
                self._respond(404, b"Not Found\n", "text/plain; charset=utf-8")
                return
            try:
                value = overview_loader(root)
                if self.path == "/":
                    body = render_overview_html(value).encode("utf-8")
                    content_type = "text/html; charset=utf-8"
                else:
                    body = _json_body(value)
                    content_type = "application/json; charset=utf-8"
            except Exception:
                self._respond(
                    500,
                    b"Observatory unavailable\n",
                    "text/plain; charset=utf-8",
                )
                return
            self._respond(200, body, content_type)

        def do_GET(self) -> None:
            self._route()

        def do_HEAD(self) -> None:
            self._route()

        def _method_not_allowed(self) -> None:
            self._respond(
                405,
                b"Method Not Allowed\n",
                "text/plain; charset=utf-8",
                allow="GET, HEAD",
            )

        do_POST = _method_not_allowed
        do_PUT = _method_not_allowed
        do_DELETE = _method_not_allowed
        do_OPTIONS = _method_not_allowed
        do_PATCH = _method_not_allowed
        do_TRACE = _method_not_allowed
        do_CONNECT = _method_not_allowed

    try:
        server = _ObservatoryServer((HOST, port), Handler)
    except OSError as error:
        raise VaultError("observatory server could not bind to loopback") from error
    server.timeout = 3
    return server


def serve(root: Path, port: int, *, startup_as_json: bool = False) -> None:
    """Serve until interrupted, always closing the listening socket."""
    server = create_server(root, port)
    selected_port = server.server_address[1]
    url = f"http://{HOST}:{selected_port}/"
    if startup_as_json:
        startup = {
            "schema_version": 1,
            "command": "observatory.serve",
            "url": url,
        }
        print(canonical_json(startup).decode("utf-8"), flush=True)
    else:
        print(f"Flight Recorder Observatory: {url}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
