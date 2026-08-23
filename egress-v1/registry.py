#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import tomllib
from typing import Any

ETC = Path(os.environ.get("MTPROXYL_EGRESS_ETC", "/etc/mtproxyl-egress"))
NODES_DIR = ETC / "nodes.d"
CONFIG = ETC / "config.toml"
LEGACY_ENV = ETC / "manager.env"

NAME_MAX = 64
ID_RE = re.compile(r"^n-[0-9a-f]{8}$")


def fail(message: str, code: int = 1) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def run(args: list[str], *, check: bool = True) -> str:
    p = subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and p.returncode != 0:
        fail(f"{' '.join(args)}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout.strip()


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def q(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as f:
        return tomllib.load(f)


def validate_name(name: str) -> str:
    name = name.strip()
    if not name:
        fail("Имя ноды не может быть пустым.")
    if len(name) > NAME_MAX:
        fail(f"Имя ноды длиннее {NAME_MAX} символов.")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in name):
        fail("Имя ноды содержит управляющие символы.")
    return name


def all_nodes() -> list[dict[str, Any]]:
    if not NODES_DIR.exists():
        return []
    result = []
    for path in sorted(NODES_DIR.glob("*.toml")):
        try:
            data = load_toml(path)
        except Exception as exc:
            fail(f"Не удалось прочитать {path}: {exc}")
        data["_path"] = str(path)
        result.append(data)
    return result


def unique_name(name: str, *, exclude_id: str | None = None) -> None:
    folded = name.casefold()
    for node in all_nodes():
        if node.get("id") == exclude_id:
            continue
        if str(node.get("name", "")).casefold() == folded:
            fail(f"Нода с именем {name!r} уже существует.")


def new_id() -> str:
    used = {str(n.get("id")) for n in all_nodes()}
    while True:
        node_id = "n-" + secrets.token_hex(4)
        if node_id not in used:
            return node_id


def node_path(node_id: str) -> Path:
    if not ID_RE.match(node_id):
        fail(f"Некорректный node id: {node_id}")
    return NODES_DIR / f"{node_id}.toml"


def render_node(node: dict[str, Any]) -> str:
    fields = [
        ("id", q(str(node["id"]))),
        ("name", q(str(node["name"]))),
        ("enabled", "true" if bool(node.get("enabled", True)) else "false"),
        ("priority", str(int(node["priority"]))),
        ("endpoint", q(str(node.get("endpoint", "")))),
        ("public_ip", q(str(node.get("public_ip", "")))),
        ("ssh_host", q(str(node.get("ssh_host", node.get("public_ip", ""))))),
        ("ssh_port", str(int(node.get("ssh_port", 22)))),
        ("ssh_user", q(str(node.get("ssh_user", "root")))),
        ("awg_interface", q(str(node["awg_interface"]))),
        ("awg_port", str(int(node.get("awg_port", 0)))),
        ("local_tunnel_ip", q(str(node["local_tunnel_ip"]))),
        ("remote_tunnel_ip", q(str(node["remote_tunnel_ip"]))),
        ("routing_table", str(int(node["routing_table"]))),
        ("agent_port", str(int(node.get("agent_port", 9784)))),
        ("agent_token_file", q(str(node.get("agent_token_file", "")))),
        ("provisioned", "true" if bool(node.get("provisioned", True)) else "false"),
        ("migration_source", q(str(node.get("migration_source", "")))),
    ]
    return "\n".join(f"{key} = {value}" for key, value in fields) + "\n"


def render_config(config: dict[str, Any]) -> str:
    manager = config["manager"]
    routing = config["routing"]
    telemt = config["telemt"]
    return f"""version = 1
mode = {q(str(config.get("mode", "auto")))}

[manager]
check_interval = {int(manager["check_interval"])}
fail_threshold = {int(manager["fail_threshold"])}
failback_hold = {int(manager["failback_hold"])}
handshake_max_age = {int(manager["handshake_max_age"])}
dc_ready_threshold = {int(manager.get("dc_ready_threshold", 80))}
recommended_max_nodes = {int(manager.get("recommended_max_nodes", 5))}

[routing]
mark = {q(str(routing.get("mark", "0x200000")))}
rule_priority = {int(routing.get("rule_priority", 11000))}
block_table = {int(routing.get("block_table", 51839))}

[telemt]
container = {q(str(telemt.get("container", "mtproxyl")))}
config = {q(str(telemt.get("config", "")))}
"""


def parse_endpoint(endpoint: str) -> tuple[str, int]:
    endpoint = endpoint.strip()
    if not endpoint or endpoint == "(none)":
        return "", 0
    if endpoint.startswith("["):
        m = re.match(r"^\[(.+)]:(\d+)$", endpoint)
        if not m:
            return endpoint, 0
        return m.group(1), int(m.group(2))
    host, sep, port = endpoint.rpartition(":")
    if not sep or not port.isdigit():
        return endpoint, 0
    return host, int(port)


def interface_ipv4(iface: str) -> str:
    text = run(["ip", "-4", "-o", "addr", "show", "dev", iface])
    for line in text.splitlines():
        parts = line.split()
        if "inet" in parts:
            addr = parts[parts.index("inet") + 1]
            return str(ipaddress.ip_interface(addr).ip)
    fail(f"Не найден IPv4 адрес интерфейса {iface}")


def awg_peer_endpoint(iface: str) -> tuple[str, int]:
    text = run(["awg", "show", iface, "endpoints"])
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            return parse_endpoint(parts[-1])
    return "", 0


def awg_remote_tunnel_ip(iface: str) -> str:
    text = run(["awg", "show", iface, "allowed-ips"])
    candidates: list[str] = []
    for line in text.splitlines():
        parts = line.split()
        for token in parts[1:]:
            for cidr in token.split(","):
                cidr = cidr.strip()
                if not cidr:
                    continue
                try:
                    net = ipaddress.ip_network(cidr, strict=False)
                except ValueError:
                    continue
                if net.version == 4 and net.prefixlen == 32:
                    ip = str(net.network_address)
                    if ip.startswith("10.253."):
                        return ip
                    candidates.append(ip)
    if candidates:
        return candidates[0]
    fail(f"Не удалось определить remote tunnel IP для {iface}")


def detect_telemt_config() -> str:
    try:
        raw = run(["docker", "inspect", "mtproxyl"])
        data = json.loads(raw)[0]
    except Exception:
        return ""
    candidates: list[tuple[int, str]] = []
    for m in data.get("Mounts", []):
        src = str(m.get("Source", ""))
        dst = str(m.get("Destination", ""))
        score = 0
        if src.endswith(".toml"):
            score += 100
        if "config.toml" in (src + " " + dst).lower():
            score += 50
        if "telemt" in (src + " " + dst).lower():
            score += 20
        if score and Path(src).is_file():
            candidates.append((score, src))
        if Path(src).is_dir():
            for name in ("config.toml", "telemt.toml"):
                p = Path(src) / name
                if p.is_file():
                    candidates.append((40, str(p)))
    return max(candidates, default=(0, ""))[1]


def current_status() -> dict[str, Any]:
    raw = run(["/usr/local/bin/mtproxyl-egress", "status", "--json"])
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"mtproxyl-egress вернул некорректный JSON: {exc}")


