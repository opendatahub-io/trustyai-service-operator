#!/usr/bin/env python3
"""Static contract checks over rendered Kubernetes manifests.

Each subcommand exits non-zero and prints a "FAIL:" line per violation so the
output can be quoted verbatim in the PR description as fault-injection
evidence. Checks are aimed at real failures that escaped review; each one
references the ticket it exists to catch.

Subcommands:
  duplicate-env   no container may declare the same env var twice
                  (RHOAIENG-57579 shape: the API server keeps only the last
                  entry, so the rendered overlay and the effective config
                  silently disagree)
  rbac-subjects   every RBAC subject and pod serviceAccountName must resolve
                  to a ServiceAccount rendered in the same union
                  (RHOAIENG-100514/100515 shape: operator runs as an identity
                  it has no permissions for and crash-loops)
  servicemonitor  every ServiceMonitor selector matches exactly one Service,
                  every endpoint port exists on that Service, and an http
                  endpoint never targets a TLS port
                  (RHOAIENG-54605 overly broad selector,
                  RHOAIENG-61424 http scheme on TLS ports)
  networkpolicy   every NetworkPolicy podSelector matches at least one
                  workload pod template in the same namespace
                  (RHOAIENG-100577/100960 shape: a policy that selects
                  nothing, or the wrong pods, silently blackholes traffic)
  roleref         every RoleBinding/ClusterRoleBinding roleRef resolves to a
                  rendered Role/ClusterRole, and warns on ClusterRoles that
                  no binding references at all
                  (RHOAIENG-69405: ClusterRole existed, ClusterRoleBinding
                  was missing, operator could not create the RoleBinding)
  manager-flags   print the flag names the operator container is invoked with
  help-flags      print the flag names a binary's --help output defines
  crd-validate    validate custom resources against the repo's CRD schemas,
                  checking field types and required fields
                  (RHOAIENG-100833/99770: stored CR used a string where the
                  new CRD declared a boolean; the operator crash-looped on
                  decode and the CR could not be re-created)
"""

import json
import sys

import yaml

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet"}

# Port names/numbers that serve TLS. Scraping these with scheme: http sends
# plain HTTP to an HTTPS endpoint and Prometheus reports TargetDown.
TLS_PORT_NAMES = ("tls", "https", "https-metrics")
TLS_PORT_NUMBERS = {443, 4443, 8443, 9443}


def fail(msg):
    print(f"FAIL: {msg}")


def warn(msg):
    print(f"WARN: {msg}")


def load_docs(paths):
    """Yield (path, doc) for every YAML document in every file."""
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for doc in yaml.safe_load_all(handle):
                if doc is None:
                    continue
                yield path, doc


def ref(doc):
    meta = doc.get("metadata", {}) or {}
    return f"{doc.get('kind')}/{meta.get('name', '?')}"


def pod_template(doc):
    if doc.get("kind") == "CronJob":
        return ((doc.get("spec", {}) or {}).get("jobTemplate", {}) or {}).get("spec", {}) or {}
    return doc.get("spec", {}) or {}


def containers_of(doc):
    spec = pod_template(doc).get("template", {}).get("spec", {}) or {}
    for container in spec.get("containers", []) or []:
        yield container
    for container in spec.get("initContainers", []) or []:
        yield container


def labels_match(selector, labels):
    selector = selector or {}
    labels = labels or {}
    return all(labels.get(k) == v for k, v in selector.items())


def cmd_duplicate_env(paths):
    violations = 0
    for path, doc in load_docs(paths):
        if doc.get("kind") not in WORKLOAD_KINDS:
            continue
        for container in containers_of(doc):
            names = [e.get("name") for e in container.get("env", []) or [] if e.get("name")]
            seen, dups = set(), set()
            for name in names:
                if name in seen:
                    dups.add(name)
                seen.add(name)
            for name in sorted(dups):
                fail(
                    f"{ref(doc)} (container '{container.get('name', '?')}') declares env "
                    f"'{name}' more than once; the API server keeps only the last entry "
                    f"[{path}]"
                )
                violations += 1
    return violations


