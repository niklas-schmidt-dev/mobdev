import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Camera, Check, ChevronRight, Circle, Code2, Crosshair, FileCode2, Home, Layers, Play, Plus, RefreshCw, Search, Send, Smartphone, Sparkles, Square, Terminal, Video, Wifi } from './icons';
import type { Action, Device, Diagnostic, Run, Screenshot, UIElement } from '../shared/schema';
import { Client, message } from './api';
import { Empty, Spinner, Status, Time } from './components';
import { toScript } from '../server/dsl';

interface Props { client: Client; device?: Device; runs: Run[]; diagnostics: Diagnostic[]; notify: (text: string, error?: boolean) => void; onDemo: () => void; onConnect: () => void; onDraft: (source: string) => void; refresh: () => Promise<void>; agentConfigured: boolean }
export function Workbench({ client, device, runs, diagnostics, notify, onDemo, onConnect, onDraft, refresh, agentConfigured }: Props) {
  const [shot, setShot] = useState<Screenshot>();
  const [screenError, setScreenError] = useState('');
  const [elements, setElements] = useState<UIElement[]>([]);
  const [treeError, setTreeError] = useState('');
  const [selectedElement, setSelectedElement] = useState<UIElement>();
  const [filter, setFilter] = useState('');
  const [pane, setPane] = useState<'inspector'|'agent'|'apps'>('inspector');
  const [live, setLive] = useState(true);
  const [busy, setBusy] = useState(false);
  const recording = device?.recording ?? false;
  const [recordingActions, setRecordingActions] = useState(false);
  const [commands, setCommands] = useState<Action[]>([]);
  const [text, setText] = useState('');
  const [prompt, setPrompt] = useState('');
  const [appId, setAppId] = useState('');
  const [apps, setApps] = useState<Array<{ id: string; name: string }>>([]);
  const [activity, setActivity] = useState<Array<{ time: string; text: string; failed?: boolean }>>([]);
  const [bottom, setBottom] = useState<'activity'|'logs'>('activity');
  const [logs, setLogs] = useState('');
  const [loadingTree, setLoadingTree] = useState(false);
  const drag = useRef<{ x: number; y: number; start: number }>(undefined);
  const deviceId = device?.id;
  const currentId = useRef(deviceId); currentId.current = deviceId;
  const deviceRun = runs.find(run => run.deviceId === deviceId && ['running','queued'].includes(run.status));
  const blocked = busy || !!deviceRun || device?.status !== 'ready';
  const canInput = device?.capabilities.includes('input');
  const base = `/devices/${encodeURIComponent(deviceId ?? '')}`;
  const reloadTree = useCallback(async () => {
    if (!deviceId || !device?.capabilities.includes('tree')) return;
    setLoadingTree(true);
    try { const tree = await client.call<UIElement[]>(`${base}/tree`); if (currentId.current === deviceId) { setElements(tree); setSelectedElement(current => current ? tree.find(element => element.id === current.id) : undefined); setTreeError(''); } }
    catch (error) { if (currentId.current === deviceId) setTreeError(message(error)); }
    finally { setLoadingTree(false); }
  }, [client, deviceId, base, device?.capabilities.join(',')]);
  useEffect(() => { setShot(undefined); setElements([]); setScreenError(''); setSelectedElement(undefined); setApps([]); setLogs(''); setRecordingActions(false); setCommands([]); setActivity([]); void reloadTree(); }, [deviceId, reloadTree]);
  useEffect(() => {
    if (!deviceId || !live || pane !== 'inspector') return;
    let active = true; let timer: ReturnType<typeof setTimeout>;
    const poll = async () => { await reloadTree(); if (active) timer = setTimeout(() => void poll(), 3000); };
    timer = setTimeout(() => void poll(), 3000);
    return () => { active = false; clearTimeout(timer); };
  }, [deviceId, live, pane, reloadTree]);
  useEffect(() => {
    if (!deviceId || device?.status !== 'ready') return;
    let active = true; let timer: ReturnType<typeof setTimeout>; const controller = new AbortController();
    const poll = async () => {
      try { const screenshot = await client.call<Screenshot>(`${base}/screenshot`, undefined, 'GET', controller.signal); if (active) { setShot(screenshot); setScreenError(''); } }
      catch (error) { if (active) setScreenError(message(error)); }
      if (active && live) timer = setTimeout(() => void poll(), 900);
    };
    void poll(); return () => { active = false; controller.abort(); clearTimeout(timer); };
  }, [client, deviceId, base, live, device?.status]);
  const act = async (action: Action) => {
    if (!deviceId) return;
    setBusy(true);
    try {
      const result = await client.call<{ artifact?: string }>(`${base}/action`, action);
      if (currentId.current === deviceId) {
        setActivity(previous => [...previous.slice(-99), { time: new Date().toISOString(), text: toScript([action]).trim() }]);
        if (recordingActions) setCommands(previous => [...previous, action]);
        if (action.action === 'type') setText('');
        void reloadTree();
      }
      if (action.action === 'record_start' || action.action === 'record_stop') await refresh();
      if (result?.artifact) { await client.download(result.artifact); notify(`Saved ${result.artifact}`); }
    } catch (error) { notify(message(error), true); setActivity(previous => [...previous.slice(-99), { time: new Date().toISOString(), text: message(error), failed: true }]); }
    finally { setBusy(false); }
  };
  const launchAgent = async (mode: 'draft'|'run') => {
    if (!prompt.trim() || !deviceId) return;
    setBusy(true);
    try {
      if (mode === 'draft') { const result = await client.call<{ source: string; explanation: string }>('/agent/draft', { deviceId, prompt }); onDraft(result.source); notify(result.explanation); }
      else { await client.call('/agent/run', { deviceId, prompt }); await refresh(); notify('Agent started. You can stop it at any time.'); }
    } catch (error) { notify(message(error), true); } finally { setBusy(false); }
  };
  if (!device) return <div className="welcome-workspace"><div className="page-heading"><div><span className="eyebrow">DEVICE WORKSPACE</span><h1>A little less setup.<br/><span>A lot more building.</span></h1><p>Your iOS and Android devices, tests and AI tools.<br/>Together in one open workspace.</p></div><span className="version-tag">v0.1 / LOCAL PREVIEW</span></div><div className="welcome-grid"><div className="connect-device-card"><div className="empty-phones"><div/><div/><span><Plus size={24}/></span></div><h2>Bring your app to the table.</h2><p>Plug in an Android phone, boot an iOS simulator,<br/>or connect a device through Appium.</p><div className="button-row"><button className="primary" onClick={onConnect}><Plus size={16}/> Connect a device</button><button className="secondary" onClick={onDemo}>Try demo phone <ArrowRight size={16}/></button></div><span className="subtle">Demo mode runs entirely offline. No phone required.</span></div><div className="getting-started"><span className="eyebrow">A WORKBENCH THAT WORKS YOUR WAY</span><article><Crosshair/><div><h3>See what your app is doing</h3><p>Inspect screens and UI elements. Tap, swipe and type directly from your desktop.</p></div></article><article><FileCode2/><div><h3>Keep the flows that matter</h3><p>Turn interactions into readable tests. Replay them across your devices.</p></div></article><article><Sparkles/><div><h3>Let your agent take the wheel</h3><p>Connect Codex, Claude Code or Cursor through MCP. Or bring a model of your own.</p></div></article></div></div><div className="environment-strip"><span className="eyebrow">YOUR ENVIRONMENT</span>{diagnostics.length ? diagnostics.map(d => <div key={d.name}><span className={d.available ? 'online-dot' : 'offline-dot'}/><strong>{d.name}</strong><small>{d.detail}</small></div>) : <span className="subtle">Discovering local device tools…</span>}</div></div>;
  const matching = elements.filter(e => e.text || e.label || !e.id.startsWith('element-')).filter(e => `${e.text} ${e.label} ${e.id}`.toLowerCase().includes(filter.toLowerCase()));
  const point = (event: React.PointerEvent<HTMLButtonElement>) => { const rect = event.currentTarget.getBoundingClientRect(); return { x: Math.max(0, Math.min((shot?.width ?? 1) - 1, Math.round((event.clientX - rect.left) / rect.width * (shot?.width ?? 1)))), y: Math.max(0, Math.min((shot?.height ?? 1) - 1, Math.round((event.clientY - rect.top) / rect.height * (shot?.height ?? 1)))) }; };
  return <div className="workbench"><div className="device-toolbar"><div><h1>{device.name}<span className={`device-tag ${device.kind === 'demo' ? 'demo' : ''}`}>{device.kind === 'demo' ? 'DEMO DEVICE' : device.kind.toUpperCase()}</span></h1><p><Wifi size={12}/>{device.platform === 'ios' ? 'iOS' : 'Android'}{device.version ? ` ${device.version}` : ''}<span>·</span><code>{device.id}</code></p></div><div className="button-row"><Status status={device.status}/><button className="secondary" onClick={onConnect}><Plus size={14}/> Add device</button></div></div>
    <div className="workbench-panels"><section className="device-stage"><div className="stage-top"><span><span className={live ? 'online-dot' : 'offline-dot'}/>{live ? 'LIVE PREVIEW' : 'PREVIEW PAUSED'}</span><button className="quiet" onClick={() => setLive(!live)}>{live ? 'Pause' : 'Resume'}</button><span className="stage-res">{shot ? `${shot.width} × ${shot.height}` : 'Connecting…'}</span></div><div className="phone-area"><div className="phone-frame" style={{ aspectRatio: shot ? `${shot.width} / ${shot.height}` : '390 / 844' }}>
      {shot ? <button className={`phone-screen ${!canInput ? 'read-only' : ''}`} aria-label="Device screen: click to tap, drag to swipe" disabled={blocked || !canInput} onPointerDown={event => { event.currentTarget.setPointerCapture(event.pointerId); drag.current = { ...point(event), start: Date.now() }; }} onPointerUp={event => { const start = drag.current; drag.current = undefined; if (!start) return; const end = point(event); if (Math.hypot(end.x - start.x, end.y - start.y) < 12) void act({ action: 'tap', x: end.x, y: end.y }); else void act({ action: 'swipe', x: start.x, y: start.y, toX: end.x, toY: end.y, duration: Math.min(2000, Math.max(100, Date.now() - start.start)) }); }} onPointerCancel={() => { drag.current = undefined; }}><img src={`data:${shot.mime};base64,${shot.data}`} alt={`Current screen of ${device.name}`} draggable={false}/>{selectedElement && <span className="element-highlight" style={{ left: `${selectedElement.bounds.x / shot.width * 100}%`, top: `${selectedElement.bounds.y / shot.height * 100}%`, width: `${selectedElement.bounds.width / shot.width * 100}%`, height: `${selectedElement.bounds.height / shot.height * 100}%` }}/>}</button> : <div className="phone-loading"><Smartphone size={32}/>{screenError ? <p>{screenError}</p> : <Spinner/>}</div>}
      {screenError && shot && <div className="screen-warning">Preview unavailable</div>}
    </div><div className="device-controls"><button className="icon-button" aria-label="Back" disabled={blocked || !canInput || device.platform === 'ios'} onClick={() => void act({ action: 'key', key: 'back' })}><ArrowLeft size={17}/></button><button className="icon-button" aria-label="Home" disabled={blocked || !canInput} onClick={() => void act({ action: 'key', key: 'home' })}><Home size={17}/></button><i/><button className="icon-button" aria-label="Save screenshot" disabled={blocked || !shot} onClick={() => void act({ action: 'screenshot', name: 'capture' })}><Camera size={17}/></button><button className={`icon-button ${recording ? 'recording' : ''}`} aria-label={recording ? 'Stop video recording' : 'Start video recording'} disabled={blocked || !device.capabilities.includes('record')} onClick={() => void act(recording ? { action: 'record_stop', name: 'demo' } : { action: 'record_start' })}>{recording ? <Square size={17}/> : <Video size={17}/>}</button></div></div><div className="stage-bottom"><Crosshair size={13}/><span>{canInput ? 'Click to tap · drag to swipe' : 'Preview only · connect Appium for input'}</span>{busy && <Spinner/>}</div></section>
    <aside className="inspector"><div className="pane-tabs" role="tablist" aria-label="Device tools">{(['inspector','agent','apps'] as const).map(tab => <button key={tab} role="tab" aria-selected={pane === tab} className={pane === tab ? 'active' : ''} onClick={() => setPane(tab)}>{tab === 'inspector' ? <Layers size={14}/> : tab === 'agent' ? <Sparkles size={14}/> : <Smartphone size={14}/>}{{ inspector: 'Inspector', agent: 'Agent', apps: 'Apps' }[tab]}</button>)}</div>
      {pane === 'inspector' && <><div className="inspector-heading"><span className="eyebrow">UI ELEMENTS <span>{matching.length}</span></span><button aria-label="Refresh UI elements" className="icon-button" disabled={loadingTree || !canInput} onClick={() => void reloadTree()}>{loadingTree ? <Spinner/> : <RefreshCw size={14}/>}</button></div><label className="search-field"><Search size={14}/><input aria-label="Filter UI elements" placeholder="Find text, label or resource ID…" value={filter} onChange={e => setFilter(e.target.value)}/></label><div className="element-list">{treeError && <p className="inline-error">{treeError}</p>}{!device.capabilities.includes('tree') ? <Empty title="Enable UI inspection" icon={<Layers/>} action={<button className="secondary" onClick={onConnect}>Connect Appium <ArrowRight size={14}/></button>}>This simulator provides a native preview. Add an XCUITest session to inspect and interact.</Empty> : matching.map((element, index) => <button className={`element-row ${selectedElement === element ? 'selected' : ''}`} key={`${element.id}-${index}`} onClick={() => setSelectedElement(element)} onMouseEnter={() => setSelectedElement(element)}><span className="element-symbol">{element.type.includes('Text') ? 'T' : <Square size={12}/>}</span><span><strong>{element.text || element.label || element.id}</strong><small>{element.type.split('.').at(-1)}</small></span><ChevronRight size={12}/></button>)}{device.capabilities.includes('tree') && !matching.length && !loadingTree && !treeError && <p className="small-empty">No matching elements on this screen.</p>}</div>{selectedElement && <div className="element-detail"><span className="eyebrow">SELECTED ELEMENT</span><code>{selectedElement.id}</code><div><span>x {selectedElement.bounds.x} · y {selectedElement.bounds.y}</span><span>{selectedElement.bounds.width} × {selectedElement.bounds.height}</span></div><button className="secondary" disabled={blocked || !canInput} onClick={() => void act({ action: 'tap', x: Math.round(selectedElement.bounds.x + selectedElement.bounds.width / 2), y: Math.round(selectedElement.bounds.y + selectedElement.bounds.height / 2) })}><Crosshair size={13}/> Tap element</button></div>}<form className="type-form" onSubmit={event => { event.preventDefault(); void act({ action: 'type', text }); }}><input aria-label="Text to type on device" value={text} onChange={e => setText(e.target.value)} placeholder="Type into the focused field…" disabled={!canInput}/><button aria-label="Send text to device" disabled={blocked || !canInput || !text}><Send size={16}/></button></form></>}
      {pane === 'agent' && <div className="agent-pane"><div className="agent-avatar"><Sparkles size={22}/></div><h2>A second pair of eyes.</h2><p>Ask your agent to explore a flow, look for bugs or draft a repeatable test.</p>{!agentConfigured && <div className="info-box">Connect a local or hosted model to get started.<button className="quiet" onClick={onConnect}>Configure AI provider <ArrowRight size={13}/></button></div>}<label className="field"><span>What should the agent do?</span><textarea value={prompt} onChange={e => setPrompt(e.target.value)} placeholder="Walk through sign-in and check that the welcome screen appears." rows={5}/></label><button className="primary" disabled={blocked || !canInput || !prompt.trim() || !agentConfigured} onClick={() => void launchAgent('run')}>{busy ? <Spinner/> : <Play size={14}/>} Run agent</button><button className="secondary" disabled={blocked || !canInput || !prompt.trim() || !agentConfigured} onClick={() => void launchAgent('draft')}><FileCode2 size={14}/> Draft a test</button><small className="privacy-note">The selected model receives visible UI text and action history. Hosted models receive this data over the network. Maximum 30 turns per run.</small><div className="agent-divider">ALREADY HAVE AN AGENT?</div><button className="integration-link" onClick={onConnect}><Code2 size={18}/><span>Codex, Claude Code, Cursor<small>Connect through MCP</small></span><ArrowRight size={14}/></button></div>}
      {pane === 'apps' && <div className="apps-pane"><h2>Open an app</h2><p>Launch an installed app by its package or bundle ID.</p><form onSubmit={event => { event.preventDefault(); void act({ action: 'launch', appId }); }}><label className="field"><span>App ID</span><input placeholder={device.platform === 'ios' ? 'com.apple.Preferences' : 'com.android.settings'} value={appId} onChange={e => setAppId(e.target.value)}/></label><button className="primary" disabled={blocked || !appId.trim()}><Play size={14}/> Launch app</button></form><button className="secondary" disabled={blocked || !device.capabilities.includes('apps')} onClick={async () => { try { setApps(await client.call(`${base}/apps`)); } catch (error) { notify(message(error), true); } }}><RefreshCw size={13}/> List installed apps</button><div className="app-list">{apps.map(app => <button key={app.id} onClick={() => setAppId(app.id)}><Smartphone size={14}/><span>{app.name}<small>{app.id}</small></span></button>)}</div><label className="field"><span>Install app from local path</span><input aria-label="App installation path" placeholder="/absolute/path/to/app.apk" onKeyDown={event => { if (event.key === 'Enter' && !blocked) { const value = event.currentTarget.value; if (value) void act({ action: 'install', path: value }); } }}/><small>Press Enter to install. APK for Android, .app for local Simulator, IPA or ZIP for Appium.</small></label></div>}
    </aside></div>
    <section className="activity-panel"><div className="activity-heading"><div className="bottom-tabs"><button className={bottom === 'activity' ? 'active' : ''} onClick={() => setBottom('activity')}><Terminal size={13}/> Activity</button><button className={bottom === 'logs' ? 'active' : ''} onClick={async () => { setBottom('logs'); try { setLogs((await client.call<{ text: string }>(`${base}/logs`)).text); } catch (error) { setLogs(message(error)); } }}>Device logs</button></div><div className="button-row">{commands.length > 0 && <button className="quiet" onClick={() => onDraft(toScript(commands))}><FileCode2 size={13}/> Save {commands.length} steps as test</button>}<button className={`quiet ${recordingActions ? 'recording' : ''}`} disabled={!canInput} onClick={() => { setRecordingActions(!recordingActions); if (!recordingActions) setCommands([]); }}><Circle size={10} fill={recordingActions ? 'currentColor' : 'none'}/>{recordingActions ? 'Stop capturing steps' : 'Capture steps'}</button></div></div><div className="activity-content">{bottom === 'logs' ? <pre>{logs || 'No recent device logs.'}</pre> : <>{deviceRun && <div className="live-run"><Spinner/><span>{deviceRun.name}</span><Status status={deviceRun.status}/><button className="quiet" onClick={async () => { try { await client.call(`/runs/${deviceRun.id}/cancel`, {}); await refresh(); } catch (error) { notify(message(error), true); } }}><Square size={12}/> Stop</button></div>}{activity.length ? activity.slice(-8).map((entry, i) => <div className={`activity-line ${entry.failed ? 'failed' : ''}`} key={i}><Time value={entry.time}/>{entry.failed ? <Circle size={11}/> : <Check size={11}/>}<code>{entry.text}</code></div>) : !deviceRun && <div className="activity-placeholder"><span className="online-dot"/> Ready when you are. Device interactions and test activity appear here.</div>}</>}</div></section>
  </div>;
}
