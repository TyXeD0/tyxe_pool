import { useCallback, useEffect, useMemo, useState } from 'react';
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

interface NodeCardProps {
  node: EgressNodeStatus;
  active: boolean;
  busy: boolean;
  onSwitch: (node: string) => Promise<void>;
  onTest: (node: string) => Promise<EgressNodeStatus>;
  onRename: (node: string, name: string) => Promise<void>;
  onEnabled: (node: string, enabled: boolean) => Promise<void>;
  onPriority: (node: string, priority: number) => Promise<void>;
}

function NodeCard({
  node,
  active,
  busy,
  onSwitch,
  onTest,
  onRename,
  onEnabled,
  onPriority,
}: NodeCardProps) {
  const [expanded, setExpanded] = useState(false);
  const [name, setName] = useState(node.name);
  const [priority, setPriority] = useState(String(node.priority));
  const [testMessage, setTestMessage] = useState<string | null>(null);

  useEffect(() => setName(node.name), [node.name]);
  useEffect(() => setPriority(String(node.priority)), [node.priority]);

  const system = node.system;
  const cpu = system?.cpu;
  const memory = system?.memory;
  const disk = system?.disk;
  const network = system?.network;
  const agent = node.agent;

  const roleLabel = node.role === 'primary'
    ? 'PRIMARY'
    : node.role === 'backup'
      ? 'BACKUP'
      : 'DISABLED';

  const test = async () => {
    setTestMessage('Проверка...');
    try {
      const result = await onTest(node.id);
      const rtt = result.connectivity?.tunnel_rtt_ms;
      setTestMessage(
        `${result.health ? 'HEALTHY' : 'DOWN'} · Telegram ${result.connectivity?.telegram ? 'OK' : 'FAIL'}`
        + `${rtt != null ? ` · RTT ${rtt} ms` : ''}`,
      );
    } catch (e) {
      setTestMessage(e instanceof Error ? e.message : 'Ошибка проверки');
    }
  };

  const rename = async () => {
    const value = name.trim();
    if (!value || value === node.name) return;
    await onRename(node.id, value);
  };

  const savePriority = async () => {
    const value = Number(priority);
    if (!Number.isInteger(value) || value < 1 || value > 9999 || value === node.priority) return;
    await onPriority(node.id, value);
  };

  const toggleEnabled = async () => {
    if (node.enabled && active) {
      const ok = window.confirm(
        `Нода "${node.name}" сейчас активна. Отключить её из AUTO? Egress переключится на следующую здоровую ноду или BLOCK.`,
      );
      if (!ok) return;
    }
    await onEnabled(node.id, !node.enabled);
  };

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <div className="font-semibold text-text-primary truncate">{node.name}</div>
            <Badge variant={node.role === 'primary' ? 'default' : 'outline'}>{roleLabel}</Badge>
            {active && <Badge variant="success">ACTIVE</Badge>}
          </div>
          <div className="text-xs text-text-secondary mt-1">
            {node.public_ip || '—'} · {node.id} · priority {node.priority}
          </div>
        </div>
        <Badge variant={!node.enabled ? 'warning' : node.health ? 'success' : 'danger'}>
          {!node.enabled ? 'DISABLED' : node.health ? 'HEALTHY' : 'DOWN'}
        </Badge>
      </div>

      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3">
        <Metric label="AWG" value={node.awg.up ? 'UP' : 'DOWN'} />
        <Metric
          label="RTT ENTER → EXIT"
          value={node.connectivity.tunnel_rtt_ms != null ? `${node.connectivity.tunnel_rtt_ms} ms` : '—'}
        />
        <Metric label="Telegram" value={node.connectivity.telegram ? 'OK' : 'FAIL'} />
        <Metric label="Agent" value={agent?.reachable ? 'ONLINE' : 'OFFLINE'} />
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant="outline" onClick={() => setExpanded((v) => !v)}>
          {expanded ? 'Скрыть подробности ▲' : 'Подробнее ▼'}
        </Button>
        <Button
          size="sm"
          variant="outline"
          disabled={busy || active || !node.enabled || !node.health}
          onClick={() => void onSwitch(node.id)}
        >
          Сделать активной
        </Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void test()}>
          Проверить
        </Button>
        {testMessage && <span className="text-xs text-text-secondary">{testMessage}</span>}
      </div>

      {expanded && (
        <div className="border-t border-border pt-4 space-y-4">
          <div className="grid grid-cols-2 xl:grid-cols-4 gap-3">
            <Metric label="AWG interface" value={node.awg.interface || '—'} />
            <Metric
              label="Handshake"
              value={node.awg.handshake_age_sec >= 0 ? `${node.awg.handshake_age_sec} с` : '—'}
            />
            <Metric label="AWG RX / TX" value={`↓ ${bytes(node.awg.rx_bytes)} · ↑ ${bytes(node.awg.tx_bytes)}`} />
            <Metric label="Счётчик ошибок" value={String(node.fail_count ?? 0)} />
            <Metric
              label="Telegram TCP"
              value={node.connectivity.telegram_tcp_ms != null ? `${node.connectivity.telegram_tcp_ms} ms` : '—'}
            />
            <Metric
              label="Agent RTT"
              value={agent?.reachable && agent.request_ms != null ? `${agent.request_ms} ms` : '—'}
            />
            <Metric label="Agent version" value={agent?.version || '—'} />
            <Metric label="Node ID" value={node.id} />
          </div>

          {system ? (
            <div className="space-y-3">
              <div className="text-xs text-text-secondary">{system.hostname || 'Системные метрики'}</div>
              <div className="grid grid-cols-2 xl:grid-cols-4 gap-3">
                <Metric label="CPU" value={`${cpu?.usage_percent ?? 0}% · ${cpu?.logical_cpus ?? '—'} CPU`} />
                <Metric label="Load" value={`${cpu?.load1 ?? 0} / ${cpu?.load5 ?? 0} / ${cpu?.load15 ?? 0}`} />
                <Metric label="RAM" value={`${bytes(memory?.used_bytes)} / ${bytes(memory?.total_bytes)} · ${memory?.usage_percent ?? 0}%`} />
                <Metric label="Диск /" value={`${bytes(disk?.used_bytes)} / ${bytes(disk?.total_bytes)} · ${disk?.usage_percent ?? 0}%`} />
                <Metric
                  label={`Сеть ${network?.interface || ''}`}
                  value={`↓ ${bitrate(network?.rx_bits_per_sec)} · ↑ ${bitrate(network?.tx_bits_per_sec)}`}
                />
                <Metric label="Сеть всего" value={`↓ ${bytes(network?.rx_bytes)} · ↑ ${bytes(network?.tx_bytes)}`} />
                <Metric label="Uptime" value={uptime(system.uptime_sec)} />
              </div>
            </div>
          ) : (
            <div className="text-xs text-warning">Системные метрики недоступны — node-agent не отвечает.</div>
          )}

          <div className="border-t border-border pt-4 space-y-3">
            <div className="text-sm font-medium text-text-primary">Управление нодой</div>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
              <div className="space-y-2">
                <div className="text-xs text-text-secondary">
                  Имя можно менять свободно. Внутренний ID и AWG interface не переименовываются.
                </div>
                <div className="flex gap-2">
                  <Input value={name} maxLength={64} onChange={(e) => setName(e.target.value)} />
                  <Button size="sm" disabled={busy || !name.trim() || name.trim() === node.name} onClick={() => void rename()}>
                    Переименовать
                  </Button>
                </div>
              </div>

              <div className="space-y-2">
                <div className="text-xs text-text-secondary">Меньшее значение = более высокий приоритет AUTO.</div>
                <div className="flex gap-2">
                  <Input
                    type="number"
                    min={1}
                    max={9999}
                    value={priority}
                    onChange={(e) => setPriority(e.target.value)}
                  />
                  <Button size="sm" disabled={busy || Number(priority) === node.priority} onClick={() => void savePriority()}>
                    Сохранить
                  </Button>
                </div>
              </div>
            </div>

            <Button
              size="sm"
              variant={node.enabled ? 'danger' : 'outline'}
              disabled={busy}
              onClick={() => void toggleEnabled()}
            >
              {node.enabled ? 'Отключить из AUTO' : 'Включить ноду'}
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}

function ModeCard({
  status,
  busy,
  onMode,
}: {
  status: EgressStatus;
  busy: boolean;
  onMode: (mode: EgressMode) => void;
}) {
  const activeNode = status.nodes.find((n) => n.id === status.active_node);
  const telemt = status.telemt;

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div>
          <div className="text-sm font-medium text-text-primary">Управление маршрутом</div>
          <div className="text-xs text-text-secondary mt-1">
            Режим: {status.mode.toUpperCase()} · активный выход: {activeNode?.name || status.active_node || '—'}
          </div>
          <div className="text-xs text-text-secondary mt-1">
            Telemt: writers {telemt?.alive_writers ?? '—'}/{telemt?.required_writers ?? '—'}
            {' · '}coverage {telemt?.dc_coverage_pct ?? '—'}%
            {' · '}NAT {telemt?.nat_ip || '—'}
          </div>
        </div>
        <Badge
          variant={
            status.active_node === 'block'
              ? 'danger'
              : status.phase === 'running'
                ? 'success'
                : 'warning'
          }
        >
          {status.phase?.toUpperCase() || 'UNKNOWN'}
        </Badge>
      </div>

      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          variant={status.mode === 'auto' ? 'default' : 'outline'}
          disabled={busy || status.mode === 'auto'}
          onClick={() => onMode('auto')}
        >
          AUTO
        </Button>
        <Button
          size="sm"
          variant={status.mode === 'direct' ? 'default' : 'outline'}
          disabled={busy || status.mode === 'direct'}
          onClick={() => onMode('direct')}
        >
          DIRECT
        </Button>
        <Button
          size="sm"
          variant="danger"
          disabled={busy || status.mode === 'block'}
          onClick={() => onMode('block')}
        >
          BLOCK
        </Button>
      </div>

      <p className="text-xs text-text-secondary">
        AUTO выбирает первую здоровую enabled-ноду по приоритету. DIRECT включается только вручную.
        При отказе всех EXIT в AUTO используется BLOCK, а не прямой выход через ENTER.
      </p>

      {status.last_error && (
        <div className="text-xs text-danger break-all">Последняя ошибка: {status.last_error}</div>
      )}
    </Card>
  );
}

