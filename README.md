# tyxe_pool

Self-hosted controller for a Telemt ENTER/EXIT topology.

Current stabilization topology:

```text
Client -> RU ENTER/controller -> (transport comes next) -> PL EXIT/Telemt
```

During stabilization tyxe_pool intentionally allows **one ENTER and one EXIT**. Multi-EXIT balancing will be enabled only after the base chain is proven stable.

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
- GitHub Actions syntax checks for Bash/Python and a guard against committed private key material.

Still intentionally pending:

- MTProxyL/Zapret2/Smart fixes on ENTER;
- AmneziaWG transport provisioning;
- official Telemt double-hop wiring / HAProxy dataplane;
- final shared-port `443` selfsteal/classifier;
- synchronized Telemt users/secrets;
- Globalping and end-to-end Telegram health checks;
- multiple EXIT nodes and load balancing/failover.

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

## Node management

On ENTER:

```bash
sudo tyxe-pool-node
```

or use the web panel. During this stabilization milestone the controller accepts only one EXIT node.

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