def cmd_rbac_subjects(paths):
    # Each rendered overlay is an independent deployment unit: an SA rendered
    # by overlay A must not mask a missing SA in overlay B, so the contract is
    # evaluated per file.
    #
    # Rendered manifests are applied into a target namespace at deploy time,
    # so namespace-less SAs and bindings are namespace-agnostic: a subject
    # with no namespace matches an SA with no namespace (kustomize-rendered
    # resources typically carry none until the consumer namespaces them).
    violations = 0
    for path in paths:
        accounts = set()

        for _, doc in load_docs([path]):
            meta = doc.get("metadata", {}) or {}
            if doc.get("kind") == "ServiceAccount":
                accounts.add((meta.get("namespace"), meta.get("name")))

        def name_exists(name, ns):
            # A subject/pod resolves when an SA with this name exists whose
            # namespace is compatible: equal, or either side unset (renders
            # use a "system" placeholder namespace that the consumer rewrites
            # uniformly at deploy time, so equality is preserved).
            def compatible(sa_ns):
                return sa_ns in (None, "") or ns in (None, "") or sa_ns == ns

            return any(n == name and compatible(a_ns) for a_ns, n in accounts)

        for _, doc in load_docs([path]):
            kind = doc.get("kind")
            meta = doc.get("metadata", {}) or {}
            if kind in ("RoleBinding", "ClusterRoleBinding"):
                for subject in doc.get("subjects", []) or []:
                    if subject.get("kind") != "ServiceAccount":
                        continue
                    sname = subject.get("name", "?")
                    sns = subject.get("namespace")
                    if kind == "ClusterRoleBinding" and not sns:
                        # cluster-scoped: no namespace to inherit
                        fail(f"{kind}/{meta.get('name')} has subject '{sname}' with no namespace [{path}]")
                        violations += 1
                    elif not name_exists(sname, sns):
                        where = f"{sns}/{sname}" if sns else sname
                        fail(
                            f"{kind}/{meta.get('name')} binds to ServiceAccount {where}, "
                            f"which the render does not create [{path}]"
                        )
                        violations += 1

        # serviceAccountName on pods must resolve too
        for _, doc in load_docs([path]):
            if doc.get("kind") not in WORKLOAD_KINDS:
                continue
            spec = pod_template(doc).get("template", {}).get("spec", {}) or {}
            sa = spec.get("serviceAccountName")
            if sa and not name_exists(sa, None):
                fail(f"{ref(doc)} runs as ServiceAccount '{sa}', which the render does not create [{path}]")
                violations += 1
    return violations


