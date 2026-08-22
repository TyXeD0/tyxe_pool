# tyxe_pool

TYXE Pool is a self-hosted ENTER/EXIT MTProto proxy control plane under active development.

> **Current stabilization topology:** one ENTER/controller and one EXIT/agent. Multi-EXIT balancing is intentionally deferred until the base chain is proven stable end-to-end.

## Current architecture

```text
Telegram client
      |
      v
ENTER / Controller
  - public client endpoint
  - HAProxy TCP/443
  - upstream MTProxyL host-only anti-DPI (optional/recommended where DPI blocks MTProto)
  - AmneziaWG client
      |
      v
EXIT / Agent
  - private Agent API over AWG
  - Telemt bound to tunnel address
  - PROXY protocol
      |
      v
Telegram DC
```

## Main menu

After installation, run:

```bash
sudo tyxe
```

On ENTER the menu exposes:

- chain/status
- EXIT node management
- AmneziaWG pair management
- HAProxy ↔ Telemt dataplane
- Anti-DPI through the official upstream MTProxyL
- emergency built-in Zapret2 fallback

On EXIT it exposes status and Telemt management.

## Anti-DPI strategy

TYXE intentionally does **not** freeze a copy of MTProxyL's current DPI-bypass logic as the primary path.

The recommended ENTER-side flow is:

```text
sudo tyxe
  -> Anti-DPI / official MTProxyL
  -> install/update current Liafanx/MTProxyL main
  -> Reanimator
  -> Only optimization / tools-only
  -> current upstream Zapret2 or Smart By-MEKO
```

This keeps ownership boundaries clear:

- TYXE owns Controller, HAProxy, AWG and the EXIT Telemt topology.
- MTProxyL is used only for host-level anti-DPI tools on the client-facing ENTER.
- The bridge refuses to apply fixes unless `mtproxyl mode --json` reports `mode=reanimator` and `tools_only=true`.
- Before applying a fix, the bridge can run the official MTProxyL update check/update, so future installs can use newer upstream DPI fixes without a TYXE release.

The built-in `tyxe-antidpi-fallback` remains an emergency fallback, not the recommended primary integration.

## Public installer

Stable branch:

```bash
curl -fsSL https://raw.githubusercontent.com/TyXeD0/tyxe_pool/main/install.sh | sudo bash -s -- --repo TyXeD0/tyxe_pool
```

Testing a feature branch:

```bash
curl -fsSL https://raw.githubusercontent.com/TyXeD0/tyxe_pool/feature/v0.3.0-telemt/install.sh | \
  sudo bash -s -- --repo TyXeD0/tyxe_pool --ref feature/v0.3.0-telemt
```

The bootstrap downloads a repository tarball, runs the interactive installer, and then installs role-appropriate TYXE management helpers. End users do not need a GitHub token for a public repository.

## Current commands

### ENTER

```bash
sudo tyxe
sudo tyxe-pool-node menu
sudo tyxe-awg list
sudo tyxe-awg setup
sudo tyxe-awg status [node-id]
sudo tyxe-awg rollback [node-id]
sudo tyxe-dataplane setup [node-id]
sudo tyxe-dataplane status [node-id]
sudo tyxe-dataplane rollback [node-id]
sudo tyxe-mtproxyl menu
```

### EXIT

```bash
sudo tyxe
sudo tyxe-telemt menu
```

## Rollback philosophy

TYXE rollback is conservative:

- preserve unrelated/pre-existing services where possible;
- preserve Let's Encrypt certificates in the persistent certificate store;
- remove/restore only paths recorded in the install manifest;
- AWG pair rollback affects only the selected pair;
- dataplane rollback restores the saved Telemt and HAProxy configuration for that pair.

## Development status

The v0.3 feature branch has been validated on real ENTER/EXIT VPSes through:

- Telemt 3.4.25 on EXIT;
- private Agent migration to AWG;
- AWG `10.10.10.0/30` with ENTER `10.10.10.2` and EXIT `10.10.10.1`;
- Controller polling the EXIT Agent over AWG;
- Telemt bound to `10.10.10.1:443` with PROXY protocol;
- HAProxy on ENTER forwarding TCP/443 to Telemt using PROXY v2.

The remaining client-level validation is the ENTER-side anti-DPI layer and an actual Telegram client connection. The v0.3 pull request remains draft until that path is proven.
