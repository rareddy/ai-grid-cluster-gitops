#!/usr/bin/env python3
"""Render the Keycloak overlays and check the identity contract."""

import json
import os
import subprocess

import yaml


APP = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ROOT = os.path.normpath(os.path.join(APP, "../.."))
OVERLAYS = ("core", "default", "direct")
FIRST_BROKER_LOGIN_FLOW = "first broker login"
LOCAL_MAPPER = "AI Grid local username"
PREFERRED_USERNAME_MAPPER = "AI Grid preferred username"
ORG_2 = "53d4f57e-3588-55e8-b96c-4ec54a7c42fa"


def render(overlay):
    output = subprocess.check_output(["kubectl", "kustomize", os.path.join(APP, "overlays", overlay)])
    return [document for document in yaml.safe_load_all(output) if document]


def realm_import(documents):
    found = [
        document
        for document in documents
        if document.get("kind") == "ConfigMap"
        and document["metadata"]["name"].startswith("keycloak-realm-import-")
    ]
    assert len(found) == 1, found
    return json.loads(found[0]["data"]["saas-realm.json"])


def tenant_realm(documents, name):
    found = [
        document
        for document in documents
        if document.get("kind") == "ConfigMap"
        and document["metadata"]["name"].startswith("keycloak-realm-import-")
    ]
    assert len(found) == 1, found
    return json.loads(found[0]["data"][name])


def check_flow(realm):
    assert "authenticationFlows" not in realm


def check_realm_sync_jobs(documents, overlay):
    names = {"keycloak-realm-sync-bootstrap", "keycloak-saas-realm-sync"}
    jobs = [document for document in documents
            if document.get("kind") == "Job" and document["metadata"]["name"] in names]
    if overlay == "direct":
        assert not jobs, jobs
        return
    assert {job["metadata"]["name"] for job in jobs} == names, jobs
    assert all(
        job["metadata"]["labels"]["app.kubernetes.io/name"] == job["metadata"]["name"]
        for job in jobs
    )


def check_client_scopes(realm):
    assert realm.get("clientScopes") is None, realm.get("clientScopes")
    client = next(
        client
        for client in realm["clients"]
        if client["clientId"] == "${KEYCLOAK_CLIENT_ID}"
    )
    assert {"profile", "email"} <= set(client["defaultClientScopes"])
    preferred = [
        mapper
        for mapper in client["protocolMappers"]
        if mapper["name"] == PREFERRED_USERNAME_MAPPER
    ]
    assert not preferred, preferred


def check_user_profile(realm):
    providers = realm["components"]["org.keycloak.userprofile.UserProfileProvider"]
    assert len(providers) == 1, providers
    config = json.loads(providers[0]["config"]["kc.user.profile.config"][0])
    attributes = {attribute["name"]: attribute for attribute in config["attributes"]}
    assert {"username", "email", "firstName", "lastName"} <= attributes.keys(), attributes
    username = attributes["username"]
    assert username["displayName"] == "${username}", username
    assert username["required"] == {}, username
    assert username["permissions"] == {"view": ["admin"], "edit": ["admin"]}, username
    assert username["validations"] == {
        "length": {"min": 3, "max": 255},
        "username-prohibited-characters": {},
        "up-username-not-idn-homograph": {},
    }, username
    for name in ("email", "firstName", "lastName"):
        attribute = attributes[name]
        assert attribute["required"] == {"roles": ["user"]}, attribute
        assert attribute["permissions"] == {
            "view": ["admin", "user"], "edit": ["admin", "user"]
        }, attribute
        assert attribute["validations"]["length"] == {"max": 255}, attribute
        validator = "email" if name == "email" else "person-name-prohibited-characters"
        assert attribute["validations"][validator] == {}, attribute
        assert attribute["displayName"] == "${%s}" % name, attribute
    assert config["groups"] == [{
        "name": "user-metadata",
        "displayHeader": "User metadata",
        "displayDescription": "Attributes, which refer to user metadata",
    }], config
    assert config["unmanagedAttributePolicy"] == "ADMIN_EDIT"


