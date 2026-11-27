#!/usr/bin/env bash
# kube-linter entry point for trustyai-service-operator.
#
# Renders every deployment profile with the repository's pinned Kustomize
# (v5.7.0) and lints the rendered manifests with the pinned kube-linter
# (v0.8.3) using .kube-linter.yaml. Run from any directory:
#
#   make lint-manifests
#
# or directly:
#
#   bash ./hack/lint-manifests.sh
#
# Findings policy: selected-check findings fail the run by default. Set
# KUBE_LINTER_FAIL_ON_FINDINGS=false to warn and succeed (the CI workflow uses
# this while the check set is being triaged). Operational errors (render or
# lint failures, invalid reports) always fail.
#
# Set KUBE_LINTER_SARIF_DIR to a directory to collect a combined SARIF report
# (one category per profile) instead of discarding it.
set -euo pipefail

config=".kube-linter.yaml"
kube_linter_version="v0.8.3" # golang.stackrox.io/kube-linter
kustomize_version="v5.7.0"   # sigs.k8s.io/kustomize/kustomize/v5 (repository pin)

die() {
  printf 'kube-linter: ERROR: %s\n' "$1"
  exit 1
}

case "${KUBE_LINTER_FAIL_ON_FINDINGS-true}" in
  true) findings_level=ERROR ;;
  false) findings_level=WARNING ;;
  *) die "KUBE_LINTER_FAIL_ON_FINDINGS must be 'true' or 'false'" ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.." || die "cannot enter the repository root"
[ -f "$config" ] || die "lint configuration file is missing"
command -v go >/dev/null || die "Go is required"
command -v jq >/dev/null || die "jq is required"

umask 077
sarif_dir="${KUBE_LINTER_SARIF_DIR:-}"
if [ -n "$sarif_dir" ]; then
  mkdir -- "$sarif_dir" || die "cannot create the SARIF output directory"
  scratch="$sarif_dir/work"
  mkdir -- "$scratch" || die "cannot create temporary scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kube-linter.XXXXXX")" || die "cannot create temporary scratch"
