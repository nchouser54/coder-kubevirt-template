
# Coder Kubevirt Template

[![Apache 2.0 License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](https://choosealicense.com/licenses/apache-2.0/)

This project is a template to create reproducible dev environments in [Coder](https://github.com/coder/coder) using [Kubevirt](https://github.com/kubevirt/kubevirt) running on a Kubernetes cluster.

Coder enables organizations to set up development environments in their public or private cloud infrastructure. Cloud development environments are defined with Terraform, connected through a secure high-speed Wireguard® tunnel, and are automatically shut down when not in use to save on costs. Coder gives engineering teams the flexibility to use the cloud for workloads that are most beneficial to them.

KubeVirt is a virtual machine management add-on for Kubernetes. The aim is to provide a common ground for virtualization solutions on top of Kubernetes.

Read below for motive.

## Template variants

This repository now includes separate template directories:

- `kubevirt-provisioner/` → Linux workspace template
- `kubevirt-provisioner-windows/` → Windows workspace template (experimental)

Use the directory matching your workspace OS policy when pushing templates to Coder.

For image hardening and readiness details, see [`docs/image-prep-guide.md`](docs/image-prep-guide.md).

## Compatibility targets (March 2026)

This template is aligned to the following baseline:

| Component | Target |
| --- | --- |
| Coder channel | Stable |
| Coder server | v2.30.x |
| Terraform Coder provider | `coder/coder ~> 2.15.0` |
| Terraform Kubernetes provider | `hashicorp/kubernetes ~> 3.0.1` |
| KubeVirt | 1.7.x |
| Kubernetes | 1.34 (primary), 1.33/1.32 compatible via KubeVirt matrix |

See KubeVirt Kubernetes compatibility matrix: [k8s-support-matrix](https://github.com/kubevirt/sig-release/blob/main/releases/k8s-support-matrix.md)

## Pre-requisites

- A running kubernetes cluster with Kubevirt deployed. See Kubevirt [installation guide](https://kubevirt.io/user-guide/operations/installation).
- Containerized Data Importer (CDI) should be installed in the kubernetes cluster for PVC management. See CDI [installation guide](https://kubevirt.io/user-guide/operations/containerized_data_importer/).
- Default storage class configured in the kubernetes cluster.
- Bare-metal kubernetes cluster preferred. For kubernetes clusters running on top of VMs, nested-virtualization support is required.

### Kubernetes API Access Pre-requisite

If the Coder host is running outside the Kubernetes cluster (where workspace VMs will be deployed), a valid "~/.kube/config" must be present on the Coder host.

If Coder host is deployed on the same Kubernetes cluster (where workspace VMs will be deployed), a service account provisioned by coder will be used for workspace deployments.

In both cases, the service-account/user(in the kubeconfig) should have bindings for following roles:

| type | apiGroups | resources | verbs | namespace |
| --- | --- | --- | --- | --- |
| clusterrole | apiextensions.k8s.io | customresourcedefinitions | get, list, watch | - |
| clusterrole | kubevirt.io | virtualmachines | * | - |
| clusterrole | cdi.kubevirt.io | datavolumes | * | - |
| role | "" | secrets | * | namespace where workspace VMs will be deployed |
| role | "" | services | * | namespace where workspace VMs will be deployed |

Permission to access secret in the namespace where VMs are deployed is required to store cloud-init configs. This secret is then mount to workspace VMs as a cloud-init drive. Kubevirt only supports 2048 byte cloud-init config if set as string. To overcome this limit, Kubernetes secrets are used.

Permission to access service in the namespace where VMs are deployed is required to add DNS entry of VMs in the Kubernetes cluster. This way a VM created by this template can be accessed by another VM in the same cluster very easily. This can be done without DNS entry, and service as well, by referring to the "pod" IP address of the VM directly. This template runs VM network in `masquerade` mode. This means that the network VM will be is different than the k8s pod network. Network traffic is NAT'ed from VM network to pod network in `masquerade` mode. The VMs won't be accessible from other VMs by using the internal VM IP address. One has to use the "pod" IP address to access the VM. Since getting the pod IP address can only be done by someone who has access to the cluster, DNS entry is added to the k8s cluster instead. This way, anyone who uses coder and does not have access to the underlying k8s cluster will be able to access other VMs.

VMs created by this template can be accessed in the following format:
`coder-<owner>-<workspace-name>.<namespace>.svc.cluster.local`

## Features

- Provision KVM Virtual Machines as dev workspaces
- Persists whole root filesystem instead of just home directory
- Persists software installs in the OS
- Code server is enabled by default
- SSH is configured
- VMs can be started/stopped/restarted from Coder webapp without losing data
- Includes pre-configured Linux distributions:
- Ubuntu 22.04
- Debian 12
- Fedora 39
- Arch Linux
- AlmaLinux 9
- CentOS Stream 9
- Rocky Linux 9
- Automatically downloads OS drives from cloud to create disk PVCs
- Supports custom OS image URL selection per workspace
- Includes Coder SSH helper access
- Optional desktop forwarding app endpoint for images configured with web desktop tooling (for example noVNC)

## Installation

This installation assumes you have a Coder deployment running and CLI authenticated.

- Clone this repository

```sh
git clone https://github.com/sulo1337/coder-kubevirt-template.git && cd coder-kubevirt-template/kubevirt-provisioner
```

- Push the Linux template

```sh
coder templates push .
```

- Push the Windows template (from repo root)

```sh
cd kubevirt-provisioner-windows
coder templates push .
```

## Upgrade notes

- This template now uses `coder_workspace_owner` for workspace owner identity in resource naming.
- `coder_agent` startup behavior uses provider v2-compatible fields.
- Resource names are normalized to lowercase for Kubernetes DNS compatibility.
- This template supports `deployment_environment` profiles (`commercial` and `govcloud`) and artifact URL overrides for restricted networks.
- If you are upgrading from an older version of this template, run a plan first and review resource name diffs carefully before applying.

## Commercial vs GovCloud configuration

This template can run in both Commercial and GovCloud by selecting an environment profile and (optionally) overriding artifact sources.

Terraform variables added for this purpose:

- `deployment_environment` (default: `commercial`, allowed: `commercial`, `govcloud`)
- `os_image_urls` (map override for qcow image URLs, HTTPS only)
- `code_server_download_base_url` (default: GitHub releases URL, HTTPS only)
- `govcloud_strict_mode` (default: `false`; when `true`, enforces URL allowlist policy)
- `strict_allowed_url_prefixes` (list of allowed HTTPS URL prefixes used by strict mode)
- `enable_preflight_url_checks` (default: `true`; runs URL reachability checks before provisioning)

Example variable files are provided under `kubevirt-provisioner/env/`:

- `commercial.tfvars.example`
- `govcloud.tfvars.example`

Copy one to a local `.tfvars` file before use (these local files are intentionally git-ignored):

- `cp env/commercial.tfvars.example env/commercial.tfvars`
- `cp env/govcloud.tfvars.example env/govcloud.tfvars`

For restricted GovCloud or disconnected networks, point image and code-server URLs to internal mirrors/artifact repositories.

Recommended for GovCloud: set `govcloud_strict_mode = true` and define `strict_allowed_url_prefixes` to your approved internal domains.

## Custom images, SSH, and desktop forwarding

- **Custom images:** In workspace parameters, set **OS image source** to `Custom URL` and provide **Custom OS image URL**.
- **SSH access:** SSH helper is enabled by default in the template (`display_apps.ssh_helper = true`).
- **Desktop forwarding:** Set **Enable desktop forwarding app** to true and choose the **Desktop forwarding port** (default `6080`).

> Note: Desktop forwarding only works if the selected VM image or startup process runs a desktop web endpoint on the configured port.

Note: If **OS image source** is `Custom URL` but the URL is left empty, the template falls back to the selected catalog OS image instead of failing with an empty DataVolume URL.

Linux code-server bootstrap now validates the downloaded tarball against the release `sha256sum.txt` before extracting.

For the Windows template, provide a **required** Windows qcow image URL (Cloudbase-Init support recommended) and rely on Coder web terminal + port forwarding/desktop app behavior.

## Troubleshooting DataVolume/import lifecycle

If workspace startup fails around CDI or VM boot, check these common failure points:

- **DataVolume stuck in `ImportScheduled`:**
  - Confirm CDI controller is healthy.
  - Confirm target storage class supports requested PVC mode/size.
  - Confirm node scheduling constraints allow importer pod placement.
- **Image download failures (`ImagePullBackOff`, HTTP/TLS/auth errors):**
  - Verify image URL is reachable from cluster nodes/importer pods.
  - Verify TLS trust chain for internal endpoints.
  - Verify credentials/proxy/network policy for artifact endpoints.
- **Strict mode failures (`govcloud_strict_mode = true`):**
  - Ensure image/artifact URLs begin with one of `strict_allowed_url_prefixes`.
  - Ensure prefixes use HTTPS.
- **Preflight check failures:**
  - Ensure the Coder/Terraform execution environment has network access to required URLs.
  - Temporarily disable with `enable_preflight_url_checks = false` only for emergency diagnostics.

Useful workflow:

1. Inspect DataVolume status/events and importer pod logs.
2. Validate URL reachability from both Terraform runtime and cluster runtime.
3. Re-run with corrected URLs/prefixes.

## Defaults

These are the default values configured in the template. These values can be changed based on the requirements

- CPU - 2 cores
- Memory - 4Gi
- Disk Size - 16Gi
- Network configured in masquerade mode. See [kubevirt networking documentation](https://kubevirt.io/user-guide/virtual_machines/interfaces_and_networks/) for more details

## Roadmap

- Enable sourcing disk PVC creations from another PVC. Currently disk PVC data is sourced from qcow2 cloud images of various OS. This feature will allow a cluster administrator to pre-configure bootable image of an OS as PVC and use that PVC as a source to create new VM disk.
- Windows OS as VMs
- VNC
- Multi-disk VMs
- Shared disks as PVC attached to VMs allowing dev workspaces to share files.

## Notes

- Management of Kubevirt is out of scope of this repository
- VolumeSnapshot and PVC backups of VM disks is out of scope of this repository
- Default cloud-init is hardened: password login is disabled (`lock_passwd: true`, `ssh_pwauth: false`)
- code-server is installed from a pinned release artifact URL (no `curl | sh`)
- code-server runs with `--auth none` inside the VM and is expected to be accessed through Coder's authenticated workspace access path

## Motive

I created this template because of three reasons.

- To safely allow container runtimes to run inside coder workspace
- To utilize existing Kubernetes cluster to provision workspaces capable of running native container workloads
- To use existing bare-metal infrastructure for provisioning coder workspaces instead of using cloud providers (AWS, Azure etc)

There are other benefits to using Virtual Machine vs Containers for dev environments which is out of scope for this documentation.

Workspaces provisioned by Coder in Kubernetes are container environments in a pod. Most modern software development requires use of containerization technologies like Docker as a part of development workflow. According to [Coder Docs](https://coder.com/docs/v2/latest/templates/docker-in-workspaces), there are multiple ways to run container environments inside pods provisioned by Coder:

- Sysbox container runtime (needs specific infrastructure configuration, and enterprise license for [more features](https://github.com/nestybox/sysbox/blob/master/docs/figures/sysbox-features.png))
- Envbox*
- Rootless podman*
- Privileged docker sidecar*

*All of these methods either will make you create a privileged pod inside your cluster or have some privileged wrapper around your workspace (except rootless podman). Limitations of using rootless podman is out of scope for this documentation.

I created this template to extend Coder's functionality to provision VMs on existing Kubernetes clusters. KVM machines being used as coder workspaces unlocks these functionalities:

- docker inside coder workspaces
- systemd
- mini kubernetes environments inside coder workspaces using [minikube](https://github.com/kubernetes/minikube) or [kind](https://github.com/kubernetes-sigs/kind)
- access to raw devices (needs configuration)
- nested virtualization inside coder workspace (needs configuration)
- more isolation from host compared to pods
and many more...
