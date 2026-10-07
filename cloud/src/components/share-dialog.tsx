import { useRouter } from "@tanstack/react-router";
import { T, Var, useGT } from "gt-tanstack-start";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import type { LiveMode } from "../../shared/live";
import type { ShareRow } from "../../shared/shares";
import { createShareLink, revokeShareLink } from "../server/live";
import { CopyButton, buttonPrimary } from "./site";

/** "in 5 h" and the like, from the time the page loaded, so the server and browser agree. */
export function useExpiry(now: number): (expiresAt: number) => string {
  const gt = useGT();
  return (expiresAt) => {
    const minutes = Math.max(1, Math.round((expiresAt - now) / 60_000));
    if (minutes < 60) return gt("expires in {minutes} min", { minutes });
    const hours = Math.round(minutes / 60);
    if (hours < 48) return gt("expires in {hours} h", { hours });
    return gt("expires in {days} days", { days: Math.round(hours / 24) });
  };
}

const field =
  "h-11 w-full rounded-xl border border-line bg-card px-3.5 text-[16px] outline-none transition-shadow placeholder:text-faint focus:border-blue focus:ring-4 focus:ring-blue/15";

/**
 * Creates and revokes links that let someone without an account watch, or watch and control, one
 * device or the whole Mac until the link expires.
 */