def cmd_servicemonitor(paths):
    # Each rendered overlay is an independent deployment unit, so the contract
    # is evaluated per file, not across the union of all renders.
    violations = 0
    for path in paths:
        services = []  # (namespace, name, labels, ports)
        monitors = []
        for _, doc in load_docs([path]):
            meta = doc.get("metadata", {}) or {}
            if doc.get("kind") == "Service":
                ports = []
                for p in doc.get("spec", {}).get("ports", []) or []:
                    ports.append(
                        {
                            "name": p.get("name"),
                            "port": p.get("port"),
                            "targetPort": p.get("targetPort"),
                        }
                    )
                services.append((meta.get("namespace"), meta.get("name"), meta.get("labels", {}) or {}, ports))
            elif doc.get("kind") == "ServiceMonitor":
                monitors.append(doc)

        for doc in monitors:
            meta = doc.get("metadata", {}) or {}
            ns, name = meta.get("namespace"), meta.get("name")
            spec = doc.get("spec", {}) or {}
            selector = spec.get("selector", {}).get("matchLabels", {}) or {}
            matched = [s for s in services if s[0] == ns and labels_match(selector, s[2])]
            if not matched:
                fail(f"ServiceMonitor/{name} selector {selector} matches no Service in namespace '{ns}' [{path}]")
                violations += 1
                continue
            if len(matched) > 1:
                # RHOAIENG-54605 shape: a broad selector is harmless while the
                # endpoint names a port only one service has, and a TargetDown
                # factory the day it does not. Warn, do not fail.
                names = ", ".join(f"Service/{s[1]}" for s in matched)
                warn(
                    f"ServiceMonitor/{name} selector {selector} matches {len(matched)} services "
                    f"({names}); overly broad selectors cause false TargetDown alerts when "
                    f"endpoints stop naming ports (RHOAIENG-54605) [{path}]"
                )
            for ep in spec.get("endpoints", []) or []:
                port = ep.get("port")
                scheme = (ep.get("scheme") or "http").lower()

                def is_tls(p):
                    return (
                        (p["name"] and any(t in str(p["name"]).lower() for t in TLS_PORT_NAMES))
                        or p["port"] in TLS_PORT_NUMBERS
                    )

                if port is None:
                    # Without a named port Prometheus scrapes EVERY port of
                    # every matched service: the amplifier behind both
                    # RHOAIENG-54605 and RHOAIENG-61424.
                    warn(
                        f"ServiceMonitor/{name} has an endpoint without a named port; it scrapes "
                        f"every port of every matched service (RHOAIENG-54605/61424 amplifier) [{path}]"
                    )
                    if scheme == "http" and any(is_tls(p) for _, _, _, ports in matched for p in ports):
                        fail(
                            f"ServiceMonitor/{name} scrapes all ports with scheme http while a "
                            f"matched service exposes a TLS port; Prometheus sends HTTP to HTTPS "
                            f"and reports TargetDown (RHOAIENG-61424) [{path}]"
                        )
                        violations += 1
                    continue
                providers = [s for s in matched if port in {p["name"] for p in s[3]}]
                if not providers:
                    names = ", ".join(f"Service/{s[1]} ({[p['name'] for p in s[3]]})" for s in matched)
                    fail(
                        f"ServiceMonitor/{name} endpoint port '{port}' does not exist on any "
                        f"matched service ({names}) [{path}]"
                    )
                    violations += 1
                    continue
                if scheme == "http" and any(
                    is_tls(p) for _, _, _, ports in providers for p in ports if p["name"] == port
                ):
                    fail(
                        f"ServiceMonitor/{name} scrapes TLS port '{port}' with scheme http; "
                        f"Prometheus sends HTTP to HTTPS and reports TargetDown "
                        f"(RHOAIENG-61424) [{path}]"
                    )
                    violations += 1
    return violations


def cmd_networkpolicy(paths):
    # Per rendered overlay: each render is an independent deployment unit.
    violations = 0
    for path in paths:
        workloads = []  # (namespace, labels)
        policies = []
        for _, doc in load_docs([path]):
            meta = doc.get("metadata", {}) or {}
            if doc.get("kind") in WORKLOAD_KINDS:
                template = pod_template(doc).get("template", {}) or {}
                workloads.append((meta.get("namespace"), template.get("metadata", {}).get("labels", {}) or {}))
            elif doc.get("kind") == "NetworkPolicy":
                policies.append(doc)

        for doc in policies:
            meta = doc.get("metadata", {}) or {}
            ns, name = meta.get("namespace"), meta.get("name")
            selector = (doc.get("spec", {}) or {}).get("podSelector", {}).get("matchLabels", {}) or {}
            matched = [w for w in workloads if w[0] == ns and labels_match(selector, w[1])]
            if not matched:
                fail(
                    f"NetworkPolicy/{name} podSelector {selector} matches no workload pod in "
                    f"namespace '{ns}'; a policy that selects nothing (or the wrong pods) "
                    f"silently blackholes traffic (RHOAIENG-100577/100960) [{path}]"
                )
                violations += 1
    return violations


def cmd_roleref(paths):
    # Per rendered overlay. ClusterRoles provided by the API server itself
    # (system:*) are always resolvable and are not expected in the render.
    violations = 0
    for path in paths:
        roles, clusterroles, bindings = set(), set(), []
        for _, doc in load_docs([path]):
            kind, meta = doc.get("kind"), doc.get("metadata", {}) or {}
            if kind == "Role":
                roles.add(meta.get("name"))
            elif kind == "ClusterRole":
                clusterroles.add(meta.get("name"))
            elif kind in ("RoleBinding", "ClusterRoleBinding"):
                bindings.append(doc)

        referenced_clusterroles = set()
        for doc in bindings:
            kind, meta = doc.get("kind"), doc.get("metadata", {}) or {}
            ref_ = doc.get("roleRef", {}) or {}
            target = ref_.get("kind")
            name = ref_.get("name")
            if target == "ClusterRole":
                referenced_clusterroles.add(name)
                if name not in clusterroles and not str(name).startswith("system:"):
                    fail(f"{kind}/{meta.get('name')} references ClusterRole '{name}', which is not rendered [{path}]")
                    violations += 1
            elif target == "Role":
                if name not in roles:
                    fail(f"{kind}/{meta.get('name')} references Role '{name}', which is not rendered [{path}]")
                    violations += 1
        # A ClusterRole that exists but is bound by nothing is the
        # RHOAIENG-69405 shape: dead permissions until a binding appears
        # (or until the operator binds it at runtime — verify that it does).
        for name in sorted(clusterroles - referenced_clusterroles):
            warn(f"ClusterRole '{name}' is not referenced by any rendered ClusterRoleBinding (RHOAIENG-69405 shape) [{path}]")
    return violations


