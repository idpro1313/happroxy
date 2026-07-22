#!/usr/bin/env python3
"""Create or update VLESS Reality inbound in 3X-UI SQLite database."""
from __future__ import annotations

import json
import sqlite3
import sys
import time
import uuid
from pathlib import Path


def load_template(path: Path, values: dict) -> dict:
    text = path.read_text(encoding="utf-8")
    for key, val in values.items():
        text = text.replace("{{" + key + "}}", str(val))
    return json.loads(text)


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (name,),
    ).fetchone()
    return row is not None


def collect_clients_from_json(conn: sqlite3.Connection) -> list[dict]:
    seen: dict[str, dict] = {}
    rows = conn.execute(
        "SELECT settings, protocol, remark FROM inbounds WHERE enable=1"
    ).fetchall()
    for settings_raw, protocol, remark in rows:
        if protocol == "vless" or remark == "vless-reality":
            continue
        if not settings_raw:
            continue
        try:
            settings = json.loads(settings_raw)
        except json.JSONDecodeError:
            continue
        for client in settings.get("clients") or []:
            if not client.get("enable", True):
                continue
            sub_id = client.get("subId") or client.get("id") or ""
            email = client.get("email") or ""
            key = sub_id or email
            if not key:
                continue
            if key not in seen:
                seen[key] = client
    return list(seen.values())


