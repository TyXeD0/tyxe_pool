#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch-provisioner-dev4.py SOURCE DEST")

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

if 'VERSION = "1.0.0-dev4"' in s:
    dst.write_text(s, encoding="utf-8")
    print("Provisioner source already at dev4")
    raise SystemExit(0)

if 'VERSION = "1.0.0-dev3"' not in s:
    raise SystemExit("unexpected provisioner source version; expected dev3")

s = s.replace('VERSION = "1.0.0-dev3"', 'VERSION = "1.0.0-dev4"', 1)

# amneziawg-tools v3.1.20260812 does not accept AdvancedSecurity in an
# awg setconf configuration. The obfuscation/security parameters are Jc/Jmin/
# Jmax/S1/S2/H1..H4 themselves, so this extra directive is both unnecessary
# and fatal ("Line unrecognized: AdvancedSecurity=on").
needle = '        "AdvancedSecurity = on",\n'
if needle not in s:
    raise SystemExit("AdvancedSecurity anchor not found")
s = s.replace(needle, "", 1)

old_remote = '''        remote_write(ssh, f"/etc/amnezia/amneziawg/{n['awg_interface']}.conf", remote_text, 0o600)\n        ssh.exec(f"systemctl daemon-reload; systemctl enable --now awg-quick@{shlex.quote(n['awg_interface'])}.service")\n\n        local_cfg.parent.mkdir(parents=True, exist_ok=True)\n'''
new_remote = '''        remote_write(ssh, f"/etc/amnezia/amneziawg/{n['awg_interface']}.conf", remote_text, 0o600)\n        remote_unit = f"awg-quick@{n['awg_interface']}.service"\n        ssh.exec(\n            "set -Eeuo pipefail; "\n            "systemctl daemon-reload; "\n            f"systemctl enable --now {shlex.quote(remote_unit)}; "\n            f"systemctl is-active --quiet {shlex.quote(remote_unit)}; "\n            f"ip link show dev {shlex.quote(str(n['awg_interface']))} >/dev/null; "\n            f"awg show {shlex.quote(str(n['awg_interface']))} >/dev/null"\n        )\n\n        local_cfg.parent.mkdir(parents=True, exist_ok=True)\n'''
if old_remote not in s:
    raise SystemExit("remote AWG start anchor not found")
s = s.replace(old_remote, new_remote, 1)

old_local = '''        atomic_write(local_cfg, local_text, 0o600)\n        run(["systemctl", "daemon-reload"])\n        run(["systemctl", "enable", "--now", f"awg-quick@{n['awg_interface']}.service"])\n\n        remote_firewall(ssh, n, ext)\n'''
new_local = '''        atomic_write(local_cfg, local_text, 0o600)\n        local_unit = f"awg-quick@{n['awg_interface']}.service"\n        run(["systemctl", "daemon-reload"])\n        run(["systemctl", "enable", "--now", local_unit])\n        run(["systemctl", "is-active", "--quiet", local_unit])\n        run(["ip", "link", "show", "dev", str(n["awg_interface"])])\n        run(["awg", "show", str(n["awg_interface"])])\n\n        remote_firewall(ssh, n, ext)\n'''
if old_local not in s:
    raise SystemExit("local AWG start anchor not found")
s = s.replace(old_local, new_local, 1)

old_cleanup = '''    run(["systemctl", "disable", "--now", f"awg-quick@{iface}.service"], check=False)\n    with contextlib.suppress(FileNotFoundError):\n'''
new_cleanup = '''    unit = f"awg-quick@{iface}.service"\n    run(["systemctl", "disable", "--now", unit], check=False)\n    run(["systemctl", "reset-failed", unit], check=False)\n    with contextlib.suppress(FileNotFoundError):\n'''
if old_cleanup not in s:
    raise SystemExit("local cleanup anchor not found")
s = s.replace(old_cleanup, new_cleanup, 1)

old_remote_cleanup = '''systemctl disable --now awg-quick@{shlex.quote(iface)}.service >/dev/null 2>&1\nrm -f /etc/amnezia/amneziawg/{shlex.quote(iface)}.conf\n'''
new_remote_cleanup = '''systemctl disable --now awg-quick@{shlex.quote(iface)}.service >/dev/null 2>&1\nsystemctl reset-failed awg-quick@{shlex.quote(iface)}.service >/dev/null 2>&1 || true\nrm -f /etc/amnezia/amneziawg/{shlex.quote(iface)}.conf\n'''
if old_remote_cleanup not in s:
    raise SystemExit("remote cleanup anchor not found")
s = s.replace(old_remote_cleanup, new_remote_cleanup, 1)

dst.write_text(s, encoding="utf-8")
print("Provisioner patched: 1.0.0-dev3 -> 1.0.0-dev4")
