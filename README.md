# tyxe_pool

Private-development project for a self-hosted Telemt enter/exit pool.

Target topology:

```text
Client -> RU ENTER -> selfsteal/classifier -> HAProxy -> AWG/transport -> PL EXIT(s) -> Telemt
```

## Current version

`v0.2.0` — bilingual installer + persistent certificates + Node Manager MVP.

Implemented:

- Russian/English language choice at the very beginning of installation;
- the selected language is stored and used by the controller web panel;
- numeric menu selection and `y/n` confirmations;
- explanatory text before important installer steps;
- ENTER/controller and EXIT/node-agent roles;
- persistent transaction manifest across upgrades;
- failed installation rolls back only the current transaction;
- full uninstall rolls back all recorded project changes;
- Let’s Encrypt certificates under `/etc/letsencrypt` are never removed by tyxe_pool rollback;
- existing certificates are detected and can be reused instead of reissued;
- minimal localized central web panel;
- add/remove EXIT nodes from the web panel;
- CLI node manager: `tyxe-pool-node`;
- optional node registration at the end of controller installation;
- node-agent bearer token;
- controller polls agent health and displays Telemt status, uptime, load and RAM;
- HAProxy and selfsteal configuration templates retained for the next dataplane milestone.

Not production-ready yet:

- final shared-port `443` classifier/selfsteal;
- automatic AWG provisioning;
- SSH bootstrap of remote EXIT nodes;
- automatic Telemt installation and configuration;
- centralized users/secrets synchronization;
- Globalping and end-to-end Telegram health checks;
- automatic HAProxy backend generation and `UP/DOWN/DRAIN` lifecycle;
- production authentication for the controller panel;
- encrypted/mTLS controller↔agent transport.

## Install from a clone

```bash
git clone git@github.com:OWNER/tyxe_pool.git
cd tyxe_pool
sudo ./install.sh
```

The first prompt is always the language:

```text
1) Русский
2) English
```

All menu choices use numbers and confirmations use `y/n`.

## Node management

On an installed controller:

```bash
sudo tyxe-pool-node
```

or directly:

```bash
sudo tyxe-pool-node list
sudo tyxe-pool-node add
sudo tyxe-pool-node remove
```

Nodes can also be added/removed in the web panel.

The EXIT installer prints a per-node API token. Add that token together with the node address and agent port on the controller. Prefer an AWG/private tunnel address when available; the v0.2 agent API itself is HTTP and should not be exposed over an untrusted network.

## Panel access

By default the controller binds to `127.0.0.1:9101`.

Example SSH tunnel:

```bash
ssh -L 9101:127.0.0.1:9101 root@ENTER_VPS_IP
```

Then open:

```text
http://127.0.0.1:9101/
```

## Certificates

Certificates are deliberately **persistent** and are not part of the rollback manifest.

Certificates issued by tyxe_pool are kept outside the rollback tree in:

```text
/var/lib/tyxe-pool-persistent/letsencrypt/live/<domain>/
```

If a matching certificate already exists in the system-standard `/etc/letsencrypt/live/<domain>/`, the installer can reuse it as well. A v0.1 custom ACME store is migrated to the persistent store on upgrade.

On reinstall, the installer checks for an existing certificate and offers:

```text
1) Reuse existing certificate
2) Issue a new certificate
3) Skip for now
```

This avoids needless repeated ACME issuance while developing/testing tyxe_pool.

## Rollback / uninstall

Preview:

```bash
sudo ./uninstall.sh --dry-run
```

Full project rollback:

```bash
sudo ./uninstall.sh
```

The rollback engine is also installed locally:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --dry-run
sudo /usr/local/sbin/proxy-pool-rollback --purge-state
```

Let’s Encrypt certificates are intentionally preserved.

## Development rule

Never commit real credentials, including:

- GitHub tokens;
- Cloudflare tokens;
- SSH private keys;
- node-agent tokens;
- Telemt user secrets;
- TLS private keys;
- generated `.env`/credential files.
