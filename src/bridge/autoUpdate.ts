import { safely, type LogSink } from "./logEntry.js";

/** Long enough to be quiet, short enough that a release reaches a till that runs for days. */
export const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;

/** The slice of electron-updater's `autoUpdater` this module touches. */
export interface Updater {
  autoDownload: boolean;
  autoInstallOnAppQuit: boolean;
  on(event: "checking-for-update" | "update-not-available", listener: () => void): unknown;
  on(event: "update-available" | "update-downloaded", listener: (info: { version: string }) => void): unknown;
  on(event: "download-progress", listener: (progress: { percent: number }) => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
  checkForUpdates(): Promise<unknown>;
  quitAndInstall(isSilent?: boolean, isForceRunAfter?: boolean): void;
}

/** The slice of Electron's own `autoUpdater` (Squirrel.Mac) this module touches. */
export interface NativeUpdater {
  on(event: "update-downloaded", listener: () => void): unknown;
}

export type UpdateStatus =
  | { state: "idle" }
  | { state: "checking" }
  | { state: "current" }
  | { state: "downloading"; version: string; percent: number | null }
  | { state: "preparing"; version: string }
  | { state: "ready"; version: string }
  | { state: "installing"; version: string }
  | { state: "failed"; code: string };

export interface UpdateControl {
  status(): UpdateStatus;
  check(): void;
  install(version: string): boolean;
  stop(): void;
}

/**
 * Check for a release now and every `CHECK_INTERVAL_MS`, download it in the background, and let
 * it install when the app next quits. Nothing here restarts the app on its own: the till may be
 * mid-order, and the hosted POS page has no way to ask the cashier first. Only `install()`, called
 * after someone at the till confirms, restarts it.
 *
 * On macOS pass Electron's `autoUpdater` as `native`: electron-updater reports a download before
 * Squirrel.Mac has fetched it, and installing before then queues a restart for whenever Squirrel
 * finishes.
 *
 * Never throws.
 */
export function startAutoUpdate(updater: Updater, log: LogSink, native: NativeUpdater | null = null): UpdateControl {
  const record = (outcome: string) =>
    void safely(log, { timestamp: new Date(), event: "update", origin: "app", outcome });

  let current: UpdateStatus = { state: "idle" };
  let errors = 0;
  const set = (next: UpdateStatus) => {
    if (current.state !== "installing") current = next;
  };

  updater.autoDownload = true;
  updater.autoInstallOnAppQuit = true;
  updater.on("checking-for-update", () => set({ state: "checking" }));
  updater.on("update-not-available", () => set({ state: "current" }));
  updater.on("update-available", (info) => {
    set({ state: "downloading", version: info.version, percent: null });
    record(`available ${info.version}`);
  });
  updater.on("download-progress", (progress) => {
    if (current.state === "downloading") set({ ...current, percent: Math.round(progress.percent) });
  });
  updater.on("update-downloaded", (info) => {
    set(native === null ? { state: "ready", version: info.version } : { state: "preparing", version: info.version });
    record(`downloaded ${info.version}`);
  });
  native?.on("update-downloaded", () => {
    if (current.state === "preparing") set({ state: "ready", version: current.version });
  });
  // electron-updater emits `error` for a failed check or download and also rejects its promise,
  // so this listener is the one place a failure is logged. On macOS it emits Squirrel's error
  // and then dispatches the same object again when the download rejects with it.
  const logged = new WeakSet<object>();
  updater.on("error", (error) => {
    if (typeof error === "object" && error !== null) {
      if (logged.has(error)) return;
      logged.add(error);
    }
    errors += 1;
    const code = failureCode(error);
    set({ state: "failed", code });
    record(`failed ${code}`);
  });

  const check = () => {
    try {
      updater
        .checkForUpdates()
        .then((result) => (result as { downloadPromise?: Promise<unknown> } | null)?.downloadPromise?.catch(() => {}))
        .catch(() => {});
    } catch (error) {
      const code = failureCode(error);
      set({ state: "failed", code });
      record(`failed ${code}`);
    }
  };

  check();
  const timer = setInterval(check, CHECK_INTERVAL_MS);
  return {
    status: () => current,
    check: () => {
      record("check");
      check();
    },
    install: (version) => {
      if (current.state !== "ready" || current.version !== version) return false;
      record(`install ${version}`);
      const before = errors;
      try {
        updater.quitAndInstall(true, true);
      } catch (error) {
        const code = failureCode(error);
        set({ state: "failed", code });
        record(`failed ${code}`);
        return false;
      }
      if (errors !== before) return false;
      set({ state: "installing", version });
      return true;
    },
    stop: () => clearInterval(timer),
  };
}

function failureCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  if (typeof code === "string" && code !== "") return code;
  const message = error instanceof Error ? error.message : String(error);
  return message.split("\n")[0]?.trim() || "error";
}