def migrate_legacy(force: bool = False) -> None:
    if CONFIG.exists() and not force:
        fail(f"{CONFIG} уже существует. Для повторной миграции используйте --force.")

    status = current_status()
    old_nodes = list(status.get("nodes") or [])
    if not old_nodes:
        fail("В текущем egress status нет нод.")

    env = parse_env(LEGACY_ENV)
    old_mode = str(status.get("mode") or "auto")
    active_old = str(status.get("active_node") or "")

    def role_key(item: tuple[int, dict[str, Any]]) -> tuple[int, int]:
        idx, node = item
        return (0 if node.get("role") == "primary" else 1, idx)

    ordered = [n for _, n in sorted(enumerate(old_nodes), key=role_key)]

    existing_ids: set[str] = set()
    migrated: list[dict[str, Any]] = []

    for idx, old in enumerate(ordered, start=1):
        old_id = str(old.get("id") or f"node{idx}")
        name = validate_name(old_id.upper())

        iface = str((old.get("awg") or {}).get("interface") or f"awg-{old_id}")
        local_ip = interface_ipv4(iface)
        remote_ip = awg_remote_tunnel_ip(iface)
        endpoint_host, awg_port = awg_peer_endpoint(iface)
        public_ip = str(old.get("public_ip") or endpoint_host)

        candidate = "n-" + secrets.token_hex(4)
        while candidate in existing_ids:
            candidate = "n-" + secrets.token_hex(4)
        existing_ids.add(candidate)

        env_prefix = old_id.upper().replace("-", "_")
        table = int(env.get(f"{env_prefix}_TABLE", str(51830 + idx)))
        token_path = ETC / "nodes" / f"{old_id}.token"

        node = {
            "id": candidate,
            "name": name,
            "enabled": True,
            "priority": idx * 10,
            "endpoint": endpoint_host or public_ip,
            "public_ip": public_ip,
            "ssh_host": public_ip or endpoint_host,
            "ssh_port": 22,
            "ssh_user": "root",
            "awg_interface": iface,
            "awg_port": awg_port,
            "local_tunnel_ip": local_ip,
            "remote_tunnel_ip": remote_ip,
            "routing_table": table,
            "agent_port": 9784,
            "agent_token_file": str(token_path) if token_path.exists() else "",
            "provisioned": True,
            "migration_source": old_id,
        }
        migrated.append(node)

    telemt_config = env.get("TELEMT_CONFIG") or detect_telemt_config()

    config = {
        "mode": old_mode,
        "manager": {
            "check_interval": int(env.get("CHECK_INTERVAL", "5")),
            "fail_threshold": int(env.get("FAIL_THRESHOLD", "3")),
            "failback_hold": int(env.get("FAILBACK_HOLD", "30")),
            "handshake_max_age": int(env.get("HANDSHAKE_MAX_AGE", "180")),
            "dc_ready_threshold": 80,
            "recommended_max_nodes": 5,
        },
        "routing": {
            "mark": "0x200000",
            "rule_priority": 11000,
            "block_table": int(env.get("BLOCK_TABLE", "51839")),
        },
        "telemt": {
            "container": env.get("TELEMT_CONTAINER", "mtproxyl"),
            "config": telemt_config,
        },
    }

    NODES_DIR.mkdir(parents=True, exist_ok=True)
    if force:
        for p in NODES_DIR.glob("*.toml"):
            p.unlink()

    for node in migrated:
        atomic_write(node_path(str(node["id"])), render_node(node), 0o600)

    atomic_write(CONFIG, render_config(config), 0o600)

    map_path = ETC / "migration-map.json"
    mapping = {
        "source": "legacy-v0.x",
        "active_legacy": active_old,
        "nodes": [
            {
                "legacy_id": n["migration_source"],
                "id": n["id"],
                "name": n["name"],
                "interface": n["awg_interface"],
                "priority": n["priority"],
            }
            for n in migrated
        ],
    }
    atomic_write(map_path, json.dumps(mapping, ensure_ascii=False, indent=2) + "\n", 0o600)

    print(f"Мигрировано нод: {len(migrated)}")
    print(f"Registry: {NODES_DIR}")
    print(f"Config:   {CONFIG}")
    print(f"Map:      {map_path}")
    print()
    list_nodes()


