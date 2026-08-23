# MTProxyL Panel — Dynamic Egress UI

Custom UI integration for the MTProxyL Dynamic Egress manager.

Base upstream:
- MTProxyL v1.5.6
- MTProxyL Panel v1.0.14
- upstream commit `8e6ef1d598a2d4f3af2b4a81ac028b0f9ae7afe5`

Custom panel version: `1.0.14-egress2`.

## What it adds

- `/egress` page / `Выходные ноды` menu item;
- arbitrary number of EXIT nodes from `/etc/mtproxyl-egress/nodes.d/`;
- stable node ID plus editable display name;
- compact cards sorted by AUTO priority;
- expandable AWG, Telemt, agent, CPU, RAM, disk, network and uptime metrics;
- AUTO / DIRECT / BLOCK plus manual selection of any healthy enabled node;
- node test, rename, enable/disable and priority controls;
- Telemt writers, coverage and NAT IP status;
- failover settings and recent egress events;
- authenticated `/api/egress/*` endpoints.

The panel remains unprivileged. State-changing actions go through one validated root bridge at
`/usr/local/sbin/mtproxyl-egress-panel-bridge`, allowed by a dedicated sudoers rule.

Adding/removing EXIT nodes over SSH is intentionally the next milestone; the button is visible but
disabled until the provisioner is connected.

## Install on ENTER

Dynamic Egress v1 must already be active.

```bash
rm -rf /tmp/tyxe_pool-panel && \
git clone --depth 1 --branch feature/dynamic-egress-nodes \
  https://github.com/TyXeD0/tyxe_pool.git /tmp/tyxe_pool-panel && \
sudo bash /tmp/tyxe_pool-panel/panel-egress/install.sh
```

## Rollback

```bash
sudo /root/rollback-mtproxyl-panel-egress.sh
```

Rollback restores the previous Panel binary, bridge and sudoers integration. Dynamic Egress,
AWG tunnels, routing and node-agents are not changed.

## Updating

The custom build may check upstream Panel releases but blocks applying an upstream Panel binary,
including auto-apply. Rebase `panel-egress/` onto a newer upstream Panel first, then rebuild/install
the custom version.