export function ShareDialog({
  open,
  onClose,
  spaceId,
  mac,
  device,
  deviceName,
  shares,
  loadedAt,
}: {
  open: boolean;
  onClose: () => void;
  spaceId: string;
  mac: string;
  device: string;
  deviceName: string;
  shares: ShareRow[];
  loadedAt: number;
}) {
  const gt = useGT();
  const router = useRouter();
  const expiry = useExpiry(loadedAt);
  const dialog = useRef<HTMLDialogElement>(null);
  const nameField = useRef<HTMLInputElement>(null);
  const titleId = useId();
  const [label, setLabel] = useState("");
  const [mode, setMode] = useState<LiveMode>("view");
  const [wholeMac, setWholeMac] = useState(false);
  const [hours, setHours] = useState(24);
  const [created, setCreated] = useState<{ url: string; label: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      element.showModal();
      nameField.current?.focus();
    }
    if (!open && element.open) element.close();
  }, [open]);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
      await router.invalidate();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  }

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    void run(async () => {
      const result = await createShareLink({ data: { spaceId, mac, device, wholeMac, mode, label, hours } });
      setCreated({ url: result.url, label: result.share.label });
      setLabel("");
    });
  }

  const choice = "flex cursor-pointer items-start gap-3 rounded-xl px-3 py-2.5 hover:bg-mist";

  return (
    <dialog
      ref={dialog}
      aria-labelledby={titleId}
      onClose={() => {
        setCreated(null);
        setError(null);
        onClose();
      }}
      className="m-auto w-[min(560px,calc(100vw-32px))] rounded-3xl bg-white p-0 text-ink shadow-2xl backdrop:bg-black/40 backdrop:backdrop-blur-sm dark:bg-[#1c1c1e] dark:ring-1 dark:ring-white/10"
    >
      <div className="max-h-[85dvh] overflow-y-auto p-7">
        <div className="flex items-start justify-between gap-4">
          <h2 id={titleId} className="text-[24px] font-semibold tracking-tight">
            <T>Share live view</T>
          </h2>
          <button
            type="button"
            onClick={() => dialog.current?.close()}
            className="text-[15px] text-link hover:underline underline-offset-4"
          >
            <T>Done</T>
          </button>
        </div>
        <T>
          <p className="mt-1.5 text-[15px] leading-[1.47] text-muted">
            Anyone with the link can watch without an account until it expires. Revoke it here at any time.
          </p>
        </T>

        {error && (
          <p role="alert" className="mt-5 rounded-2xl bg-alert px-4 py-3 text-[15px] text-alert-ink">
            {error}
          </p>
        )}

        {created ? (
          <div className="mt-6 rounded-2xl bg-mist p-5">
            <T>
              <p className="text-[15px] font-medium">
                Link for “<Var>{created.label}</Var>”
              </p>
              <p className="mt-1 text-[14px] text-muted">It is shown only once. Copy it now.</p>
            </T>
            <p className="mt-3 break-all rounded-xl bg-card px-3.5 py-2.5 text-[14px] [font-feature-settings:'zero'_1]">
              {created.url}
            </p>
            <div className="mt-4 flex flex-wrap items-center gap-4">
              <CopyButton text={created.url} label={gt("Copy link")} />
              <button
                type="button"
                onClick={() => setCreated(null)}
                className="text-[15px] text-link hover:underline underline-offset-4"
              >
                <T>Create another</T>
              </button>
            </div>
          </div>
        ) : (
          <form onSubmit={onSubmit} className="mt-6 space-y-5">
            <div>
              <label htmlFor={`${titleId}-label`} className="mb-1.5 block text-[14px] font-medium">
                <T>Name</T>
              </label>
              <input
                id={`${titleId}-label`}
                value={label}
                onChange={(event) => setLabel(event.target.value)}
                placeholder={gt("e.g. For Anna")}
                ref={nameField}
                maxLength={60}
                className={field}
              />
            </div>
            <fieldset>
              <legend className="mb-1 text-[14px] font-medium">
                <T>Access</T>
              </legend>
              <label className={choice}>
                <input type="radio" name="mode" checked={mode === "view"} onChange={() => setMode("view")} className="mt-1" />
                <T>
                  <span>
                    <span className="block text-[15px]">View only</span>
                    <span className="block text-[13px] text-muted">They see the screen and cannot touch it.</span>
                  </span>
                </T>
              </label>
              <label className={choice}>
                <input type="radio" name="mode" checked={mode === "control"} onChange={() => setMode("control")} className="mt-1" />
                <T>
                  <span>
                    <span className="block text-[15px]">View and control</span>
                    <span className="block text-[13px] text-muted">They can tap, swipe and type, as you can.</span>
                  </span>
                </T>
              </label>
            </fieldset>
            <fieldset>
              <legend className="mb-1 text-[14px] font-medium">
                <T>Shows</T>
              </legend>
              <label className={choice}>
                <input type="radio" name="scope" checked={!wholeMac} onChange={() => setWholeMac(false)} className="mt-1" />
                <span className="text-[15px]">{deviceName}</span>
              </label>
              <label className={choice}>
                <input type="radio" name="scope" checked={wholeMac} onChange={() => setWholeMac(true)} className="mt-1" />
                <T>
                  <span className="text-[15px]">
                    Every device on <Var>{mac}</Var>
                  </span>
                </T>
              </label>
            </fieldset>
            <div>
              <label htmlFor={`${titleId}-hours`} className="mb-1.5 block text-[14px] font-medium">
                <T>Expires after</T>
              </label>
              <select
                id={`${titleId}-hours`}
                value={hours}
                onChange={(event) => setHours(Number(event.target.value))}
                className={field}
              >
                <option value={1}>{gt("1 hour")}</option>
                <option value={24}>{gt("1 day")}</option>
                <option value={168}>{gt("7 days")}</option>
              </select>
            </div>
            <button type="submit" disabled={busy} className={`${buttonPrimary} w-full`}>
              <T>Create link</T>
            </button>
          </form>
        )}

        <h3 className="mt-8 text-[17px] font-semibold">
          <T>Links to this Mac</T>
        </h3>
        {shares.length === 0 ? (
          <T>
            <p className="mt-2 text-[15px] text-muted">None yet.</p>
          </T>
        ) : (
          <ul className="mt-2 divide-y divide-line/70">
            {shares.map((share) => (
              <li key={share.id} className="flex items-center gap-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-[15px] font-medium">{share.label}</p>
                  <p className="text-[13px] text-muted">
                    {share.mode === "control" ? gt("View and control") : gt("View only")} ·{" "}
                    {share.device === null ? gt("every device") : gt("one device")} · {expiry(share.expires_at)}
                  </p>
                </div>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void run(async () => void (await revokeShareLink({ data: { id: share.id } })))}
                  className="text-[15px] text-danger transition-opacity hover:opacity-70 disabled:opacity-40"
                  aria-label={gt("Revoke “{name}”", { name: share.label })}
                >
                  <T>Revoke</T>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </dialog>
  );
}
