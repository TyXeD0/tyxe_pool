# Changelog

## v0.2.1

- Switched remote bootstrap to anonymous downloads from a public GitHub repository.
- Added `--repo OWNER/tyxe_pool` and `--ref` bootstrap options.
- Added administrator username/password wizard for the controller.
- Passwords are stored as PBKDF2-SHA256 hashes, never plaintext.
- Added localized login screen and signed HttpOnly sessions.
- Added SameSite cookie and CSRF protection for browser mutations.
- Added separate local API bearer token for `tyxe-pool-node`.
- Added optional Internet-facing panel via nginx HTTPS reverse proxy while controller remains on localhost.
- Added separate panel-domain certificate reuse/issuance.
- Added nginx per-IP login throttling for public panel mode.
- Development topology temporarily fixed to one ENTER + one EXIT.

## v0.2.0

- Bilingual installer/panel.
- Persistent certificates.
- Node Manager MVP.
