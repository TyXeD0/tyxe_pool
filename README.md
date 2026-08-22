# tyxe_pool

Private-development MVP for a self-hosted Telemt enter/exit pool.

Current target topology:

```text
Client -> RU enter -> selfsteal/classifier -> HAProxy -> AWG -> PL exit(s) -> Telemt
```

## Status

`v0.1.1` is an intentionally conservative bootstrap milestone. It focuses on repeatable install/rollback before the final dataplane is enabled.

Currently included:

- interactive Ubuntu/Debian installer;
- RU `controller` role;
- exit `agent` role;
- minimal dashboard/API;
- HAProxy configuration template;
- HTTP selfsteal placeholder + optional Let's Encrypt issuance;
- transactional file backups and rollback;
- `uninstall.sh` full project rollback entry point;
- private-GitHub bootstrap support.

Not production-ready yet:

- final 443 MTProto/web classifier;
- AWG provisioning;
- Telemt installation/config synchronization;
- centralized user secrets;
- Globalping and end-to-end health checks;
- automatic HAProxy backend lifecycle;
- production authentication/mTLS for agents.

## Install from a clone

```bash
git clone git@github.com:OWNER/tyxe_pool.git
cd tyxe_pool
sudo ./install.sh
```

The installer is interactive and asks whether the node is a controller or agent.

## Rollback / uninstall

Dry run:

```bash
sudo ./uninstall.sh --dry-run
```

Full rollback:

```bash
sudo ./uninstall.sh
```

The installed system also has a local rollback command, so GitHub does not need to be reachable to recover:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --dry-run
sudo /usr/local/sbin/proxy-pool-rollback --purge-state
```

## Private GitHub bootstrap

Because the repository is private, anonymous `raw.githubusercontent.com/.../install.sh | bash` is not available. See [`docs/GITHUB_PRIVATE.md`](docs/GITHUB_PRIVATE.md) for read-only deploy-key/token options.

## Security rule

Never commit:

- GitHub tokens;
- Cloudflare tokens;
- SSH private keys;
- Telemt user secrets;
- TLS private keys;
- generated credentials.

The `.gitignore` blocks common secret-file patterns, but it is not a substitute for reviewing commits before push.
