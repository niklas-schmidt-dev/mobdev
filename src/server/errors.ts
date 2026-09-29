export class AppError extends Error {
  constructor(message: string, public status = 400) { super(message); this.name = 'AppError'; }
}
export function errorMessage(error: unknown): string { return error instanceof Error ? error.message : String(error); }
export function aborted(signal?: AbortSignal) { if (signal?.aborted) throw new AppError('Run cancelled', 499); }
export async function pause(ms: number, signal?: AbortSignal): Promise<void> {
  aborted(signal);
  await new Promise<void>((resolve, reject) => {
    const done = () => { signal?.removeEventListener('abort', cancel); resolve(); };
    const timer = setTimeout(done, ms);
    const cancel = () => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); reject(new AppError('Run cancelled', 499)); };
    signal?.addEventListener('abort', cancel, { once: true });
  });
}
