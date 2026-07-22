#!/usr/bin/env python3
"""Restore Phase 1: disable VLESS, re-link clients to SS + VMess in client_inbounds."""
from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (name,),
    ).fetchone()
    return row is not None


def inbound_id(conn: sqlite3.Connection, port: int) -> int | None:
    row = conn.execute(
        "SELECT id FROM inbounds WHERE port=? LIMIT 1",
        (port,),
    ).fetchone()
    return int(row[0]) if row else None


def disable_vless(conn: sqlite3.Connection) -> dict:
    rows = conn.execute(
        "SELECT id FROM inbounds WHERE protocol='vless' OR remark='vless-reality'"
    ).fetchall()
    ids = [int(r[0]) for r in rows]
    if not ids:
        return {"vless_inbounds": 0, "links_removed": 0}
    conn.execute(
        f"UPDATE inbounds SET enable=0 WHERE id IN ({','.join('?' * len(ids))})",
        ids,
    )
    removed = 0
    if table_exists(conn, "client_inbounds"):
        removed = conn.execute(
            f"DELETE FROM client_inbounds WHERE inbound_id IN ({','.join('?' * len(ids))})",
            ids,
        ).rowcount
    return {"vless_inbounds": len(ids), "links_removed": removed}


def enable_legacy_inbounds(conn: sqlite3.Connection, ss_port: int, vmess_port: int) -> dict:
    out = {}
    for port, name in ((ss_port, "ss"), (vmess_port, "vmess")):
        iid = inbound_id(conn, port)
        if iid is None:
            out[name] = "missing"
            continue
        conn.execute("UPDATE inbounds SET enable=1 WHERE id=?", (iid,))
        out[name] = iid
    return out


def link_client(conn: sqlite3.Connection, client_pk: int, inbound_id: int, flow: str = "") -> bool:
    if not table_exists(conn, "client_inbounds"):
        return False
    exists = conn.execute(
        "SELECT 1 FROM client_inbounds WHERE client_id=? AND inbound_id=? LIMIT 1",
        (client_pk, inbound_id),
    ).fetchone()
    if exists:
        return False
    now = int(time.time() * 1000)
    conn.execute(
        """
        INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
        VALUES (?, ?, ?, ?)
        """,
        (client_pk, inbound_id, flow, now),
    )
    return True


def restore_client_links(conn: sqlite3.Connection, ss_port: int, vmess_port: int) -> dict:
    ss_id = inbound_id(conn, ss_port)
    vmess_id = inbound_id(conn, vmess_port)
    if not table_exists(conn, "clients") or not table_exists(conn, "client_inbounds"):
        return {"error": "clients or client_inbounds table missing"}

    clients = conn.execute(
        """
        SELECT id, email, sub_id FROM clients
        WHERE enable=1 AND sub_id IS NOT NULL AND sub_id != ''
        ORDER BY id
        """
    ).fetchall()

    linked_ss = linked_vmess = 0
    for client_pk, email, sub_id in clients:
        if ss_id is not None and link_client(conn, int(client_pk), ss_id):
            linked_ss += 1
        if vmess_id is not None and link_client(conn, int(client_pk), vmess_id):
            linked_vmess += 1

    return {
        "clients": len(clients),
        "linked_ss": linked_ss,
        "linked_vmess": linked_vmess,
        "ss_inbound_id": ss_id,
        "vmess_inbound_id": vmess_id,
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} DB [SS_PORT] [VMESS_PORT]", file=sys.stderr)
        return 2

    db_path = Path(sys.argv[1])
    ss_port = int(sys.argv[2]) if len(sys.argv) > 2 else 8388
    vmess_port = int(sys.argv[3]) if len(sys.argv) > 3 else 16888

    conn = sqlite3.connect(str(db_path))
    try:
        result = {
            "vless": disable_vless(conn),
            "inbounds": enable_legacy_inbounds(conn, ss_port, vmess_port),
            "clients": restore_client_links(conn, ss_port, vmess_port),
        }
        conn.commit()
        print(json.dumps(result, ensure_ascii=False))
        if result["clients"].get("error"):
            return 1
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