def load_client_records(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """Clients linked to legacy inbounds (3X-UI subscription uses clients + client_inbounds)."""
    if not table_exists(conn, "clients") or not table_exists(conn, "client_inbounds"):
        return []
    return conn.execute(
        """
        SELECT DISTINCT
          c.id AS client_pk,
          c.email,
          c.sub_id,
          c.uuid,
          c.limit_ip,
          c.total_gb,
          c.expiry_time,
          c.enable,
          c.tg_id,
          c.comment,
          c.reset,
          c.created_at,
          c.updated_at
        FROM clients c
        JOIN client_inbounds ci ON ci.client_id = c.id
        JOIN inbounds i ON i.id = ci.inbound_id
        WHERE c.enable = 1
          AND c.sub_id IS NOT NULL
          AND c.sub_id != ''
          AND i.enable = 1
          AND i.protocol != 'vless'
        ORDER BY c.id
        """
    ).fetchall()


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


def client_json_from_record(row: sqlite3.Row) -> dict:
    now = int(time.time() * 1000)
    client_uuid = row["uuid"] or str(uuid.uuid4())
    return {
        "id": client_uuid,
        "flow": "xtls-rprx-vision",
        "email": row["email"],
        "limitIp": row["limit_ip"] if row["limit_ip"] is not None else 3,
        "totalGB": row["total_gb"] or 0,
        "expiryTime": row["expiry_time"] or 0,
        "enable": bool(row["enable"]),
        "tgId": normalize_tg_id(row["tg_id"]),
        "subId": row["sub_id"],
        "comment": row["comment"] or "",
        "reset": row["reset"] or 0,
        "createdAt": row["created_at"] or now,
        "updatedAt": now,
    }


def make_vless_client(source: dict | None) -> dict:
    now = int(time.time() * 1000)
    client_id = str(uuid.uuid4())
    if source:
        sub_id = source.get("subId") or source.get("id") or client_id.replace("-", "")[:16]
        return {
            "id": source.get("id") or client_id,
            "flow": "xtls-rprx-vision",
            "email": source.get("email") or f"family-{client_id[:8]}",
            "limitIp": source.get("limitIp", 3),
            "totalGB": source.get("totalGB", 0),
            "expiryTime": source.get("expiryTime", 0),
            "enable": True,
            "tgId": normalize_tg_id(source.get("tgId")),
            "subId": sub_id,
            "comment": source.get("comment", ""),
            "reset": source.get("reset", 0),
            "createdAt": source.get("createdAt", now),
            "updatedAt": now,
        }
    sub_id = client_id.replace("-", "")[:16]
    return {
        "id": client_id,
        "flow": "xtls-rprx-vision",
        "email": "family-default",
        "limitIp": 3,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "tgId": 0,
        "subId": sub_id,
        "comment": "",
        "reset": 0,
        "createdAt": now,
        "updatedAt": now,
    }


def link_clients_to_inbound(
    conn: sqlite3.Connection, inbound_id: int, client_pks: list[int]
) -> int:
    if not table_exists(conn, "client_inbounds") or not client_pks:
        return 0
    now = int(time.time() * 1000)
    linked = 0
    for client_pk in client_pks:
        exists = conn.execute(
            "SELECT 1 FROM client_inbounds WHERE client_id=? AND inbound_id=? LIMIT 1",
            (client_pk, inbound_id),
        ).fetchone()
        if exists:
            conn.execute(
                """
                UPDATE client_inbounds
                SET flow_override=?
                WHERE client_id=? AND inbound_id=?
                """,
                ("xtls-rprx-vision", client_pk, inbound_id),
            )
            continue
        conn.execute(
            """
            INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (client_pk, inbound_id, "xtls-rprx-vision", now),
        )
        linked += 1
    return linked


def resolve_clients(conn: sqlite3.Connection) -> tuple[list[dict], list[int]]:
    records = load_client_records(conn)
    if records:
        clients = [client_json_from_record(row) for row in records]
        client_pks = [int(row["client_pk"]) for row in records]
        return clients, client_pks

    sources = collect_clients_from_json(conn)
    if sources:
        return [make_vless_client(src) for src in sources], []

    return [make_vless_client(None)], []


def upsert_vless_inbound(
    db_path: Path,
    template_path: Path,
    *,
    vless_port: int,
    reality_dest: str,
    reality_sni: str,
    private_key: str,
    public_key: str,
    short_id: str,
) -> dict:
    tpl = load_template(
        template_path,
        {
            "VLESS_PORT": vless_port,
            "REALITY_DEST": reality_dest,
            "REALITY_SNI": reality_sni,
            "REALITY_PRIVATE_KEY": private_key,
            "REALITY_PUBLIC_KEY": public_key,
            "REALITY_SHORT_ID": short_id,
        },
    )

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        existing = conn.execute(
            "SELECT id FROM inbounds WHERE port=? OR remark=? LIMIT 1",
            (vless_port, tpl["remark"]),
        ).fetchone()

        clients, client_pks = resolve_clients(conn)
        tpl["settings"]["clients"] = clients

        settings_json = json.dumps(tpl["settings"], ensure_ascii=False)
        stream_json = json.dumps(tpl["streamSettings"], ensure_ascii=False)
        sniff_json = json.dumps(tpl["sniffing"], ensure_ascii=False)
        tag = tpl["tag"]

        if existing:
            inbound_id = int(existing["id"])
            conn.execute(
                """
                UPDATE inbounds SET
                  remark=?, enable=1, listen='', port=?, protocol='vless',
                  settings=?, stream_settings=?, tag=?, sniffing=?
                WHERE id=?
                """,
                (
                    tpl["remark"],
                    vless_port,
                    settings_json,
                    stream_json,
                    tag,
                    sniff_json,
                    inbound_id,
                ),
            )
            action = "updated"
        else:
            conn.execute(
                """
                INSERT INTO inbounds (
                  user_id, up, down, total, remark, enable, expiry_time,
                  listen, port, protocol, settings, stream_settings, tag, sniffing, traffic_reset
                ) VALUES (
                  1, 0, 0, 0, ?, 1, 0,
                  '', ?, 'vless', ?, ?, ?, ?, ''
                )
                """,
                (
                    tpl["remark"],
                    vless_port,
                    settings_json,
                    stream_json,
                    tag,
                    sniff_json,
                ),
            )
            row = conn.execute(
                "SELECT id FROM inbounds WHERE port=? LIMIT 1", (vless_port,)
            ).fetchone()
            inbound_id = int(row["id"])
            action = "created"

        linked = link_clients_to_inbound(conn, inbound_id, client_pks)
        conn.commit()
        return {
            "action": action,
            "port": vless_port,
            "inbound_id": inbound_id,
            "clients": len(clients),
            "client_inbounds_linked": linked,
            "sub_ids": [c["subId"] for c in clients],
        }
    finally:
        conn.close()


def main() -> int:
    if len(sys.argv) != 9:
        print(
            "Usage: vless-inbound.py DB TEMPLATE PORT DEST SNI PRIVATE PUBLIC SHORT_ID",
            file=sys.stderr,
        )
        return 2

    db_path = Path(sys.argv[1])
    template_path = Path(sys.argv[2])
    vless_port = int(sys.argv[3])
    result = upsert_vless_inbound(
        db_path,
        template_path,
        vless_port=vless_port,
        reality_dest=sys.argv[4],
        reality_sni=sys.argv[5],
        private_key=sys.argv[6],
        public_key=sys.argv[7],
        short_id=sys.argv[8],
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
