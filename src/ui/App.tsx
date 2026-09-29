import { useCallback, useEffect, useState } from 'react';
import { Cable, ChevronRight, CircleHelp, Code2, FlaskConical, History, LayoutPanelLeft, Plus, RefreshCw, ShieldCheck, Terminal, X, ArrowRight } from './icons';
import type { Bootstrap, Device, Diagnostic, Run, TestCase } from '../shared/schema';
import { Client, message, type PublicSettings } from './api';
import { Logo, DeviceIcon, Spinner } from './components';
import { Workbench } from './Workbench';
import { Tests } from './Tests';
import { Runs } from './Runs';
import { Connections } from './Connections';

type Page = 'workbench'|'tests'|'runs'|'connections';
export function App() {
  const [client, setClient] = useState<Client>();
  const [initializing, setInitializing] = useState(true);
  const [token, setToken] = useState('');
  const [page, setPage] = useState<Page>('workbench');
  const [devices, setDevices] = useState<Device[]>([]);
  const [diagnostics, setDiagnostics] = useState<Diagnostic[]>([]);
  const [tests, setTests] = useState<TestCase[]>([]);
  const [runs, setRuns] = useState<Run[]>([]);
  const [settings, setSettings] = useState<PublicSettings>();
  const [selected, setSelected] = useState('');
  const [online, setOnline] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [notice, setNotice] = useState<{ text: string; error: boolean }>();
  const [draft, setDraft] = useState<string>();
  const [help, setHelp] = useState(false);
  const notify = useCallback((text: string, error = false) => setNotice({ text, error }), []);
  useEffect(() => { let current = true; void (async () => {
    try { const credentials: Bootstrap | undefined = await window.mobdev?.bootstrap(); if (current && credentials) setClient(new Client(credentials)); }
    catch (error) { if (current) notify(message(error), true); }
    finally { if (current) setInitializing(false); }
  })(); return () => { current = false; }; }, [notify]);
  const refresh = useCallback(async (discover = false) => {
    if (!client) return;
    const [inventory, savedTests, savedRuns, config] = await Promise.all([
      client.call<{ devices: Device[]; diagnostics: Diagnostic[] }>(discover ? '/devices/refresh' : '/devices', discover ? {} : undefined),
      client.call<TestCase[]>('/tests'), client.call<Run[]>('/runs'), client.call<PublicSettings>('/settings'),
    ]);
    setDevices(inventory.devices); setDiagnostics(inventory.diagnostics); setTests(savedTests); setRuns(savedRuns); setSettings(config); setOnline(true);
    setSelected(current => inventory.devices.some(d => d.id === current) ? current : inventory.devices.find(d => d.status === 'ready')?.id ?? '');
  }, [client]);
  useEffect(() => { if (!client) return; let active = true; let timer: ReturnType<typeof setTimeout>; const poll = async () => { try { await refresh(); } catch { if (active) setOnline(false); } if (active) timer = setTimeout(() => void poll(), 2000); }; void poll(); return () => { active = false; clearTimeout(timer); }; }, [client, refresh]);
  useEffect(() => { if (!notice || notice.error) return; const timer = setTimeout(() => setNotice(undefined), 4500); return () => clearTimeout(timer); }, [notice]);
  const connect = async () => {
    setRefreshing(true);
    const next = new Client({ url: location.port === '5173' ? 'http://127.0.0.1:4686' : location.origin, token });
    try { await next.call('/settings'); setClient(next); setToken(''); }
    catch (error) { notify(message(error), true); } finally { setRefreshing(false); }
  };
  const loadDemo = async () => { if (!client) return; try { await client.call('/demo', {}); await refresh(); setSelected('demo:android'); setPage('workbench'); notify('Demo phone connected. This is a virtual device.'); } catch (error) { notify(message(error), true); } };
  const inspectDraft = (source: string) => { setDraft(source); setPage('tests'); };
  if (initializing) return <div className="boot"><Logo/><Spinner/></div>;
  if (!client) return <main className="connect-screen"><div className="connect-intro"><Logo/><div><span className="eyebrow">THE OPEN MOBILE WORKBENCH</span><h1>Your devices.<br/>Your tools.<br/><em>Your rules.</em></h1><p>Inspect, automate and test iOS and Android.<br/>Built in the open. Running on your machine.</p></div><span className="connect-platforms">macOS <i/> Windows <i/> Linux</span></div><form className="connect-card" onSubmit={event => { event.preventDefault(); void connect(); }}><ShieldCheck size={30}/><h2>Connect to your workspace</h2><p>The local API uses a token to keep device access under your control.</p><label className="field"><span>Workspace token</span><input autoFocus aria-label="Workspace token" type="password" value={token} onChange={event => setToken(event.target.value)} placeholder="Paste your local token" required autoComplete="off"/></label><button className="primary" disabled={refreshing}>{refreshing ? <Spinner/> : <ArrowRight size={16}/>} Open workspace</button><div className="code-hint"><span>Find your token in a terminal</span><code>bun run cli token</code></div>{notice && <p className="inline-error" role="alert">{notice.text}</p>}</form></main>;
  const device = devices.find(d => d.id === selected);
  const activeRuns = runs.filter(run => ['running','queued'].includes(run.status)).length;
  return <div className="app-shell">
    <aside className="sidebar"><div className="drag-space"/><Logo/><div className="workspace-switch"><span className="workspace-avatar">M</span><div>Local workspace<small>Personal · open source</small></div></div><div className="nav-label">WORKSPACE</div><nav aria-label="Main navigation">{([{ id: 'workbench', label: 'Workbench', Icon: LayoutPanelLeft }, { id: 'tests', label: 'Tests', Icon: FlaskConical }, { id: 'runs', label: 'Run history', Icon: History }, { id: 'connections', label: 'Connections', Icon: Cable }] as const).map(({ id, label, Icon }) => <button key={id} onClick={() => setPage(id)} className={page === id ? 'active' : ''}><Icon size={17}/>{label}{id === 'tests' && tests.length > 0 && <span className="nav-count">{tests.length}</span>}{id === 'runs' && activeRuns > 0 && <span className="nav-count lime">{activeRuns}</span>}</button>)}</nav><div className="nav-label devices-label">DEVICES <button className="icon-button" aria-label="Add device connection" onClick={() => setPage('connections')}><Plus size={13}/></button></div><div className="device-list">{devices.map(d => <button key={d.id} className={`device-row ${selected === d.id ? 'selected' : ''}`} onClick={() => { setSelected(d.id); setPage('workbench'); }}><DeviceIcon device={d}/><span>{d.name}<small>{d.kind === 'demo' ? 'Demo fixture' : `${d.platform === 'ios' ? 'iOS' : 'Android'} · ${d.kind}`}</small></span><i className={`connection-dot ${d.status}`}/></button>)}{!devices.length && <p className="sidebar-empty">No devices yet.<br/>Connect a phone to get started.</p>}</div><div className="sidebar-bottom"><div className="open-source-note"><Code2 size={18}/><strong>Open by design.</strong><p>No seat limits. No telemetry.<br/>Your entire lab, in your hands.</p></div><button className="quiet help-button" onClick={() => setHelp(true)}><CircleHelp size={15}/> Quick start <ChevronRight size={14}/></button><div className="version"><span className={online ? 'online-dot' : 'offline-dot'}/>{online ? 'Local daemon connected' : 'Reconnecting to daemon…'}<span>0.1.0</span></div></div></aside>
    <main className="main-panel"><header className="topbar"><div className="breadcrumb">Workspace <ChevronRight size={13}/><span>{{ workbench: 'Workbench', tests: 'Tests', runs: 'Run history', connections: 'Connections' }[page]}</span></div><div className="topbar-actions"><span className="local-badge"><ShieldCheck size={13}/> LOCAL FIRST</span><button className="quiet" disabled={refreshing} onClick={async () => { setRefreshing(true); try { await refresh(true); } catch (error) { notify(message(error), true); } finally { setRefreshing(false); } }}><RefreshCw size={14} className={refreshing ? 'spin' : ''}/><span>Refresh devices</span></button></div></header>
      {!online && <div className="offline-banner" role="status">Waiting for the local daemon. Start Mobdev or run <code>bun run daemon</code>.</div>}
      {page === 'workbench' && <Workbench client={client} device={device} runs={runs} diagnostics={diagnostics} notify={notify} onDemo={() => void loadDemo()} onConnect={() => setPage('connections')} onDraft={inspectDraft} refresh={() => refresh()} agentConfigured={!!settings?.agent.model}/ >}
      <div hidden={page !== 'tests'}><Tests client={client} devices={devices} selected={selected} tests={tests} draft={draft} clearDraft={() => setDraft(undefined)} notify={notify} refresh={() => refresh()} onRuns={() => setPage('runs')}/></div>
      {page === 'runs' && <Runs client={client} runs={runs} notify={notify} refresh={() => refresh()} onDraft={inspectDraft}/>}
      {page === 'connections' && <Connections client={client} settings={settings} diagnostics={diagnostics} notify={notify} refresh={() => refresh()} onDemo={() => void loadDemo()}/>}
    </main>
    {notice && <div className={`toast ${notice.error ? 'error' : ''}`} role={notice.error ? 'alert' : 'status'}><span>{notice.text}</span><button aria-label="Dismiss notification" onClick={() => setNotice(undefined)}><X size={15}/></button></div>}
    {help && <div className="modal-backdrop" onClick={() => setHelp(false)}><section className="modal" role="dialog" aria-modal="true" aria-label="Quick start" onClick={event => event.stopPropagation()}><button className="modal-close icon-button" aria-label="Close quick start" onClick={() => setHelp(false)}><X/></button><Terminal size={26}/><h2>A phone for every workflow.</h2><p>Connect Android with USB debugging enabled. For iOS, boot a simulator on your Mac or add an Appium connection.</p><div className="help-step"><span>01</span><div><strong>Try it without hardware</strong><p>The demo phone has a real, executable sign-in test.</p><button className="secondary" onClick={() => { void loadDemo(); setHelp(false); }}>Open demo phone <ArrowRight size={14}/></button></div></div><div className="help-step"><span>02</span><div><strong>Give your AI access</strong><p>Use the MCP configuration in Connections with Codex, Claude Code or Cursor.</p></div></div><div className="help-step"><span>03</span><div><strong>Turn a flow into a test</strong><p>Record your interactions or write a .mob script. Run it on one device or across your lab.</p></div></div></section></div>}
  </div>;
}
