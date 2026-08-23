import { useCallback, useEffect, useMemo, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ErrorAlert } from '@/components/ErrorAlert';
import {
  egressApi,
  type EgressAddNodeRequest,
  type EgressConfig,
  type EgressJob,
  type EgressMode,
  type EgressNodeStatus,
  type EgressRemoveNodeRequest,
  type EgressSSHAuthMode,
  type EgressStatus,
} from '@/lib/api';

const fieldClass = 'w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-text-primary';

function bytes(value?: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—';
  let v = value;
  for (const unit of ['B', 'KB', 'MB', 'GB', 'TB']) {
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

function AuthFields({
  mode,
  secret,
  onMode,
  onSecret,
}: {
  mode: EgressSSHAuthMode;
  secret: string;
  onMode: (value: EgressSSHAuthMode) => void;
  onSecret: (value: string) => void;
}) {
  return (
    <div className="space-y-2">
      <label className="space-y-1 block">
        <span className="text-xs text-text-secondary">SSH авторизация</span>
        <select className={fieldClass} value={mode} onChange={(e) => onMode(e.target.value as EgressSSHAuthMode)}>
          <option value="auto">Уже настроенный root SSH ключ</option>
          <option value="password">Пароль</option>
          <option value="key">Private key</option>
        </select>
      </label>
      {mode === 'password' && (
        <label className="space-y-1 block">
          <span className="text-xs text-text-secondary">SSH пароль</span>
          <Input type="password" autoComplete="new-password" value={secret} onChange={(e) => onSecret(e.target.value)} />
        </label>
      )}
      {mode === 'key' && (
        <label className="space-y-1 block">
          <span className="text-xs text-text-secondary">Private key</span>
          <textarea
            className={`${fieldClass} min-h-36 font-mono`}
            value={secret}
            onChange={(e) => onSecret(e.target.value)}
            placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
          />
        </label>
      )}
      <p className="text-xs text-text-secondary">
        Credentials используются только для этой операции и не сохраняются в registry или job-логах.
      </p>
    </div>
  );
}

function AddNodeCard({
  busy,
  suggestedPriority,
  onCancel,
  onStart,
}: {
  busy: boolean;
  suggestedPriority: number;
  onCancel: () => void;
  onStart: (request: EgressAddNodeRequest) => Promise<void>;
}) {
  const [name, setName] = useState('');
  const [host, setHost] = useState('');
  const [port, setPort] = useState('22');
  const [priority, setPriority] = useState(String(suggestedPriority));
  const [mode, setMode] = useState<EgressSSHAuthMode>('auto');
  const [secret, setSecret] = useState('');

  const submit = async () => {
    const p = Number(port);
    const prio = Number(priority);
    if (!name.trim() || !host.trim() || !Number.isInteger(p) || p < 1 || p > 65535) return;
    if (!Number.isInteger(prio) || prio < 1 || prio > 9999) return;
    if ((mode === 'password' || mode === 'key') && !secret) return;
    await onStart({
      name: name.trim(),
      host: host.trim(),
      port: p,
      user: 'root',
      priority: prio,
      auth: { mode, secret: mode === 'auto' ? undefined : secret },
    });
    setSecret('');
  };

  return (
    <Card className="p-4 space-y-4 border border-border">
      <div>
        <div className="text-sm font-medium text-text-primary">Добавить EXIT-ноду</div>
        <p className="text-xs text-text-secondary mt-1">
          Нужна чистая Ubuntu 24.04 с root SSH. Provisioner установит AmneziaWG, firewall/NAT и node-agent,
          затем добавит ноду в registry только после успешных проверок.
        </p>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        <label className="space-y-1">
          <span className="text-xs text-text-secondary">Название</span>
          <Input value={name} maxLength={64} onChange={(e) => setName(e.target.value)} placeholder="PL3" />
        </label>
        <label className="space-y-1">
          <span className="text-xs text-text-secondary">IP или домен</span>
          <Input value={host} onChange={(e) => setHost(e.target.value)} placeholder="203.0.113.10" />
        </label>
        <label className="space-y-1">
          <span className="text-xs text-text-secondary">SSH port</span>
          <Input type="number" min={1} max={65535} value={port} onChange={(e) => setPort(e.target.value)} />
        </label>
        <label className="space-y-1">
          <span className="text-xs text-text-secondary">Priority</span>
          <Input type="number" min={1} max={9999} value={priority} onChange={(e) => setPriority(e.target.value)} />
        </label>
      </div>
      <AuthFields mode={mode} secret={secret} onMode={(v) => { setMode(v); setSecret(''); }} onSecret={setSecret} />
      <div className="flex gap-2">
        <Button size="sm" disabled={busy} onClick={() => void submit()}>Начать установку</Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={onCancel}>Отмена</Button>
      </div>
    </Card>
  );
}

function RemoveNodeCard({
  node,
  busy,
  onCancel,
  onStart,
}: {
  node: EgressNodeStatus;
  busy: boolean;
  onCancel: () => void;
  onStart: (request: EgressRemoveNodeRequest) => Promise<void>;
}) {
  const [remoteCleanup, setRemoteCleanup] = useState(false);
  const [fallback, setFallback] = useState<'block' | 'direct'>('block');
  const [mode, setMode] = useState<EgressSSHAuthMode>('auto');
  const [secret, setSecret] = useState('');

  const submit = async () => {
    if (remoteCleanup && (mode === 'password' || mode === 'key') && !secret) return;
    if (!window.confirm(`Удалить ноду "${node.name}"? Локальная конфигурация ENTER будет удалена.`)) return;
    await onStart({
      remote_cleanup: remoteCleanup,
      fallback,
      auth: { mode, secret: remoteCleanup && mode !== 'auto' ? secret : undefined },
    });
    setSecret('');
  };

  return (
    <Card className="p-4 space-y-4 border border-border">
      <div>
        <div className="text-sm font-medium text-text-primary">Удаление: {node.name}</div>
        <p className="text-xs text-text-secondary mt-1">
          Если нода ACTIVE, production сначала уйдёт на другую здоровую EXIT. Для последней ноды используется выбранный fallback.
        </p>
      </div>
      <label className="flex items-start gap-2 text-sm text-text-primary">
        <input type="checkbox" className="mt-1" checked={remoteCleanup} onChange={(e) => setRemoteCleanup(e.target.checked)} />
        <span>
          Очистить удалённую VPS по SSH
          <span className="block text-xs text-text-secondary">Без этого удалится только конфигурация ENTER; AWG/agent на EXIT останутся.</span>
        </span>
      </label>
      <label className="space-y-1 block max-w-sm">
        <span className="text-xs text-text-secondary">Fallback, если это последняя EXIT</span>
        <select className={fieldClass} value={fallback} onChange={(e) => setFallback(e.target.value as 'block' | 'direct')}>
          <option value="block">BLOCK — fail closed</option>
          <option value="direct">DIRECT — через ENTER</option>
        </select>
      </label>
      {remoteCleanup && (
        <AuthFields mode={mode} secret={secret} onMode={(v) => { setMode(v); setSecret(''); }} onSecret={setSecret} />
      )}
      <div className="flex gap-2">
        <Button size="sm" variant="danger" disabled={busy} onClick={() => void submit()}>Удалить ноду</Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={onCancel}>Отмена</Button>
      </div>
    </Card>
  );
}

function JobCard({ job, onDismiss }: { job: EgressJob; onDismiss: () => void }) {
  const active = job.state === 'queued' || job.state === 'running';
  const variant = job.state === 'done' ? 'success' : job.state === 'error' ? 'danger' : 'warning';
  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-sm font-medium text-text-primary">{job.label || (job.action === 'add' ? 'Добавление ноды' : 'Удаление ноды')}</div>
          <div className="text-xs text-text-secondary mt-1">{job.id} · {job.stage || job.state}</div>
        </div>
        <Badge variant={variant}>{job.state.toUpperCase()}</Badge>
      </div>
      <div className="text-sm text-text-secondary">{job.message || 'Выполняется...'}</div>
      {active && <div className="text-xs text-text-secondary">Provisioning выполняется в фоне. Эту страницу можно обновлять.</div>}
      {job.error && <div className="text-xs text-danger whitespace-pre-wrap break-all">{job.error}</div>}
      {job.state === 'done' && job.result && (
        <pre className="text-xs text-text-secondary whitespace-pre-wrap break-all">{JSON.stringify(job.result, null, 2)}</pre>
      )}
      {!active && <Button size="sm" variant="outline" onClick={onDismiss}>Закрыть</Button>}
    </Card>
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
  onRemove: (node: EgressNodeStatus) => void;
}

function NodeCard({ node, active, busy, onSwitch, onTest, onRename, onEnabled, onPriority, onRemove }: NodeCardProps) {
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
  const roleLabel = node.role === 'primary' ? 'PRIMARY' : node.role === 'backup' ? 'BACKUP' : 'DISABLED';

  const test = async () => {
    setTestMessage('Проверка...');
    try {
      const result = await onTest(node.id);
      const rtt = result.connectivity?.tunnel_rtt_ms;
      setTestMessage(`${result.health ? 'HEALTHY' : 'DOWN'} · Telegram ${result.connectivity?.telegram ? 'OK' : 'FAIL'}${rtt != null ? ` · RTT ${rtt} ms` : ''}`);
    } catch (e) {
      setTestMessage(e instanceof Error ? e.message : 'Ошибка проверки');
    }
  };

  const toggleEnabled = async () => {
    if (node.enabled && active && !window.confirm(`Нода "${node.name}" сейчас активна. Отключить её из AUTO?`)) return;
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
          <div className="text-xs text-text-secondary mt-1">{node.public_ip || '—'} · {node.id} · priority {node.priority}</div>
        </div>
        <Badge variant={!node.enabled ? 'warning' : node.health ? 'success' : 'danger'}>
          {!node.enabled ? 'DISABLED' : node.health ? 'HEALTHY' : 'DOWN'}
        </Badge>
      </div>

      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3">
        <Metric label="AWG" value={node.awg.up ? 'UP' : 'DOWN'} />
        <Metric label="RTT ENTER → EXIT" value={node.connectivity.tunnel_rtt_ms != null ? `${node.connectivity.tunnel_rtt_ms} ms` : '—'} />
        <Metric label="Telegram" value={node.connectivity.telegram ? 'OK' : 'FAIL'} />
        <Metric label="Agent" value={agent?.reachable ? 'ONLINE' : 'OFFLINE'} />
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant="outline" onClick={() => setExpanded((v) => !v)}>{expanded ? 'Скрыть подробности ▲' : 'Подробнее ▼'}</Button>
        <Button size="sm" variant="outline" disabled={busy || active || !node.enabled || !node.health} onClick={() => void onSwitch(node.id)}>Сделать активной</Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void test()}>Проверить</Button>
        {testMessage && <span className="text-xs text-text-secondary">{testMessage}</span>}
      </div>

      {expanded && (
        <div className="border-t border-border pt-4 space-y-4">
          <div className="grid grid-cols-2 xl:grid-cols-4 gap-3">
            <Metric label="AWG interface" value={node.awg.interface || '—'} />
            <Metric label="Handshake" value={node.awg.handshake_age_sec >= 0 ? `${node.awg.handshake_age_sec} с` : '—'} />
            <Metric label="AWG RX / TX" value={`↓ ${bytes(node.awg.rx_bytes)} · ↑ ${bytes(node.awg.tx_bytes)}`} />
            <Metric label="Счётчик ошибок" value={String(node.fail_count ?? 0)} />
            <Metric label="Telegram TCP" value={node.connectivity.telegram_tcp_ms != null ? `${node.connectivity.telegram_tcp_ms} ms` : '—'} />
            <Metric label="Agent RTT" value={agent?.reachable && agent.request_ms != null ? `${agent.request_ms} ms` : '—'} />
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
                <Metric label={`Сеть ${network?.interface || ''}`} value={`↓ ${bitrate(network?.rx_bits_per_sec)} · ↑ ${bitrate(network?.tx_bits_per_sec)}`} />
                <Metric label="Сеть всего" value={`↓ ${bytes(network?.rx_bytes)} · ↑ ${bytes(network?.tx_bytes)}`} />
                <Metric label="Uptime" value={uptime(system.uptime_sec)} />
              </div>
            </div>
          ) : <div className="text-xs text-warning">Системные метрики недоступны — node-agent не отвечает.</div>}

          <div className="border-t border-border pt-4 space-y-3">
            <div className="text-sm font-medium text-text-primary">Управление нодой</div>
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
              <div className="space-y-2">
                <div className="text-xs text-text-secondary">Имя меняется свободно; ID и AWG interface остаются неизменными.</div>
                <div className="flex gap-2">
                  <Input value={name} maxLength={64} onChange={(e) => setName(e.target.value)} />
                  <Button size="sm" disabled={busy || !name.trim() || name.trim() === node.name} onClick={() => void onRename(node.id, name.trim())}>Переименовать</Button>
                </div>
              </div>
              <div className="space-y-2">
                <div className="text-xs text-text-secondary">Меньшее значение = выше приоритет AUTO.</div>
                <div className="flex gap-2">
                  <Input type="number" min={1} max={9999} value={priority} onChange={(e) => setPriority(e.target.value)} />
                  <Button size="sm" disabled={busy || Number(priority) === node.priority} onClick={() => void onPriority(node.id, Number(priority))}>Сохранить</Button>
                </div>
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button size="sm" variant={node.enabled ? 'danger' : 'outline'} disabled={busy} onClick={() => void toggleEnabled()}>{node.enabled ? 'Отключить из AUTO' : 'Включить ноду'}</Button>
              <Button size="sm" variant="danger" disabled={busy} onClick={() => onRemove(node)}>Удалить ноду…</Button>
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}

function ModeCard({ status, busy, onMode }: { status: EgressStatus; busy: boolean; onMode: (mode: EgressMode) => void }) {
  const activeNode = status.nodes.find((n) => n.id === status.active_node);
  const telemt = status.telemt;
  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div>
          <div className="text-sm font-medium text-text-primary">Управление маршрутом</div>
          <div className="text-xs text-text-secondary mt-1">Режим: {status.mode.toUpperCase()} · активный выход: {activeNode?.name || status.active_node || '—'}</div>
          <div className="text-xs text-text-secondary mt-1">Telemt: writers {telemt?.alive_writers ?? '—'}/{telemt?.required_writers ?? '—'} · coverage {telemt?.dc_coverage_pct ?? '—'}% · NAT {telemt?.nat_ip || '—'}</div>
        </div>
        <Badge variant={status.active_node === 'block' ? 'danger' : status.phase === 'running' ? 'success' : 'warning'}>{status.phase?.toUpperCase() || 'UNKNOWN'}</Badge>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant={status.mode === 'auto' ? 'default' : 'outline'} disabled={busy || status.mode === 'auto'} onClick={() => onMode('auto')}>AUTO</Button>
        <Button size="sm" variant={status.mode === 'direct' ? 'default' : 'outline'} disabled={busy || status.mode === 'direct'} onClick={() => onMode('direct')}>DIRECT</Button>
        <Button size="sm" variant="danger" disabled={busy || status.mode === 'block'} onClick={() => onMode('block')}>BLOCK</Button>
      </div>
      <p className="text-xs text-text-secondary">AUTO выбирает первую здоровую enabled-ноду по priority. При отказе всех EXIT используется BLOCK.</p>
      {status.last_error && <div className="text-xs text-danger break-all">Последняя ошибка: {status.last_error}</div>}
    </Card>
  );
}

function ConfigCard({ config, busy, onSave }: { config: EgressConfig; busy: boolean; onSave: (config: EgressConfig) => void }) {
  const [draft, setDraft] = useState<EgressConfig>(config);
  useEffect(() => setDraft(config), [config]);
  const field = (key: keyof EgressConfig, label: string, min: number, max: number) => (
    <label className="space-y-1">
      <span className="text-xs text-text-secondary">{label}</span>
      <Input type="number" min={min} max={max} value={draft[key]} onChange={(e) => setDraft((prev) => ({ ...prev, [key]: Number(e.target.value) }))} />
    </label>
  );
  return (
    <Card className="p-4 space-y-4">
      <div>
        <div className="text-sm font-medium text-text-primary">Failover</div>
        <p className="text-xs text-text-secondary mt-1">Настройки применяются динамически. AWG и Telemt без необходимости не перезапускаются.</p>
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
  const [addOpen, setAddOpen] = useState(false);
  const [removeTarget, setRemoveTarget] = useState<EgressNodeStatus | null>(null);
  const [job, setJob] = useState<EgressJob | null>(null);

  const nodes = useMemo(() => [...(status?.nodes || [])].sort((a, b) => a.priority - b.priority || a.name.localeCompare(b.name)), [status]);
  const jobBusy = job?.state === 'queued' || job?.state === 'running';
  const controlsBusy = busy || Boolean(jobBusy);
  const suggestedPriority = Math.min(9999, Math.max(10, (Math.floor(Math.max(0, ...nodes.map((n) => n.priority)) / 10) + 1) * 10));

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
      const [nextStatus, nextConfig, nextEvents] = await Promise.all([egressApi.status(), egressApi.config(), egressApi.events(30)]);
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

  useEffect(() => {
    if (!job || (job.state !== 'queued' && job.state !== 'running')) return;
    let stopped = false;
    const poll = async () => {
      try {
        const next = await egressApi.job(job.id);
        if (stopped) return;
        setJob(next);
        if (next.state === 'done' || next.state === 'error') await loadAll();
      } catch (e) {
        if (!stopped) setError(e instanceof Error ? e.message : 'Не удалось получить статус provisioning job');
      }
    };
    void poll();
    const timer = window.setInterval(() => void poll(), 1500);
    return () => { stopped = true; window.clearInterval(timer); };
  }, [job?.id, job?.state, loadAll]);

  const refreshAfterMutation = async () => {
    const [nextStatus, nextEvents] = await Promise.all([egressApi.status(), egressApi.events(30)]);
    setStatus(nextStatus);
    setEvents(nextEvents);
  };

  const setMode = async (mode: EgressMode, node?: string) => {
    if (mode === 'block' && !window.confirm('Включить BLOCK? Telegram-трафик будет принудительно заблокирован.')) return;
    if (mode === 'direct' && !window.confirm('Включить DIRECT? Telegram будет выходить напрямую через ENTER.')) return;
    setBusy(true);
    try {
      setStatus(await egressApi.setMode(mode, node));
      setEvents(await egressApi.events(30));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось переключить egress');
    } finally { setBusy(false); }
  };

  const mutate = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await fn();
      await refreshAfterMutation();
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось изменить ноду');
    } finally { setBusy(false); }
  };

  const startAdd = async (request: EgressAddNodeRequest) => {
    setBusy(true);
    try {
      const next = await egressApi.addNode(request);
      setJob(next);
      setAddOpen(false);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить добавление ноды');
    } finally { setBusy(false); }
  };

  const startRemove = async (request: EgressRemoveNodeRequest) => {
    if (!removeTarget) return;
    setBusy(true);
    try {
      const next = await egressApi.removeNode(removeTarget.id, request);
      setJob(next);
      setRemoveTarget(null);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось запустить удаление ноды');
    } finally { setBusy(false); }
  };

  const saveConfig = async (value: EgressConfig) => {
    setBusy(true);
    try {
      setConfig(await egressApi.saveConfig(value));
      await loadStatus();
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось сохранить настройки');
    } finally { setBusy(false); }
  };

  return (
    <div>
      <Header title="Выходные ноды" refreshing={loading} onRefresh={loadAll} />
      <div className="p-4 lg:p-6 space-y-4 lg:space-y-6">
        <p className="text-sm text-text-secondary max-w-4xl">
          Динамические AmneziaWG EXIT-ноды для Telegram. Количество нод программно не ограничено; рекомендуется до 5. AUTO использует priority и работает fail-closed.
        </p>

        {error && <ErrorAlert message={error} onRetry={loadAll} />}
        {job && <JobCard job={job} onDismiss={() => setJob(null)} />}
        {addOpen && <AddNodeCard busy={controlsBusy} suggestedPriority={suggestedPriority} onCancel={() => setAddOpen(false)} onStart={startAdd} />}
        {removeTarget && <RemoveNodeCard node={removeTarget} busy={controlsBusy} onCancel={() => setRemoveTarget(null)} onStart={startRemove} />}

        {status && (
          <>
            <ModeCard status={status} busy={controlsBusy} onMode={(mode) => void setMode(mode)} />
            <div className="flex items-center justify-between gap-3">
              <div className="text-sm font-medium text-text-primary">Ноды: {nodes.length}</div>
              <Button size="sm" variant="outline" disabled={controlsBusy || addOpen} onClick={() => { setRemoveTarget(null); setAddOpen(true); }}>+ Добавить ноду</Button>
            </div>
            <div className="grid grid-cols-1 2xl:grid-cols-2 gap-4">
              {nodes.map((node) => (
                <NodeCard
                  key={node.id}
                  node={node}
                  active={status.active_node === node.id}
                  busy={controlsBusy}
                  onSwitch={async (id) => { await setMode('manual', id); }}
                  onTest={(id) => egressApi.testNode(id)}
                  onRename={(id, name) => mutate(() => egressApi.renameNode(id, name))}
                  onEnabled={(id, enabled) => mutate(() => egressApi.setNodeEnabled(id, enabled))}
                  onPriority={(id, priority) => mutate(() => egressApi.setNodePriority(id, priority))}
                  onRemove={(nodeToRemove) => { setAddOpen(false); setRemoveTarget(nodeToRemove); }}
                />
              ))}
            </div>
          </>
        )}

        {config && <ConfigCard config={config} busy={controlsBusy} onSave={(value) => void saveConfig(value)} />}

        <Card className="p-4">
          <div className="text-sm font-medium text-text-primary mb-3">События Egress</div>
          {events.length === 0 ? <div className="text-xs text-text-secondary">Событий пока нет.</div> : (
            <div className="space-y-1 font-mono text-xs">
              {[...events].reverse().map((line, index) => <div key={`${index}-${line}`} className="text-text-secondary break-all">{line}</div>)}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
