/**
 * Local SOCKS5 bridge — accepts unauthenticated connections on 127.0.0.1:<ephemeral>
 * and relays them through an authenticated reference SOCKS5 proxy.
 *
 * Why this exists: Chromium does not prompt for SOCKS5 auth at launch. To use
 * an auth-required reference (residential SOCKS5 from a VPN provider, for
 * example), we run a no-auth listener locally that the browser talks to, and
 * the bridge handles the auth handshake with reference.
 *
 * Architecture:
 *   Chromium  →  socks5://127.0.0.1:<ephemeral>  (this bridge, no auth)
 *                  └→ authenticated SOCKS5 to reference  →  destination
 *
 * Design notes: the listen port is ephemeral (never a hardcoded 1090) and the
 * bind is 127.0.0.1-only, so the bridge is unreachable from off-box. A stream
 * error closes the affected client connection and does not retry — a SOCKS
 * bridge is transport, not request-aware, and a retry can corrupt browser
 * traffic mid-stream.
 */

import * as net from 'net';
import { SocksClient, type SocksProxy } from 'socks';

export interface ReferenceConfig {
  host: string;
  port: number;
  userId?: string;
  password?: string;
}

export interface BridgeHandle {
  /** Local port the bridge is listening on (ephemeral). */
  port: number;
  /** Underlying server. Exposed for tests; production code uses close(). */
  server: net.Server;
  /** Close the listener and all in-flight client sockets. */
  close: () => Promise<void>;
}

const SOCKS5_VERSION = 0x05;
const NO_AUTH_METHOD = 0x00;
const CMD_CONNECT = 0x01;
const ATYP_IPV4 = 0x01;
const ATYP_DOMAINNAME = 0x03;
const ATYP_IPV6 = 0x04;
const REPLY_SUCCESS = 0x00;
const REPLY_GENERAL_FAILURE = 0x01;
const REPLY_HOST_UNREACHABLE = 0x04;
const PROXY_CONNECT_TIMEOUT_MS = 15000;

function buildReference(reference: ReferenceConfig): SocksProxy {
  return {
    host: reference.host,
    port: reference.port,
    type: 5,
    ...(reference.userId ? { userId: reference.userId } : {}),
    ...(reference.password ? { password: reference.password } : {}),
  };
}

function parseConnectRequest(reqData: Buffer): { host: string; port: number } | null {
  if (reqData.length < 7 || reqData[0] !== SOCKS5_VERSION || reqData[1] !== CMD_CONNECT) {
    return null;
  }
  const atyp = reqData[3];
  if (atyp === ATYP_IPV4) {
    if (reqData.length < 10) return null;
    const host = `${reqData[4]}.${reqData[5]}.${reqData[6]}.${reqData[7]}`;
    const port = reqData.readUInt16BE(8);
    return { host, port };
  }
  if (atyp === ATYP_DOMAINNAME) {
    const len = reqData[4];
    if (reqData.length < 5 + len + 2) return null;
    const host = reqData.subarray(5, 5 + len).toString('utf8');
    const port = reqData.readUInt16BE(5 + len);
    return { host, port };
  }
  if (atyp === ATYP_IPV6) {
    if (reqData.length < 22) return null;
    const parts: string[] = [];
    for (let i = 4; i < 20; i += 2) parts.push(reqData.readUInt16BE(i).toString(16));
    const host = parts.join(':');
    const port = reqData.readUInt16BE(20);
    return { host, port };
  }
  return null;
}

function writeReply(sock: net.Socket, code: number): void {
  // SOCKS5 reply: VER REP RSV ATYP BND.ADDR(0.0.0.0) BND.PORT(0)
  const reply = Buffer.from([SOCKS5_VERSION, code, 0x00, ATYP_IPV4, 0, 0, 0, 0, 0, 0]);
  try { sock.write(reply); } catch { /* peer already gone */ }
}

/**
 * Start a local SOCKS5 bridge that relays to an authenticated reference.
 * Listens on 127.0.0.1 only (never 0.0.0.0). port: 0 picks an ephemeral port.
 *
 * Stream-error policy: on any error during a relayed connection, the affected
 * client socket and its reference pair are destroyed. No transport retries.
 * Browser sees a proxy/connection error and surfaces it as such.
 */
