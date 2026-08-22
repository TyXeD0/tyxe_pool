// ── Custom egress manager ───────────────────────────────────────────────────

export type EgressMode = 'auto' | 'pl1' | 'pl2' | 'block';

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
    tunnel_rtt_ms?: number | null;
    telegram: boolean;
    routing?: boolean;
    nftables?: boolean;
  };
  agent?: EgressAgentStatus;
  system?: EgressSystemStatus | null;
}

export interface EgressStatus {
  version?: string;
  timestamp?: string;
  mode: EgressMode;
  active_node: string;
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

  setMode: (mode: EgressMode) =>
    request<EgressStatus>(EGRESS_BASE, '/mode', {
      method: 'POST',
      body: JSON.stringify({ mode }),
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
