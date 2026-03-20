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
  description = "Kubernetes namespace to deploy the workspace VM into"
  default     = "coder"
}

variable "use_kubeconfig" {
  type        = bool
  description = "Use host kubeconfig?"
  default     = false
}

provider "coder" {}

provider "kubernetes" {
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

locals {
  workspace_owner = lower(data.coder_workspace_owner.me.name)
  workspace_name  = lower(data.coder_workspace.me.name)
  workspace_id    = "coder-${local.workspace_owner}-${local.workspace_name}"

  cloudinit_secret_name = "${local.workspace_id}-cloudinit"
  rootfs_name           = "${local.workspace_id}-rootfs"
}

data "coder_parameter" "windows_image_url" {
  name         = "Windows image URL"
  display_name = "Windows QCOW image URL"
  description  = "HTTP(S) URL to Windows qcow image (Cloudbase-Init recommended)."
  type         = "string"
  mutable      = false
  default      = "https://artifacts.example.mil/os-images/windows/windows-server-2022.qcow2"
  validation {
    regex = "^https?://.+$"
    error = "Windows image URL must be a valid http(s) URL."
  }
}

data "coder_parameter" "windows_user" {
  name         = "Windows username"
  type         = "string"
  description  = "Windows user account for workspace context"
  default      = "coder"
  mutable      = true
}

data "coder_parameter" "cpu" {
  name         = "CPU cores"
  type         = "number"
  description  = "Number of CPU cores"
  default      = 2
  mutable      = true
  order        = 1
  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "memory" {
  name         = "Memory (MB)"
  type         = "number"
  description  = "VM memory in MB"
  default      = 4096
  mutable      = true
  order        = 2
  validation {
    min = 2048
    max = 16384
  }
}

data "coder_parameter" "disk_size" {
  name         = "PVC (rootfs) size"
  type         = "number"
  description  = "Disk size in GB"
  default      = 40
  mutable      = false
  order        = 3
  validation {
    min       = 20
    max       = 200
    monotonic = "increasing"
  }
}

data "coder_parameter" "enable_desktop_app" {
  name         = "Enable desktop forwarding app"
  type         = "bool"
  description  = "Adds a Coder app for a web desktop endpoint running in the Windows VM."
  default      = true
  mutable      = true
  order        = 4
}

data "coder_parameter" "desktop_port" {
  name         = "Desktop forwarding port"
  type         = "number"
  description  = "Desktop web endpoint port (for example, noVNC gateway)."
  default      = 6080
  mutable      = true
  order        = 5
  validation {
    min = 1
    max = 65535
  }
}

resource "coder_agent" "dev" {
  count                   = data.coder_workspace.me.start_count
  arch                    = "amd64"
  auth                    = "token"
  dir                     = "C:/Users/${data.coder_parameter.windows_user.value}"
  os                      = "windows"
  startup_script_behavior = "blocking"
  startup_script          = <<EOT
powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host 'Coder startup script running on Windows workspace';"
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
    interval     = 600
    timeout      = 30
    script       = "coder stat disk --path C:/"
  }

  display_apps {
    vscode                 = false
    vscode_insiders        = false
    web_terminal           = true
    ssh_helper             = false
    port_forwarding_helper = true
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

resource "kubernetes_secret" "cloudinit-secret" {
  count = data.coder_workspace.me.transition == "start" ? 1 : 0
  metadata {
    name      = local.cloudinit_secret_name
    namespace = var.namespace
  }

  data = {
    userdata = templatefile("cloud-config-windows.yaml.tftpl", {
      hostname          = local.workspace_name
      username          = data.coder_parameter.windows_user.value
      init_script       = base64encode(try(coder_agent.dev[0].init_script, ""))
      coder_agent_token = try(coder_agent.dev[0].token, "")
    })
  }
}

resource "kubernetes_manifest" "datavolume" {
  manifest = {
    "apiVersion" = "cdi.kubevirt.io/v1beta1"
    "kind"       = "DataVolume"
    "metadata" = {
      "name"      = local.rootfs_name
      "namespace" = var.namespace
    }
    "spec" = {
      "pvc" = {
        "accessModes" = ["ReadWriteOnce"]
        "resources" = {
          "requests" = {
            "storage" = "${data.coder_parameter.disk_size.value}G"
          }
        }
      }
      "source" = {
        "http" = {
          "url" = data.coder_parameter.windows_image_url.value
        }
      }
    }
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
      "namespace" = var.namespace
    }
    "spec" = {
      "running" = true
      "template" = {
        "metadata" = {
          "labels" = {
            "kubevirt.io/vm" = local.workspace_id
          }
        }
        "spec" = {
          "domain" = {
            "devices" = {
              "disks" = [
                {
                  "disk" = { "bus" = "virtio" }
                  "name" = local.rootfs_name
                },
                {
                  "disk" = { "bus" = "virtio" }
                  "name" = "cloudinitdisk"
                }
              ]
              "interfaces" = [
                {
                  "masquerade" = {}
                  "name"       = "default"
                }
              ]
            }
            "resources" = {
              "requests" = {
                "cpu"    = data.coder_parameter.cpu.value
                "memory" = "${data.coder_parameter.memory.value}M"
              }
            }
          }
          "networks" = [
            {
              "name" = "default"
              "pod"  = {}
            }
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
                "secretRef" = {
                  "name" = local.cloudinit_secret_name
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

resource "kubernetes_manifest" "service" {
  depends_on = [kubernetes_manifest.virtualmachine]
  manifest = {
    "apiVersion" = "v1"
    "kind"       = "Service"
    "metadata" = {
      "name"      = local.workspace_id
      "namespace" = var.namespace
    }
    "spec" = {
      "clusterIP" = "None"
      "selector" = {
        "kubevirt.io/vm" = local.workspace_id
      }
    }
  }
}
