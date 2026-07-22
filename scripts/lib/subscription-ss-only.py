#!/usr/bin/env python3
"""Limit subscription to Shadowsocks only (fix Happ EOF from vmess/vless parse errors)."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (name,),
    ).fetchone()
    return row is not None


def ss_only_client_inbounds(conn: sqlite3.Connection, ss_port: int) -> dict:
    row = conn.execute(
        "SELECT id FROM inbounds WHERE port=? AND enable=1 LIMIT 1",
        (ss_port,),
    ).fetchone()
    if not row:
        return {"error": f"No enabled SS inbound on port {ss_port}"}
    ss_inbound_id = int(row[0])

    if not table_exists(conn, "client_inbounds"):
        return {"skipped": "no client_inbounds table"}

    before = conn.execute("SELECT COUNT(*) FROM client_inbounds").fetchone()[0]
    cur = conn.execute(
        "DELETE FROM client_inbounds WHERE inbound_id != ?",
        (ss_inbound_id,),
    )
    after = conn.execute("SELECT COUNT(*) FROM client_inbounds").fetchone()[0]
    return {
        "ss_inbound_id": ss_inbound_id,
        "links_before": before,
        "links_after": after,
        "removed": cur.rowcount,
    }


def clear_subscription_routing_settings(conn: sqlite3.Connection) -> list[str]:
    cleared: list[str] = []
    for key in (
        "subJsonRules",
        "subRules",
        "subRoutingRules",
        "routingRules",
    ):
        row = conn.execute(
            "SELECT value FROM settings WHERE key=? LIMIT 1", (key,)
        ).fetchone()
        if row and row[0] and row[0] not in ("", "[]", "{}"):
            conn.execute("UPDATE settings SET value='' WHERE key=?", (key,))
            cleared.append(key)
    return cleared


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} DB [SS_PORT]", file=sys.stderr)
        return 2

    db_path = Path(sys.argv[1])
    ss_port = int(sys.argv[2]) if len(sys.argv) > 2 else 8388

    conn = sqlite3.connect(str(db_path))
    try:
        result = ss_only_client_inbounds(conn, ss_port)
        result["routing_cleared"] = clear_subscription_routing_settings(conn)
        conn.commit()
        print(json.dumps(result, ensure_ascii=False))
        return 0 if "error" not in result else 1
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
