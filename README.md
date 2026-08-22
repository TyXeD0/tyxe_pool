# tyxe_pool

Self-hosted controller for a Telemt ENTER/EXIT topology.

Current stabilization topology:

```text
Client -> RU ENTER/controller -> AmneziaWG -> PL EXIT/Telemt
```

During stabilization tyxe_pool intentionally allows **one ENTER and one EXIT** in the controller. Multi-EXIT balancing will be enabled only after the base chain is proven stable, but the AWG allocator is already designed not to lock us into a single tunnel.

## Current development version

`v0.3.0` (feature branch while being tested)

Implemented in this milestone:

- public GitHub bootstrap via `curl`, no GitHub token required;
- Russian/English language selection at installer start;
- selected language is used by the web panel;
- numeric choices and `y/n` confirmations;
- explanatory installer steps;
- ENTER/controller and EXIT/node-agent roles;
- automatic IDN/Unicode hostname conversion to ASCII/Punycode before DNS/TLS/nginx/Certbot use;
- persistent Let’s Encrypt certificates that survive rollback/uninstall and can be reused;
- public HTTPS panel option with administrator username/password;
- PBKDF2-SHA256 password storage, signed HttpOnly sessions and CSRF protection;
- controller remains bound to `127.0.0.1`; nginx publishes the panel when requested;
- separate proxy/selfsteal and panel hostnames;
- basic HTTPS decoy/selfsteal website (final shared-port classifier is a later milestone);
- node-agent bearer token;
- one-EXIT stabilization guard in the controller;
- node status, load, RAM and uptime in the central panel;
- official Telemt installation/update on EXIT;
- local `tyxe-telemt` management menu on EXIT;
- Telemt installed/running/version/config status in the central panel;
- Telemt start/stop/restart and journal logs from the central panel through the node agent;
- rollback tracking for Telemt files/service plus the `telemt` system user/group when tyxe_pool created them;
- experimental `tyxe-awg` pair manager for ENTER↔EXIT AmneziaWG;
- collision-aware `/30` allocation for future multiple EXIT nodes;
- separate `awgN` interface/state/backup per EXIT on ENTER;
- AWG backups on both VPSes, randomized keys/PSK/obfuscation parameters, restricted EXIT UDP firewall rule, tunnel health checks and Agent migration to the tunnel IP;
- GitHub Actions syntax checks for Bash/Python and a guard against committed private key material.

Still intentionally pending:

- real-VPS validation of the new AWG pair manager;
- Telemt `proxy_protocol`/tunnel bind and HAProxy dataplane;
- MTProxyL/Zapret2/Smart fixes on ENTER;
- final shared-port `443` selfsteal/classifier;
- synchronized Telemt users/secrets;
- Globalping and end-to-end Telegram health checks;
- enabling multiple EXIT nodes in the controller and load balancing/failover.

## Install from public GitHub

Stable `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/TyXeD0/tyxe_pool/main/install.sh \
  | sudo bash -s -- --repo TyXeD0/tyxe_pool
```

Test the current v0.3 feature branch:

```bash
curl -fsSL https://raw.githubusercontent.com/TyXeD0/tyxe_pool/feature/v0.3.0-telemt/install.sh \
  | sudo bash -s -- \
      --repo TyXeD0/tyxe_pool \
      --ref feature/v0.3.0-telemt
```

The bootstrap downloads the repository to a temporary directory, runs the interactive installer, and removes the temporary checkout automatically.

## Domain layout

Recommended:

```text
example.com       -> proxy/selfsteal on ENTER
panel.example.com -> authenticated TYXE Pool panel on ENTER
```

IDN domains may be entered in Unicode form. The installer shows and uses their Punycode form for Certbot/nginx/DNS-facing configuration.

## EXIT / Telemt

During EXIT installation the wizard offers:

```text
1) Install/update Telemt now
2) Use existing Telemt
3) Skip and configure later
```