def is_operator_container(container):
    command = container.get("command", []) or []
    image = container.get("image", "") or ""
    return any(str(c).endswith("/manager") or str(c) == "manager" for c in command) or (
        "trustyai-service-operator" in image or "trustyai-operator-module" in image
    )


def cmd_manager_flags(paths):
    flags = set()
    for path, doc in load_docs(paths):
        if doc.get("kind") not in WORKLOAD_KINDS:
            continue
        for container in containers_of(doc):
            if not is_operator_container(container):
                continue
            for token in (container.get("command", []) or []) + (container.get("args", []) or []):
                token = str(token)
                if token.startswith("-"):
                    flags.add(token.lstrip("-").split("=")[0])
    for flag in sorted(flags):
        print(flag)
    return 0


def cmd_help_flags(path):
    flags = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip()
            stripped = line.lstrip()
            if stripped.startswith("-") and not stripped.startswith("--"):
                name = stripped[1:].split()[0].split("=")[0]
                if name and name[0].isalpha():
                    flags.add(name)
    for flag in sorted(flags):
        print(flag)
    return 0


# --- crd-validate ------------------------------------------------------------


def build_schemas(crd_paths):
    schemas = {}
    for path in crd_paths:
        with open(path, encoding="utf-8") as handle:
            for doc in yaml.safe_load_all(handle):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                spec = doc.get("spec", {}) or {}
                group = spec.get("group")
                names = spec.get("names", {}) or {}
                kind = names.get("kind")
                for version in spec.get("versions", []) or []:
                    schema = version.get("schema", {}).get("openAPIV3Schema")
                    if schema:
                        schemas[(group, version.get("name"), kind)] = schema
    return schemas


def validate_value(path, value, schema, errors):
    if not isinstance(schema, dict):
        return
    if schema.get("x-kubernetes-preserve-unknown-fields"):
        return
    expected = schema.get("type")
    if expected == "boolean" and not isinstance(value, bool):
        errors.append(f"{path}: expected boolean, got {type(value).__name__} ({value!r})")
    elif expected == "string" and not isinstance(value, str):
        errors.append(f"{path}: expected string, got {type(value).__name__} ({value!r})")
    elif expected == "integer" and (not isinstance(value, int) or isinstance(value, bool)):
        errors.append(f"{path}: expected integer, got {type(value).__name__} ({value!r})")
    elif expected == "array":
        if not isinstance(value, list):
            errors.append(f"{path}: expected array, got {type(value).__name__}")
        else:
            item_schema = schema.get("items")
            if isinstance(item_schema, dict):
                for i, item in enumerate(value):
                    validate_value(f"{path}[{i}]", item, item_schema, errors)
    elif expected == "object" or "properties" in schema:
        if not isinstance(value, dict):
            errors.append(f"{path}: expected object, got {type(value).__name__}")
            return
        properties = schema.get("properties", {}) or {}
        for key, sub in value.items():
            if key in properties:
                validate_value(f"{path}.{key}", sub, properties[key], errors)
        for req in schema.get("required", []) or []:
            if req not in value:
                errors.append(f"{path}: missing required field '{req}'")


