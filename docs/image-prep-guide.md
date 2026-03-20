# Image Preparation Guide (Linux, Windows, GovCloud)

This repository provisions KubeVirt VMs from **QCOW image URLs** (via CDI DataVolume), not directly from EC2 AMIs. The guidance below focuses on preparing source images so Coder workspaces start reliably and securely.

## Scope

- Linux image prep for `kubevirt-provisioner/`
- Windows image prep for `kubevirt-provisioner-windows/`
- GovCloud and restricted-network considerations

---

## Linux image prep checklist

### Linux required baseline

- Cloud-init installed and enabled
- systemd available and functioning
- `bash`, `curl`, `tar`, `sha256sum`, `ca-certificates` installed
- Networking defaults that allow DHCP on first interface
- Root disk filesystem expands correctly (cloud image behavior)

### Linux Coder compatibility

- No preinstalled long-running process that blocks user startup scripts
- User creation should not conflict with template-provided username
- Outbound access (or internal mirror access) for code-server artifact download

### Linux security baseline

- Latest patch level for your distro
- No embedded secrets, keys, or credentials
- SSH password auth disabled (template already sets `ssh_pwauth: false`)
- Default account passwords locked where applicable
- Audit/logging agents preconfigured if required by policy

### Optional performance tuning

- Preinstall common developer packages to reduce first boot time
- Keep image size reasonable; remove unnecessary artifacts/cache

---

## Windows image prep checklist

### Windows required baseline

- **Cloudbase-Init installed and enabled**
- Windows image exported as QCOW2 and reachable by CDI
- Stable networking with DHCP enabled
- PowerShell available and execution policy supports bootstrap script execution

### Windows Coder compatibility

- Ensure startup scripts can run under expected user context
- Avoid first-boot workflows that require manual interaction
- If using desktop forwarding, image must include and start your desktop web endpoint

### Windows security baseline

- Apply patch baseline and hardening profile
- No embedded credentials/secrets
- Endpoint protection configured per enterprise policy
- Logging/auditing configured (event forwarding, SIEM agents, etc.)

---

## GovCloud / restricted network checklist

### Artifact and image hosting

- Host Linux/Windows QCOW images in approved internal artifact storage
- Host code-server release assets in internal mirror
- Avoid dependencies on public internet from workspace startup

### Template inputs to set

- Linux template:
  - `deployment_environment = "govcloud"`
  - `os_image_urls` mapped to internal URLs
  - `code_server_download_base_url` set to internal mirror
- Windows template:
  - Set `windows_image_url` to internal approved image URL

### Policy controls (recommended)

- Enforce allowed URL domains for image and artifact sources
- Enforce max CPU/memory/disk workspace bounds
- Enforce required labels/tags for compliance and cost attribution

---

## Validation before publishing an image

For each candidate image:

1. Boot test in target cluster via temporary DataVolume + VM
2. Verify cloud-init/Cloudbase-Init completion
3. Confirm Coder agent startup succeeds
4. Verify code-server (Linux) checksum validation/download path
5. Verify desktop endpoint behavior if enabled
6. Verify logs are exported to required audit systems

---

## Operational notes

- Linux and Windows are provided as separate template variants in this repository.
- Keep image versions immutable and track provenance (source, patch date, hardening baseline, scan results).
- Promote images through dev -> staging -> prod channels with the same validation gates.
