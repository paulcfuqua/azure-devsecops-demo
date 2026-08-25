/** Shared test scaffolding: a real listening server, and a real `fetch` at it. */
import fs from "node:fs";
import http, { type Server } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createApp, type AppDeps } from "../src/app.js";
import { loadConfig, type DataApiConfig } from "../src/config.js";

const here = path.dirname(fileURLToPath(import.meta.url));
export const packageRoot = path.resolve(here, "..");
export const repoRoot = path.resolve(packageRoot, "..", "..");
export const generatedDataDir = path.join(repoRoot, "data", "generated");
export const launchOpsProviderDir = path.join(
  repoRoot,
  "apps",
  "launch-ops",
  "src",
  "providers",
);
export const controlTowerProviderDir = path.join(
  repoRoot,
  "apps",
  "control-tower",
  "src",
  "providers",
);

/**
 * A config built from an explicit env object, never `process.env`: a developer
 * with MLS_* set in their shell must not change what these tests assert.
 */
export function testConfig(env: Record<string, string> = {}): DataApiConfig {
  return loadConfig({ MLS_DATA_BACKENDS: "local", ...env } as NodeJS.ProcessEnv);
}

export interface TestServer {
  readonly baseUrl: string;
  close(): Promise<void>;
}

/**
 * Start the real Express app on an ephemeral port and talk to it with the same
 * global `fetch` the browser providers use. Nothing is stubbed between the
 * assertion and the socket, which is what makes these contract tests rather
 * than handler tests.
 */
export async function startServer(deps: AppDeps = {}): Promise<TestServer> {
  const app = createApp({ config: testConfig(), ...deps });
  const server = await new Promise<Server>((resolve, reject) => {
    const listener = app.listen(0, "127.0.0.1", () => resolve(listener));
    listener.once("error", reject);
  });
  const address = server.address() as AddressInfo;
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

/**
 * A conditional GET issued with the raw http client rather than `fetch`.
 *
 * Node's `fetch` (undici) attaches `cache-control: no-cache` to every request
 * it makes, which by RFC 9111 forces revalidation — so a `fetch`-based
 * conditional request can never observe a 304 no matter what the server does.
 * A browser's `fetch` does not do this. This helper talks HTTP directly so the
 * assertion is about the server rather than about undici.
 */
export function conditionalGet(
  baseUrl: string,
  routePath: string,
  etag: string,
): Promise<{ status: number; length: number }> {
  const url = new URL(`${baseUrl}${routePath}`);
  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        hostname: url.hostname,
        port: Number(url.port),
        path: url.pathname + url.search,
        method: "GET",
        headers: { "If-None-Match": etag },
      },
      (response) => {
        let length = 0;
        response.on("data", (chunk: Buffer) => {
          length += chunk.length;
        });
        response.on("end", () => resolve({ status: response.statusCode ?? 0, length }));
      },
    );
    request.on("error", reject);
    request.end();
  });
}

/** Read one of the frontends' provider sources verbatim. */
export function readProviderSource(dir: string, file: string): string {
  return fs.readFileSync(path.join(dir, file), "utf-8");
}