function ConfigCard({
  config,
  busy,
  onSave,
}: {
  config: EgressConfig;
  busy: boolean;
  onSave: (config: EgressConfig) => void;
}) {
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
          Настройки применяются динамическим egress daemon. AWG и Telemt без необходимости не перезапускаются.
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

  const nodes = useMemo(
    () => [...(status?.nodes || [])].sort((a, b) => a.priority - b.priority || a.name.localeCompare(b.name)),
    [status],
  );

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

  const refreshAfterMutation = async () => {
    const [nextStatus, nextEvents] = await Promise.all([egressApi.status(), egressApi.events(30)]);
    setStatus(nextStatus);
    setEvents(nextEvents);
  };

  const setMode = async (mode: EgressMode, node?: string) => {
    if (mode === 'block' && !window.confirm('Включить BLOCK? Telegram-трафик будет принудительно заблокирован.')) return;
    if (mode === 'direct' && !window.confirm('Включить DIRECT? Telegram будет выходить напрямую через ENTER, минуя EXIT-ноды.')) return;
    setBusy(true);
    try {
      setStatus(await egressApi.setMode(mode, node));
      setEvents(await egressApi.events(30));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить egress');
    } finally {
      setBusy(false);
    }
  };

  const mutate = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await fn();
      await refreshAfterMutation();
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось изменить ноду');
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
          Динамические AmneziaWG EXIT-ноды для Telegram. Количество нод не ограничено; для обычной схемы рекомендуется до 5.
          AUTO использует порядок priority и работает fail-closed.
        </p>

        {error && <ErrorAlert message={error} onRetry={loadAll} />}

        {status && (
          <>
            <ModeCard status={status} busy={busy} onMode={(mode) => void setMode(mode)} />

            <div className="flex items-center justify-between gap-3">
              <div className="text-sm font-medium text-text-primary">
                Ноды: {nodes.length}
              </div>
              <Button size="sm" variant="outline" disabled title="Будет включено после подключения SSH provisioner">
                + Добавить ноду
              </Button>
            </div>

            <div className="grid grid-cols-1 2xl:grid-cols-2 gap-4">
              {nodes.map((node) => (
                <NodeCard
                  key={node.id}
                  node={node}
                  active={status.active_node === node.id}
                  busy={busy}
                  onSwitch={async (id) => {
                    await setMode('manual', id);
                  }}
                  onTest={(id) => egressApi.testNode(id)}
                  onRename={(id, name) => mutate(() => egressApi.renameNode(id, name))}
                  onEnabled={(id, enabled) => mutate(() => egressApi.setNodeEnabled(id, enabled))}
                  onPriority={(id, priority) => mutate(() => egressApi.setNodePriority(id, priority))}
                />
              ))}
            </div>
          </>
        )}

        {config && <ConfigCard config={config} busy={busy} onSave={(value) => void saveConfig(value)} />}

        <Card className="p-4">
          <div className="text-sm font-medium text-text-primary mb-3">События Egress</div>
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
