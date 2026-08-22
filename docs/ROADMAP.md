# Roadmap

## v0.2.1 — panel/auth/bootstrap

Public curl bootstrap, bilingual authenticated controller, persistent TLS and single ENTER + single EXIT development topology.

## v0.3.0 — Telemt + MTProxyL on EXIT

Planned first real proxy-engine milestone:

- install MTProxyL on the EXIT node using its argument-driven manager installation;
- use Telemt as the engine;
- expose only the tunnel-side Telemt listener when double-hop mode is enabled;
- choose/store FakeTLS/SNI settings centrally;
- install/own the Telemt engine through MTProxyL Manager and expose MTProxyL controls/metrics to TYXE;
- keep client-facing TCP anti-DPI fixes separate until the ENTER dataplane is active (the client TCP session terminates at ENTER/HAProxy, so those rules must be validated on ENTER rather than assumed to work on EXIT);
- read Telemt REST API/metrics from TYXE agent;
- start/stop/restart/update engine from the main TYXE panel;
- backup configuration before every write;
- rollback the TYXE-created MTProxyL/Telemt installation without touching persistent TLS.

## v0.4.0 — users/secrets

- central user database;
- create/disable users in TYXE panel;
- deterministic synchronization to EXIT Telemt;
- desired/actual config revisions;
- traffic/connection aggregation.

## v0.5.0 — transport, dataplane and client-facing fixes

- AmneziaWG ENTER<->EXIT setup;
- HAProxy/TCP forwarding based on Telemt double-hop design;
- preserve Proxy Protocol where required;
- validate/apply the selected MTProxyL-derived client-facing TCP fix profile on ENTER;
- end-to-end health state.

## v0.6.0 — selfsteal/shared 443

- final shared-port entry classifier;
- normal web decoy for unrelated traffic;
- panel hostname coexistence;
- no management information on proxy hostname.

## v0.7.0 — Globalping and failover groundwork

- Globalping integration;
- Russia-region reachability checks;
- Telegram end-to-end probes;
- health history/events.

## Later

Only after one ENTER + one EXIT is stable: enable PL2/PL3 and HAProxy balancing/failover policies.
