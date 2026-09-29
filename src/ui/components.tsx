import type { ReactNode } from 'react';
import { LoaderCircle, Smartphone, TabletSmartphone, Check, X, Circle } from './icons';
import type { Device, Run } from '../shared/schema';

export function Logo({ small = false }: { small?: boolean }) { return <div className={`brand ${small ? 'small' : ''}`}><span className="brand-mark"><i /><i /><i /></span>{!small && <><strong>mobdev<span> /</span></strong><span className="oss">OSS</span></>}</div>; }
export function Spinner() { return <LoaderCircle size={15} className="spin" aria-label="Loading" />; }
export function Status({ status }: { status: Run['status'] | Device['status'] }) { return <span className={`status ${status}`}>{status === 'running' || status === 'booting' || status === 'queued' ? <Spinner /> : status === 'passed' ? <Check size={12}/> : status === 'failed' ? <X size={12}/> : <Circle size={7} fill="currentColor" />}{status}</span>; }
export function Empty({ icon, title, children, action }: { icon?: ReactNode; title: string; children: ReactNode; action?: ReactNode }) { return <div className="empty"><div className="empty-icon">{icon ?? <TabletSmartphone size={25}/>}</div><h2>{title}</h2><p>{children}</p>{action}</div>; }
export function DeviceIcon({ device }: { device: Device }) { return <span className={`device-icon ${device.platform}`}><Smartphone size={19}/>{device.platform === 'ios' && <i/>}</span>; }
export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) { return <label className="field"><span>{label}</span>{children}{hint && <small>{hint}</small>}</label>; }
export function Time({ value }: { value: string }) { return <time dateTime={value}>{new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</time>; }
