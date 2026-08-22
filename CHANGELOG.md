# Changelog

## 0.2.0

- Added Russian/English language selection and localized web panel.
- Changed all installer menus to numeric choices and y/n confirmations.
- Certificates are now persistent across rollback/uninstall.
- Added detection/reuse of an existing Let’s Encrypt certificate.
- Installer manifest now accumulates across upgrades; failed attempts roll back only their own transaction.
- Added `tyxe-pool-node` CLI Node Manager.
- Added add/remove-node form to the controller panel.
- Added per-node agent API token.
- Added Telemt status, uptime, load and memory reporting from agents.
- Added optional node registration at the end of controller installation.
