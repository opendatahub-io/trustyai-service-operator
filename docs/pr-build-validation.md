# PR Build Validation (Konflux build simulator)

`scripts/validate-build.sh` simulates, at PR time, what the Konflux pipelines
build from this repository and the contracts the shipped manifests must hold.
It runs in CI on every PR that touches build-relevant paths
(`.github/workflows/pr-build-validation.yml`) and can be run locally with the
same modes.

Konflux builds **three images** from this repository (see the downstream
`red-hat-data-services/trustyai-service-operator` `.tekton/` PipelineRuns):

| Image | Dockerfile | Context |
|-------|-----------|---------|
| `odh-trustyai-service-operator` | `Dockerfile` | `.` |
| `odh-ta-lmes-driver` | `Dockerfile.driver` | `.` |
| `odh-trustyai-module-operator` | `trustyai-operator-module/Dockerfile` | `./trustyai-operator-module/` |

`Dockerfile.lmes-job` is not built by these pipelines and is not simulated.

## Modes

```bash
./scripts/validate-build.sh static      # build-input contracts, no toolchain
./scripts/validate-build.sh hermetic    # GOPROXY=off builds of all three Go modules
./scripts/validate-build.sh manifests   # overlay renders + manifest contracts
./scripts/validate-build.sh images      # container builds + runtime contracts
./scripts/validate-build.sh downstream  # pinned downstream build contract
./scripts/validate-build.sh drift       # generated-artifact drift vs BASE_REF
./scripts/validate-build.sh all         # static + hermetic + manifests + drift
```

### static

- Every `COPY`/`ADD` source in the three Dockerfiles exists in its build
  context (a reorganization that breaks `docker build` fails here first).
- Every `$(var)` declared by `config/base/kustomization.yaml` is defined in
  `config/base/params.env`.
- New serving-cert secret names must be operator-prefixed
  (RHOAIENG-97774: generic `webhook-server-cert` collides with other
  operators in the same namespace). Pre-existing unprefixed names warn
  while they are cleaned up.

### hermetic

Konflux builds are hermetic: Go modules come from a `gomod` prefetch step,
not the network. The check populates an isolated module cache
(`go mod download` + `go mod verify`), then builds **all three modules**
with `GOPROXY=off` — a `go.sum` entry missed by the prefetch fails here
instead of in the Konflux build.

### manifests

- `kustomize build` of every shipped overlay (`odh`, `rhoai`, `evalhub-only`,
  `lmes`, `mcp-guardrails`, `odh-kueue`, `testing`) plus the module
  operator's `config/default`.
- No declared kustomize `$(var)` survives rendering unsubstituted.
- kubeconform in `-strict` mode as a typo guard: a built-in kind reported as
  "skipped" is treated as an apiVersion/kind typo.
- CR samples validate against the repo's CRD schemas, including field types
  (RHOAIENG-100833/99770: stored CRs with `permitCodeExecution: "deny"`
  string vs boolean CRD crash-looped the operator on decode). A CR whose
  group matches a repo CRD but whose kind does not is a hard failure.
- Manifest contracts over each rendered overlay (see
  `scripts/manifest_contract.py`):
  - `duplicate-env` — no container declares the same env var twice
    (the API server keeps only the last entry).
  - `rbac-subjects` — every RBAC subject and pod `serviceAccountName`
    resolves to a ServiceAccount in the same render
    (RHOAIENG-100514/100515 shape).
  - `servicemonitor` — selectors match Services, endpoint ports exist,
    `scheme: http` never targets a TLS port (RHOAIENG-54605/61424).
  - `networkpolicy` — every podSelector matches at least one workload pod
    in the same namespace (RHOAIENG-100577/100960).
  - `roleref` — every roleRef resolves to a rendered Role/ClusterRole
    (RHOAIENG-69405: ClusterRole existed, binding was missing); unreferenced
    ClusterRoles warn.
- Manager flag contract: every flag the overlays pass to the manager
  container must be defined by the binary's `--help` (the container exits
  during flag parsing otherwise).

Each rendered overlay is checked as an independent deployment unit — a
ServiceAccount rendered by one overlay never masks a missing one in another.

### images

Builds all three images with `podman` (or `docker`) and checks:

- `--help` starts and prints a usage banner (proves the binary links and
  parses flags — catches base-image and link-flag breakage).
- Non-root users: manager and driver as `65532:65532`, module as `1000`.
- The module image bundles `/opt/manifests-template/overlays/{odh,rhoai}`
  (the controller renders its workload from that path at runtime; a COPY
  path mismatch ships an operator that can never deploy its workload).

### downstream

Checks the pinned `red-hat-data-services/trustyai-service-operator` ref
(`DOWNSTREAM_SHA` in the script) — bump it deliberately:

- `.tekton` PipelineRuns point at Dockerfiles and path-contexts that exist.
- Every `gomod` prefetch path has a `go.mod`.
- The Konflux Dockerfiles' `COPY` sources exist in **this** tree (an
  upstream reorganization breaks the downstream build on its next sync).
- Module rpm prefetch (`.konflux/rpms.in.yaml`) covers the Dockerfile's
  `microdnf install` packages (hermetic builds cannot fetch unlisted rpms).
- FIPS posture: warns when upstream and downstream diverge on
  `strictfipsruntime`.

### drift

Regenerates from HEAD (`make manifests generate manifests-tom generate-tom`)
in an isolated copy and diffs:

- If regeneration changes files on HEAD, the PR must not **introduce**
  drift: the same regeneration is run on `BASE_REF` (default `origin/main`)
  and only new drift fails. Pre-existing drift on main warns, so the check
  can land on a stale tree and tighten over time.

## Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `CONTAINER_TOOL` | `podman` | `docker` on CI runners |
| `KUSTOMIZE_BIN` | auto-download v5.7.0 (repo pin) | use a local kustomize |
| `KUBECONFORM_BIN` | auto-download v0.7.0 | use a local kubeconform |
| `PYTHON_BIN` | auto (python3 with PyYAML, `uv` fallback) | interpreter for `manifest_contract.py` |
| `BASE_REF` | `origin/main` | drift baseline |
| `DOWNSTREAM_SHA` | pinned in script | downstream contract ref |
| `DOWNSTREAM_DIR` | clone at `DOWNSTREAM_SHA` | use a local downstream checkout |
| `PLATFORM` | native | image build platform |

## Adding checks

When a build or manifest failure escapes review, add a check that would have
caught it, reference the ticket in the failure message, and fault-inject the
check (break the tree, capture the failing output, revert) so there is proof
it fires. Checks must pass on a clean tree before they are merged.
