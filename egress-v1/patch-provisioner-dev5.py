#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch-provisioner-dev5.py SOURCE DEST")

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

if 'VERSION = "1.0.0-dev5"' in s:
    dst.write_text(s, encoding="utf-8")
    print("Provisioner source already at dev5")
    raise SystemExit(0)

if 'VERSION = "1.0.0-dev4"' not in s:
    raise SystemExit("unexpected provisioner source version; expected dev4")

s = s.replace('VERSION = "1.0.0-dev4"', 'VERSION = "1.0.0-dev5"', 1)

anchor = '''def local_cleanup(n: dict[str, Any]) -> None:\n'''
helpers = r'''def cleanup_enter_nft(iface: str) -> None:
    p = run(["nft", "-a", "list", "chain", "inet", "mtproxyl_egress", "postrouting"], check=False)
    if p.returncode != 0:
        return
    for line in p.stdout.splitlines():
        if f'oifname "{iface}"' not in line:
            continue
        m = re.search(r"# handle ([0-9]+)\s*$", line)
        if m:
            run([
                "nft", "delete", "rule", "inet", "mtproxyl_egress", "postrouting",
                "handle", m.group(1),
            ], check=False)


def candidate_route_up(n: dict[str, Any]) -> None:
    rules = run(["ip", "rule", "show"], check=False).stdout.splitlines()
    used: set[int] = set()
    for line in rules:
        m = re.match(r"^([0-9]+):", line.strip())
        if m:
            used.add(int(m.group(1)))
    prio = next((p for p in range(10700, 10800) if p not in used), None)
    if prio is None:
        fail("no free temporary policy-rule priority for candidate probe")

    iface = str(n["awg_interface"])
    local = str(n["local_tunnel_ip"])
    table = str(int(n["routing_table"]))
    n["_candidate_rule_priority"] = prio

    run(["ip", "route", "replace", "blackhole", "default", "metric", "32760", "table", table])
    run(["ip", "route", "replace", "default", "dev", iface, "src", local, "metric", "10", "table", table])
    run(["ip", "rule", "add", "priority", str(prio), "from", f"{local}/32", "lookup", table])

    p = run([
        "ip", "route", "get", TEST_TELEGRAM_IP,
        "from", local, "mark", "0x200000",
    ], check=False)
    if p.returncode != 0 or f"dev {iface}" not in p.stdout:
        candidate_route_down(n, flush=True)
        fail("candidate Telegram probe is not routed through the new AWG interface")


def candidate_route_down(n: dict[str, Any], *, flush: bool = False) -> None:
    prio = n.pop("_candidate_rule_priority", None)
    if prio is not None:
        while run(["ip", "rule", "del", "priority", str(int(prio))], check=False).returncode == 0:
            pass
    if flush:
        run(["ip", "route", "flush", "table", str(int(n["routing_table"]))], check=False)


'''
if anchor not in s:
    raise SystemExit("local_cleanup anchor not found")
s = s.replace(anchor, helpers + anchor, 1)

old_cleanup = '''def local_cleanup(n: dict[str, Any]) -> None:\n    iface = str(n["awg_interface"])\n    unit = f"awg-quick@{iface}.service"\n    run(["systemctl", "disable", "--now", unit], check=False)\n    run(["systemctl", "reset-failed", unit], check=False)\n    with contextlib.suppress(FileNotFoundError):\n        (Path("/etc/amnezia/amneziawg") / f"{iface}.conf").unlink()\n    token = Path(str(n.get("agent_token_file", "")))\n    if token:\n        with contextlib.suppress(FileNotFoundError):\n            token.unlink()\n'''
new_cleanup = '''def local_cleanup(n: dict[str, Any]) -> None:\n    iface = str(n["awg_interface"])\n    candidate_route_down(n, flush=True)\n    unit = f"awg-quick@{iface}.service"\n    run(["systemctl", "disable", "--now", unit], check=False)\n    run(["systemctl", "reset-failed", unit], check=False)\n    cleanup_enter_nft(iface)\n    with contextlib.suppress(FileNotFoundError):\n        (Path("/etc/amnezia/amneziawg") / f"{iface}.conf").unlink()\n    token = Path(str(n.get("agent_token_file", "")))\n    if token:\n        with contextlib.suppress(FileNotFoundError):\n            token.unlink()\n'''
if old_cleanup not in s:
    raise SystemExit("dev4 local_cleanup body not found")
s = s.replace(old_cleanup, new_cleanup, 1)

old_probe = '''        rtt = ping_tunnel(str(n["awg_interface"]), str(n["remote_tunnel_ip"]))\n        tg_ms = telegram_tcp(str(n["local_tunnel_ip"]))\n        agent_check(n, token)\n'''
new_probe = '''        rtt = ping_tunnel(str(n["awg_interface"]), str(n["remote_tunnel_ip"]))\n        candidate_route_up(n)\n        try:\n            tg_ms = telegram_tcp(str(n["local_tunnel_ip"]))\n        finally:\n            candidate_route_down(n, flush=False)\n        agent_check(n, token)\n'''
if old_probe not in s:
    raise SystemExit("candidate Telegram probe anchor not found")
s = s.replace(old_probe, new_probe, 1)

old_remove = '''    run([str(REGISTRY), "validate"])\n    control({"action": "reload"})\n    event(f"node_remove id={node_id} name={n['name']!r} remote_cleanup={remote_result}")\n'''
new_remove = '''    run([str(REGISTRY), "validate"])\n    control({"action": "reload"})\n    # Reload first so egressd no longer considers the removed node, then clean\n    # any stale per-interface NAT/routing state without a race that could add it back.\n    cleanup_enter_nft(str(n["awg_interface"]))\n    run(["ip", "route", "flush", "table", str(int(n["routing_table"]))], check=False)\n    event(f"node_remove id={node_id} name={n['name']!r} remote_cleanup={remote_result}")\n'''
if old_remove not in s:
    raise SystemExit("remove finalization anchor not found")
s = s.replace(old_remove, new_remove, 1)

dst.write_text(s, encoding="utf-8")
print("Provisioner patched: 1.0.0-dev4 -> 1.0.0-dev5")
