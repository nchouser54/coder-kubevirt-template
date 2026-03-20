terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.15.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0.1"
    }
  }
}

variable "namespace" {
  description = <<-EOF
  Kubernetes namespace to deploy the workspace VM into

  EOF
  default     = "coder"
}

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}

variable "deployment_environment" {
  type        = string
  description = "Deployment environment profile used for defaults (commercial or govcloud)."
  default     = "commercial"

  validation {
    condition     = contains(["commercial", "govcloud"], var.deployment_environment)
    error_message = "deployment_environment must be one of: commercial, govcloud."
  }
}

variable "govcloud_strict_mode" {
  type        = bool
  description = "When true, enforce strict URL policy checks for OS image and code-server artifact sources."
  default     = false
}

variable "strict_allowed_url_prefixes" {
  type        = list(string)
  description = "Allowed URL prefixes enforced when govcloud_strict_mode is true (for example https://artifacts.internal.example/)."
  default     = []

  validation {
    condition     = alltrue([for prefix in var.strict_allowed_url_prefixes : can(regex("^https://.+$", prefix))])
    error_message = "strict_allowed_url_prefixes values must be valid https:// URL prefixes."
  }
}

variable "os_image_urls" {
  type        = map(string)
  description = "Optional override map of OS qcow image URLs by key (ubuntu_2204, fedora_39, debian_12, arch_latest, almalinux_9, centos_stream_9, rocky_9)."
  default     = {}

  validation {
    condition     = alltrue([for url in values(var.os_image_urls) : can(regex("^https://.+$", url))])
    error_message = "All os_image_urls entries must be valid https:// URLs."
  }
}

variable "code_server_download_base_url" {
  type        = string
  description = "Base URL for code-server release artifacts. Override with an internal mirror for restricted environments."
  default     = "https://github.com/coder/code-server/releases/download"

  validation {
    condition     = can(regex("^https://.+$", var.code_server_download_base_url))
    error_message = "code_server_download_base_url must be a valid https:// URL."
  }
}

variable "enable_preflight_url_checks" {
  type        = bool
  description = "Run local preflight HEAD checks for required image/artifact URLs before creating DataVolume/VM resources."
  default     = true
}

provider "coder" {
}