def list_nodes() -> None:
    nodes = sorted(all_nodes(), key=lambda n: (int(n.get("priority", 999999)), str(n.get("name", ""))))
    if not nodes:
        print("Нод нет.")
        return
    print(f"{'PRIO':<6} {'ID':<11} {'NAME':<24} {'EN':<4} {'INTERFACE':<16} {'PUBLIC IP':<16}")
    for n in nodes:
        print(
            f"{int(n.get('priority', 0)):<6} "
            f"{str(n.get('id', '-')):<11} "
            f"{str(n.get('name', '-'))[:23]:<24} "
            f"{'yes' if n.get('enabled', True) else 'no':<4} "
            f"{str(n.get('awg_interface', '-')):<16} "
            f"{str(n.get('public_ip', '-')):<16}"
        )


def find_node(ref: str) -> dict[str, Any]:
    nodes = all_nodes()
    exact_id = [n for n in nodes if n.get("id") == ref]
    if exact_id:
        return exact_id[0]
    exact_name = [n for n in nodes if str(n.get("name", "")).casefold() == ref.casefold()]
    if len(exact_name) == 1:
        return exact_name[0]
    if len(exact_name) > 1:
        fail(f"Имя {ref!r} неоднозначно.")
    fail(f"Нода {ref!r} не найдена.")