export async function startSocksBridge(opts: {
  reference: ReferenceConfig;
  port?: number;
}): Promise<BridgeHandle> {
  const referenceProxy = buildReference(opts.reference);
  const requestedPort = opts.port ?? 0;
  const inFlight = new Set<net.Socket>();

  // Frame-size predicates for the two SOCKS5 messages we read from the
  // client. Both return null when we don't yet have enough bytes to know
  // the frame size, or a positive integer when we do.
  function greetingSize(buf: Buffer): number | null {
    if (buf.length < 2) return null;
    return 2 + buf[1]; // VER NMETHODS + N method bytes
  }
  function connectSize(buf: Buffer): number | null {
    if (buf.length < 5) return null;
    const atyp = buf[3];
    if (atyp === ATYP_IPV4) return 10;        // VER CMD RSV ATYP + 4 + 2
    if (atyp === ATYP_IPV6) return 22;        // VER CMD RSV ATYP + 16 + 2
    if (atyp === ATYP_DOMAINNAME) return 7 + buf[4]; // VER CMD RSV ATYP LEN + N + 2
    return null;
  }

  type State = 'greeting' | 'connect' | 'connecting' | 'piped' | 'closed';

  const server = net.createServer((clientSocket) => {
    inFlight.add(clientSocket);
    clientSocket.once('close', () => inFlight.delete(clientSocket));

    let state: State = 'greeting';
    let buf = Buffer.alloc(0);
    let referenceSocket: net.Socket | null = null;

    const killBoth = (reason?: string) => {
      void reason;
      state = 'closed';
      try { clientSocket.destroy(); } catch { /* already gone */ }
      if (referenceSocket) {
        try { referenceSocket.destroy(); } catch { /* already gone */ }
      }
    };

    const handshakeTimeout = setTimeout(() => {
      if (state === 'greeting' || state === 'connect' || state === 'connecting') {
        killBoth('handshake timeout');
      }
    }, 30000);
    clientSocket.once('close', () => clearTimeout(handshakeTimeout));

    const onData = (chunk: Buffer) => {
      if (state === 'closed' || state === 'piped') return;
      buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);

      if (state === 'greeting') {
        const sz = greetingSize(buf);
        if (sz == null || buf.length < sz) return;
        const greeting = buf.subarray(0, sz);
        buf = buf.subarray(sz);
        if (greeting[0] !== SOCKS5_VERSION) { killBoth('bad version'); return; }
        try { clientSocket.write(Buffer.from([SOCKS5_VERSION, NO_AUTH_METHOD])); }
        catch { killBoth('write greeting reply failed'); return; }
        state = 'connect';
        // Fall through — buf may already contain CONNECT bytes (coalesced).
      }

      if (state === 'connect') {
        const sz = connectSize(buf);
        if (sz == null || buf.length < sz) return;
        const reqData = buf.subarray(0, sz);
        const remainder = buf.subarray(sz);
        const dest = parseConnectRequest(reqData);
        if (!dest) {
          writeReply(clientSocket, REPLY_GENERAL_FAILURE);
          killBoth('bad connect request');
          return;
        }
        state = 'connecting';
        // Pause client reads so any post-handshake bytes don't get dropped.
        // We replay `remainder` after reference is established.
        clientSocket.pause();
        SocksClient.createConnection({
          proxy: referenceProxy,
          command: 'connect',
          destination: { host: dest.host, port: dest.port },
          timeout: PROXY_CONNECT_TIMEOUT_MS,
        }).then((result) => {
          if (state === 'closed') {
            try { result.socket.destroy(); } catch { /* shutdown */ }
            return;
          }
          referenceSocket = result.socket;
          writeReply(clientSocket, REPLY_SUCCESS);
          // Replay any pre-buffered post-handshake bytes BEFORE we pipe.
          if (remainder.length > 0) {
            try { referenceSocket.write(remainder); } catch { killBoth('replay write failed'); return; }
          }
          // Wire the rest of the connection through the pipe.
          referenceSocket.on('error', () => killBoth('reference error'));
          referenceSocket.on('close', () => { try { clientSocket.destroy(); } catch { /* already gone */ } });
          clientSocket.removeListener('data', onData);
          clientSocket.pipe(referenceSocket);
          referenceSocket.pipe(clientSocket);
          clientSocket.resume();
          state = 'piped';
        }).catch(() => {
          writeReply(clientSocket, REPLY_HOST_UNREACHABLE);
          killBoth('reference connect failed');
        });
        return;
      }
    };

    clientSocket.on('data', onData);
    clientSocket.on('error', () => killBoth('client error'));
  });

  await new Promise<void>((resolve, reject) => {
    const onErr = (e: unknown) => { server.off('listening', onListen); reject(e); };
    const onListen = () => { server.off('error', onErr); resolve(); };
    server.once('error', onErr);
    server.once('listening', onListen);
    server.listen(requestedPort, '127.0.0.1');
  });

  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('socks-bridge: unexpected listener address');
  }

  return {
    port: address.port,
    server,
    close: async () => {
      for (const sock of inFlight) {
        try { sock.destroy(); } catch { /* already gone */ }
      }
      inFlight.clear();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

export interface ReferenceTestOpts {
  reference: ReferenceConfig;
  /** Hostname to test connectivity to through the reference. Default 1.1.1.1. */
  testHost?: string;
  /** Port. Default 443. */
  testPort?: number;
  /** Total time budget across all retries. Default 5000ms. */
  budgetMs?: number;
  /** Number of attempts. Default 3. */
  retries?: number;
  /** Backoff between attempts. Default 500ms. */
  backoffMs?: number;
}

/**
 * Pre-flight: verify the reference proxy actually accepts our credentials and
 * can reach a known endpoint. Called before chromium.launch so failures
 * surface as a clear startup error instead of a confusing 'connection
 * refused' on first navigation.
 *
 * Retries a few times with backoff because residential VPNs can take a
 * second to fully establish on first connect.
 *
 * Throws on final failure. Caller is responsible for redacting any error
 * that may leak credentials.
 */
export async function testReference(opts: ReferenceTestOpts): Promise<{ ok: true; attempts: number; ms: number }> {
  const referenceProxy = buildReference(opts.reference);
  const testHost = opts.testHost ?? '1.1.1.1';
  const testPort = opts.testPort ?? 443;
  const budgetMs = opts.budgetMs ?? 5000;
  const retries = opts.retries ?? 3;
  const backoffMs = opts.backoffMs ?? 500;

  const start = Date.now();
  let lastErr: unknown;

  for (let attempt = 1; attempt <= retries; attempt++) {
    const elapsed = Date.now() - start;
    const remaining = budgetMs - elapsed;
    if (remaining <= 0) break;
    const perAttempt = Math.min(remaining, Math.max(500, Math.floor(budgetMs / retries)));

    try {
      const result = await SocksClient.createConnection({
        proxy: referenceProxy,
        command: 'connect',
        destination: { host: testHost, port: testPort },
        timeout: perAttempt,
      });
      try { result.socket.destroy(); } catch { /* test connection done */ }
      return { ok: true, attempts: attempt, ms: Date.now() - start };
    } catch (err) {
      lastErr = err;
      if (attempt < retries) {
        const elapsedAfter = Date.now() - start;
        if (elapsedAfter + backoffMs >= budgetMs) break;
        await new Promise<void>((r) => setTimeout(r, backoffMs));
      }
    }
  }

  const reason = lastErr instanceof Error ? lastErr.message : String(lastErr);
  const err = new Error(`SOCKS5 reference rejected or unreachable after ${retries} attempts (${Date.now() - start}ms): ${reason}`);
  (err as Error & { referenceHost?: string; referencePort?: number }).referenceHost = opts.reference.host;
  (err as Error & { referenceHost?: string; referencePort?: number }).referencePort = opts.reference.port;
  throw err;
}