provider "kubernetes" {
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {

}

data "coder_workspace_owner" "me" {
}

locals {
  workspace_owner = lower(data.coder_workspace_owner.me.name)
  workspace_name  = lower(data.coder_workspace.me.name)
  workspace_id    = "coder-${local.workspace_owner}-${local.workspace_name}"

  cloudinit_secret_name = "${local.workspace_id}-cloudinit"
  rootfs_name           = "${local.workspace_id}-rootfs"

  os_image_catalog = {
    commercial = {
      ubuntu_2204     = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img"
      fedora_39       = "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2"
      debian_12       = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      arch_latest     = "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
      almalinux_9     = "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
      centos_stream_9 = "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
      rocky_9         = "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
    }
    govcloud = {
      # Defaults mirror commercial public endpoints. For restricted GovCloud,
      # override via var.os_image_urls to internal artifact locations.
      ubuntu_2204     = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img"
      fedora_39       = "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2"
      debian_12       = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      arch_latest     = "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
      almalinux_9     = "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
      centos_stream_9 = "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
      rocky_9         = "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
    }
  }

  selected_os_image_urls = merge(local.os_image_catalog[var.deployment_environment], var.os_image_urls)
  effective_os_image_url = data.coder_parameter.os_image_source.value == "custom_url" && trimspace(data.coder_parameter.custom_os_image_url.value) != "" ? data.coder_parameter.custom_os_image_url.value : data.coder_parameter.os_image.value
  strict_mode_image_allowed = length(var.strict_allowed_url_prefixes) > 0 && anytrue([
    for prefix in var.strict_allowed_url_prefixes : startswith(local.effective_os_image_url, prefix)
  ])
  strict_mode_code_server_allowed = length(var.strict_allowed_url_prefixes) > 0 && anytrue([
    for prefix in var.strict_allowed_url_prefixes : startswith(var.code_server_download_base_url, prefix)
  ])
}

data "coder_parameter" "os_image_source" {
  name         = "OS image source"
  type         = "string"
  description  = "Choose catalog image or a custom qcow URL"
  default      = "catalog"
  mutable      = true

  option {
    name  = "Catalog image"
    value = "catalog"
  }

  option {
    name  = "Custom URL"
    value = "custom_url"
  }
}

data "coder_parameter" "custom_os_image_url" {
  name        = "Custom OS image URL"
  type        = "string"
  description = "Used when OS image source is Custom URL. Must be an http(s) qcow/IMG endpoint reachable by the cluster."
  default     = ""
  mutable     = true

  validation {
    regex = "^(|https?://.+)$"
    error = "Custom OS image URL must be empty or a valid http(s) URL."
  }
}

data "coder_parameter" "os_image" {
    name = "os_image"
    display_name = "OS Image"
    description = "OS Image type should your workspace use?"
  default = local.selected_os_image_urls.ubuntu_2204
    mutable = false
    option {
        name = "Ubuntu 22.04"
    value = local.selected_os_image_urls.ubuntu_2204
        icon = "/icon/ubuntu.svg"
    }
    option {
        name = "Fedora 39"
    value = local.selected_os_image_urls.fedora_39
        icon = "/icon/fedora.svg"
    }
    option {
        name = "Debian 12"
    value = local.selected_os_image_urls.debian_12
        icon = "/icon/debian.svg"
    }
    option {
        name = "Arch Linux"
    value = local.selected_os_image_urls.arch_latest
        icon = "https://cdn0.iconfinder.com/data/icons/flat-round-system/512/archlinux-512.png"
    }
    option {
        name = "AlmaLinux 9"
    value = local.selected_os_image_urls.almalinux_9
        icon = "/icon/almalinux.svg"
    }
    option {
        name = "CentOS Stream 9"
    value = local.selected_os_image_urls.centos_stream_9
        icon = "/icon/centos.svg"
    }
    option {
        name = "Rocky Linux 9"
    value = local.selected_os_image_urls.rocky_9
        icon = "/icon/rockylinux.svg"
    }
}

data "coder_parameter" "linux_user" {
  name        = "Linux username"
  type        = "string"
  description = "Username for default coder workspace linux user"
  validation {
    regex = "^[a-z_][a-z0-9_-]{0,31}$"
    error = "Username must satisfy regex /^[a-z_][a-z0-9_-]{0,31}$/"
  }
  default = "coder"
}

data "coder_parameter" "cpu" {
  name        = "CPU cores"
  type        = "number"
  description = "Number of CPU Cores"
  icon        = "https://png.pngtree.com/png-clipart/20191122/original/pngtree-processor-icon-png-image_5165793.jpg"
  validation {
    min = 1
    max = 4
  }
  mutable = true
  default = 2
  order   = 1
}

data "coder_parameter" "memory" {
  name        = "Memory (__ MB)"
  type        = "number"
  description = ""
  icon        = "https://www.vhv.rs/dpng/d/33-338595_random-access-memory-logo-hd-png-download.png"
  validation {
    min = 1024
    max = 8192
  }
  mutable = true
  default = 4096
  order   = 2
}

data "coder_parameter" "disk_size" {
  name        = "PVC (your rootfs) storage size"
  type        = "number"
  description = "Number of GB of storage"
  icon        = "https://www.pngall.com/wp-content/uploads/5/Database-Storage-PNG-Clipart.png"
  validation {
    min       = 4
    max       = 64
    monotonic = "increasing"
  }
  mutable = false
  default = 16
  order   = 3
}

data "coder_parameter" "enable_desktop_app" {
  name        = "Enable desktop forwarding app"
  type        = "bool"
  description = "Adds a Coder app that points to a desktop web endpoint running inside the VM (for example noVNC)."
  default     = false
  mutable     = true
  order       = 4
}

data "coder_parameter" "desktop_port" {
  name        = "Desktop forwarding port"
  type        = "number"
  description = "Port used by the desktop forwarding app when enabled."
  default     = 6080
  mutable     = true
  order       = 5

  validation {
    min = 1
    max = 65535
  }
}

resource "coder_agent" "dev" {
  count = data.coder_workspace.me.start_count
  arch                   = "amd64"
  auth                   = "token"
  dir                    = "/home/${data.coder_parameter.linux_user.value}"
  os                     = "linux"
  startup_script_behavior = "blocking"
  startup_script         = <<EOT
    set -euo pipefail

    # install and start code-server from a pinned release asset
    CODE_SERVER_VERSION="4.11.0"
    CODE_SERVER_TARBALL="code-server-$${CODE_SERVER_VERSION}-linux-amd64.tar.gz"
    CODE_SERVER_URL="${var.code_server_download_base_url}/v$${CODE_SERVER_VERSION}/$${CODE_SERVER_TARBALL}"
    CODE_SERVER_SHA_URL="${var.code_server_download_base_url}/v$${CODE_SERVER_VERSION}/sha256sum.txt"

    mkdir -p /tmp/code-server
    curl -fL "$${CODE_SERVER_URL}" -o "/tmp/$${CODE_SERVER_TARBALL}"
    curl -fL "$${CODE_SERVER_SHA_URL}" -o /tmp/code-server-sha256sum.txt
    grep " $${CODE_SERVER_TARBALL}$" /tmp/code-server-sha256sum.txt | sha256sum -c -
    tar -xzf "/tmp/$${CODE_SERVER_TARBALL}" -C /tmp/code-server --strip-components=1

    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT

  metadata {
    key          = "cpu"
    display_name = "CPU Usage"
    interval     = 5
    timeout      = 5
    script       = "coder stat cpu"
  }
  metadata {
    key          = "memory"
    display_name = "Memory Usage"
    interval     = 5
    timeout      = 5
    script       = "coder stat mem"
  }
  metadata {
    key          = "disk"
    display_name = "Disk Usage"
    interval     = 600 # every 10 minutes
    timeout      = 30  # df can take a while on large filesystems
    script       = "coder stat disk --path /"
  }
  display_apps {
    vscode          = true
    vscode_insiders = false
    web_terminal    = true
    ssh_helper      = true
    port_forwarding_helper = true
  }

  lifecycle {
    precondition {
      condition     = !var.govcloud_strict_mode || local.strict_mode_code_server_allowed
      error_message = "govcloud_strict_mode is enabled and code_server_download_base_url is not allowed by strict_allowed_url_prefixes."
    }
  }
}

resource "terraform_data" "preflight_urls" {
  count = data.coder_workspace.me.transition == "start" && var.enable_preflight_url_checks ? 1 : 0

  input = {
    effective_os_image_url      = local.effective_os_image_url
    code_server_sha256sum_url   = "${var.code_server_download_base_url}/v4.11.0/sha256sum.txt"
  }

  lifecycle {
    precondition {
      condition     = !var.govcloud_strict_mode || (local.strict_mode_image_allowed && local.strict_mode_code_server_allowed)
      error_message = "govcloud_strict_mode is enabled: effective OS image URL and code-server base URL must both match strict_allowed_url_prefixes."
    }
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      curl -fsSLI "${self.input.effective_os_image_url}" >/dev/null
      curl -fsSLI "${self.input.code_server_sha256sum_url}" >/dev/null
    EOT
  }
}

resource "coder_app" "code-server" {
  agent_id     = try(coder_agent.dev[0].id, "")
  slug         = "code-server-${local.workspace_owner}-${local.workspace_name}"
  display_name = "code-server"
  icon         = "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9a/Visual_Studio_Code_1.35_icon.svg/2560px-Visual_Studio_Code_1.35_icon.svg.png"
  url          = "http://localhost:13337/?folder=/home/${data.coder_parameter.linux_user.value}"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "coder_app" "desktop" {
  count        = data.coder_workspace.me.start_count * (data.coder_parameter.enable_desktop_app.value ? 1 : 0)
  agent_id     = try(coder_agent.dev[0].id, "")
  slug         = "desktop-${local.workspace_owner}-${local.workspace_name}"
  display_name = "Desktop"
  icon         = "/icon/desktop.svg"
  url          = "http://localhost:${data.coder_parameter.desktop_port.value}"
  subdomain    = true
  share        = "owner"
}

# cloud init user data and coder agent api token is stored in secret
# secret is destroyed on stopping workspace and re-created on starting a workspace
resource "kubernetes_secret" "cloudinit-secret" {
  count = data.coder_workspace.me.transition == "start" ? 1 : 0
  metadata {
    name      = local.cloudinit_secret_name
    namespace = var.namespace
  }
  data = {
    userdata = templatefile("cloud-config.yaml.tftpl", {
      hostname = local.workspace_name
      username = lower(data.coder_parameter.linux_user.value)
      init_script = base64encode(try(coder_agent.dev[0].init_script, ""))
      coder_agent_token = try(coder_agent.dev[0].token, "")
    })
  }
}

resource "kubernetes_manifest" "virtualmachine" {
  count = data.coder_workspace.me.transition == "start" ? 1 : 0
  depends_on = [
    kubernetes_manifest.datavolume,
    kubernetes_secret.cloudinit-secret,
  ]
  manifest = {
    "apiVersion" = "kubevirt.io/v1"
    "kind"       = "VirtualMachine"
    "metadata" = {
      "labels" = {
        "kubevirt.io/vm" = local.workspace_id
      }
      "name"      = local.workspace_id
      "namespace" = "${var.namespace}"
    }
    "spec" = {
      "running" = true
      "template" = {
        "metadata" = {
          "creationTimestamp" = null
          "labels" = {
            "kubevirt.io/vm" = local.workspace_id
          }
        }
        "spec" = {
          "domain" = {
            "devices" = {
              "disks" = [
                {
                  "disk" = {
                    "bus" = "virtio"
                  }
                  "name" = local.rootfs_name
                },
                {
                  "disk" = {
                    "bus" = "virtio"
                  }
                  "name" = "cloudinitdisk"
                }
              ]
              "interfaces" = [
                {
                  "masquerade" = {}
                  "name"       = "default"
                },
              ]
            }
            "resources" = {
              "requests" = {
                "cpu"    = "${data.coder_parameter.cpu.value}"
                "memory" = "${data.coder_parameter.memory.value}M"
              }
            }
          }
          "networks" = [
            {
              "name" = "default"
              "pod"  = {}
            },
          ]
          "terminationGracePeriodSeconds" = 300
          "volumes" = [
            {
              "dataVolume" = {
                "name" = local.rootfs_name
              }
              "name" = local.rootfs_name
            },
            {
              "cloudInitNoCloud" = {
                "networkData" = <<-EOT
                #cloud-config
                network:
                  version: 2
                  ethernets:
                    enp1s0:
                      dhcp4: true
                EOT
                "secretRef" = {
                  name = local.cloudinit_secret_name
                }
              }
              "name" = "cloudinitdisk"
            }
          ]
        }
      }
    }
  }
}

resource "kubernetes_manifest" "datavolume" {
  depends_on = [terraform_data.preflight_urls]
  manifest = {
    "apiVersion" = "cdi.kubevirt.io/v1beta1"
    "kind"       = "DataVolume"
    "metadata" = {
      "name"      = local.rootfs_name
      "namespace" = "${var.namespace}"
    }
    "spec" = {
      "pvc" = {
        "accessModes" = [
          "ReadWriteOnce",
        ]
        "resources" = {
          "requests" = {
            "storage" = "${data.coder_parameter.disk_size.value}G"
          }
        }
      }
      "source" = {
        "http" = {
          "url" = local.effective_os_image_url
        }
      }
    }
  }
}

# expose the vm via kubernetes service
# exposed in the following format coder-<owner>-<workspace-name>.<namespace>.svc.cluster.local
resource "kubernetes_manifest" "service" {
  depends_on = [kubernetes_manifest.virtualmachine]
  manifest = {
    "apiVersion" = "v1"
    "kind" = "Service"
    "metadata" = {
      "name"      = local.workspace_id
      "namespace" = "${var.namespace}"
    }
    "spec" = {
      "clusterIP" = "None"
      "selector" = {
        "kubevirt.io/vm" = local.workspace_id
      }
    }
  }
}