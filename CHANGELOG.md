# Changelog

## Unreleased — v0.3.0 beta

### Added
- EXIT Telemt lifecycle integration and central status/control.
- Private Agent migration over AmneziaWG.
- Collision-aware `/30` AWG pair allocator and per-pair rollback.
- Host-level HAProxy dataplane with PROXY protocol v2 to tunnel-bound Telemt.
- `tyxe-dataplane` backup/status/rollback workflow.
- Persistent role-aware `sudo tyxe` main menu.
- Post-install management component deployment (`tyxe-awg`, `tyxe-dataplane`, `tyxe-mtproxyl`, fallback anti-DPI helper).
- Official upstream MTProxyL anti-DPI bridge for ENTER.
  - downloads/updates current `Liafanx/MTProxyL` upstream when selected;
  - requires `Reanimator` + `tools_only=true` before applying any fix;
  - exposes current upstream Zapret2, Smart By-MEKO and wscale diagnostics;
  - keeps TYXE ownership of HAProxy/AWG/EXIT Telemt;
  - retains the built-in Zapret2 implementation only as an emergency fallback.

### Fixed during real-VPS validation
- Interactive AWG input variable shadowing.
- Agent systemd AWG dependency uses the explicit `.service` unit name.
- SSH multiplexing avoids repeated password prompts within one provisioning run.
- `set -e` false failure when an optional SSH key is empty.
- Remote dataplane backup directory creation before copying Telemt config.

### Validated on real VPSes
- Telemt 3.4.25 on EXIT.
- ENTER `10.10.10.2/30` ↔ EXIT `10.10.10.1/30` AWG tunnel.
- Agent reachable only through the tunnel path.
- Controller keeps the EXIT node `up` across polling cycles.
- HAProxy `0.0.0.0:443` → `10.10.10.1:443` with `send-proxy-v2`.
- Telemt tunnel bind and `proxy_protocol=true`.
- Server-side dataplane postcheck passes.

### Pending live validation
- Actual Telegram client connection through the upstream MTProxyL anti-DPI layer on ENTER.
- Shared 443 selfsteal/classifier.
- Multi-EXIT balancing/failover.
