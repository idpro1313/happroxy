#!/usr/bin/env python3
"""X25519 keygen fallback for VLESS Reality (docker xray or cryptography)."""
from __future__ import annotations

import base64
import subprocess
import sys


def _via_docker() -> bool:
    images = (
        ["docker", "run", "--rm", "ghcr.io/xtls/xray-core", "x25519"],
        ["docker", "run", "--rm", "ghcr.io/xtls/xray-core:latest", "x25519"],
    )
    for cmd in images:
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        out = (proc.stdout or "").strip()
        if proc.returncode == 0 and "PrivateKey" in out and "PublicKey" in out:
            print(out)
            return True
    return False


def _via_cryptography() -> bool:
    from cryptography.hazmat.primitives.asymmetric import x25519
    from cryptography.hazmat.primitives import serialization

    private = x25519.X25519PrivateKey.generate()
    priv_bytes = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub_bytes = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    enc = base64.urlsafe_b64encode
    print(f"PrivateKey: {enc(priv_bytes).decode().rstrip('=')}")
    print(f"Password (PublicKey): {enc(pub_bytes).decode().rstrip('=')}")
    return True


def main() -> int:
    if _via_docker():
        return 0
    try:
        if _via_cryptography():
            return 0
    except ImportError:
        pass
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
