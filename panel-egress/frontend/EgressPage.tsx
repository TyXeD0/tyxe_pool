import { useCallback, useEffect, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import {
  egressApi,
  type EgressConfig,
  type EgressMode,
  type EgressNodeStatus,
  type EgressStatus,
} from '@/lib/api';

function bytes(value?: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—';
  let v = value;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  for (const unit of units) {
    if (Math.abs(v) < 1024) return `${v.toFixed(v >= 100 ? 0 : 1)} ${unit}`;
    v /= 1024;
  }
  return `${v.toFixed(1)} PB`;
}

function bitrate(value?: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—';
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)} Gbit/s`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)} Mbit/s`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)} Kbit/s`;
  return `${value.toFixed(0)} bit/s`;
}

function uptime(value?: number | null): string {
  if (value == null || value < 0) return '—';
  const days = Math.floor(value / 86400);
  const hours = Math.floor((value % 86400) / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  if (days > 0) return `${days} д ${hours} ч`;
  if (hours > 0) return `${hours} ч ${minutes} мин`;
  return `${minutes} мин`;
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <div className="text-xs text-text-secondary">{label}</div>
      <div className="text-sm text-text-primary truncate" title={value}>{value}</div>
    </div>
  );
}

function NodeCard({ node, active }: { node: EgressNodeStatus; active: boolean }) {
  const agent = node.agent;
  const system = node.system;
  const cpu = system?.cpu;
  const memory = system?.memory;
  const disk = system?.disk;
  const network = system?.network;

  return (
    <Card className="p-4 space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2 flex-wrap">
            <div className="font-semibold text-text-primary">{node.id.toUpperCase()}</div>
            <Badge variant={node.role === 'primary' ? 'default' : 'outline'}>
              {node.role === 'primary' ? 'PRIMARY' : 'BACKUP'}
            </Badge>
            {active && <Badge variant="success">ACTIVE</Badge>}
          </div>
          <div className="text-xs text-text-secondary mt-1">{node.public_ip}</div>
        </div>
        <Badge variant={node.health ? 'success' : 'danger'}>
          {node.health ? 'HEALTHY' : 'DOWN'}
        </Badge>
      </div>

      <div className="grid grid-cols-2 xl:grid-cols-3 gap-3">
        <Metric label="AWG" value={node.awg.up ? `${node.awg.interface} · UP` : 'DOWN'} />
        <Metric label="Handshake" value={node.awg.handshake_age_sec >= 0 ? `${node.awg.handshake_age_sec} с` : '—'} />
        <Metric label="RTT ENTER → EXIT" value={node.connectivity.tunnel_rtt_ms != null ? `${node.connectivity.tunnel_rtt_ms} ms` : '—'} />
        <Metric label="Telegram" value={node.connectivity.telegram ? 'доступен' : 'недоступен'} />
        <Metric label="Agent" value={agent?.reachable ? `online · ${agent.request_ms ?? '—'} ms` : `offline${agent?.error ? ` · ${agent.error}` : ''}`} />
        <Metric label="Счётчик ошибок" value={String(node.fail_count ?? 0)} />
      </div>

      {system ? (
        <div className="border-t border-border pt-4">
          <div className="text-xs text-text-secondary mb-3">{system.hostname || 'Системные метрики'}</div>
          <div className="grid grid-cols-2 xl:grid-cols-3 gap-3">
            <Metric label="CPU" value={`${cpu?.usage_percent ?? 0}% · ${cpu?.logical_cpus ?? '—'} CPU`} />
            <Metric label="Load" value={`${cpu?.load1 ?? 0} / ${cpu?.load5 ?? 0} / ${cpu?.load15 ?? 0}`} />
            <Metric label="RAM" value={`${bytes(memory?.used_bytes)} / ${bytes(memory?.total_bytes)} · ${memory?.usage_percent ?? 0}%`} />
            <Metric label="Диск /" value={`${bytes(disk?.used_bytes)} / ${bytes(disk?.total_bytes)} · ${disk?.usage_percent ?? 0}%`} />
            <Metric label={`Сеть ${network?.interface || ''}`} value={`↓ ${bitrate(network?.rx_bits_per_sec)} · ↑ ${bitrate(network?.tx_bits_per_sec)}`} />
            <Metric label="Сеть всего" value={`↓ ${bytes(network?.rx_bytes)} · ↑ ${bytes(network?.tx_bytes)}`} />
            <Metric label="Uptime" value={uptime(system.uptime_sec)} />
            <Metric label="AWG RX / TX" value={`↓ ${bytes(node.awg.rx_bytes)} · ↑ ${bytes(node.awg.tx_bytes)}`} />
          </div>
        </div>
      ) : (
        <div className="border-t border-border pt-3 text-xs text-warning">
          Метрики системы недоступны — проверьте node-agent.
        </div>
      )}
    </Card>
  );
}

function ModeCard({ status, busy, onMode }: { status: EgressStatus; busy: boolean; onMode: (mode: EgressMode) => void }) {
  const modes: Array<{ mode: EgressMode; label: string; danger?: boolean }> = [
    { mode: 'auto', label: 'AUTO' },
    { mode: 'pl1', label: 'PL1' },
    { mode: 'pl2', label: 'PL2' },
    { mode: 'block', label: 'BLOCK', danger: true },
  ];

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div>
          <div className="text-sm font-medium text-text-primary">Управление маршрутом</div>
          <div className="text-xs text-text-secondary mt-1">
            Текущий режим: {status.mode.toUpperCase()} · активный выход: {status.active_node.toUpperCase()}
          </div>
        </div>
        <Badge variant={status.active_node === 'block' ? 'danger' : status.mode === 'auto' ? 'success' : 'warning'}>
          {status.active_node === 'block' ? 'FAIL-CLOSED' : status.active_node.toUpperCase()}
        </Badge>
      </div>

      <div className="flex flex-wrap gap-2">
        {modes.map((item) => (
          <Button
            key={item.mode}
            size="sm"
            variant={status.mode === item.mode ? (item.danger ? 'danger' : 'default') : (item.danger ? 'danger' : 'outline')}
            disabled={busy || status.mode === item.mode}
            onClick={() => onMode(item.mode)}
          >
            {item.label}
          </Button>
        ))}
      </div>

      <p className="text-xs text-text-secondary">
        AUTO: PL1 основной, PL2 резервный. BLOCK принудительно включает fail-closed и запрещает Telegram egress.
      </p>
    </Card>
  );
}

function ConfigCard({ config, busy, onSave }: { config: EgressConfig; busy: boolean; onSave: (config: EgressConfig) => void }) {
  const [draft, setDraft] = useState<EgressConfig>(config);

  useEffect(() => setDraft(config), [config]);

  const field = (key: keyof EgressConfig, label: string, min: number, max: number) => (
    <label className="space-y-1">
      <span className="text-xs text-text-secondary">{label}</span>
      <Input
        type="number"
        min={min}
        max={max}
        value={draft[key]}
        onChange={(e) => {
          const value = Number(e.target.value);
          setDraft((prev) => ({ ...prev, [key]: Number.isFinite(value) ? value : prev[key] }));
        }}
      />
    </label>
  );

  return (
    <Card className="p-4 space-y-4">
      <div>
        <div className="text-sm font-medium text-text-primary">Failover</div>
        <p className="text-xs text-text-secondary mt-1">
          Изменение параметров перезапускает только egress-manager. AWG и MTProxyL не перезапускаются.
        </p>
      </div>
      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
        {field('check_interval', 'Интервал проверки, с', 2, 60)}
        {field('fail_threshold', 'Ошибок до failover', 1, 10)}
        {field('failback_hold', 'Hold перед failback, с', 5, 600)}
        {field('handshake_max_age', 'Макс. возраст handshake, с', 30, 600)}
      </div>
      <Button size="sm" disabled={busy} onClick={() => onSave(draft)}>Сохранить настройки</Button>
    </Card>
  );
}

export function EgressPage() {
  const [status, setStatus] = useState<EgressStatus | null>(null);
  const [config, setConfig] = useState<EgressConfig | null>(null);
  const [events, setEvents] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadStatus = useCallback(async () => {
    try {
      setStatus(await egressApi.status());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние egress');
    }
  }, []);

  const loadAll = useCallback(async () => {
    setLoading(true);
    try {
      const [nextStatus, nextConfig, nextEvents] = await Promise.all([
        egressApi.status(),
        egressApi.config(),
        egressApi.events(30),
      ]);
      setStatus(nextStatus);
      setConfig(nextConfig);
      setEvents(nextEvents);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось получить состояние egress');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAll();
    const timer = window.setInterval(() => void loadStatus(), 5000);
    return () => window.clearInterval(timer);
  }, [loadAll, loadStatus]);

  const setMode = async (mode: EgressMode) => {
    if (mode === 'block' && !window.confirm('Включить BLOCK? Telegram-трафик будет принудительно заблокирован.')) return;
    setBusy(true);
    try {
      setStatus(await egressApi.setMode(mode));
      setEvents(await egressApi.events(30));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить egress');
    } finally {
      setBusy(false);
    }
  };

  const saveConfig = async (value: EgressConfig) => {
    setBusy(true);
    try {
      setConfig(await egressApi.saveConfig(value));
      await loadStatus();
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить настройки');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <Header title="Выходные ноды" refreshing={loading} onRefresh={loadAll} />
      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <p className="text-sm text-text-secondary max-w-4xl">
          Собственные AmneziaWG egress-ноды для Telegram. Клиенты подключаются к ENTER как раньше; наружу Telegram выходит через активную EXIT-ноду. При отказе обеих нод используется fail-closed.
        </p>

        {error && <ErrorAlert message={error} onRetry={loadAll} />}

        {status && (
          <>
            <ModeCard status={status} busy={busy} onMode={(mode) => void setMode(mode)} />
            <div className="grid grid-cols-1 2xl:grid-cols-2 gap-4">
              {status.nodes.map((node) => (
                <NodeCard key={node.id} node={node} active={status.active_node === node.id} />
              ))}
            </div>
          </>
        )}

        {config && <ConfigCard config={config} busy={busy} onSave={(value) => void saveConfig(value)} />}

        <Card className="p-4">
          <div className="text-sm font-medium text-text-primary mb-3">Последние переключения</div>
          {events.length === 0 ? (
            <div className="text-xs text-text-secondary">Событий пока нет.</div>
          ) : (
            <div className="space-y-1 font-mono text-xs">
              {[...events].reverse().map((line, index) => (
                <div key={`${index}-${line}`} className="text-text-secondary break-all">{line}</div>
              ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
