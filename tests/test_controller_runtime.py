#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "controller"))

import controller as app  # noqa: E402
import runtime  # noqa: E402


class ControllerRuntimeRaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_base = app.BASE
        self.old_state = app.STATE
        self.old_agent_request = app.agent_request
        app.BASE = self.tmp.name
        app.STATE = os.path.join(self.tmp.name, "controller-state.json")

    def tearDown(self):
        app.BASE = self.old_base
        app.STATE = self.old_state
        app.agent_request = self.old_agent_request
        self.tmp.cleanup()

    def test_stale_probe_does_not_overwrite_edited_endpoint(self):
        app.save_state({
            "version": 3,
            "language": "ru",
            "nodes": [{
                "id": "node1",
                "name": "PL",
                "address": "10.10.10.1",
                "agent_port": 9100,
                "token": "old-token",
                "status": "unknown",
            }],
        })

        def fake_agent_request(node, path, method="GET", payload=None, timeout=4):
            # Simulate a user/API edit while the old endpoint is still being
            # queried. The returning probe result belongs to old-token/address.
            with app.LOCK:
                current = app.load_state()
                current["nodes"][0]["address"] = "10.20.20.1"
                current["nodes"][0]["token"] = "new-token"
                current["nodes"][0]["status"] = "unknown"
                app.save_state(current)
            return True, {"telemt_info": {"active": True}, "source": "stale"}

        app.agent_request = fake_agent_request
        runtime.poll_once()

        node = app.load_state()["nodes"][0]
        self.assertEqual(node["address"], "10.20.20.1")
        self.assertEqual(node["token"], "new-token")
        self.assertEqual(node["status"], "unknown")
        self.assertNotIn("metrics", node)

    def test_concurrent_new_node_is_preserved(self):
        app.save_state({
            "version": 3,
            "language": "ru",
            "nodes": [{
                "id": "node1",
                "name": "PL1",
                "address": "10.10.10.1",
                "agent_port": 9100,
                "token": "token1",
                "status": "unknown",
            }],
        })

        def fake_agent_request(node, path, method="GET", payload=None, timeout=4):
            with app.LOCK:
                current = app.load_state()
                current["nodes"].append({
                    "id": "node2",
                    "name": "PL2",
                    "address": "10.10.20.1",
                    "agent_port": 9100,
                    "token": "token2",
                    "status": "unknown",
                })
                app.save_state(current)
            return True, {"telemt_info": {"active": True}}

        app.agent_request = fake_agent_request
        runtime.poll_once()

        state = app.load_state()
        self.assertEqual([n["id"] for n in state["nodes"]], ["node1", "node2"])
        self.assertEqual(state["nodes"][0]["status"], "up")
        self.assertEqual(state["nodes"][1]["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
