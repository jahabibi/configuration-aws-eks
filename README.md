# AWS Compute Configuration

This repository contains an Upbound project, tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration provisions a fully managed Kubernetes cluster on AWS, backed by [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/).

The API is deliberately modeled as a **`Compute`** abstraction rather than an `EKS` one: the engine (EKS today) is an implementation detail selected by the composition, not a leaked API surface. Consumers express *intent* — capacity, version, who can administer the cluster — and the composition owns the mapping to provider machinery.

## Overview

The core components of a custom API in an [Upbound Project](https://docs.upbound.io/learn/control-plane-project/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Configures the Functions Pipeline
- **Embedded Function(s):** Encapsulates the Composition logic and implementation within a self-contained, reusable unit

In this specific configuration, the API contains:

- **a [`Compute`](/apis/eks/definition.yaml) custom resource type** (`computes.aws.platform.upbound.io`).
- **Composition:** Configured in [/apis/eks/composition.yaml](/apis/eks/composition.yaml)
- **Embedded Function:** The Composition logic is encapsulated within an [embedded function](/functions/eks/main.k)

## API design

This configuration was reworked to remove leaky provider- and Crossplane-specific fields from the consumer-facing contract. The `Compute` API speaks intent; the composition (Layer 3) translates that intent into provider managed resources.

| Consumer intent (`spec.parameters`) | What it maps to in the composition |
| --- | --- |
| `engine` (`eks`) | Selects the implementation. Additive enum — adding another engine later is not a new API. |
| `nodes.size` (`small`/`medium`/`large`) | Mapped to the current right instance type (e.g. `t3.small`). Consumers never name a provider instance type. |
| `adminPrincipals[]` | One EKS `AccessEntry` + `AccessPolicyAssociation` per cluster-admin principal. |
| `reclaimPolicy` (`Delete`/`Retain`, PV vocabulary) | Crossplane management policies. The contract speaks Kubernetes; only the composition speaks Crossplane. |
| `overrides.providerConfigName` | Bounded escape hatch for account/credential selection, with an explicit support boundary. |

Inter-domain wiring is handled without provider-MR label selectors:

- **`networkRef` / `subnetIds`** — subnet placement comes from the [Network](https://marketplace.upbound.io/configurations/upbound/configuration-aws-network) domain's published `status.zones[]`. When nested under a parent `Cluster`, the parent injects `subnetIds`; standalone, the referenced `Network` is fetched via extra-resources and its status is read.
- **Structured `status`** — `clusterName`, `networkId`, `oidcProviderArn`, `clusterSecurityGroupId`, `connectionConfigName`, `region`, and `version` form the inter-domain contract consumed by sibling domains (Identity, Ingress) instead of having them reach into the implementation.

## Deployment

- Execute `up project run`
- Alternatively, install the Configuration from the [Upbound Marketplace](https://marketplace.upbound.io/configurations/upbound/configuration-aws-eks)
- Check [examples](/examples/) for an example XR (Composite Resource)

This configuration depends on [`configuration-aws-network`](https://marketplace.upbound.io/configurations/upbound/configuration-aws-network) (`v3.0.0-dev.11`) for the `Network` domain it references, plus the Helm, Kubernetes, and AWS family providers (see [upbound.yaml](/upbound.yaml)).

> **Note:** standalone resolution of `networkRef` requires `function-kcl >= v0.11.6` (for `matchNamespace` support). Older runtimes silently query cluster-scoped and find nothing.

## Testing

The configuration can be tested using:

- `up composition render --xrd=apis/eks/definition.yaml apis/eks/composition.yaml examples/eks/eks-xr.yaml` to render the composition
- `up test run tests/*` to run the composition tests (`test-eks-cluster-security-group`, `test-eks-iam`, `test-eks-sequence`)
- `up test run tests/* --e2e` to run the end-to-end test in `tests/e2etest-eks/`

## Next steps

This repository serves as a foundational step. To enhance your configuration, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs

To learn more about how to build APIs for your managed control planes in Upbound, read the guide on [Upbound's docs](https://docs.upbound.io/).
