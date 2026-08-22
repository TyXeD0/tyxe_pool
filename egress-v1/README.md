# Dynamic Egress Nodes v1

This branch starts the migration from the fixed `PL1/PL2` prototype to a dynamic
node registry.

## Design rules

- every node has an immutable internal ID (`n-xxxxxxxx`);
- the display name is editable and does **not** rename Linux/AWG interfaces;
- failover order is represented by an integer priority (`10, 20, 30, ...`);
- SSH credentials are provisioning-only and are never stored in the node registry;
- node monitoring/agent health is separate from traffic health;
- AUTO is fail-closed: if no enabled EXIT node is healthy, Telegram is blocked,
  never silently sent through ENTER;
- DIRECT will be an explicit administrator-only mode, never an automatic fallback.

## Registry

Global configuration:

```text
/etc/mtproxyl-egress/config.toml
```

Nodes:

```text
/etc/mtproxyl-egress/nodes.d/n-xxxxxxxx.toml
```

A node keeps both its immutable ID and its mutable name. Existing `awg-pl1` and
`awg-pl2` interfaces are intentionally preserved during migration.

## Milestone 1 — safe live migration

`install-migrate.sh` imports the currently working PL1/PL2 deployment into the
new registry without changing:

- nftables;
- policy routing;
- AmneziaWG;
- Telemt;
- the existing failover manager.

Run on ENTER:

```bash
rm -rf /tmp/tyxe-egress-v1
git clone --depth 1 --branch feature/dynamic-egress-nodes \
  https://github.com/TyXeD0/tyxe_pool.git /tmp/tyxe-egress-v1
sudo bash /tmp/tyxe-egress-v1/egress-v1/install-migrate.sh
```

Commands after migration:

```bash
mtproxyl-egress-node list
mtproxyl-egress-node show PL1
mtproxyl-egress-node rename PL1 "Poland Main"
mtproxyl-egress-node validate
```

Renaming changes only the human-readable name in the registry.

## Next milestones

1. Replace the fixed shell failover manager with `mtproxyl-egressd`, reading all
   enabled nodes from `nodes.d`.
2. Add dynamic priority, enable/disable, manual selection, DIRECT and BLOCK.
3. Add SSH provisioner:
   - automatic existing SSH credentials;
   - password;
   - private key.
4. Add node add/test/remove/cleanup workflows.
5. Expose the same operations through the MTProxyL Panel.
6. Convert the Egress page to compact cards with expandable system metrics.
