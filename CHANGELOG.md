# Changelog

## v0.3.0 — in testing

- Added automatic Unicode/IDN hostname conversion to ASCII/Punycode before Certbot/nginx use.
- Kept Let’s Encrypt certificates outside rollback and added reuse/new/skip choices.
- Added official Telemt provisioning on EXIT with install/update/use-existing/skip choices.
- Added local `tyxe-telemt` manager for Telemt status, install/update, start/stop/restart and logs.
- Extended node agent with Telemt version/config/service metadata, whitelisted service control and journal logs.
- Extended central web panel with Telemt status, start/stop/restart and logs.
- Enforced one EXIT during the stabilization milestone.
- Extended rollback to remove the Telemt system user/group only when tyxe_pool recorded that it created them.
- Rollback no longer sources `settings.env`; this fixes node names containing spaces such as `PL Hostoff` and makes partial-install rollback safer.
- Agent fallback settings parsing now discards malformed UTF-8 fragments, NUL bytes and control characters instead of sourcing the file.
- Node-agent systemd startup waits for `/healthz` and follows the configured bind address instead of assuming localhost.
- Added experimental `tyxe-awg` provisioning for one ENTER↔EXIT AmneziaWG pair using the official `10.10.10.2 ↔ 10.10.10.1` double-hop layout.
- `tyxe-awg` backs up both sides, generates fresh keys/PSK/obfuscation parameters, limits the EXIT UDP endpoint via UFW when possible, moves Agent API to the tunnel IP, validates ping/API reachability and can roll the pair back independently.
- The Agent AWG systemd drop-in replaces the old localhost health probe with a tunnel-address probe and is checked with `systemd-analyze verify` before restart.
- Added GitHub Actions Bash/Python/systemd syntax checks and a private-key-material guard.
- MTProxyL/Zapret2 remains intentionally planned for ENTER, not EXIT.

## v0.2.1

- Public GitHub bootstrap via `curl` without a GitHub token.
- Authenticated panel with PBKDF2-SHA256 admin password hash.
- Signed HttpOnly session cookie and CSRF protection.
- Optional Internet-facing panel through nginx HTTPS reverse proxy.
- Separate panel hostname and login throttling.

## v0.2.0

- Russian/English installer and panel language.
- Numeric menu choices and `y/n` prompts.
- Basic node manager and central node status.
- Certificates made persistent across rollback/uninstall.

## v0.1.1

- Initial installer/rollback foundation.