Local management afterwards:

```bash
sudo tyxe-telemt
```

The central controller can query Telemt status and perform only the whitelisted service actions `start`, `stop`, and `restart` through the authenticated node agent. It can also read recent Telemt journal logs.

## ENTER ↔ EXIT AmneziaWG beta

The allocator uses a separate `/30` point-to-point network for every EXIT. The first free pair keeps the official Telemt example convention where EXIT gets the first usable address and ENTER the second usable address:

```text
PL1: awg0 on ENTER, 10.10.10.0/30  -> EXIT 10.10.10.1, ENTER 10.10.10.2
PL2: awg1 on ENTER, 10.10.10.4/30  -> EXIT 10.10.10.5, ENTER 10.10.10.6
PL3: awg2 on ENTER, 10.10.10.8/30  -> EXIT 10.10.10.9, ENTER 10.10.10.10
...
```

On each separate EXIT VPS the local interface may still be named `awg0`; only ENTER needs `awg0`, `awg1`, `awg2`, ... because all tunnels coexist there.

Before allocating a subnet, TYXE compares the candidate against IPv4 addresses and routes, existing AmneziaWG/WireGuard configs, and TYXE AWG state on ENTER, plus addresses/routes/configs on the new EXIT. Any overlapping `/30` is skipped. Default pools are tried in this order:

```text
10.10.10.0/24
10.254.0.0/16
172.31.240.0/20
192.168.250.0/24
```

A custom pool can be supplied when needed:

```bash
TYXE_AWG_POOLS=10.200.0.0/16 sudo -E tyxe-awg setup
```

The setup also serializes allocation with a lock so two simultaneous provisioning runs cannot reserve the same network.

The default EXIT AWG UDP endpoint remains `8443/udp` (the same port may be reused on different EXIT VPSes because they have different public IPs). If UFW is active, TYXE adds the rule only for the public IPv4 of ENTER when no pre-existing rule is present.

For the current test, both VPSes should be Ubuntu 22.04/24.04 and ENTER must be able to SSH to EXIT as `root`. Install the manager on ENTER:

```bash
sudo curl -fsSL \
  https://raw.githubusercontent.com/TyXeD0/tyxe_pool/feature/v0.3.0-telemt/scripts/awg-pair.sh \
  -o /usr/local/sbin/tyxe-awg
sudo chmod 755 /usr/local/sbin/tyxe-awg
```

Create another pair:

```bash
sudo tyxe-awg setup
```

List allocated pairs:

```bash
sudo tyxe-awg list
```

Inspect a pair:

```bash
sudo tyxe-awg status <node-id>
```

Rollback only one pair:

```bash
sudo tyxe-awg rollback <node-id>
```

The manager does not install a default route through AWG and does not change the public SSH route. Each pair has its own state and backup, so removing one EXIT is not supposed to overwrite or stop other AWG pairs. The Agent on each EXIT is rebound from localhost to that EXIT's tunnel IP and made dependent on its local `awg-quick@awg0.service`.

## Node management

On ENTER:

```bash
sudo tyxe-pool-node
```

or use the web panel. During this stabilization milestone the controller still accepts only one EXIT node; that guard will be removed only after the single ENTER↔EXIT dataplane is proven stable.

## Certificates

Certificates intentionally live outside the rollback lifecycle:

```text
/var/lib/tyxe-pool-persistent/letsencrypt/
```

Existing system Certbot certificates under `/etc/letsencrypt/` can also be reused. If a matching certificate exists, the installer asks whether to reuse it, issue a new one, or skip TLS for that hostname.

## Rollback / uninstall

Preview:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --dry-run
```

Full rollback of tyxe_pool-managed changes:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --purge-state
```

TLS certificates are preserved.

## Security rule

Never commit real node tokens, Telemt user secrets, API tokens, SSH private keys, TLS private keys, generated `.env` files, or generated server settings.
