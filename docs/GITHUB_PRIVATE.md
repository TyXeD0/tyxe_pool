# GitHub repository status

`tyxe_pool` is now intended to be hosted as a **public** GitHub repository so bootstrap installation can run anonymously with `curl`/`wget`.

Do not commit generated credentials or machine-specific secrets. Runtime secrets belong on the VPS under `/etc/proxy-pool/` and are excluded from source control.

Public install example:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/tyxe_pool/main/install.sh \
  | sudo bash -s -- --repo OWNER/tyxe_pool
```
