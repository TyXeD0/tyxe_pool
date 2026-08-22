#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import sys

SOCKET = "/run/mtproxyl-egress/control.sock"
EVENTS = Path("/var/lib/mtproxyl-egress/events.log")


def request(payload: dict) -> dict:
    raw = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20)
    try:
        s.connect(SOCKET)
        s.sendall(raw)
        chunks = []
        while True:
            part = s.recv(65536)
            if not part:
                break
            chunks.append(part)
            if b"\n" in part:
                break
    finally:
        s.close()
    if not chunks:
        raise RuntimeError("egressd returned empty response")
    reply = json.loads(b"".join(chunks).split(b"\n", 1)[0])
    if not reply.get("ok"):
        err = reply.get("error") or {}
        raise RuntimeError(err.get("message") or "egressd request failed")
    return reply["data"]


def human_bytes(value):
    if value is None:
        return "—"
    v = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(v) < 1024:
            return f"{v:.1f} {unit}"
        v /= 1024
    return f"{v:.1f} PB"


def human_status(d: dict) -> None:
    print("MTProxyL Dynamic Egress")
    print("=======================")
    print(f"Version:     {d.get('version')}")
    print(f"Phase:       {d.get('phase')}")
    print(f"Mode:        {d.get('mode')}")
    if d.get("manual_node"):
        print(f"Manual node: {d.get('manual_node')}")
    print(f"Active:      {d.get('active_node')}")
    if d.get("last_error"):
        print(f"Last error:  {d.get('last_error')}")
    t = d.get("telemt") or {}
    print(
        "Telemt:      "
        f"NAT={t.get('nat_ip') or '—'} "
        f"writers={t.get('alive_writers')}/{t.get('required_writers')} "
        f"coverage={t.get('dc_coverage_pct')}% "
        f"verdict={t.get('dc_verdict')}"
    )
    print()

    nodes = sorted(d.get("nodes", []), key=lambda n: (int(n.get("priority", 999999)), n.get("id", "")))
    for n in nodes:
        flags = ["HEALTHY" if n.get("health") else "DOWN", str(n.get("role", "disabled")).upper()]
        if n.get("id") == d.get("active_node"):
            flags.append("ACTIVE")
        if not n.get("enabled"):
            flags.append("DISABLED")

        print(
            f"{int(n.get('priority', 0)):>3} "
            f"{n.get('name')} [{n.get('id')}] "
            + " ".join(flags)
        )
        awg = n.get("awg") or {}
        c = n.get("connectivity") or {}
        agent = n.get("agent") or {}
        print(
            f"    {n.get('public_ip') or '—'} "
            f"{awg.get('interface') or '—'} "
            f"hs={awg.get('handshake_age_sec')}s "
            f"rtt={c.get('tunnel_rtt_ms')}ms "
            f"TG={'OK' if c.get('telegram') else 'FAIL'} "
            f"Agent={'OK' if agent.get('reachable') else 'OFF'} "
            f"fails={n.get('fail_count', 0)}"
        )
        system = n.get("system") or {}
        if system:
            cpu = system.get("cpu") or {}
            mem = system.get("memory") or {}
            disk = system.get("disk") or {}
            net = system.get("network") or {}
            print(
                f"    host={system.get('hostname') or '—'} "
                f"cpu={cpu.get('usage_percent', '—')}% "
                f"ram={mem.get('usage_percent', '—')}% "
                f"disk={disk.get('usage_percent', '—')}% "
                f"net={net.get('interface') or '—'} "
                f"rx={human_bytes(net.get('rx_bytes'))} "
                f"tx={human_bytes(net.get('tx_bytes'))}"
            )


def panel_compat(d: dict) -> dict:
    # Temporary compatibility for Panel egress1 while the dynamic UI is being
    # built. Migrated PL1/PL2 retain their legacy IDs in this view.
    out = json.loads(json.dumps(d))
    id_map = {}
    for n in out.get("nodes", []):
        stable = n.get("id")
        legacy = n.get("migration_source") or n.get("name") or stable
        compat = str(legacy).lower()
        id_map[stable] = compat
        n["registry_id"] = stable
        n["id"] = compat

    active = out.get("active_node")
    if active in id_map:
        out["active_node"] = id_map[active]

    mode = out.get("mode")
    if mode == "manual":
        manual = out.get("manual_node")
        out["mode"] = id_map.get(manual, "manual")
    return out


def node_list(d: dict) -> None:
    print(f"{'PRIO':<6} {'ID':<11} {'NAME':<24} {'EN':<4} {'HEALTH':<8} {'ACTIVE':<7} {'PUBLIC IP':<16}")
    for n in sorted(d.get("nodes", []), key=lambda x: (int(x.get("priority", 999999)), x.get("id", ""))):
        print(
            f"{int(n.get('priority', 0)):<6} "
            f"{str(n.get('id', '-')):<11} "
            f"{str(n.get('name', '-'))[:23]:<24} "
            f"{'yes' if n.get('enabled') else 'no':<4} "
            f"{'healthy' if n.get('health') else 'down':<8} "
            f"{'yes' if n.get('id') == d.get('active_node') else 'no':<7} "
            f"{str(n.get('public_ip', '-')):<16}"
        )


