import path from "node:path";
import { pathToFileURL } from "node:url";
import { app } from "electron";
import { originOf } from "../bridge/hostPolicy.js";

/**
 * Development overrides. Every one is read only in an unpackaged build: a shipped build that
 * trusted an environment variable would trust anything that could set one.
 *
 * - `GOOPTER_DEBUG_URL`: load this address instead of the saved store and skip the store screen.
 *   Its origin is allowlisted exactly, so the bridge is exposed against a local Odoo.
 * - `GOOPTER_USER_DATA`: keep settings, the log and cookies somewhere else, for isolated tests.
 * - `GOOPTER_WINDOWED=true`: an ordinary window instead of kiosk, with developer tools.
 * - `GOOPTER_ALWAYS_KIOSK=false`: launch in the saved window mode instead of always in kiosk.
 */
const dev = !app.isPackaged;

export const debugUrl: string | null = (() => {
  const raw = dev ? process.env.GOOPTER_DEBUG_URL : undefined;
  return raw && originOf(raw) !== null ? raw : null;
})();

export const debugOrigin: string | null = debugUrl === null ? null : originOf(debugUrl);

export const userDataOverride: string | null = (dev && process.env.GOOPTER_USER_DATA) || null;

export const windowed = dev && process.env.GOOPTER_WINDOWED === "true";

/** Feature flag: every launch opens in kiosk mode, whatever window mode is saved. */
const ALWAYS_KIOSK = true;

export const alwaysKiosk = dev && process.env.GOOPTER_ALWAYS_KIOSK === "false" ? false : ALWAYS_KIOSK;

/** The app's own screens. Anything under this URL gets the shell API and nothing else does. */
export const rendererDir = path.join(__dirname, "..", "..", "renderer");
export const shellUrlPrefix = pathToFileURL(rendererDir + path.sep).href;

export const preloadPath = path.join(__dirname, "..", "preload", "preload.js");

export const windowIcon: { icon?: string } =
  process.platform !== "linux"
    ? {}
    : {
        icon: app.isPackaged
          ? path.join(process.resourcesPath, "icon.png")
          : path.join(app.getAppPath(), "build", "icons", "256x256.png"),
      };
