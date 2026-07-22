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


def collect_clients(conn: sqlite3.Connection) -> list[dict]:
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


def make_vless_client(source: dict | None) -> dict:
    now = int(time.time() * 1000)
    client_id = str(uuid.uuid4())
    if source:
        sub_id = source.get("subId") or source.get("id") or client_id.replace("-", "")[:16]
        return {
            "id": client_id,
            "flow": "xtls-rprx-vision",
            "email": source.get("email") or f"family-{client_id[:8]}",
            "limitIp": source.get("limitIp", 3),
            "totalGB": source.get("totalGB", 0),
            "expiryTime": source.get("expiryTime", 0),
            "enable": True,
            "tgId": source.get("tgId", ""),
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
        "tgId": "",
        "subId": sub_id,
        "comment": "",
        "reset": 0,
        "createdAt": now,
        "updatedAt": now,
    }


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
    try:
        existing = conn.execute(
            "SELECT id FROM inbounds WHERE port=? OR remark=? LIMIT 1",
            (vless_port, tpl["remark"]),
        ).fetchone()

        sources = collect_clients(conn)
        clients = [make_vless_client(src) for src in sources] if sources else [make_vless_client(None)]
        tpl["settings"]["clients"] = clients

        settings_json = json.dumps(tpl["settings"], ensure_ascii=False)
        stream_json = json.dumps(tpl["streamSettings"], ensure_ascii=False)
        sniff_json = json.dumps(tpl["sniffing"], ensure_ascii=False)
        tag = tpl["tag"]

        if existing:
            inbound_id = existing[0]
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
            action = "created"

        conn.commit()
        return {
            "action": action,
            "port": vless_port,
            "clients": len(clients),
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
