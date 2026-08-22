# tyxe_pool

Self-hosted controller for a Telemt enter/exit topology.

Current development topology:

```text
Client -> RU ENTER -> selfsteal/classifier -> transport -> PL EXIT -> Telemt
```

During the stabilization phase tyxe_pool intentionally uses **one ENTER and one EXIT**. Multiple EXIT nodes will be enabled only after the base chain is proven stable.

## Current version

`v0.2.1` — public curl bootstrap + authenticated web panel.

Implemented:

- public GitHub bootstrap via `curl`, no GitHub token required;
- Russian/English language selection at the start;
- selected language is applied to the web panel;
- numeric menu choices and `y/n` confirmations;
- explanatory installer steps;
- ENTER/controller and EXIT/node-agent roles;
- persistent rollback manifest across upgrades;
- Let’s Encrypt certificates survive rollback/uninstall and can be reused;
- controller admin username/password setup during installation;
- PBKDF2-SHA256 password storage (no plaintext admin password on disk);
- signed HttpOnly panel sessions + SameSite cookies;
- CSRF protection for state-changing web API calls;
- controller remains bound to `127.0.0.1`;
- optional Internet-facing panel through nginx HTTPS reverse proxy;
- separate panel hostname supported (recommended: `panel.example.com`);
- per-IP login throttling in nginx for public mode;
- node-agent bearer token;
- add/remove EXIT node from web UI and `tyxe-pool-node` CLI;
- controller displays agent/Telemt service status, load, RAM and uptime.

Not production-ready yet:

- MTProxyL/Telemt provisioning;
- final shared-port 443 selfsteal/classifier;
- AmneziaWG transport provisioning;
- synchronized Telemt users/secrets;
- Globalping / end-to-end Telegram checks;
- HAProxy exit selection/failover;
- multiple EXIT nodes.

## Install from public GitHub with curl

Replace `OWNER` with the GitHub account that owns `tyxe_pool`:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/tyxe_pool/main/install.sh \
  | sudo bash -s -- --repo OWNER/tyxe_pool
```

Install a tagged version instead of `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/tyxe_pool/v0.2.1/install.sh \
  | sudo bash -s -- --repo OWNER/tyxe_pool --ref v0.2.1
```

The bootstrap downloads the rest of the public repository into a temporary directory and starts the full interactive installer. The temporary checkout is removed automatically.

## Panel modes

The ENTER installer offers:

```text
1) Localhost only + SSH tunnel
2) Public HTTPS panel
```

The controller process always listens on `127.0.0.1`. In public mode nginx exposes the configured panel hostname over HTTPS and reverse-proxies to the local controller.

Recommended domain layout:

```text
example.com       -> proxy / selfsteal hostname
panel.example.com -> TYXE Pool panel
```

The installer asks for an administrator username and password twice. The password itself is never written to disk; only a PBKDF2-SHA256 hash is stored in `/etc/proxy-pool/settings.env`.

## Node management

```bash
sudo tyxe-pool-node
```

or:

```bash
sudo tyxe-pool-node list
sudo tyxe-pool-node add
sudo tyxe-pool-node remove
```

## Certificates

Certificates are persistent and are intentionally outside the rollback lifecycle. When a certificate already exists, the installer offers to reuse it rather than issue another one.

Primary persistent store:

```text
/var/lib/tyxe-pool-persistent/letsencrypt/
```

Existing system Certbot certificates under `/etc/letsencrypt/` can also be reused.

## Rollback / uninstall

Preview:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --dry-run
```

Full rollback of tyxe_pool-managed changes:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --purge-state
```

Certificates are preserved.

## Security rule

Never commit real credentials, including node tokens, Telemt user secrets, API tokens, SSH private keys, TLS private keys or generated settings files.
