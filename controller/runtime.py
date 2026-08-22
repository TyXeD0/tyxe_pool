#!/usr/bin/env python3
"""TYXE Controller runtime wrapper.

Keeps controller.py as the application/UI source, but replaces the background
Agent poller with a merge-only implementation. A slow probe must never save an
old controller-state snapshot over a node that was concurrently added, removed
or edited through the web/API.
"""

import time

import controller as app


def _probe_identity(node):
    """Fields that define which Agent endpoint a probe belongs to."""
    return (
        node.get("id"),
        node.get("address", ""),
        int(node.get("agent_port", 9100)),
        node.get("token", ""),
    )


def poll_once():
    """Probe one snapshot and merge results into the newest state."""
    snapshot = app.load_state()
    results = []

    for node in snapshot.get("nodes", []):
        identity = _probe_identity(node)
        ok, payload = app.agent_request(node, "/v1/status", timeout=2.5)
        checked = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
        results.append((identity, ok, payload, checked))

    # Merge only probe-owned fields into the latest state. RLock is
    # intentionally re-entrant because load_state/save_state lock too.
    with app.LOCK:
        current = app.load_state()
        by_id = {node.get("id"): node for node in current.get("nodes", [])}

        for identity, ok, payload, checked in results:
            node_id = identity[0]
            node = by_id.get(node_id)
            if node is None:
                # Node was deleted while its Agent was being queried.
                continue
            if _probe_identity(node) != identity:
                # Address/port/token changed during the request. Discard the
                # stale result and let the next polling cycle probe new data.
                continue

            node["status"] = "up" if ok else (
                "auth_error" if payload.get("probe_error") == "auth" else "down"
            )
            node["last_check"] = checked
            node["probe_error"] = payload.get("probe_error", "")
            if ok:
                node["last_seen"] = checked
                node["metrics"] = payload

        app.save_state(current)


def safe_refresh_nodes():
    while True:
        poll_once()
        time.sleep(max(2, app.POLL_INTERVAL))


# main() resolves the global refresh_nodes when it creates its worker thread.
app.refresh_nodes = safe_refresh_nodes


if __name__ == "__main__":
    app.main()
