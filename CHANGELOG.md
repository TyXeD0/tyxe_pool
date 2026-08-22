# Changelog

## v0.3.0 — in testing

- Added automatic Unicode/IDN hostname conversion to ASCII/Punycode before Certbot/nginx use.
- Kept Let’s Encrypt certificates outside rollback and added reuse/new/skip choices.
- Added official Telemt provisioning on EXIT with install/update/use-existing/skip choices.
- Added local `tyxe-telemt` manager for Telemt status, install/update, start/stop/restart and logs.
- Extended node agent with Telemt version/config/service metadata, whitelisted service control and journal logs.
- Extended central web panel with Telemt status, start/stop/restart and logs.
- Enforced one EXIT in the controller during the stabilization milestone.
- Extended rollback to remove the Telemt system user/group only when tyxe_pool recorded that it created them.
- Rollback no longer sources `settings.env`; this fixes node names containing spaces such as `PL Hostoff` and makes partial-install rollback safer.
- Agent fallback settings parsing now discards malformed UTF-8 fragments, NUL bytes and control characters instead of sourcing the file.
- Node-agent systemd startup now waits for `/healthz` before reporting a successful start, avoiding the first-install readiness race on port 9100.
- Added experimental ENTER↔EXIT AmneziaWG provisioning.
- AWG allocator now reserves a separate collision-checked `/30` and `awgN` interface per EXIT on ENTER, with independent state/backup/rollback for future multi-node operation.
- AWG address allocation checks current IPv4 addresses/routes, AmneziaWG/WireGuard configs and TYXE state on ENTER and the candidate EXIT; overlapping networks are skipped automatically.
- Added fallback private address pools and optional `TYXE_AWG_POOLS` override.
- AWG provisioning uses explicit `awg-quick@awg0.service` ordering for the EXIT Agent and SSH multiplexing for repeated remote calls.
- Added guarded `tyxe-dataplane` provisioning: Telemt is backed up, restricted to the AWG address with PROXY protocol enabled, public link host is moved to ENTER, and host-level HAProxy forwards `:443` to the EXIT with `send-proxy-v2`.
- Dataplane setup refuses to overwrite custom active `[[server.listeners]]`, validates the ENTER `:443` listener, keeps independent state/backups, and supports rollback without touching AWG/Agent/users/certificates.
- Added GitHub Actions Bash/Python/systemd syntax checks and a private-key-material guard.
- MTProxyL/Zapret2 remains intentionally planned for ENTER, not EXIT.

## v0.2.1
