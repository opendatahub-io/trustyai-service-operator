# TrustyAI Kubernetes Operator
[![Controller Tests](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/controller-tests.yaml/badge.svg)](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/controller-tests.yaml)
[![YAML lint](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/lint-yaml.yaml/badge.svg)](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/lint-yaml.yaml)
[![Gosec Security Scan](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/gosec.yaml/badge.svg)](https://github.com/trustyai-explainability/trustyai-service-operator/actions/workflows/gosec.yaml)
[![Go Report Card](https://goreportcard.com/badge/github.com/trustyai-explainability/trustyai-service-operator)](https://goreportcard.com/report/github.com/trustyai-explainability/trustyai-service-operator)


## Overview

The TrustyAI Kubernetes Operator aims at simplifying the deployment and management of various TrustyAI Kubernetes components, such as:
- [TrustyAI Service](https://github.com/trustyai-explainability/trustyai-explainability): A service that deploys alongside KServe models and collects
inference data to enable model explainability, fairness monitoring, and drift tracking.
- [FMS-Guardrails](https://github.com/foundation-model-stack/fms-guardrails-orchestrator): A modular framework for guardrailing LLMs
- [LM-Eval](https://github.com/EleutherAI/lm-evaluation-harness/tree/main): A job-based architecture for deploying and managing LLM evaluations, based on EleutherAI's lm-evaluation-harness library.

## Prerequisites
- Kubernetes cluster v1.19+ or OpenShift cluster v4.6+
- `kubectl` v1.19+ or `oc` client v4.6+
- `kustomize` v5+
## Installation

This operator is available as an [image on Quay.io](https://quay.io/repository/trustyai/trustyai-service-operator?tab=history). 
To deploy it on your cluster:

```shell
OPERATOR_NAMESPACE=opendatahub
make manifest-gen NAMESPACE=$OPERATOR_NAMESPACE KUSTOMIZE=kustomize
oc apply -f release/trustyai_bundle.yaml -n $OPERATOR_NAMESPACE
```
You can also build your own image, and use that as your TrustyAI operator:

```shell
OPERATOR_NAMESPACE=opendatahub
OPERATOR_IMAGE=quay.io/yourorg/your-image-name:latest
podman build -t $OPERATOR_IMAGE --platform linux/amd64 -f Dockerfile .
podman push $OPERATOR_IMAGE
make manifest-gen NAMESPACE=$OPERATOR_NAMESPACE OPERATOR_IMAGE=$OPERATOR_IMAGE KUSTOMIZE=kustomize
oc apply -f release/trustyai_bundle.yaml -n $OPERATOR_NAMESPACE
```

## Usage
For usage information, please see the [OpenDataHub documentation of TrustyAI](https://opendatahub.io/docs/monitoring-data-science-models/#configuring-trustyai_monitor).

## Testing

### PR Integration Testing

Pull requests against this repository trigger automated integration tests via the [ODH Konflux Central pipeline](https://github.com/opendatahub-io/odh-konflux-central/pull/552). This pipeline:

- Provisions an ephemeral Hypershift cluster via EaaS (Ephemeral-as-a-Service)
- Deploys the opendatahub-operator
- Injects the TrustyAI operator image from the PR snapshot into the DataScienceCluster
- Runs opendatahub-operator e2e tests to validate TrustyAI integration
- Posts test results and artifacts back to the PR

The pipeline is defined in `odh-konflux-central/integration-tests/trustyai-service-operator/pr-testing-pipeline.yaml` and runs automatically on pull requests targeting the main branch. Test artifacts are available via the Konflux artifact browser.

### Konflux Integration Test Scenario (ITS) Setup

The TrustyAI Service Operator uses **Konflux Integration Test Scenarios (ITS)** for automated PR gating with cluster provisioning and testing. This setup consists of several components:

#### Components

1. **PR Build Pipeline (`.tekton` folder)**
   - Located in this repository's `.tekton` directory
   - Contains `trustyai-service-operator-pull-request.yaml` 
   - Automatically triggers component image builds on PR creation

2. **Integration Test Pipeline (`odh-konflux-central`)**
   - Centrally managed in the `opendatahub-io/odh-konflux-central` repository
   - Located at `integration-tests/trustyai-service-operator/pr-testing-pipeline.yaml`
   - Implements E2E test logic with the following tasks:
     - Parse metadata and check prerequisites
     - Provision EaaS space (`provision-eaas-space`)
     - Provision ephemeral cluster at runtime (`provision-cluster`)
     - Deploy and test (`deploy-and-test`)
   - Based on the template at `integration-tests/template/pr-its-pipelinerun.yaml`

3. **ITS Registration (`konflux-release-data`)**
   - Registered in `releng/konflux-release-data` GitLab repository
   - Configuration in `opendatahub-integration-test-scenarios.yaml`
   - Synced to cluster via ArgoCD

4. **PR Gating (Mergify)**
   - Configured via `.mergify.yml` in this repository
   - Enforces that PRs cannot be merged unless ITS tests pass
   - Available free for public repositories in the ODH GitHub organization

#### Debugging Failed Tests

The DevOps infrastructure provides automatic "Must-gather" support for Konflux ITS:
- Automatically collects cluster state and logs before cluster destruction
- Uploads artifacts to the OCI Artifact Browser for troubleshooting
- Available at: `https://app-artifact-browser.apps.rosa.konflux-qe.zmr9.p3.openshiftapps.com`

#### Setting Up ITS for New Components

**Prerequisite:** Component must be onboarded to ODH CI/Nightly builds.

1. **Enable PR Builds**
   - Add `.tekton` folder with pull request pipeline configuration

2. **Develop Integration Test Pipeline**
   - Fork `opendatahub-io/odh-konflux-central`
   - Create `integration-tests/<component>/` directory
   - Copy and customize `integration-tests/template/pr-its-pipelinerun.yaml`
   - Implement deploy and test logic (e.g., using `opendatahub-tests` with `uv run pytest`)

3. **Register ITS in Konflux**
   - In `releng/konflux-release-data` GitLab repo
   - Update `opendatahub-integration-test-scenarios.yaml`
   - Submit MR to main branch
   - Wait for ArgoCD reconciliation after merge

4. **Configure PR Gating**
   - Add `.mergify.yml` configuration to your repository
   - Define mandatory test checks and merge rules

#### Reusable Tasks

Available from `rhoai-konflux-tasks`:
- `generate-snapshot-for-group-testing`
- `trigger-group-testing`
- Additional tasks for common testing scenarios

## Contributing

Please see the [CONTRIBUTING.md](./CONTRIBUTING.md) file for more details on how to contribute to this project.

## License

This project is licensed under the Apache License Version 2.0 - see the [LICENSE](./LICENSE) file for details.
