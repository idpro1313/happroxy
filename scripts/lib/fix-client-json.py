#!/usr/bin/env python3
"""Fix client JSON fields that break 3X-UI panel (tgId must be int64, not string)."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path


def normalize_tg_id(value) -> int:
    if value is None or value == "":
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return 0
        try:
            return int(text)
        except ValueError:
            return 0
    return 0


def normalize_client_dict(client: dict) -> bool:
    changed = False
    if "tgId" not in client or not isinstance(client.get("tgId"), int):
        client["tgId"] = normalize_tg_id(client.get("tgId"))
        changed = True
    if "limitIp" in client and not isinstance(client["limitIp"], int):
        try:
            client["limitIp"] = int(client["limitIp"])
            changed = True
        except (TypeError, ValueError):
            client["limitIp"] = 3
            changed = True
    if "totalGB" in client and isinstance(client["totalGB"], str):
        try:
            client["totalGB"] = int(client["totalGB"])
            changed = True
        except ValueError:
            client["totalGB"] = 0
            changed = True
    return changed


def fix_inbounds_settings(conn: sqlite3.Connection) -> int:
    fixed = 0
    rows = conn.execute("SELECT id, settings FROM inbounds").fetchall()
    for inbound_id, settings_raw in rows:
        if not settings_raw:
            continue
        try:
            settings = json.loads(settings_raw)
        except json.JSONDecodeError:
            continue
        clients = settings.get("clients") or []
        if not clients:
            continue
        changed = False
        for client in clients:
            if isinstance(client, dict) and normalize_client_dict(client):
                changed = True
        if changed:
            conn.execute(
                "UPDATE inbounds SET settings=? WHERE id=?",
                (json.dumps(settings, ensure_ascii=False), inbound_id),
            )
            fixed += 1
    return fixed


def fix_clients_table(conn: sqlite3.Connection) -> int:
    if not conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='clients' LIMIT 1"
    ).fetchone():
        return 0
    fixed = 0
    rows = conn.execute("SELECT id, tg_id FROM clients").fetchall()
    for client_id, tg_id in rows:
        norm = normalize_tg_id(tg_id)
        if tg_id != norm:
            conn.execute("UPDATE clients SET tg_id=? WHERE id=?", (norm, client_id))
            fixed += 1
    return fixed


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} DB_PATH", file=sys.stderr)
        return 2

    db_path = Path(sys.argv[1])
    if not db_path.is_file():
        print(f"Database not found: {db_path}", file=sys.stderr)
        return 1

    conn = sqlite3.connect(str(db_path))
    try:
        inbounds_fixed = fix_inbounds_settings(conn)
        clients_fixed = fix_clients_table(conn)
        conn.commit()
        print(
            json.dumps(
                {
                    "inbounds_fixed": inbounds_fixed,
                    "clients_fixed": clients_fixed,
                }
            )
        )
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