def check_identity_providers(realm):
    aliases = {"grid-tenant-1", "grid-tenant-2"}
    assert {provider["alias"] for provider in realm["identityProviders"]} == aliases
    for alias in aliases:
        provider = next(provider for provider in realm["identityProviders"] if provider["alias"] == alias)
        assert provider["firstBrokerLoginFlowAlias"] == FIRST_BROKER_LOGIN_FLOW
        mappers = [
            mapper
            for mapper in realm["identityProviderMappers"]
            if mapper["identityProviderAlias"] == alias
        ]
        local = next(mapper for mapper in mappers if mapper["name"] == LOCAL_MAPPER)
        assert local["identityProviderMapper"] == "oidc-username-idp-mapper"
        assert local["config"] == {
            "template": "${UUID}",
            "target": "LOCAL",
            "syncMode": "IMPORT",
        }
        preferred = next(mapper for mapper in mappers if mapper["name"] == PREFERRED_USERNAME_MAPPER)
        assert preferred["identityProviderMapper"] == "oidc-user-attribute-idp-mapper"
        assert preferred["config"] == {
            "claim": "preferred_username",
            "user.attribute": "maas_preferred_username",
            "syncMode": "FORCE",
        }


def check_tenant_2_fixture(documents):
    realm = tenant_realm(documents, "grid-tenant-2-idp-realm.json")
    groups = {group["name"] for group in realm["groups"]}
    assert "ai-grid-bob" in groups, groups
    alice = next(user for user in realm["users"] if user["username"] == "alice")
    bob = next(user for user in realm["users"] if user["username"] == "bob")
    carol = next(user for user in realm["users"] if user["username"] == "carol")
    assert alice["email"] != "alice@grid-tenant-1.test"
    assert alice["credentials"][0]["value"] == "${GRID_TENANT_2_TEST_USER_PASSWORD}"
    assert "/ai-grid-bob" in bob["groups"], bob["groups"]
    assert "/ai-grid-bob" not in alice["groups"], alice["groups"]
    assert "/ai-grid-bob" not in carol.get("groups", []), carol.get("groups", [])


def check_tenant_client_scopes(documents):
    for name in ("grid-tenant-1-idp-realm.json", "grid-tenant-2-idp-realm.json"):
        realm = tenant_realm(documents, name)
        client = next(client for client in realm["clients"] if client["clientId"] == "saas-broker")
        scopes = set(client.get("defaultClientScopes", []))
        assert {"profile", "email"} <= scopes, (name, scopes)


def check_maas_policy():
    path = os.path.join(
        ROOT,
        "apps/acm-models/maas/policies/"
        "20-tenant-53d4f57e-3588-55e8-b96c-4ec54a7c42fa-maas-policies.yaml",
    )
    with open(path) as stream:
        documents = list(yaml.safe_load_all(stream))
    assert len(documents) == 2, documents
    subscription, policy = documents
    assert subscription["spec"]["owner"] == {
        "groups": [{"name": f"{ORG_2}/ai-grid-bob"}]
    }
    assert policy["spec"]["subjects"] == {
        "groups": [{"name": f"{ORG_2}/ai-grid-bob"}]
    }


def main():
    realms = {}
    for overlay in OVERLAYS:
        documents = render(overlay)
        check_realm_sync_jobs(documents, overlay)
        realms[overlay] = realm_import(documents)
        check_flow(realms[overlay])
        check_client_scopes(realms[overlay])
        check_user_profile(realms[overlay])
        if overlay == "core":
            assert realms[overlay].get("identityProviders", []) == []
            assert realms[overlay].get("identityProviderMappers", []) == []
        else:
            check_identity_providers(realms[overlay])
            check_tenant_2_fixture(documents)
            check_tenant_client_scopes(documents)
    check_maas_policy()
    print("identity contract render checks: ok")


if __name__ == "__main__":
    main()