def main() -> None:
    ap = argparse.ArgumentParser(prog="mtproxyl-egress")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.add_argument("--panel-json", action="store_true")

    p = sub.add_parser("mode")
    p.add_argument("value")
    p.add_argument("node", nargs="?")

    p = sub.add_parser("switch")
    p.add_argument("node")

    sub.add_parser("auto")
    sub.add_parser("direct")
    sub.add_parser("block")

    p = sub.add_parser("events")
    p.add_argument("limit", nargs="?", type=int, default=30)

    p = sub.add_parser("config")
    csub = p.add_subparsers(dest="config_cmd", required=True)
    csub.add_parser("get")
    ps = csub.add_parser("set")
    ps.add_argument("check_interval", type=int)
    ps.add_argument("fail_threshold", type=int)
    ps.add_argument("failback_hold", type=int)
    ps.add_argument("handshake_max_age", type=int)

    p = sub.add_parser("node")
    nsub = p.add_subparsers(dest="node_cmd", required=True)
    nsub.add_parser("list")
    ps = nsub.add_parser("show"); ps.add_argument("node")
    ps = nsub.add_parser("test"); ps.add_argument("node")
    ps = nsub.add_parser("rename"); ps.add_argument("node"); ps.add_argument("name")
    ps = nsub.add_parser("enable"); ps.add_argument("node")
    ps = nsub.add_parser("disable"); ps.add_argument("node")
    ps = nsub.add_parser("priority"); ps.add_argument("node"); ps.add_argument("priority", type=int)

    args = ap.parse_args()

    try:
        if args.cmd == "status":
            d = request({"action": "status"})
            if args.panel_json:
                print(json.dumps(panel_compat(d), ensure_ascii=False))
            elif args.json:
                print(json.dumps(d, ensure_ascii=False, indent=2))
            else:
                human_status(d)

        elif args.cmd == "mode":
            value = args.value.casefold()
            if value in {"auto", "direct", "block"}:
                d = request({"action": "set_mode", "mode": value})
            else:
                node = args.node or args.value
                d = request({"action": "set_mode", "mode": "manual", "node": node})
            print(json.dumps(d, ensure_ascii=False, indent=2))

        elif args.cmd == "switch":
            d = request({"action": "set_mode", "mode": "manual", "node": args.node})
            print(json.dumps(d, ensure_ascii=False, indent=2))

        elif args.cmd in {"auto", "direct", "block"}:
            d = request({"action": "set_mode", "mode": args.cmd})
            print(json.dumps(d, ensure_ascii=False, indent=2))

        elif args.cmd == "events":
            limit = max(1, min(200, int(args.limit)))
            if not EVENTS.exists():
                return
            lines = EVENTS.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
            print("\n".join(lines))

        elif args.cmd == "config":
            if args.config_cmd == "get":
                d = request({"action": "config_get"})
            else:
                d = request(
                    {
                        "action": "config_set",
                        "config": {
                            "check_interval": args.check_interval,
                            "fail_threshold": args.fail_threshold,
                            "failback_hold": args.failback_hold,
                            "handshake_max_age": args.handshake_max_age,
                        },
                    }
                )
            print(json.dumps(d, ensure_ascii=False, indent=2))

        elif args.cmd == "node":
            if args.node_cmd == "list":
                d = request({"action": "status"})
                node_list(d)
            elif args.node_cmd == "show":
                d = request({"action": "status"})
                folded = args.node.casefold()
                hits = [
                    n for n in d.get("nodes", [])
                    if folded in {
                        str(n.get("id", "")).casefold(),
                        str(n.get("name", "")).casefold(),
                        str(n.get("migration_source", "")).casefold(),
                    }
                ]
                if len(hits) != 1:
                    raise RuntimeError("node not found or ambiguous")
                print(json.dumps(hits[0], ensure_ascii=False, indent=2))
            elif args.node_cmd == "test":
                d = request({"action": "node_test", "node": args.node})
                print(json.dumps(d, ensure_ascii=False, indent=2))
            elif args.node_cmd == "rename":
                d = request({"action": "node_rename", "node": args.node, "value": args.name})
                print(json.dumps(d, ensure_ascii=False, indent=2))
            elif args.node_cmd == "enable":
                d = request({"action": "node_enable", "node": args.node})
                print(json.dumps(d, ensure_ascii=False, indent=2))
            elif args.node_cmd == "disable":
                d = request({"action": "node_disable", "node": args.node})
                print(json.dumps(d, ensure_ascii=False, indent=2))
            elif args.node_cmd == "priority":
                d = request({"action": "node_priority", "node": args.node, "value": args.priority})
                print(json.dumps(d, ensure_ascii=False, indent=2))

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
