# Bootstrap readiness checks

Check the hub foundation after `bootstrap.sh`, then check the installed stack before moving to functional tests.

## Run after bootstrap

From the repository root, with your hub selected in kubeconfig:

```bash
./testing/scripts/check-grid-bootstrap.sh --stage import --wait 1800
```

When it exits successfully, proceed with spoke import and site selection. Workload Applications may still be pending at this stage. Requires Bash, `jq`, and `oc` or `kubectl`, with permission to read the checked resources.

## Run after site selection

After importing/selecting sites and completing the documented console secret creation step:

```bash
./testing/scripts/check-grid-bootstrap.sh --stage stack --wait 1800
```

To select a hub explicitly, add `--context YOUR_HUB_CONTEXT`. Run `--help` for all options. Without `--wait`, it performs one scan. The expected repository URL comes from the local `bootstrap/applicationset.yaml`; override it with `--repo URL` if needed. Profile defaults to auto-detection; `--profile combined` or `--profile dedicated-hub` asserts your intended profile.

## Results

- `OK`: check passed.
- `WAIT`: resource missing, inaccessible or not ready. Correct source/configuration errors before waiting further.
- Exit `0`: selected gate passed; continue to the next setup step.
- Exit `1`: checks pending or API access failed.
- Exit `2`: invalid arguments or missing local prerequisites.

`--wait` polls every 15 seconds. Each API call has a 10-second timeout, so the overall deadline can overrun by one scan. Stop with Ctrl-C.

## Checks and limits

The **import** gate checks the root source, foundation Applications, Argo controllers, ACM MultiClusterHub, hub membership, global cluster-set binding, governance/config-policy add-ons and registry pull Secret presence. It does not wait for every workload before importing spokes.

The **stack** gate adds expected root and recognized generated Application health, site selection, CA issuer and immutable bootstrap state. On the combined profile it also checks generated hub Applications, MaaS database, Keycloak, Grid operator/network, KServe/AIGrid conditions and console Deployment/Secret presence. The dedicated profile checks hub reconciliation and MaaS-home selection; verify remote site runtimes separately.

Checks only read cluster resources; they do not create, repair or delete anything. Secret checks request names only. A passing check does not establish credential validity, remote inference, cross-site connectivity, quota enforcement or complete policy compliance. An inference-only site's Argo health may need investigation even when its KServe/AIGrid components are ready.

The root ApplicationSet does not update itself from Git. After publishing a root source change, reapply the root for your profile using the hub onboarding guide, then rerun this checker. If console Secrets are missing, follow `apps/console/README.md` and its `create-secrets.sh` instructions.