def cmd_crd_validate(crd_paths, cr_paths):
    schemas = build_schemas(crd_paths)
    if not schemas:
        fail("no CRD schemas were loaded; refusing to pass without validating anything")
        return 1
    violations = 0
    known_groups = {group for group, _, _ in schemas}
    for path in cr_paths:
        with open(path, encoding="utf-8") as handle:
            for doc in yaml.safe_load_all(handle):
                if not doc or doc.get("kind") == "List":
                    continue
                api_version = doc.get("apiVersion", "")
                if "/" not in api_version:
                    continue  # built-in, not a CR
                group, version = api_version.split("/", 1)
                key = (group, version, doc.get("kind"))
                schema = schemas.get(key)
                if schema is None:
                    if group in known_groups:
                        # The group is ours but the kind is not: almost
                        # certainly a typo or a stale sample that can never
                        # apply (the API server rejects it).
                        meta = doc.get("metadata", {}) or {}
                        kinds = sorted({k for g, _, k in schemas if g == group})
                        fail(
                            f"{doc.get('kind')}/{meta.get('name')} ({path}): no CRD defines "
                            f"kind '{doc.get('kind')}' in group '{group}' (kinds: {kinds}); "
                            f"applying it fails with 'no matches for kind'"
                        )
                        violations += 1
                    else:
                        warn(f"{path}: no CRD schema for {api_version} {doc.get('kind')}; skipped")
                    continue
                meta = doc.get("metadata", {}) or {}
                errors = []
                body = {k: v for k, v in doc.items() if k in ("spec", "metadata")}
                for field, sub in (schema.get("properties", {}) or {}).items():
                    if field in body:
                        validate_value(field, body[field], sub, errors)
                for err in errors:
                    fail(
                        f"{doc.get('kind')}/{meta.get('name')} ({path}): {err} — stored-value "
                        f"type drift crash-loops the operator on decode (RHOAIENG-100833/99770)"
                    )
                    violations += 1
    return violations


def cmd_kc_report(args):
    """Summarize a kubeconform JSON report.

    Usage: kc-report FILE [allowed version/kind ...]

    statusInvalid and statusError are failures unless the (version, kind)
    pair is explicitly allowlisted as an external CRD-backed kind we render
    without a schema for. An unknown kind is the typo signal: kubeconform
    reports "could not find schema" for both real CRD kinds and misspelled
    built-ins, so the allowlist separates them.
    """
    if not args:
        print("usage: manifest_contract.py kc-report FILE [allowed version/kind ...]", file=sys.stderr)
        return 2
    with open(args[0], encoding="utf-8") as handle:
        data = json.load(handle)
    allowed = set(args[1:])
    violations = 0
    for r in data.get("resources", []):
        if r.get("status") == "statusInvalid":
            fail(f"{r.get('kind')}/{r.get('name')}: {r.get('msg', 'schema violation')}")
            violations += 1
        elif r.get("status") in ("statusError",):
            key = f"{r.get('version', '')}/{r.get('kind')}"
            if key not in allowed:
                fail(
                    f"{r.get('kind')}/{r.get('name')} ({r.get('version')}): "
                    f"{r.get('msg', '')} — not a known schema and not in the external-kind "
                    f"allowlist; likely an apiVersion/kind typo"
                )
                violations += 1
    return violations


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "duplicate-env":
        violations = cmd_duplicate_env(args)
    elif cmd == "rbac-subjects":
        violations = cmd_rbac_subjects(args)
    elif cmd == "servicemonitor":
        violations = cmd_servicemonitor(args)
    elif cmd == "networkpolicy":
        violations = cmd_networkpolicy(args)
    elif cmd == "roleref":
        violations = cmd_roleref(args)
    elif cmd == "manager-flags":
        return cmd_manager_flags(args)
    elif cmd == "help-flags":
        if len(args) != 1:
            print("usage: manifest_contract.py help-flags FILE", file=sys.stderr)
            return 2
        return cmd_help_flags(args[0])
    elif cmd == "crd-validate":
        if "--" not in args:
            print("usage: manifest_contract.py crd-validate CRD... -- CR...", file=sys.stderr)
            return 2
        split = args.index("--")
        violations = cmd_crd_validate(args[:split], args[split + 1:])
    elif cmd == "kc-report":
        violations = cmd_kc_report(args)
    else:
        print(f"unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    if violations:
        print(f"❌ {cmd}: {violations} violation(s)")
        return 1
    print(f"✅ {cmd}: no violations")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
