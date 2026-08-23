// ── Custom egress manager ───────────────────────────────────────────────────

export type EgressMode = 'auto' | 'direct' | 'block' | 'manual';

export interface EgressAgentStatus {
  reachable: boolean;
  request_ms?: number | null;
  version?: string | null;
  error?: string | null;
}

export interface EgressCPUStatus {
  usage_percent?: number;
  load1?: number;
  load5?: number;
  load15?: number;
  logical_cpus?: number;
}

export interface EgressMemoryStatus {
  total_bytes?: number;
  used_bytes?: number;
  available_bytes?: number;
  usage_percent?: number;
}

export interface EgressDiskStatus {
  mount?: string;
  total_bytes?: number;
  used_bytes?: number;
  available_bytes?: number;
  usage_percent?: number;
}

export interface EgressNetworkStatus {
  interface?: string | null;
  rx_bytes?: number;
  tx_bytes?: number;
  rx_bytes_per_sec?: number;
  tx_bytes_per_sec?: number;
  rx_bits_per_sec?: number;
  tx_bits_per_sec?: number;
}

export interface EgressSystemStatus {
  hostname?: string | null;
  uptime_sec?: number;
  cpu?: EgressCPUStatus;
  memory?: EgressMemoryStatus;
  disk?: EgressDiskStatus;
  network?: EgressNetworkStatus;
}

export interface EgressNodeStatus {
  id: string;
  name: string;
  migration_source?: string;
  enabled: boolean;
  priority: number;
  role: string;
  public_ip: string;
  health: boolean;
  fail_count?: number;
  awg: {
    interface: string;
    up: boolean;
    handshake_age_sec: number;
    rx_bytes?: number;
    tx_bytes?: number;
  };
  connectivity: {
    tunnel?: boolean;
    tunnel_rtt_ms?: number | null;
    telegram: boolean;
    telegram_tcp_ms?: number | null;
    routing?: boolean;
    nftables?: boolean;
  };
  agent?: EgressAgentStatus;
  system?: EgressSystemStatus | null;
}

export interface EgressTelemtStatus {
  nat_ip?: string | null;
  dc_available?: boolean | null;
  dc_verdict?: string | null;
  dc_coverage_pct?: number | null;
  alive_writers?: number | null;
  required_writers?: number | null;
}

export interface EgressStatus {
  version?: string;
  timestamp?: string;
  phase?: string;
  mode: EgressMode;
  manual_node?: string | null;
  active_node: string;
  last_error?: string | null;
  telemt?: EgressTelemtStatus;
  nodes: EgressNodeStatus[];
}

export interface EgressConfig {
  check_interval: number;
  fail_threshold: number;
  failback_hold: number;
  handshake_max_age: number;
}

const EGRESS_BASE = `${BASE}/api/egress`;

export const egressApi = {
  status: () => request<EgressStatus>(EGRESS_BASE, '/status'),

  setMode: (mode: EgressMode, node?: string) =>
    request<EgressStatus>(EGRESS_BASE, '/mode', {
      method: 'POST',
      body: JSON.stringify({ mode, node }),
    }),

  testNode: (node: string) =>
    request<EgressNodeStatus>(EGRESS_BASE, `/nodes/${encodeURIComponent(node)}/test`, {
      method: 'POST',
    }),

  renameNode: (node: string, name: string) =>
    request<Record<string, unknown>>(EGRESS_BASE, `/nodes/${encodeURIComponent(node)}`, {
      method: 'PATCH',
      body: JSON.stringify({ name }),
    }),

  setNodeEnabled: (node: string, enabled: boolean) =>
    request<Record<string, unknown>>(EGRESS_BASE, `/nodes/${encodeURIComponent(node)}`, {
      method: 'PATCH',
      body: JSON.stringify({ enabled }),
    }),

  setNodePriority: (node: string, priority: number) =>
    request<Record<string, unknown>>(EGRESS_BASE, `/nodes/${encodeURIComponent(node)}`, {
      method: 'PATCH',
      body: JSON.stringify({ priority }),
    }),

  config: () => request<EgressConfig>(EGRESS_BASE, '/config'),

  saveConfig: (config: EgressConfig) =>
    request<EgressConfig>(EGRESS_BASE, '/config', {
      method: 'PUT',
      body: JSON.stringify(config),
    }),

  events: (limit = 30) =>
    request<string[]>(EGRESS_BASE, `/events?limit=${limit}`),
};