fi
trap 'rm -rf -- "$scratch" 2>/dev/null || printf "%s\n" "kube-linter: WARNING: scratch cleanup failed"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
scratch_path="$(cd "$scratch" && pwd -P)" || die "cannot locate temporary scratch"
case "$scratch_path/" in "$(pwd -P)"/*) die "temporary scratch must be outside the repository" ;; esac

failed=0
incomplete=0
profiles=0

tool_log() {
  # Prefix tool text and neutralize legacy Actions command syntax.
  sed 's/[[:cntrl:]]/ /g; s/##\[/# #[/g; s/^/kube-linter:   /' "$1"
}

lint_profile() {
  local name="$1" entry="$2" status=0 summary operational count known=true
  local rendered="$scratch_path/$1.yaml" report="$scratch_path/$1.sarif"
  local diagnostics="$scratch_path/stderr" text="$scratch_path/report.txt"
  shift 2
  case "$name" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid lint profile name" ;; esac
  [ ! -e "$rendered" ] || die "duplicate lint profile name: $name"
  printf '%s\t%s\n' "$name" "$entry" >> "$scratch_path/profiles.tsv" || die "cannot record the lint profile"
  profiles=$((profiles + 1))
  if ! env GOFLAGS= GOWORK=off go run "$@" > "$rendered" 2> "$diagnostics"; then
    printf 'kube-linter: ERROR [%s] render failed (%s)\n' "$name" "$entry"
    tool_log "$diagnostics"
    failed=1 incomplete=1
    return
  fi
  if ! grep -Eq '^[[:space:]]*[^[:space:]#-]' "$rendered"; then
    printf 'kube-linter: ERROR [%s] render is empty (%s)\n' "$name" "$entry"
    failed=1 incomplete=1
    return
  fi
  tool_log "$diagnostics" || failed=1

  : > "$text" || die "cannot write the temporary text report"
  env GOFLAGS= GOWORK=off go run "golang.stackrox.io/kube-linter/cmd/kube-linter@$kube_linter_version" lint \
    --config "$config" --format plain --output "$text" --format sarif --output "$report" \
    --fail-if-no-objects-found --fail-on-invalid-resource "$rendered" > "$diagnostics" 2>&1 || status=$?
  if [ ! -s "$text" ] || ! IFS=$'\t' read -r summary operational count < <(jq -ers '
    select(length == 1) | .[0]
    | select(.version == "2.1.0" and (.runs | type == "array" and length == 1))
    | .runs[0]
    | select((.tool.driver.rules | type == "array" and length > 0)
        and all(.tool.driver.rules[]; .id | type == "string" and length > 0)
        and (.invocations[0].executionSuccessful | type == "boolean")
        and (.results == null or (.results | type == "array")))
    | (.tool.driver.rules | map(.id)) as $rules
    | (.results // []) as $results
    | select(all($results[]; (.message.text | type == "string")
        and (.ruleId as $id | $id == "failed-to-load-object" or ($rules | index($id) != null))))
    | [.invocations[0].executionSuccessful,
       ([$results[] | select(.ruleId == "failed-to-load-object" or
           (.message.text | startswith("error evaluating CEL check expression:")
                          or startswith("error while processing resource:")))] | length),
       ($results | length)] | @tsv
  ' "$report" 2>/dev/null); then
    printf 'kube-linter: ERROR [%s] missing or invalid lint report (%s)\n' "$name" "$entry"
    tool_log "$text"
    tool_log "$diagnostics"
    failed=1 incomplete=1
    return
  fi

  # go run can return 1 for both findings and tool failures. Check stderr
  # against the messages expected from pinned kube-linter v0.8.3.
  if ! awk -v status="$status" -v count="$count" '
    !NF || /^go: downloading / || /^go: toolchain / || /^Wrote (plain|sarif) output to / { next }
    /^Flag --fail-on-invalid-resource has been deprecated, Use \047schema-validation\047 builtin check or kubeconform template for better schema validation\.$/ { next }
    /^Error: found [0-9]+ lint errors?$/ && status == 1 && $3 == count && count > 0 { next }
    /^exit status 1$/ && status == 1 && count > 0 { next }
    { bad=1 }
    END { exit bad }
  ' "$diagnostics"; then
    known=false
    tool_log "$diagnostics"
  fi

  case "$known:$status:$summary:$operational:$count" in
    true:0:true:0:0) printf 'kube-linter: [%s] clean (%s)\n' "$name" "$entry" || failed=1 ;;
    true:1:false:0:[1-9]*)
      printf 'kube-linter: %s [%s] %s finding(s) (%s)\n' "$findings_level" "$name" "$count" "$entry" || failed=1
      if [ "$findings_level" = ERROR ]; then failed=1; fi
      ;;
    *)
      printf 'kube-linter: ERROR [%s] lint could not complete (%s, exit %s)\n' "$name" "$entry" "$status"
      failed=1 incomplete=1
      ;;
  esac
  tool_log "$text" || failed=1
}

# One profile per deployment context: the roots `make policy-check` renders
# (config/base + the six overlays) plus the module operator's own deployment
# root. trustyai-operator-module/config/manifests-template is byte-identical
# to config/ (enforced by the manifest-consistency workflow) and needs no
# separate profile.
lint_profile base config/base \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/base

lint_profile odh config/overlays/odh \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/odh

lint_profile rhoai config/overlays/rhoai \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/rhoai

lint_profile lmes config/overlays/lmes \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/lmes

lint_profile odh-kueue config/overlays/odh-kueue \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/odh-kueue

lint_profile testing config/overlays/testing \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/testing

lint_profile mcp-guardrails config/overlays/mcp-guardrails \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm config/overlays/mcp-guardrails

lint_profile module-default trustyai-operator-module/config/default \
  sigs.k8s.io/kustomize/kustomize/v5@"$kustomize_version" build --enable-helm trustyai-operator-module/config/default

if [ "$profiles" -eq 0 ]; then die "configure at least one lint profile"; fi
if [ "$incomplete" -eq 0 ] && [ -n "$sarif_dir" ]; then
  # Results must point at files committed to the repository: the renders are
  # temporary (deleted by the EXIT trap) and outside the checkout, so Code
  # Scanning can neither display nor fingerprint results that reference
  # them. Each profile's kustomization.yaml stands in for its rendered
  # corpus — an approximation, as kustomize combines several source files.
  # Every result in a profile would otherwise share the mapped file's
  # line-1 hash, so two objects failing the same check would merge into a
  # single alert (and a dismissal would apply to both); the
  # primaryLocationLineHash partial fingerprint — the only key Code
  # Scanning consumes, and one the upload action never overwrites — is
  # built from the result's own rule ID and object identity to keep them
  # distinct.
  while IFS=$'\t' read -r name entry; do
    [ -n "$name" ] || continue
    [ -f "$entry/kustomization.yaml" ] ||
      die "no committed kustomization.yaml to attribute profile $name findings to ($entry)"
  done < "$scratch_path/profiles.tsv"
  entries="$(jq -R -n 'reduce (inputs | split("\t")) as $row ({}; . + {($row[0]): ($row[1] + "/kustomization.yaml")})' \
    "$scratch_path/profiles.tsv")" || die "cannot build the profile-to-file mapping"
  # Each profile gets a stable Code Scanning category within the upload.
  jq -n --argjson entries "$entries" '
    def loc($k): [.locations[0].logicalLocations[]? | select(.kind == $k) | .name] | first // "";
    [inputs | (input_filename | split("/") | last | rtrimstr(".sarif")) as $profile
            | .runs[0].automationDetails.id = "kube-linter/\($profile)/"
            | .runs[0].results |= ((. // [])
              | map(
                  .partialFingerprints.primaryLocationLineHash =
                    ((.ruleId // "") + ":" + (loc("GVK/Kind") + "/" + loc("Object Namespace") + "/" + loc("Object Name")))
                  | .locations |= ((. // [])
                    | map(.physicalLocation.artifactLocation.uri = $entries[$profile]))))]
    | .[0] + {runs: map(.runs[0])}
  ' \
    "$scratch_path"/*.sarif > "$sarif_dir/report.sarif" || die "cannot write the combined SARIF report"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'sarif-ready=true\n' >> "$GITHUB_OUTPUT" || die "cannot publish the SARIF step output"
  fi
fi
exit "$failed"
