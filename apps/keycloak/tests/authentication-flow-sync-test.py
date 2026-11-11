#!/usr/bin/env python3
"""Exercise additive authentication-flow sync without a live Keycloak."""

import copy
import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "base/manifests/scripts/sync-saas-realm.py"
SPEC = importlib.util.spec_from_file_location("realm_sync", SCRIPT)
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)
ALIAS = "ai-grid-first-broker-login"
DEFINITION = {"authenticationFlows": [{
    "alias": ALIAS, "providerId": "basic-flow", "topLevel": True, "builtIn": False,
    "authenticationExecutions": [{"authenticator": "idp-create-user-if-unique", "requirement": "REQUIRED", "authenticatorFlow": False}],
}]}


class FakeAdmin:
    def __init__(self):
        self.flows = []
        self.executions = []
        self.writes = []

    def call(self, method, path, body=None):
        if method == "GET":
            return copy.deepcopy(self.flows if path == "/authentication/flows" else self.executions)
        self.writes.append((method, path, copy.deepcopy(body)))
        if method == "POST" and path == "/authentication/flows":
            self.flows.append(copy.deepcopy(body))
        elif method == "POST" and path.endswith("/executions/execution"):
            self.executions.append({"id": "exec-1", "providerId": body["provider"], "requirement": "DISABLED"})
        elif method == "PUT" and path.endswith("/executions"):
            self.executions = [copy.deepcopy(body) if item["id"] == body["id"] else item for item in self.executions]
        else:
            raise AssertionError((method, path))


class FlowSyncTest(unittest.TestCase):
    def test_missing_flow_is_created_and_retry_is_idempotent(self):
        admin = FakeAdmin()
        SYNC.sync_authentication_flows(admin, DEFINITION)
        self.assertEqual(admin.flows[0]["alias"], ALIAS)
        self.assertEqual(admin.executions[0]["requirement"], "REQUIRED")
        self.assertEqual(len(admin.writes), 3)
        admin.writes.clear()
        SYNC.sync_authentication_flows(admin, DEFINITION)
        self.assertEqual(admin.writes, [])

    def test_partial_creation_is_completed_without_recreating_flow(self):
        admin = FakeAdmin()
        admin.flows = [{"alias": ALIAS, "topLevel": True, "builtIn": False}]
        SYNC.sync_authentication_flows(admin, DEFINITION)
        self.assertEqual(len(admin.flows), 1)
        self.assertEqual(len(admin.executions), 1)
        self.assertEqual(len(admin.writes), 2)

    def test_unexpected_execution_is_rejected_without_writes(self):
        admin = FakeAdmin()
        admin.flows = [{"alias": ALIAS, "topLevel": True, "builtIn": False}]
        admin.executions = [{"id": "extra", "providerId": "idp-auto-link", "requirement": "ALTERNATIVE"}]
        with self.assertRaises(SYNC.Failure):
            SYNC.sync_authentication_flows(admin, DEFINITION)
        self.assertEqual(admin.writes, [])

    def test_no_declared_flows_performs_no_writes(self):
        admin = FakeAdmin()
        SYNC.sync_authentication_flows(admin, {})
        self.assertEqual(admin.writes, [])

    def test_builtin_flow_is_rejected_without_writes(self):
        admin = FakeAdmin()
        admin.flows = [{"alias": ALIAS, "topLevel": True, "builtIn": True}]
        with self.assertRaises(SYNC.Failure):
            SYNC.sync_authentication_flows(admin, DEFINITION)
        self.assertEqual(admin.writes, [])


if __name__ == "__main__":
    unittest.main()
