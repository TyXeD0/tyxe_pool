# Private GitHub workflow

The repository is designed to remain private during development.

## Important

A private GitHub repository cannot be fetched anonymously from `raw.githubusercontent.com`.
Use one of these methods:

1. Read-only SSH deploy key + `git clone` (recommended for long-lived VPS nodes).
2. A fine-grained GitHub token with read-only Contents access, exported temporarily as `GITHUB_TOKEN`.
3. GitHub CLI (`gh auth login`) and a normal private clone.

Never put a GitHub token directly into a URL, shell history, config file, or this repository.

## Local clone install

```bash
git clone git@github.com:OWNER/tyxe_pool.git
cd tyxe_pool
sudo ./install.sh
```

## Remote bootstrap from private GitHub

Fetch the bootstrap `install.sh` via the GitHub Contents API, then it downloads the complete repository archive and starts the interactive installer.

Set `TYXE_POOL_REPO=OWNER/tyxe_pool` and provide a read-only `GITHUB_TOKEN` in the environment/session.

## Uninstall

After installation the rollback engine is local:

```bash
sudo /usr/local/sbin/proxy-pool-rollback --dry-run
sudo /usr/local/sbin/proxy-pool-rollback --purge-state
```

or from a clone:

```bash
sudo ./uninstall.sh --dry-run
sudo ./uninstall.sh
```
