#!/usr/bin/env python3
"""Build Happ routing profile JSON (official field names) and optional base64 deeplink."""
from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path


GEOIP_URL = (
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
)
GEOSITE_URL = (
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
)

REQUIRED_STRING_FIELDS = (
    "Name",
    "GlobalProxy",
    "RemoteDNSType",
    "RemoteDNSDomain",
    "RemoteDNSIP",
    "DomesticDNSType",
    "DomesticDNSDomain",
    "DomesticDNSIP",
    "Geoipurl",
    "Geositeurl",
    "DomainStrategy",
    "FakeDNS",
)


def load_template(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def inject_direct(
    data: dict, server_ip: str, panel_domain: str, profile_name: str = ""
) -> dict:
    if profile_name:
        data["Name"] = profile_name

    direct = data.setdefault("DirectIp", [])
    direct_sites = data.setdefault("DirectSites", [])

    for entry in ("geoip:private", "geoip:ru"):
        if entry not in direct:
            direct.append(entry)

    if server_ip:
        cidr = server_ip if "/" in server_ip else f"{server_ip}/32"
        if cidr not in direct:
            direct.append(cidr)

    if panel_domain:
        for site in (panel_domain, f"full:{panel_domain}"):
            if site not in direct_sites:
                direct_sites.append(site)

    return data


def normalize(data: dict) -> dict:
    """Ensure Happ-compatible DNS / geo fields (drop legacy keys)."""
    data.pop("RemoteDns", None)
    data.pop("DomesticDns", None)
    data.pop("RemoteRouting", None)

    data.setdefault("RemoteDNSType", "DoH")
    data.setdefault("RemoteDNSDomain", "https://cloudflare-dns.com/dns-query")
    data.setdefault("RemoteDNSIP", "1.1.1.1")
    data.setdefault("DomesticDNSType", "DoH")
    data.setdefault("DomesticDNSDomain", "https://dns.google/dns-query")
    data.setdefault("DomesticDNSIP", "8.8.8.8")
    data.setdefault("Geoipurl", GEOIP_URL)
    data.setdefault("Geositeurl", GEOSITE_URL)
    data.setdefault(
        "DnsHosts",
        {"cloudflare-dns.com": "1.1.1.1", "dns.google": "8.8.8.8"},
    )
    data.setdefault("RouteOrder", "block-proxy-direct")

    if data.get("RouteOrder") == "block-direct-proxy":
        data["RouteOrder"] = "block-proxy-direct"

    return data


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    for key in REQUIRED_STRING_FIELDS:
        if not data.get(key):
            errors.append(f"Missing or empty field: {key}")
    if not isinstance(data.get("DnsHosts"), dict):
        errors.append("DnsHosts must be an object")
    for legacy in ("RemoteDns", "DomesticDns", "RemoteRouting"):
        if legacy in data:
            errors.append(f"Legacy/invalid field present: {legacy}")
    if data.get("RouteOrder") not in (
        "block-proxy-direct",
        "block-direct-proxy",
        "proxy-direct-block",
        "direct-proxy-block",
        None,
    ):
        errors.append(f"Unknown RouteOrder: {data.get('RouteOrder')}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Happ routing JSON")
    parser.add_argument("template", type=Path)
    parser.add_argument("server_ip", nargs="?", default="")
    parser.add_argument("panel_domain", nargs="?", default="")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--json-only", action="store_true")
    parser.add_argument("--b64-only", action="store_true")
    parser.add_argument(
        "--profile-name",
        default="",
        help="Override Name (must match subscription title in Happ)",
    )
    args = parser.parse_args()

    data = normalize(
        inject_direct(
            load_template(args.template),
            args.server_ip,
            args.panel_domain,
            args.profile_name,
        )
    )
    errors = validate(data)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    compact = json.dumps(data, separators=(",", ":"), ensure_ascii=False)

    if args.validate_only or args.json_only:
        print(compact)
        return 0

    b64 = base64.b64encode(compact.encode("utf-8")).decode("ascii")

    if args.b64_only:
        print(b64)
        return 0

    print(compact)
    print("---B64---")
    print(b64)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
