#!/usr/bin/env python3
"""Verify VLESS Reality: .env keys, DB inbound, subscription link."""
from __future__ import annotations

import json
import sqlite3
import sys
import urllib.parse
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        val = val.strip().strip('"').strip("'")
        out[key.strip()] = val
    return out


def parse_vless_link(line: str) -> dict[str, str] | None:
    line = line.strip()
    if not line.startswith("vless://"):
        return None
    body = line[len("vless://") :]
    if "#" in body:
        body, _ = body.split("#", 1)
    if "?" not in body:
        return None
    user_host, qs = body.rsplit("?", 1)
    uuid, _, hostport = user_host.partition("@")
    host, _, port = hostport.rpartition(":")
    params = urllib.parse.parse_qs(qs, keep_blank_values=True)
    flat = {k: v[0] if v else "" for k, v in params.items()}
    flat["uuid"] = uuid
    flat["host"] = host
    flat["port"] = port
    return flat


def reality_from_stream(raw: str) -> dict:
    try:
        stream = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {}
    rs = stream.get("realitySettings") or {}
    nested = rs.get("settings") or {}
    return {
        "dest": rs.get("dest") or rs.get("target") or "",
        "private_key": rs.get("privateKey") or "",
        "public_key": rs.get("publicKey") or nested.get("publicKey") or "",
        "short_ids": rs.get("shortIds") or [],
        "server_names": rs.get("serverNames") or [],
        "client_fields": [
            k
            for k in ("serverName", "fingerprint", "password", "shortId", "spiderX")
            if rs.get(k)
        ],
        "has_settings": bool(nested),
    }


def client_flows(settings_raw: str) -> list[dict]:
    try:
        settings = json.loads(settings_raw or "{}")
    except json.JSONDecodeError:
        return []
    out = []
    for c in settings.get("clients") or []:
        out.append(
            {
                "email": c.get("email") or "",
                "id": c.get("id") or "",
                "flow": c.get("flow") or "",
                "enable": c.get("enable", True),
                "subId": c.get("subId") or "",
            }
        )
    return out


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "Usage: verify-vless-reality.py DB ENV_FILE SUBSCRIPTION_TEXT [SUB_ID]",
            file=sys.stderr,
        )
        return 2

    db_path = Path(sys.argv[1])
    env_path = Path(sys.argv[2])
    sub_text = sys.argv[3]
    sub_id = sys.argv[4] if len(sys.argv) > 4 else ""

    env = load_env(env_path)
    vless_port = int(env.get("VLESS_PORT") or "4433")
    exp_pub = env.get("REALITY_PUBLIC_KEY") or ""
    exp_priv = env.get("REALITY_PRIVATE_KEY") or ""
    exp_sid = env.get("REALITY_SHORT_ID") or ""

    issues: list[str] = []
    warnings: list[str] = []

    vless_line = next((ln for ln in sub_text.splitlines() if ln.startswith("vless://")), "")
    vless = parse_vless_link(vless_line) if vless_line else None
    if not vless:
        issues.append("No vless:// line in subscription")
    else:
        print(f"subscription uuid={vless['uuid']} host={vless['host']}:{vless['port']}")
        print(
            f"subscription flow={vless.get('flow') or '(empty)'} "
            f"pbk={vless.get('pbk') or '(empty)'} sid={vless.get('sid') or '(empty)'}"
        )
        if vless.get("flow") != "xtls-rprx-vision":
            issues.append(f"Subscription flow is '{vless.get('flow')}', expected xtls-rprx-vision")
        if not vless.get("pbk"):
            issues.append("Subscription pbk (public key) is empty")
        elif exp_pub and vless.get("pbk") != exp_pub:
            issues.append("Subscription pbk does not match REALITY_PUBLIC_KEY in .env")
        if exp_sid and not vless.get("sid"):
            issues.append(
                f"Subscription sid is empty but REALITY_SHORT_ID={exp_sid} — "
                "run: python3 scripts/lib/fix-client-json.py DB .env && docker restart happroxy_3xui"
            )
        if exp_sid and vless.get("sid") and vless.get("sid") not in (exp_sid, ""):
            warnings.append(
                f"Subscription sid={vless.get('sid')} differs from .env REALITY_SHORT_ID={exp_sid}"
            )

    conn = sqlite3.connect(str(db_path))
    try:
        owner_email = ""
        owner_uuid = ""
        if sub_id:
            owner = conn.execute(
                "SELECT email, uuid FROM clients WHERE sub_id=? LIMIT 1",
                (sub_id,),
            ).fetchone()
            if owner:
                owner_email, owner_uuid = owner[0] or "", owner[1] or ""
                print(f"subscription owner email={owner_email} uuid={owner_uuid}")

        row = conn.execute(
            """
            SELECT remark, enable, settings, stream_settings
            FROM inbounds
            WHERE port=? OR remark='vless-reality'
            LIMIT 1
            """,
            (vless_port,),
        ).fetchone()
        if not row:
            issues.append(f"No vless inbound on port {vless_port}")
        else:
            remark, enable, settings_raw, stream_raw = row
            print(f"inbound remark={remark} enable={enable}")
            if not enable:
                issues.append("vless-reality inbound is disabled")

            reality = reality_from_stream(stream_raw or "")
            if not reality["dest"]:
                issues.append("Inbound realitySettings missing dest/target")
            if not reality["private_key"]:
                issues.append("Inbound realitySettings missing privateKey")
            elif exp_priv and reality["private_key"] != exp_priv:
                issues.append("Inbound privateKey does not match REALITY_PRIVATE_KEY in .env")
            if exp_pub and reality["public_key"] and reality["public_key"] != exp_pub:
                issues.append("Inbound publicKey does not match REALITY_PUBLIC_KEY in .env")
            if exp_sid and exp_sid not in (reality["short_ids"] or []):
                issues.append(f"REALITY_SHORT_ID {exp_sid} not in inbound shortIds")
            if reality["client_fields"]:
                warnings.append(
                    "Inbound realitySettings has client-side fields at top level: "
                    + ", ".join(reality["client_fields"])
                    + " (re-run setup-vless-reality.sh if connections fail)"
                )

            clients = client_flows(settings_raw or "")
            if not clients:
                issues.append("No clients in vless inbound settings")
            else:
                owner_in_inbound = False
                for c in clients:
                    print(
                        f"  client email={c['email']} id={c['id']} "
                        f"flow={c['flow'] or '(empty)'} enable={c['enable']}"
                    )
                    if c["enable"] and c["flow"] != "xtls-rprx-vision":
                        issues.append(
                            f"Client {c['email']} flow is '{c['flow']}', expected xtls-rprx-vision"
                        )
                    if owner_uuid and c["id"] == owner_uuid:
                        owner_in_inbound = True

                check_uuid = owner_uuid or (vless["uuid"] if vless else "")
                check_email = owner_email or ""
                if check_uuid and not owner_in_inbound:
                    issues.append(
                        f"Subscription UUID {check_uuid} ({check_email or '?'}) "
                        "missing in vless inbound settings — run: "
                        "python3 scripts/lib/fix-client-json.py DB"
                    )
                elif check_uuid and owner_in_inbound:
                    print(f"subscription owner present in vless inbound — OK")
    finally:
        conn.close()

    for w in warnings:
        print(f"WARN: {w}")
    for i in issues:
        print(f"FAIL: {i}")

    if issues:
        print("Fix: python3 scripts/lib/fix-client-json.py DB && docker restart happroxy_3xui")
        return 1
    print("VLESS Reality config looks consistent (.env, DB, subscription)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
