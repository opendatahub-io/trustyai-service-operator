#!/usr/bin/env bash
# Konflux build simulator for trustyai-service-operator.
#
# Simulates, at PR time and locally, what the Konflux pipelines build for this
# repository and the contracts the shipped manifests must hold. Aimed at real
# failures that escaped review (ticket references inline); every check has
# been fault-injected to prove it fires.
#
# Modes (run one, or "all"):
#   static      Dockerfile COPY walk, params.env contract, webhook-cert naming
#   hermetic    GOPROXY=off builds for all three Go modules Konflux builds
#   manifests   overlay renders + manifest contracts + CRD schema + flag contract
#   images      container builds, --help, UID and bundled-manifests contracts
#   downstream  pinned red-hat-data-services build contract
#   drift       generated-artifact drift (make manifests/generate)
#
# Environment overrides:
#   CONTAINER_TOOL   podman (default) or docker
#   KUSTOMIZE_BIN    path to kustomize (default: kustomize on PATH, else bin/)
#   KUBECONFORM_BIN  path to kubeconform (default: kubeconform on PATH, else bin/)
#   PYTHON_BIN       python3 with PyYAML (default: auto-detected, uv fallback)
#   GO_BIN           go binary (default: go)
#   DOWNSTREAM_SHA   red-hat-data-services ref to check (default: pinned below)
#   DOWNSTREAM_DIR   use a local downstream checkout instead of cloning
#   BASE_REF         drift baseline (default: origin/main)
#   PLATFORM         image build platform (default: native)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
GO_BIN="${GO_BIN:-go}"
KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-}"
KUBECONFORM_BIN="${KUBECONFORM_BIN:-}"
PYTHON_BIN="${PYTHON_BIN:-}"
BASE_REF="${BASE_REF:-origin/main}"
PLATFORM="${PLATFORM:-linux/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"

# Pinned downstream build contract. Bump deliberately; a moving ref makes this
# check fail for reasons unrelated to the PR.
DOWNSTREAM_REPO="${DOWNSTREAM_REPO:-https://github.com/red-hat-data-services/trustyai-service-operator.git}"
DOWNSTREAM_SHA="${DOWNSTREAM_SHA:-0b032317296ccf1d459e92ec319e9e818e2538d9}"

# The three images Konflux builds from PRs (see downstream .tekton):
#   odh-trustyai-service-operator  <- Dockerfile (path-context .)
#   odh-ta-lmes-driver             <- Dockerfile.driver (path-context .)
#   odh-trustyai-module-operator   <- trustyai-operator-module/Dockerfile
#   (path-context ./trustyai-operator-module/, gomod + rpm prefetch)
# Dockerfile.lmes-job is NOT built by these pipelines and is not simulated
# here.
ROOT_DOCKERFILES=("Dockerfile" "Dockerfile.driver")
MODULE_CONTEXT="trustyai-operator-module"

OVERLAYS=("odh" "rhoai" "evalhub-only" "lmes" "mcp-guardrails" "odh-kueue" "testing")

WORKDIR="$(mktemp -d)"
trap 'chmod -R u+w "$WORKDIR" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

log()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
bad()  { printf '❌ %s\n' "$*"; }

# Download a release asset and verify it against a pinned SHA-256 before
# extraction (CWE-494): a substituted release asset must never execute.
# An empty expected digest fails closed — add a digest or set *_BIN.
verified_download() {
  local url="$1" asset="$2" expected="$3"
  if [ -z "$expected" ]; then
    bad "no pinned SHA-256 digest for $asset (add it to the digest table, or set the *_BIN override)"
    return 1
  fi
  curl -fsSL -o "$WORKDIR/$asset" "$url" || { bad "download failed: $asset"; return 1; }
  local actual
  actual=$({ sha256sum "$WORKDIR/$asset" 2>/dev/null || shasum -a 256 "$WORKDIR/$asset"; } | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    bad "$asset: SHA-256 mismatch (want $expected, got $actual) — refusing to extract"
    return 1
  fi
  tar xzf "$WORKDIR/$asset" -C "$WORKDIR"
}

resolve_tools() {
  if [ -z "$KUSTOMIZE_BIN" ]; then
    if command -v kustomize >/dev/null 2>&1; then
      KUSTOMIZE_BIN="$(command -v kustomize)"
    else
      log "fetching kustomize ${KUSTOMIZE_VERSION:-v5.7.0} (set KUSTOMIZE_BIN to override)"
      KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.7.0}"
      case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) asset="kustomize_${KUSTOMIZE_VERSION}_darwin_arm64.tar.gz" ;;
        Darwin-x86_64) asset="kustomize_${KUSTOMIZE_VERSION}_darwin_amd64.tar.gz" ;;
        Linux-arm64)  asset="kustomize_${KUSTOMIZE_VERSION}_linux_arm64.tar.gz" ;;
        *)            asset="kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" ;;
      esac
      # Pinned SHA-256 digests of the release assets (fail closed on any
      # version without a pinned digest — set KUSTOMIZE_BIN to override).
      case "$asset" in
        kustomize_v5.7.0_darwin_arm64.tar.gz) digest=c0dac68dc7870e1f673ae4d8fb554df971e0b9b9f0affc4be4c0852f62d0796e ;;
        kustomize_v5.7.0_darwin_amd64.tar.gz) digest=277a7401f969ce3945e8f0ff8b0cce6f4353854db1ff89ba070001e3246e7f22 ;;
        kustomize_v5.7.0_linux_arm64.tar.gz)  digest=744bb1bc1854b6634dea9eaf6db2f401a734ed25d6837baa6f91157d79c27d5e ;;
        kustomize_v5.7.0_linux_amd64.tar.gz)  digest=0d98f06d6d2c2c0ff8923cc136a517af74aaa187f1b9f3e17ff370d0625ede84 ;;
        *)                                     digest="" ;;
      esac
      verified_download \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/${asset}" \
        "$asset" "$digest" || exit 1
      KUSTOMIZE_BIN="$WORKDIR/kustomize"
    fi
  fi
  if [ -z "$KUBECONFORM_BIN" ]; then
    if command -v kubeconform >/dev/null 2>&1; then
      KUBECONFORM_BIN="$(command -v kubeconform)"
    else
      log "fetching kubeconform ${KUBECONFORM_VERSION:-v0.7.0} (set KUBECONFORM_BIN to override)"
      KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.7.0}"
      case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) asset="kubeconform-darwin-arm64.tar.gz" ;;
        Darwin-x86_64) asset="kubeconform-darwin-amd64.tar.gz" ;;
        Linux-arm64)  asset="kubeconform-linux-arm64.tar.gz" ;;
        *)            asset="kubeconform-linux-amd64.tar.gz" ;;
      esac
      case "$asset" in
        kubeconform-darwin-arm64.tar.gz) digest=b5d32b2cb77f9c781c976b20a85e2d0bc8f9184d5d1cfe665a2f31a19f99eeb9 ;;
        kubeconform-darwin-amd64.tar.gz) digest=c6771cc894d82e1b12f35ee797dcda1f7da6a3787aa30902a15c264056dd40d4 ;;
        kubeconform-linux-arm64.tar.gz)  digest=cc907ccf9e3c34523f0f32b69745265e0a6908ca85b92f41931d4537860eb83c ;;
        kubeconform-linux-amd64.tar.gz)  digest=c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3 ;;
        *)                                digest="" ;;
      esac
      verified_download \
        "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/${asset}" \
        "$asset" "$digest" || exit 1
      KUBECONFORM_BIN="$WORKDIR/kubeconform"
    fi
  fi
  if [ -z "$PYTHON_BIN" ]; then
    if python3 -c "import yaml" >/dev/null 2>&1; then
      PYTHON_BIN="python3"
    elif command -v uv >/dev/null 2>&1; then
      PYTHON_BIN="uv run --with pyyaml python3"
    else
      bad "no python3 with PyYAML available (install pyyaml, or set PYTHON_BIN)"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# static: build-input contracts that need no toolchain
