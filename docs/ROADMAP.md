# tyxe_pool roadmap

## v0.2.0 — Node Manager foundation

- RU/EN installer and UI.
- Persistent Let’s Encrypt certificate reuse.
- Transactional multi-version rollback.
- EXIT agent registration from CLI and web UI.
- Agent authentication and basic system/Telemt status.

## v0.3.0 — Remote provisioning + Telemt control

Planned:

- add a new EXIT by SSH from the controller;
- copy/install tyxe_pool agent remotely;
- discover an existing Telemt installation;
- install Telemt only after explicit confirmation;
- backup Telemt configuration before every change;
- start/stop/restart/update Telemt from the panel;
- centralized logs;
- desired/actual configuration version tracking.

## v0.4.0 — Central users/secrets

Planned:

- one source of truth for Telemt users;
- same user secret on every EXIT;
- create/disable/remove users from one panel;
- atomic config deployment and rollback;
- per-node synchronization state.

## v0.5.0 — Multi-exit dataplane

Planned:

- multiple RU→EXIT transports;
- HAProxy backend generation;
- leastconn / roundrobin / weighted / primary-backup modes;
- UP / DOWN / DRAIN / DISABLED states;
- graceful reload and maintenance mode.

## v0.6.0 — Health and Globalping

Planned:

- Globalping availability checks;
- tunnel checks;
- Telemt checks;
- end-to-end Telegram path checks;
- automatic exit quarantine/recovery with hysteresis.

## v0.7.0 — Selfsteal shared :443

Planned:

- shared-port classifier;
- ordinary HTTPS decoy site for unrelated traffic;
- proxy traffic forwarded to dataplane;
- panel kept on a separate management endpoint;
- configurable decoy website and certificate lifecycle.
