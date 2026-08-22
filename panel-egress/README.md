# MTProxyL Panel — Egress UI

Custom UI integration for the MTProxyL AWG egress manager.

Base upstream:
- MTProxyL v1.5.6
- MTProxyL Panel v1.0.14
- upstream commit `8e6ef1d598a2d4f3af2b4a81ac028b0f9ae7afe5`

Custom panel version: `1.0.14-egress1`.

## What it adds

- `/egress` page / `Выходные ноды` menu item;
- PL1 / PL2 health and ACTIVE/STANDBY state;
- AWG handshake and traffic counters;
- ENTER → EXIT RTT and Telegram reachability;
- node-agent CPU, load, RAM, disk, network and uptime;
- AUTO / PL1 / PL2 / BLOCK controls;
- failover settings: check interval, failure threshold, failback hold, handshake age;
- recent switch events;
- authenticated `/api/egress/*` endpoints.

The panel remains unprivileged. State-changing actions go through one validated root bridge at `/usr/local/sbin/mtproxyl-egress-panel-bridge`, allowed by a dedicated sudoers rule.

## Install on ENTER

```bash
rm -rf /tmp/tyxe_pool-panel && \
git clone --depth 1 https://github.com/TyXeD0/tyxe_pool.git /tmp/tyxe_pool-panel && \
sudo bash /tmp/tyxe_pool-panel/panel-egress/install.sh
```

## Rollback

```bash
sudo /root/rollback-mtproxyl-panel-egress.sh
```

Rollback restores only the official Panel binary/integration. AWG, routing, failover manager and node-agents are preserved.

## Updating

The custom build may check upstream Panel releases but blocks applying the upstream Panel binary, including auto-apply. This prevents `/egress` from being overwritten. Rebase `panel-egress/` onto a newer upstream Panel first, then rebuild/install the custom version.