def show_node(ref: str) -> None:
    node = find_node(ref)
    clean = {k: v for k, v in node.items() if not k.startswith("_")}
    print(json.dumps(clean, ensure_ascii=False, indent=2))


def rename_node(ref: str, name: str) -> None:
    node = find_node(ref)
    name = validate_name(name)
    unique_name(name, exclude_id=str(node["id"]))
    old = str(node["name"])
    node["name"] = name
    atomic_write(node_path(str(node["id"])), render_node(node), 0o600)
    print(f"{old} -> {name}")
    print(f"ID и AWG interface не изменены: {node['id']} / {node['awg_interface']}")


def validate_registry() -> None:
    if not CONFIG.exists():
        fail(f"Нет {CONFIG}")
    cfg = load_toml(CONFIG)
    if int(cfg.get("version", 0)) != 1:
        fail("Неподдерживаемая версия registry.")
    seen_names: set[str] = set()
    seen_ids: set[str] = set()
    seen_ifaces: set[str] = set()
    seen_tables: set[int] = set()
    seen_local: set[str] = set()
    priorities: list[int] = []

    for node in all_nodes():
        node_id = str(node.get("id", ""))
        if not ID_RE.match(node_id):
            fail(f"Некорректный id: {node_id}")
        if node_id in seen_ids:
            fail(f"Повтор ID: {node_id}")
        seen_ids.add(node_id)

        name = validate_name(str(node.get("name", "")))
        folded = name.casefold()
        if folded in seen_names:
            fail(f"Повтор имени: {name}")
        seen_names.add(folded)

        iface = str(node.get("awg_interface", ""))
        if not iface or iface in seen_ifaces:
            fail(f"Повтор/пустой interface: {iface}")
        seen_ifaces.add(iface)

        table = int(node.get("routing_table", 0))
        if table <= 0 or table in seen_tables:
            fail(f"Повтор/некорректная routing table: {table}")
        seen_tables.add(table)

        local = str(node.get("local_tunnel_ip", ""))
        ipaddress.ip_address(local)
        if local in seen_local:
            fail(f"Повтор local tunnel IP: {local}")
        seen_local.add(local)

        remote = str(node.get("remote_tunnel_ip", ""))
        ipaddress.ip_address(remote)

        priorities.append(int(node.get("priority", 0)))

    if len(priorities) != len(set(priorities)):
        fail("Приоритеты нод должны быть уникальными.")

    print(f"Registry OK: {len(priorities)} node(s)")


def main() -> None:
    parser = argparse.ArgumentParser(description="MTProxyL Egress v1 node registry")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("migrate-legacy")
    p.add_argument("--force", action="store_true")

    sub.add_parser("list")

    p = sub.add_parser("show")
    p.add_argument("node")

    p = sub.add_parser("rename")
    p.add_argument("node")
    p.add_argument("name")

    sub.add_parser("validate")

    args = parser.parse_args()

    if args.cmd == "migrate-legacy":
        migrate_legacy(force=args.force)
    elif args.cmd == "list":
        list_nodes()
    elif args.cmd == "show":
        show_node(args.node)
    elif args.cmd == "rename":
        rename_node(args.node, args.name)
    elif args.cmd == "validate":
        validate_registry()


if __name__ == "__main__":
    main()