# ---------------------------------------------------------------------------
mode_static() {
  local issues=0

  log "static: Dockerfile COPY sources exist in the build context"
  local dockerfile context_dir line token src
  for dockerfile in "${ROOT_DOCKERFILES[@]}"; do
    context_dir="$REPO_ROOT"
    check_dockerfile_copies "$dockerfile" "$context_dir" || issues=$((issues + 1))
  done
  check_dockerfile_copies "Dockerfile" "$REPO_ROOT/$MODULE_CONTEXT" || issues=$((issues + 1))
  [ "$issues" -eq 0 ] && ok "all COPY sources resolve"

  log "static: every \$(var) referenced by the base kustomization is defined"
  local declared defined ref
  declared=$(yq -r '.vars[].name' "$REPO_ROOT/config/base/kustomization.yaml" | sort -u)
  defined=$(grep -oE '^[a-zA-Z0-9_-]+=' "$REPO_ROOT/config/base/params.env" | tr -d '=' | sort -u)
  for ref in $declared; do
    if ! grep -Fqx -- "$ref" <<<"$defined"; then
      bad "var '$ref' is declared in config/base/kustomization.yaml but config/base/params.env does not define it"
      issues=$((issues + 1))
    fi
  done
  [ "$issues" -eq 0 ] && ok "vars resolve"

  log "static: serving-cert secret names are operator-prefixed (RHOAIENG-97774)"
  # A generic name like 'webhook-server-cert' collides with other operators in
  # the same namespace; the TLS hostname check then fails for one of them.
  # The tree still carries known violations, so fail only on names this PR
  # introduces and warn about the pre-existing ones (day-one-stale rule).
  local unprefixed_new unprefixed_all base_ref
  base_ref=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF" || true)
  unprefixed_all=$(grep -rhn "serving-cert-secret-name:" "$REPO_ROOT/config" --include="*.yaml" 2>/dev/null \
    | sed 's/.*serving-cert-secret-name:[[:space:]]*//' | tr -d '"' | grep -v '^$' | grep -v '^trustyai' | sort -u || true)
  if [ -n "$unprefixed_all" ]; then
    if [ -n "$base_ref" ]; then
      local unprefixed_base
      unprefixed_base=$(git -C "$REPO_ROOT" grep -h "serving-cert-secret-name:" "$base_ref" -- config '*.yaml' 2>/dev/null \
        | sed 's/.*serving-cert-secret-name:[[:space:]]*//' | tr -d '"' | grep -v '^$' | grep -v '^trustyai' | sort -u || true)
      unprefixed_new=$(comm -13 <(echo "$unprefixed_base") <(echo "$unprefixed_all") || true)
    else
      unprefixed_new="$unprefixed_all"
    fi
    if [ -n "$unprefixed_new" ]; then
      bad "new unprefixed serving-cert secret name(s); generic names collide with other operators (RHOAIENG-97774):"
      echo "$unprefixed_new" | sed 's/^/  /'
      issues=$((issues + 1))
    else
      printf 'WARN: %s pre-existing unprefixed serving-cert name(s) on %s (warn-only while main is stale):\n' \
        "$(wc -l <<<"$unprefixed_all" | tr -d ' ')" "$BASE_REF"
      echo "$unprefixed_all" | sed 's/^/  /'
    fi
  fi
  [ "$issues" -eq 0 ] && ok "no new unprefixed serving-cert names"

  log "static: floating :latest image tags (warning only — channels track them deliberately)"
  local latest
  latest=$(grep -h ":latest" "$REPO_ROOT"/config/overlays/*/params.env 2>/dev/null | sort -u || true)
  if [ -n "$latest" ]; then
    printf 'WARN: %s floating tags in overlay params.env\n' "$(wc -l <<<"$latest" | tr -d ' ')"
  else
    ok "no floating tags"
  fi

  if [ "$issues" -gt 0 ]; then
    bad "static: $issues issue(s)"
    exit 1
  fi
  ok "static: passed"
}

# Walk COPY instructions of a Dockerfile and assert every build-context source
# exists. Multi-stage aware: --from=<stage> sources are skipped (they are
# stage paths, not build-context paths), and so are absolute /stage paths.
check_dockerfile_copies() {
  local dockerfile="$1" context_dir="$2" failures=0
  local line tokens token src
  if [ ! -f "$context_dir/$dockerfile" ]; then
    bad "$dockerfile: no such file in $context_dir (fail closed)"
    return 1
  fi
  echo "  checking $dockerfile"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2206
    tokens=($line)
    # drop COPY keyword and flags (--chown=, --chmod=, ...). A --from flag
    # means the sources live in the source stage's filesystem, not the
    # build context — context validation does not apply to them. The flag
    # is matched at token level: a substring match on the whole line would
    # also skip sources whose names merely contain "--from=".
    local args=() has_from=0
    for token in "${tokens[@]:1}"; do
      [[ "$token" == --from=* ]] && has_from=1
      [[ "$token" == --* || "$token" == -* ]] && continue
      args+=("$token")
    done
    [ "$has_from" -eq 1 ] && continue
    [ "${#args[@]}" -lt 2 ] && continue
    # last token is the destination; sources may use dir-relative globs.
    # A leading / in a plain COPY is still build-context-root relative.
    for src in "${args[@]:0:${#args[@]}-1}"; do
      src="${src#/}"
      if ! glob_exists "$context_dir/$src"; then
        bad "$dockerfile: COPY source '$src' does not exist in the build context"
        failures=$((failures + 1))
      fi
    done
  done < <(grep -E '^(COPY|ADD)[[:space:]]' "$context_dir/$dockerfile" || true)
  return "$failures"
}

# True when a (possibly globbed) path matches at least one file. Literal paths
# are tested with -e (nullglob does not drop non-matching literals); globs
# are expanded with nullglob so no-match yields an empty list.
glob_exists() {
  case "$1" in
    *[\*\?\[]*)
      local matches=()
      shopt -s nullglob
      # shellcheck disable=SC2206
      matches=($1)
      shopt -u nullglob
      [ "${#matches[@]}" -gt 0 ]
      ;;
    *)
      [ -e "$1" ]
      ;;
  esac
}

# ---------------------------------------------------------------------------
# hermetic: prove the module graph is complete without network
# ---------------------------------------------------------------------------
hermetic_go_build() (
  local dir="$1" target="$2" label="$3"
  local workdir modcache
  workdir="$(mktemp -d)"
  trap 'chmod -R u+w "$workdir" 2>/dev/null || true; rm -rf "$workdir"' EXIT
  modcache="$workdir/gomodcache"

  echo "  [$label] network phase: populating isolated module cache"
  (cd "$dir" && GOTOOLCHAIN=auto GOMODCACHE="$modcache" GOFLAGS="-mod=readonly" \
    "$GO_BIN" mod download) || return 1
  (cd "$dir" && GOTOOLCHAIN=auto GOMODCACHE="$modcache" GOFLAGS="-mod=readonly" \
    "$GO_BIN" mod verify) >/dev/null || return 1

  echo "  [$label] offline phase: GOPROXY=off build (a missing prefetch fails here)"
  # CGO_ENABLED=0 GOOS=linux deviates from the Konflux link flags on purpose:
  # this preflight proves module-graph completeness, not linking; the link
  # flags are exercised by the images mode below.
  (cd "$dir" && GOTOOLCHAIN=auto GOMODCACHE="$modcache" GOPROXY=off GOFLAGS="-mod=readonly" \
    CGO_ENABLED=0 GOOS=linux "$GO_BIN" build -buildvcs=false -o "$workdir/app" "$target") || return 1
  echo "  [$label] offline build succeeded"
)

mode_hermetic() {
  log "hermetic: go mod verify + GOPROXY=off builds (Konflux builds are hermetic with gomod prefetch)"
  hermetic_go_build "$REPO_ROOT" "./cmd/main.go" "trustyai-service-operator" \
    || { bad "hermetic: manager build failed offline"; exit 1; }
  hermetic_go_build "$REPO_ROOT" "./cmd/lmes_driver" "ta-lmes-driver" \
    || { bad "hermetic: driver build failed offline"; exit 1; }
  hermetic_go_build "$REPO_ROOT/$MODULE_CONTEXT" "./cmd/trustyai-operator-module" "trustyai-operator-module" \
    || { bad "hermetic: module build failed offline"; exit 1; }
  ok "hermetic: all three modules build with GOPROXY=off"
}

# ---------------------------------------------------------------------------
# manifests: render every overlay the operator ships, then check contracts
# ---------------------------------------------------------------------------
mode_manifests() {
  resolve_tools
  local out="$WORKDIR/rendered"
  mkdir -p "$out"
  local issues=0 overlay

  log "manifests: kustomize build every shipped overlay"
  for overlay in "${OVERLAYS[@]}"; do
    echo "  rendering config/overlays/$overlay"
    "$KUSTOMIZE_BIN" build "$REPO_ROOT/config/overlays/$overlay" > "$out/$overlay.yaml" 2> "$out/$overlay.stderr" \
      || { bad "kustomize build config/overlays/$overlay failed:"; cat "$out/$overlay.stderr"; issues=$((issues + 1)); }
    grep -v "^#" "$out/$overlay.stderr" | grep -v "^$" || true
  done
  echo "  rendering $MODULE_CONTEXT/config/default (module operator)"
  "$KUSTOMIZE_BIN" build "$REPO_ROOT/$MODULE_CONTEXT/config/default" > "$out/module-operator.yaml" \
    || { bad "kustomize build module config/default failed"; issues=$((issues + 1)); }
  [ "$issues" -gt 0 ] && exit 1
  ok "all overlays render"

  log "manifests: no unresolved \$(var) placeholders survive rendering"
  local leftovers varname hits
  leftovers=""
  # Check for the var names kustomize actually substitutes; a bare '$(' grep
  # would false-positive on Kubernetes documentation text embedded in CRD
  # descriptions (env var expansion syntax).
  # Capture the declared vars with a checked command: a failed yq inside a
  # process substitution would silently yield no names and print a vacuous
  # "all vars substituted".
  local varlist vars_scan_failed=0
  if ! varlist=$(yq -r '.vars[].name' "$REPO_ROOT/config/base/kustomization.yaml" 2>/dev/null); then
    bad "vars check: cannot read declared vars from config/base/kustomization.yaml (yq failed) — refusing to pass vacuously"
    issues=$((issues + 1))
    varlist=""
    vars_scan_failed=1
  elif [ -z "$varlist" ]; then
    printf 'WARN: config/base/kustomization.yaml declares no vars; nothing to substitute-check\n'
  fi
  while IFS= read -r varname; do
    [ -z "$varname" ] && continue
    hits=$(grep -lF "\$($varname)" "$out"/*.yaml 2>/dev/null || true)
    if [ -n "$hits" ]; then
      leftovers="$leftovers [$varname: $(echo "$hits" | xargs -n1 basename | tr '\n' ' ')]"
    fi
  done <<<"$varlist"
  if [ -n "${leftovers// /}" ]; then
    bad "unresolved kustomize vars in renders:$leftovers"
    issues=$((issues + 1))
  elif [ "$vars_scan_failed" -eq 0 ]; then
    ok "all vars substituted"
  fi

  log "manifests: kubeconform schema validation + typo guard"
  # kubeconform's JSON output lists only resources with findings; skipped
  # kinds surface as statusError "could not find schema". Real external
  # CRD-backed kinds we render are allowlisted below — anything else failing
  # to resolve a schema is an apiVersion/kind typo.
  local kc_external=(
    "apiextensions.k8s.io/v1/CustomResourceDefinition"
    "monitoring.coreos.com/v1/ServiceMonitor"
    "monitoring.coreos.com/v1/PodMonitor"
    "monitoring.coreos.com/v1/Prometheus"
    "route.openshift.io/v1/Route"
  )
  local f
  for f in "$out"/*.yaml; do
    set +e
    "$KUBECONFORM_BIN" -strict -kubernetes-version 1.31.0 -output json "$f" > "$f.kc.json" 2>/dev/null
    set -e
    if [ ! -s "$f.kc.json" ]; then
      bad "kubeconform produced no output for $(basename "$f") (fail closed)"
      issues=$((issues + 1))
      continue
    fi
    if ! $PYTHON_BIN "$REPO_ROOT/scripts/manifest_contract.py" kc-report "$f.kc.json" "${kc_external[@]}"; then
      issues=$((issues + 1))
    fi
  done
  [ "$issues" -eq 0 ] && ok "kubeconform clean"

  log "manifests: CRs validate against the repo CRDs (RHOAIENG-100833/99770)"
  local crd_paths=()
  local c
  for c in "$REPO_ROOT"/config/components/*/crd/*.yaml; do
    [ -e "$c" ] && crd_paths+=("$c")
  done
  for c in "$REPO_ROOT/$MODULE_CONTEXT"/config/crd/bases/*.yaml; do
    [ -e "$c" ] && crd_paths+=("$c")
  done
  if [ "${#crd_paths[@]}" -eq 0 ]; then
    bad "no CRD schemas found under config/components/*/crd or module config/crd/bases (fail closed)"
    issues=$((issues + 1))
  else
    $PYTHON_BIN "$REPO_ROOT/scripts/manifest_contract.py" crd-validate \
      "${crd_paths[@]}" \
      -- \
      "$REPO_ROOT"/config/samples/*.yaml \
      "$REPO_ROOT/$MODULE_CONTEXT/tests/e2e/manifests/"*.yaml \
      || issues=$((issues + 1))
  fi

  log "manifests: manifest contracts on the rendered union"
  local check
  for check in duplicate-env rbac-subjects servicemonitor networkpolicy roleref; do
    $PYTHON_BIN "$REPO_ROOT/scripts/manifest_contract.py" "$check" "$out"/*.yaml \
      || issues=$((issues + 1))
  done

  log "manifests: manager flag contract (overlay flags vs binary --help)"
  # Two different operators ship from this repo: the root manager
  # (config/overlays/*) and the module operator (module-operator.yaml). Each
  # render's flags must be validated against the binary that render actually
  # deploys — the flag sets differ (only the root manager defines
  # --enable-services/--configmap), so comparing a render against the wrong
  # binary lets a flag the target rejects pass vacuously.
  check_flags_against_binary() {
    local binary="$1" label="$2"; shift 2
    local helpfile="$WORKDIR/help-$label.txt"
    "$binary" --help > "$helpfile" 2>&1 || true
    if ! grep -q "Usage of" "$helpfile"; then
      bad "$label: --help produced no usage output; refusing to compare (fail closed)"
      return 1
    fi
    # Fail closed: if flag extraction fails before printing anything, the
    # used-flags file would be empty, comm would find nothing missing, and
    # the check would pass vacuously.
    if ! $PYTHON_BIN "$REPO_ROOT/scripts/manifest_contract.py" manager-flags "$@" \
      | sort -u > "$WORKDIR/used-$label.txt"; then
      bad "$label: manager-flags extraction failed; refusing to compare (fail closed)"
      return 1
    fi
    if ! $PYTHON_BIN "$REPO_ROOT/scripts/manifest_contract.py" help-flags "$helpfile" \
      | sort -u > "$WORKDIR/known-$label.txt"; then
      bad "$label: help-flags extraction failed; refusing to compare (fail closed)"
      return 1
    fi
    local missing
    missing=$(comm -23 "$WORKDIR/used-$label.txt" "$WORKDIR/known-$label.txt")
    if [ -n "$missing" ]; then
      bad "$label render passes flag(s) its binary does not define:"
      echo "$missing"
      bad "the container exits during flag parsing and never reconciles (RHOAIENG-100779 shape)"
      return 1
    fi
    ok "all $label render flags are defined by the $label binary"
  }
  local binary="$WORKDIR/manager"
  (cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS="$(uname -s | tr '[:upper:]' '[:lower:]')" \
    "$GO_BIN" build -buildvcs=false -o "$binary" ./cmd/main.go) || issues=$((issues + 1))
  local module_binary="$WORKDIR/module-manager"
  (cd "$REPO_ROOT/$MODULE_CONTEXT" && CGO_ENABLED=0 GOOS="$(uname -s | tr '[:upper:]' '[:lower:]')" \
    "$GO_BIN" build -buildvcs=false -o "$module_binary" ./cmd/trustyai-operator-module) || issues=$((issues + 1))
  if [ "$issues" -eq 0 ]; then
    # root-manager renders: every overlay except the module operator's own
    local root_renders=() r
    for r in "$out"/*.yaml; do
      [ "$(basename "$r")" = "module-operator.yaml" ] || root_renders+=("$r")
    done
    check_flags_against_binary "$binary" "manager" "${root_renders[@]}" || issues=$((issues + 1))
    check_flags_against_binary "$module_binary" "module-operator" "$out/module-operator.yaml" \
      || issues=$((issues + 1))
  fi

  if [ "$issues" -gt 0 ]; then
    bad "manifests: $issues issue(s)"
    exit 1
  fi
  ok "manifests: passed"
}

# ---------------------------------------------------------------------------
# images: build and run the three images Konflux builds
# ---------------------------------------------------------------------------
run_image_help() {
  local image="$1" name="$2"
  # Go's flag package prints usage and exits 2 for -h/--help; both 0 and 2
  # with a usage banner prove the binary starts and parses flags.
  set +e
  "$CONTAINER_TOOL" run --rm "$image" --help > "$WORKDIR/$name.help" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
    bad "$name: --help exited $status"
    cat "$WORKDIR/$name.help"
    return 1
  fi
  if ! grep -q "Usage of" "$WORKDIR/$name.help"; then
    bad "$name: --help produced no usage banner"
    cat "$WORKDIR/$name.help"
    return 1
  fi
  ok "$name: binary starts and prints usage"
}

mode_images() {
  log "images: building with $CONTAINER_TOOL for $PLATFORM"
  local tag="konflux-sim-pr"
  local issues=0

  echo "  building manager (Dockerfile)"
  "$CONTAINER_TOOL" build --platform "$PLATFORM" -t "trustyai-service-operator:$tag" -f Dockerfile . \
    || { bad "manager image build failed"; exit 1; }
  echo "  building driver (Dockerfile.driver)"
  "$CONTAINER_TOOL" build --platform "$PLATFORM" -t "ta-lmes-driver:$tag" -f Dockerfile.driver . \
    || { bad "driver image build failed"; exit 1; }
  echo "  building module operator ($MODULE_CONTEXT/Dockerfile)"
  "$CONTAINER_TOOL" build --platform "$PLATFORM" -t "trustyai-operator-module:$tag" \
    -f "$MODULE_CONTEXT/Dockerfile" "$MODULE_CONTEXT" \
    || { bad "module image build failed"; exit 1; }

  log "images: --help contract"
  run_image_help "trustyai-service-operator:$tag" manager || issues=$((issues + 1))
  run_image_help "ta-lmes-driver:$tag" driver || issues=$((issues + 1))
  run_image_help "trustyai-operator-module:$tag" module || issues=$((issues + 1))

  log "images: non-root user contract"
  local user
  user=$("$CONTAINER_TOOL" inspect -f '{{.Config.User}}' "trustyai-service-operator:$tag")
  [ "$user" = "65532:65532" ] || { bad "manager runs as '$user', expected 65532:65532"; issues=$((issues + 1)); }
  user=$("$CONTAINER_TOOL" inspect -f '{{.Config.User}}' "ta-lmes-driver:$tag")
  [ "$user" = "65532:65532" ] || { bad "driver runs as '$user', expected 65532:65532"; issues=$((issues + 1)); }
  user=$("$CONTAINER_TOOL" inspect -f '{{.Config.User}}' "trustyai-operator-module:$tag")
  [ "$user" = "1000" ] || { bad "module operator runs as '$user', expected 1000"; issues=$((issues + 1)); }
  [ "$issues" -eq 0 ] && ok "all images run non-root as declared"

  log "images: module image bundles the manifests template (path contract)"
  # The module controller renders ODH/RHOAI overlays from /opt/manifests-template
  # at runtime; a mismatch between the Dockerfile COPY destination and the
  # controller's read path ships an operator that can never deploy its workload
  # (RHOAIENG-99568 shape).
  local bundled
  bundled=$("$CONTAINER_TOOL" run --rm --entrypoint /bin/sh "trustyai-operator-module:$tag" \
    -c 'ls /opt/manifests-template/overlays 2>/dev/null | tr "\n" " "' || true)
  for overlay in odh rhoai; do
    if ! grep -qw "$overlay" <<<"$bundled"; then
      bad "module image is missing /opt/manifests-template/overlays/$overlay (got: '${bundled}')"
      issues=$((issues + 1))
    fi
  done
  [ "$issues" -eq 0 ] && ok "module image bundles odh and rhoai overlays"

  if [ "$issues" -gt 0 ]; then
    bad "images: $issues issue(s)"
    exit 1
  fi
  ok "images: passed"
}

# ---------------------------------------------------------------------------
# downstream: the pinned red-hat-data-services Konflux build contract
# ---------------------------------------------------------------------------
mode_downstream() {
  local ds="$WORKDIR/downstream"
  if [ -n "${DOWNSTREAM_DIR:-}" ]; then
    ds="$DOWNSTREAM_DIR"
    echo "using local downstream checkout: $ds"
  else
    log "downstream: cloning $DOWNSTREAM_REPO at pinned ref ${DOWNSTREAM_SHA:0:12}"
    git clone --quiet --depth 1 "$DOWNSTREAM_REPO" "$ds" 2>/dev/null
    (cd "$ds" && git fetch --quiet --depth 1 origin "$DOWNSTREAM_SHA" && git checkout --quiet "$DOWNSTREAM_SHA") \
      || { bad "cannot pin downstream ref $DOWNSTREAM_SHA"; exit 1; }
  fi
  local issues=0

  # Fail closed: an empty or mis-shaped downstream checkout must not produce
  # a vacuous "contract holds". The pinned ref defines the expected shape:
  # the three konflux build targets (manager, driver, module).
  local n_prs=0 pr
  for pr in "$ds"/.tekton/*pull-request.yaml; do
    [ -e "$pr" ] && n_prs=$((n_prs + 1))
  done
  if [ "$n_prs" -lt 3 ]; then
    bad "downstream: expected at least 3 .tekton pull-request PipelineRuns (manager, driver, module) at the pinned ref, found $n_prs — refusing to pass vacuously"
    exit 1
  fi
  # Counting PipelineRuns is not enough: they could all build the same
  # target. Each of the three (path-context, dockerfile) build targets must
  # be referenced by at least one PipelineRun (exact line match).
  local pr_targets=""
  for pr in "$ds"/.tekton/*pull-request.yaml; do
    [ -e "$pr" ] || continue
    pr_targets+=$(yq -r '[.spec.params[] | select(.name == "path-context") | .value] + [.spec.params[] | select(.name == "dockerfile") | .value] | @tsv' "$pr" 2>/dev/null || true)$'\n'
  done
  local target
  # NB: the \t separators must be real tabs — printf, not "\t" in double
  # quotes (which bash leaves as a literal backslash-t).
  for target in "$(printf '.\tDockerfile.konflux')" "$(printf '.\tDockerfile.konflux.driver')" "$(printf './%s/\tDockerfile.konflux' "$MODULE_CONTEXT")"; do
    if ! grep -Fxq -- "$target" <<<"$pr_targets"; then
      bad "downstream: no PipelineRun builds target '$(echo "$target" | tr '\t' ' ')' at the pinned ref — refusing to pass vacuously"
      exit 1
    fi
  done
  local kd n_kd=0
  for kd in "$ds"/Dockerfile.konflux "$ds"/Dockerfile.konflux.driver "$ds/$MODULE_CONTEXT/Dockerfile.konflux"; do
    [ -f "$kd" ] && n_kd=$((n_kd + 1))
  done
  if [ "$n_kd" -ne 3 ]; then
    bad "downstream: expected the 3 konflux Dockerfiles (manager, driver, module) at the pinned ref, found $n_kd — refusing to pass vacuously"
    exit 1
  fi

  log "downstream: .tekton PipelineRuns point at paths that exist"
  local pr dockerfile path_context prefetch
  for pr in "$ds"/.tekton/*pull-request.yaml; do
    [ -e "$pr" ] || continue
    echo "  checking $(basename "$pr")"
    dockerfile=$(yq -r '.spec.params[] | select(.name == "dockerfile") | .value' "$pr")
    if [ ! -f "$ds/$dockerfile" ]; then
      bad "$(basename "$pr"): dockerfile '$dockerfile' does not exist in the downstream tree"
      issues=$((issues + 1))
    fi
    path_context=$(yq -r '.spec.params[] | select(.name == "path-context") | .value' "$pr")
    if [ ! -d "$ds/$path_context" ]; then
      bad "$(basename "$pr"): path-context '$path_context' does not exist"
      issues=$((issues + 1))
    fi
    # prefetch-input is a JSON array. The gomod paths are extracted with a
    # single yq pass — never re-encoded with to_json and split by lines:
    # yq >= 4.53 pretty-prints to_json, which silently turned this check
    # into a no-op (each JSON fragment failed the .type lookup and was
    # skipped). A parse failure on an existing param is reported instead
    # of silently disabling the check.
    local gomod_paths=""
    if yq -r '.spec.params[] | select(.name == "prefetch-input") | .value' "$pr" > "$WORKDIR/prefetch-$$.json" 2>/dev/null && [ -s "$WORKDIR/prefetch-$$.json" ]; then
      if ! gomod_paths=$(yq -p json -r '.[] | select(.type == "gomod") | .path // ""' "$WORKDIR/prefetch-$$.json" 2>/dev/null); then
        bad "$(basename "$pr"): prefetch-input is present but not parseable"
        issues=$((issues + 1))
      fi
    fi
    rm -f "$WORKDIR/prefetch-$$.json"
    # every gomod prefetch path must have a go.mod
    while IFS= read -r path; do
      [ -z "$path" ] || [ "$path" = "null" ] && continue
      if [ ! -f "$ds/$path/go.mod" ]; then
        bad "$(basename "$pr"): gomod prefetch path '$path' has no go.mod"
        issues=$((issues + 1))
      fi
    done <<<"$gomod_paths"
  done

  log "downstream: konflux Dockerfile COPY sources exist in this (upstream) tree"
  # The downstream Dockerfiles COPY source paths that must exist here; an
  # upstream reorganization breaks the downstream build on its next sync.
  local kd
  for kd in "$ds"/Dockerfile.konflux "$ds"/Dockerfile.konflux.driver "$ds/$MODULE_CONTEXT/Dockerfile.konflux"; do
    [ -f "$kd" ] || continue
    check_downstream_copies "$kd" || issues=$((issues + 1))
  done

  log "downstream: hermetic build posture"
  local f
  for f in "$ds"/Dockerfile.konflux "$ds"/Dockerfile.konflux.driver "$ds/$MODULE_CONTEXT/Dockerfile.konflux"; do
    [ -f "$f" ] || continue
    if ! grep -qE '^FROM .*@sha256:' "$f"; then
      printf 'WARN: %s has a floating (non digest-pinned) base image\n' "$(basename "$f")"
    fi
    if ! grep -q "strictfipsruntime" "$f"; then
      printf 'WARN: %s builds without strictfipsruntime\n' "$(basename "$f")"
    fi
  done
  if ! grep -q "strictfipsruntime" "$REPO_ROOT/Dockerfile"; then
    echo "WARN: upstream Dockerfile builds without strictfipsruntime while downstream konflux builds with it (FIPS posture diverges)"
  fi

  log "downstream: module rpm prefetch covers the Dockerfile installs"
  local installed locked
  if [ ! -f "$ds/$MODULE_CONTEXT/.konflux/rpms.in.yaml" ]; then
    bad "downstream: $MODULE_CONTEXT/.konflux/rpms.in.yaml not found at the pinned ref — cannot verify rpm prefetch"
    exit 1
  fi
  # Join backslash-continued lines (portable awk joiner — BSD sed has no
  # \n in s/// patterns), then capture EVERY package of each microdnf
  # install command — the previous two-package regex let a third package
  # escape the check.
  installed=$(awk '
      /\\$/ { sub(/\\$/, ""); buf = buf $0 " "; next }
      { line = buf $0; gsub(/[ \t]+/, " ", line); print line; buf = "" }
    ' "$ds/$MODULE_CONTEXT/Dockerfile.konflux" \
    | grep -oE 'microdnf install -y [a-zA-Z0-9@._-]+( [a-zA-Z0-9@._-]+)*' \
    | sed 's/^microdnf install -y //' | tr ' ' '\n' | sort -u || true)
  if [ -z "$installed" ]; then
    printf 'WARN: module Dockerfile installs no rpms; prefetch coverage is vacuous\n'
  fi
  locked=$(yq -r '.reinstallPackages[]' "$ds/$MODULE_CONTEXT/.konflux/rpms.in.yaml" 2>/dev/null | sort -u || true)
  locked="$locked
$(yq -r '.packages[]' "$ds/$MODULE_CONTEXT/.konflux/rpms.in.yaml" 2>/dev/null | sort -u || true)"
  local pkg
  for pkg in $installed; do
    if ! grep -Fqx -- "$pkg" <<<"$locked"; then
      bad "module Dockerfile installs rpm '$pkg' but .konflux/rpms.in.yaml does not prefetch it (hermetic build will fail)"
      issues=$((issues + 1))
    fi
  done
  [ "$issues" -eq 0 ] && ok "rpm prefetch covers microdnf installs"

  if [ "$issues" -gt 0 ]; then
    bad "downstream: $issues issue(s)"
    exit 1
  fi
  ok "downstream: contract holds at ${DOWNSTREAM_SHA:0:12}"
}

check_downstream_copies() {
  local kd="$1" failures=0 line tokens token src context_dir
  # COPY paths are relative to the build context: the module Dockerfile's
  # context is the module directory, the others the repo root.
  case "$kd" in
    *"$MODULE_CONTEXT"/*) context_dir="$REPO_ROOT/$MODULE_CONTEXT" ;;
    *)                    context_dir="$REPO_ROOT" ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2206
    tokens=($line)
    # drop COPY keyword and flags; a --from flag means the sources live in
    # the source stage's filesystem, not the build context. Matched at token
    # level so source names containing "--from=" stay validated.
    local args=() has_from=0
    for token in "${tokens[@]:1}"; do
      [[ "$token" == --from=* ]] && has_from=1
      [[ "$token" == --* || "$token" == -* ]] && continue
      args+=("$token")
    done
    [ "$has_from" -eq 1 ] && continue
    [ "${#args[@]}" -lt 2 ] && continue
    for src in "${args[@]:0:${#args[@]}-1}"; do
      src="${src#/}"
      if ! glob_exists "$context_dir/$src"; then
        bad "$(basename "$kd"): COPY source '$src' does not exist in the upstream tree (an upstream reorg breaks the downstream build)"
        failures=$((failures + 1))
      fi
    done
  done < <(grep -E '^(COPY|ADD)[[:space:]]' "$kd" || true)
  return "$failures"
}

# ---------------------------------------------------------------------------
# drift: generated artifacts match their sources
# ---------------------------------------------------------------------------
generate_into() {
  local src_ref="$1" dir="$2"
  git -C "$REPO_ROOT" archive "$src_ref" | tar x -C "$dir"
  # Snapshot the pristine state so regeneration can be diffed against it.
  (cd "$dir" \
    && git init -q . \
    && git config user.email konflux-sim@localhost \
    && git config user.name konflux-sim \
    && git add -A >/dev/null \
    && git commit -qm pristine) \
    || { bad "cannot snapshot pristine state for $src_ref"; return 1; }
  (cd "$dir" && make manifests generate manifests-tom generate-tom >/dev/null 2>&1) \
    || { bad "generation failed for $src_ref"; return 1; }
}

drifted_files() {
  local dir="$1"
  # Tracked changes AND new untracked artifacts: regeneration can also
  # create files the PR forgot to commit, which git diff alone never lists.
  (cd "$dir" && { git diff --name-only HEAD --; git ls-files --others --exclude-standard; } 2>/dev/null) | sort -u || true
}

# Whether a file drifting on both HEAD and the baseline is only the
# pre-existing baseline drift: the committed artifact AND its regeneration
# must both be identical on the two sides — the regeneration delta is then
# necessarily the same. Comparing the two contents directly (instead of
# diffing diffs) keeps full rule/field identity: normalized +/- line lists
# lose it, so the same added verb in a different RBAC rule would compare as
# the same drift. It also sidesteps git diff's blob IDs, hunk offsets and
# context, which pick up unrelated committed changes.
drift_is_preexisting() {
  local head_dir="$1" base_dir="$2" f="$3"
  # untracked at HEAD: no committed baseline to compare against — new drift
  git -C "$head_dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 || return 1
  # untracked at the baseline while tracked at HEAD: the PR newly tracks a
  # path the baseline only ever regenerated. Without this check, git show's
  # failure inside the process substitution below would surface as empty
  # output and compare equal to an empty committed file.
  git -C "$base_dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 || return 1
  git -C "$head_dir" show "HEAD:$f" 2>/dev/null | cmp -s - <(git -C "$base_dir" show "HEAD:$f" 2>/dev/null) || return 1
  # Identical deletions — both regenerations removed the file — are the
  # same pre-existing drift (cmp on two absent paths would fail). One-sided
  # absence still falls through to cmp and is classified as new drift.
  if [ ! -e "$head_dir/$f" ] && [ ! -e "$base_dir/$f" ]; then
    return 0
  fi
  cmp -s "$head_dir/$f" "$base_dir/$f"
}

mode_drift() {
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    bad "drift: working tree is dirty; commit or stash first (the check regenerates from HEAD)"
    exit 1
  fi
  log "drift: regenerating from HEAD (make manifests generate + module targets)"
  local head_dir="$WORKDIR/head"
  mkdir -p "$head_dir"
  generate_into HEAD "$head_dir" || exit 1
  local head_drift
  head_drift=$(drifted_files "$head_dir")
  if [ -z "$head_drift" ]; then
    ok "drift: HEAD is clean"
    return 0
  fi
  echo "regeneration changed files on HEAD:"
  echo "$head_drift" | sed 's/^/  /'

  log "drift: comparing against $BASE_REF (warn while main is already stale)"
  # Refresh the tracking ref for the baseline branch so a stale local
  # origin/main cannot grandfather drift that main has already fixed.
  # NB: fetching "origin/main" as a source ref is a silent no-op — the
  # remote advertises refs/heads/main, not refs/heads/origin/main.
  local base_branch
  base_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref "$BASE_REF" 2>/dev/null || true)
  base_branch="${base_branch#*/}"
  [ -n "$base_branch" ] || base_branch=main
  if ! git -C "$REPO_ROOT" fetch --quiet origin "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}" 2>/dev/null; then
    bad "drift: cannot refresh origin/${base_branch} to verify the baseline — continuing would classify this drift against a possibly stale baseline (fix network/remote access, or point BASE_REF at a ref you know is current)"
    exit 1
  fi
  local base_commit
  base_commit=$(git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF" 2>/dev/null || true)
  if [ -z "$base_commit" ]; then
    bad "drift: HEAD has generated-artifact drift and BASE_REF ${BASE_REF} cannot be resolved — no evidence the drift is pre-existing (set BASE_REF to a valid ref)"
    exit 1
  fi
  local base_dir="$WORKDIR/base"
  mkdir -p "$base_dir"
  generate_into "$base_commit" "$base_dir" || exit 1
  local base_drift new_drift f
  base_drift=$(drifted_files "$base_dir")
  new_drift=$(comm -23 <(echo "$head_drift") <(echo "$base_drift"))
  # A file drifting on both sides is only pre-existing if both the committed
  # artifact and its regeneration are identical on the two sides; a PR that
  # changes how a file drifts (or hand-edits a drifting artifact) is new
  # drift.
  for f in $(comm -12 <(echo "$head_drift") <(echo "$base_drift")); do
    if ! drift_is_preexisting "$head_dir" "$base_dir" "$f"; then
      new_drift="${new_drift:+$new_drift
}$f"
    fi
  done
  if [ -n "$new_drift" ]; then
    bad "drift: this PR changes generated inputs without regenerating:"
    echo "$new_drift" | sed 's/^/  /'
    bad "run 'make manifests generate manifests-tom generate-tom' and commit the result"
    exit 1
  fi
  echo "WARN: drift is pre-existing on $BASE_REF (warn-only while main is stale); no new drift introduced"
}

# ---------------------------------------------------------------------------

mode_all() {
  mode_static
  mode_hermetic
  mode_manifests
  mode_drift
  ok "all: passed"
}

case "${1:-}" in
  static)     mode_static ;;
  hermetic)   mode_hermetic ;;
  manifests)  mode_manifests ;;
  images)     mode_images ;;
  downstream) mode_downstream ;;
  drift)      mode_drift ;;
  all)        mode_all ;;
  *)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//g' | head -30
    echo "usage: $0 {static|hermetic|manifests|images|downstream|drift|all}"
    exit 2
    ;;
esac
