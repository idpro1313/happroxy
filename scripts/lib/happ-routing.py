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
    "RemoteDNSType",
    "RemoteDNSDomain",
    "RemoteDNSIP",
    "DomesticDNSType",
    "DomesticDNSDomain",
    "DomesticDNSIP",
    "Geoipurl",
    "Geositeurl",
    "DomainStrategy",
)

BOOL_FIELDS = ("GlobalProxy", "FakeDNS", "UseChunkFiles")

# Happ profile mapped from runetfreedom all_except_ru.json (v2rayN rules → Direct/Block lists).
# https://github.com/runetfreedom/russia-v2ray-custom-routing-list/tree/main/v2rayN
RUNETFREEDOM_DIRECT_SITES = (
    "geosite:private",
    "geosite:ru-available-only-inside",
)
RUNETFREEDOM_DIRECT_IP = ("geoip:private", "geoip:ru")
RUNETFREEDOM_BLOCK_SITES = ("geosite:category-ads-all",)


def as_bool(value: object, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return default


def load_template(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def sanitize_direct_sites(sites: list[str]) -> list[str]:
    """Happ routing builder rejects regexp:/full:/domain: in DirectSites."""
    result: list[str] = []
    seen: set[str] = set()
    for site in sites:
        if site.startswith("regexp:"):
            continue
        if site.startswith("full:"):
            site = site.removeprefix("full:")
        elif site.startswith("domain:"):
            site = site.removeprefix("domain:")
        if not site or site in seen:
            continue
        seen.add(site)
        result.append(site)
    return result


def inject_direct(
    data: dict, server_ip: str, panel_domain: str, profile_name: str = ""
) -> dict:
    if profile_name:
        data["Name"] = profile_name

    direct = data.setdefault("DirectIp", [])
    direct_sites = data.setdefault("DirectSites", [])
    block_sites = data.setdefault("BlockSites", [])

    for entry in RUNETFREEDOM_DIRECT_IP:
        if entry not in direct:
            direct.append(entry)

    for entry in RUNETFREEDOM_DIRECT_SITES:
        if entry not in direct_sites:
            direct_sites.append(entry)

    for entry in RUNETFREEDOM_BLOCK_SITES:
        if entry not in block_sites:
            block_sites.append(entry)

    if server_ip:
        cidr = server_ip if "/" in server_ip else f"{server_ip}/32"
        if cidr not in direct:
            direct.append(cidr)

    if panel_domain:
        if panel_domain not in direct_sites:
            direct_sites.append(panel_domain)

    return data


def normalize(data: dict) -> dict:
    """Ensure Happ-compatible DNS / geo fields (drop legacy keys)."""
    data.pop("RemoteDns", None)
    data.pop("DomesticDns", None)
    data.pop("RemoteRouting", None)

    data.setdefault("RemoteDNSType", "DoH")
    data.setdefault("RemoteDNSDomain", "https://cloudflare-dns.com/dns-query")
    data.setdefault("RemoteDNSIP", "1.1.1.1")
    data.setdefault("DomesticDNSType", "DoU")
    data.setdefault("DomesticDNSDomain", "")
    data.setdefault("DomesticDNSIP", "77.88.8.8")
    data.setdefault("Geoipurl", GEOIP_URL)
    data.setdefault("Geositeurl", GEOSITE_URL)
    data.setdefault(
        "DnsHosts",
        {"cloudflare-dns.com": "1.1.1.1"},
    )
    data.setdefault("DomainStrategy", "IPOnDemand")
    data.setdefault("RouteOrder", "block-proxy-direct")
    data.setdefault("LastUpdated", "")

    if data.get("RouteOrder") == "block-direct-proxy":
        data["RouteOrder"] = "block-proxy-direct"

    for key in BOOL_FIELDS:
        default = key != "FakeDNS"
        data[key] = as_bool(data.get(key), default=default)

    data["DirectSites"] = sanitize_direct_sites(data.get("DirectSites", []))

    return data


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    for key in REQUIRED_STRING_FIELDS:
        if key not in data or data[key] is None:
            errors.append(f"Missing field: {key}")
        elif key != "DomesticDNSDomain" and not data.get(key):
            errors.append(f"Missing or empty field: {key}")
    for key in BOOL_FIELDS:
        if not isinstance(data.get(key), bool):
            errors.append(f"Field must be boolean: {key}")
    if not isinstance(data.get("DnsHosts"), dict):
        errors.append("DnsHosts must be an object")
    for legacy in ("RemoteDns", "DomesticDns", "RemoteRouting"):
        if legacy in data:
            errors.append(f"Legacy/invalid field present: {legacy}")
    if data.get("RouteOrder") not in (
        "block-proxy-direct",
        "block-direct-proxy",
        "proxy-direct-block",
        "proxy-block-direct",
        "direct-proxy-block",
        "direct-block-proxy",
        None,
    ):
        errors.append(f"Unknown RouteOrder: {data.get('RouteOrder')}")
    for site in data.get("DirectSites", []):
        if site.startswith(("regexp:", "full:", "domain:")):
            errors.append(f"DirectSites: unsupported entry {site}")
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
