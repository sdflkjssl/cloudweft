#!/usr/bin/env node
'use strict';

// Multi-provider AList bridge for the Plinth File Provider extension.
//
// One loopback process serves every configured provider:
//
//   /dav/quark/...   -> AList /dav/quark/...
//   /dav/baidu/...   -> AList /dav/baidu/...
//
// Each provider has an independent persisted id<->path map, so opaque File
// Provider identifiers can overlap safely across domains. The old single-drive
// /dav/... route is retained and defaults to Quark for upgrade compatibility.
//
// Provider authentication and storage configuration belong entirely to AList.
// The loopback control API is read-only: Plinth only discovers whether a
// configured AList mount is present and healthy.

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { URL } = require('url');
const { once } = require('events');
const { Readable } = require('stream');
const { bridgePort, providers, requireProvider } = require('./providers');

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const PORT = parseInt(argOf('--port', String(bridgePort)), 10);
const HOST = argOf('--host', process.env.FP_BRIDGE_HOST || '127.0.0.1');
const REMOTE_AUTH_FILE = argOf('--remote-auth-file', process.env.FP_REMOTE_AUTH_FILE || '');
const REMOTE_ALLOW_IP = argOf('--allow-ip', process.env.FP_REMOTE_ALLOW_IP || '');
const ONLY_PROVIDER = argOf('--provider', process.env.FP_BRIDGE_PROVIDER || '');
const ALIST = argOf('--alist', 'http://127.0.0.1:5244');
const LEGACY_ROOT = argOf('--root', '/quark');
const preferredDataDir = path.join(os.homedir(), '.cloud-drive-fp-data');
const legacyDataDir = path.join(__dirname, '..', '..', '..', 'quark-sync');
const DATA_DIR = process.env.FP_DATA_DIR
  || (fs.existsSync(path.join(preferredDataDir, 'alist-admin-pass.txt'))
    || !fs.existsSync(path.join(legacyDataDir, 'alist-admin-pass.txt'))
    ? preferredDataDir
    : legacyDataDir);
const DAV_PREFIX = '/dav';
const CONTROL_PREFIX = '/control/providers';

fs.mkdirSync(DATA_DIR, { recursive: true });

const defaultProvider = [...providers.values()].find((p) => p.mountPath === LEGACY_ROOT)
  || providers.get('quark')
  || { id: 'legacy', displayName: 'Legacy', mountPath: LEGACY_ROOT };

function adminPassword() {
  try {
    return fs.readFileSync(path.join(DATA_DIR, 'alist-admin-pass.txt'), 'utf8').trim();
  } catch {
    return '';
  }
}

function alistWebDAVAuthorization() {
  const password = adminPassword();
  return password ? 'Basic ' + Buffer.from(`admin:${password}`).toString('base64') : '';
}

// --- Per-provider identity state --------------------------------------------

class ProviderState {
  constructor(provider) {
    this.provider = provider;
    // Preserve the original Quark id map verbatim so an upgrade does not change
    // identifiers underneath the existing plinth-drive File Provider database.
    const legacy = path.join(DATA_DIR, 'fp-idmap.json');
    this.file = provider.id === 'quark' && fs.existsSync(legacy)
      ? legacy
      : path.join(DATA_DIR, `fp-idmap-${provider.id}.json`);
    this.idToPath = new Map();
    this.pathToId = new Map();
    this.nextId = 1;
    this.load();
  }

  load() {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      this.idToPath = new Map(Object.entries(raw.idToPath || {}));
      this.pathToId = new Map(Object.entries(raw.pathToId || {}));
      this.nextId = raw.nextId || 1;
    } catch {
      this.idToPath = new Map();
      this.pathToId = new Map();
      this.nextId = 1;
    }
  }

  save() {
    try {
      fs.writeFileSync(this.file, JSON.stringify({
        idToPath: Object.fromEntries(this.idToPath),
        pathToId: Object.fromEntries(this.pathToId),
        nextId: this.nextId,
      }));
    } catch (error) {
      console.error(`[${this.provider.id}] idmap save failed:`, error.message);
    }
  }

  idForPath(relPath) {
    if (this.pathToId.has(relPath)) return this.pathToId.get(relPath);
    const id = 'f' + (this.nextId++).toString(36);
    this.idToPath.set(id, relPath);
    this.pathToId.set(relPath, id);
    return id;
  }

  forgetID(id) {
    const rel = this.idToPath.get(id);
    if (rel !== undefined) this.pathToId.delete(rel);
    this.idToPath.delete(id);
  }
}

const states = new Map();
function stateFor(provider) {
  if (!states.has(provider.id)) states.set(provider.id, new ProviderState(provider));
  return states.get(provider.id);
}

// --- AList WebDAV ------------------------------------------------------------

const relToURL = (provider, rel) => ALIST + '/dav' + provider.mountPath
  + (rel ? '/' + rel.split('/').map(encodeURIComponent).join('/') : '');

function forward(provider, req, res, method, relPath, extraHeaders = {}) {
  const authorization = alistWebDAVAuthorization();
  if (!authorization) return send(res, 503, 'AList admin credential is not configured');
  const u = new URL(relToURL(provider, relPath));
  const headers = { Authorization: authorization, ...extraHeaders };
  const upstream = http.request(u, { method, headers }, (downstream) => {
    const responseHeaders = {
      'Content-Type': downstream.headers['content-type'] || 'application/octet-stream',
      'Accept-Ranges': downstream.headers['accept-ranges'] || 'bytes',
    };
    if (downstream.headers['content-length']) {
      responseHeaders['Content-Length'] = downstream.headers['content-length'];
    }
    if (downstream.headers['content-range']) {
      responseHeaders['Content-Range'] = downstream.headers['content-range'];
    }
    res.writeHead(downstream.statusCode || 200, responseHeaders);
    downstream.pipe(res);
  });
  upstream.on('error', () => { try { send(res, 502, 'Backend error'); } catch {} });
  if (req) req.pipe(upstream);
  else upstream.end();
}

function propfindAndRewrite(provider, state, relPath, depth, callback) {
  const authorization = alistWebDAVAuthorization();
  if (!authorization) return callback(null, 503, 'AList admin credential is not configured');
  const u = new URL(relToURL(provider, relPath));
  const upstream = http.request(u, {
    method: 'PROPFIND',
    headers: { Authorization: authorization, Depth: depth || '1' },
  }, (downstream) => {
    const chunks = [];
    downstream.on('data', (chunk) => chunks.push(chunk));
    downstream.on('end', () => {
      const xml = Buffer.concat(chunks).toString('utf8');
      if (downstream.statusCode !== 207) {
        return callback(null, downstream.statusCode || 500, xml);
      }
      callback(rewritePropfind(provider, state, xml, relPath, depth), 207, null);
    });
  });
  upstream.on('error', () => callback(null, 502, null));
  upstream.end();
}

const xmlEscape = (value) => String(value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function rewritePropfind(provider, state, xml, dirRel, depth) {
  const responses = xml.match(/<D:response>[\s\S]*?<\/D:response>/g) || [];
  const parts = [];
  const prefix = '/dav' + provider.mountPath;

  for (const response of responses) {
    const href = (response.match(/<D:href>([^<]*)<\/D:href>/) || [])[1] || '';
    let rel = '';
    try {
      const full = decodeURIComponent(href).replace(/\/$/, '');
      rel = full.startsWith(prefix)
        ? full.slice(prefix.length + (full[prefix.length] === '/' ? 1 : 0))
        : '';
    } catch {
      continue;
    }

    const id = rel === '' ? '' : state.idForPath(rel);
    let parentID;
    const parentRel = rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
    // A Depth:1 PROPFIND includes the requested directory itself followed by
    // its children. The requested directory must report its real parent; using
    // dirRel for that first response makes the directory its own parent and
    // causes File Provider write coordination to fail with EDEADLK.
    if (depth === '0' || rel === dirRel) {
      parentID = parentRel === '' ? '' : state.idForPath(parentRel);
    } else {
      parentID = dirRel === '' ? '' : state.idForPath(dirRel);
    }

    const isDirectory = /<D:collection[^>]*\/>/.test(response) || href.endsWith('/');
    const size = (response.match(/<D:getcontentlength>(\d+)<\/D:getcontentlength>/) || [])[1] || '';
    const modified = (response.match(/<D:getlastmodified>([^<]*)<\/D:getlastmodified>/) || [])[1] || '';
    const etag = (response.match(/<D:getetag>([^<]*)<\/D:getetag>/) || [])[1] || '';

    parts.push([
      '  <D:response>',
      `    <D:href>${xmlEscape(href)}</D:href>`,
      '    <D:propstat>',
      '      <D:prop>',
      `        <D:resourcetype>${isDirectory ? '<D:collection/>' : ''}</D:resourcetype>`,
      isDirectory ? '' : `        <D:getcontentlength>${size}</D:getcontentlength>`,
      `        <D:getlastmodified>${modified}</D:getlastmodified>`,
      `        <D:getetag>${etag}</D:getetag>`,
      `        <D:fileid>${xmlEscape(id)}</D:fileid>`,
      `        <D:parentid>${xmlEscape(parentID)}</D:parentid>`,
      '      </D:prop>',
      '      <D:status>HTTP/1.1 200 OK</D:status>',
      '    </D:propstat>',
      '  </D:response>',
    ].join('\n'));
  }

  state.save();
  return '<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">\n'
    + parts.join('\n') + '\n</D:multistatus>\n';
}

// --- Bridge routing ----------------------------------------------------------

function davRoute(pathname) {
  if (pathname !== DAV_PREFIX && !pathname.startsWith(DAV_PREFIX + '/')) return null;
  const rest = pathname.slice(DAV_PREFIX.length);
  const segments = rest.split('/').filter(Boolean);

  let provider = defaultProvider;
  if (segments.length && providers.has(decodeURIComponent(segments[0]))) {
    provider = providers.get(decodeURIComponent(segments.shift()));
  }

  return {
    provider,
    state: stateFor(provider),
    providerPath: '/' + segments.join('/'),
  };
}

function resolve(state, providerPath) {
  let rel;
  try {
    rel = decodeURIComponent(providerPath);
  } catch {
    return null;
  }
  const parts = rel.split('/').filter(Boolean);
  if (parts.length === 0) return { target: '', parentDir: null, name: null };

  if (parts[0] === '.id') {
    const id = parts[1];
    const baseRel = state.idToPath.get(id);
    if (baseRel === undefined) return null;
    if (parts.length === 2) return { target: baseRel, parentDir: null, name: null };
    const name = parts.slice(2).join('/');
    if (!safeName(name)) return null;
    return {
      target: baseRel ? baseRel + '/' + name : name,
      parentDir: baseRel,
      name,
    };
  }

  const name = parts.join('/');
  if (!safeName(name)) return null;
  return { target: name, parentDir: '', name };
}

const safeName = (name) => !name.split('/').some((part) => part === '.' || part === '..');

// --- AList provider-management API ------------------------------------------

let cachedAdminToken = '';
let cachedAdminTokenExpiresAt = 0;

async function alistAdminToken() {
  if (cachedAdminToken && Date.now() < cachedAdminTokenExpiresAt) return cachedAdminToken;

  const password = adminPassword();
  if (!password) throw new Error('AList admin credential is not configured');
  const response = await fetch(ALIST + '/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password }),
  });
  const payload = await response.json();
  if (payload.code !== 200 || !payload.data?.token) {
    throw new Error(payload.message || 'AList admin login failed');
  }
  cachedAdminToken = payload.data.token;
  cachedAdminTokenExpiresAt = Date.now() + 5 * 60 * 1000;
  return cachedAdminToken;
}

const alistPath = (provider, relPath) =>
  provider.mountPath + (relPath ? '/' + relPath.replace(/^\/+|\/+$/g, '') : '');

async function alistJSON(endpoint, body) {
  const token = await alistAdminToken();
  const response = await fetch(ALIST + endpoint, {
    method: 'POST',
    headers: {
      Authorization: token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  let payload = null;
  try { payload = await response.json(); } catch {}
  if (!response.ok || payload?.code !== 200) {
    throw new Error(payload?.message || `AList ${endpoint} returned HTTP ${response.status}`);
  }
  return payload?.data;
}

async function alistUpload(provider, req, relPath) {
  const token = await alistAdminToken();
  const fullPath = alistPath(provider, relPath);
  const headers = {
    Authorization: token,
    'File-Path': encodeURIComponent(fullPath),
    'As-Task': 'false',
    'Content-Type': req.headers['content-type'] || 'application/octet-stream',
  };
  const length = req.headers['content-length'];
  if (length) headers['Content-Length'] = String(length);
  const response = await fetch(ALIST + '/api/fs/put', {
    method: 'PUT',
    headers,
    body: req,
    duplex: 'half',
  });
  let payload = null;
  try { payload = await response.json(); } catch {}
  if (!response.ok || payload?.code !== 200) {
    throw new Error(payload?.message || `AList upload returned HTTP ${response.status}`);
  }
}

async function alistMkdir(provider, relPath) {
  await alistJSON('/api/fs/mkdir', { path: alistPath(provider, relPath) });
}

function splitRelPath(relPath) {
  const parts = String(relPath || '').split('/').filter(Boolean);
  const name = parts.pop() || '';
  return { dir: parts.join('/'), name };
}

async function alistRemove(provider, relPath) {
  const { dir, name } = splitRelPath(relPath);
  if (!name) throw new Error('Refusing to remove provider root');
  await alistJSON('/api/fs/remove', {
    dir: alistPath(provider, dir),
    names: [name],
  });
}

async function alistRename(provider, relPath, newName) {
  await alistJSON('/api/fs/rename', {
    path: alistPath(provider, relPath),
    name: newName,
  });
}

async function alistMove(provider, sourceRel, destinationRel, overwrite) {
  if (sourceRel === destinationRel) return;
  const source = splitRelPath(sourceRel);
  const destination = splitRelPath(destinationRel);
  if (!source.name || !destination.name) throw new Error('Invalid AList move path');

  if (overwrite) {
    try { await alistRemove(provider, destinationRel); } catch {}
  }

  let movingName = source.name;
  if (source.dir !== destination.dir && source.name !== destination.name) {
    const temporaryName = `.plinth-move-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    await alistRename(provider, sourceRel, temporaryName);
    movingName = temporaryName;
    await alistJSON('/api/fs/move', {
      src_dir: alistPath(provider, source.dir),
      dst_dir: alistPath(provider, destination.dir),
      names: [movingName],
    });
    await alistRename(
      provider,
      destination.dir ? destination.dir + '/' + movingName : movingName,
      destination.name,
    );
    return;
  }

  if (source.dir !== destination.dir) {
    await alistJSON('/api/fs/move', {
      src_dir: alistPath(provider, source.dir),
      dst_dir: alistPath(provider, destination.dir),
      names: [movingName],
    });
  }
  if (movingName !== destination.name) {
    const currentRel = destination.dir ? destination.dir + '/' + movingName : movingName;
    await alistRename(provider, currentRel, destination.name);
  }
}

async function alistFileLink(provider, relPath) {
  const token = await alistAdminToken();
  const fullPath = provider.mountPath + (relPath ? '/' + relPath : '');
  const response = await fetch(ALIST + '/api/fs/get', {
    method: 'POST',
    headers: {
      Authorization: token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ path: fullPath, password: '', refresh: false }),
  });
  const payload = await response.json();
  if (payload.code !== 200 || !payload.data?.raw_url) {
    throw new Error(payload.message || 'AList did not return a direct download link');
  }
  return {
    url: payload.data.raw_url,
    size: Number(payload.data.size || 0),
    headers: payload.data.header || {},
  };
}

function directDownloadHeaders(provider, link, range) {
  const headers = { ...link.headers, 'Accept-Encoding': 'identity' };
  if (provider.downloadUserAgent) headers['User-Agent'] = provider.downloadUserAgent;
  if (range) headers.Range = range;
  return headers;
}

async function directProxyDownload(provider, res, relPath, range) {
  const link = await alistFileLink(provider, relPath);
  const response = await fetch(link.url, {
    headers: directDownloadHeaders(provider, link, range),
    redirect: 'follow',
  });
  if (!response.ok && response.status !== 206) {
    await response.body?.cancel();
    throw new Error(`Direct download returned HTTP ${response.status}`);
  }

  const headers = {
    'Content-Type': response.headers.get('content-type') || 'application/octet-stream',
    'Accept-Ranges': response.headers.get('accept-ranges') || 'bytes',
  };
  for (const name of ['content-length', 'content-range']) {
    const value = response.headers.get(name);
    if (value) headers[name.replace(/^./, (c) => c.toUpperCase()).replace(/-./g, (m) => m.toUpperCase())] = value;
  }
  res.writeHead(response.status, headers);
  if (!response.body) return res.end();
  Readable.fromWeb(response.body).pipe(res);
}

async function fetchDirectChunk(provider, link, start, end, signal) {
  const response = await fetch(link.url, {
    headers: directDownloadHeaders(provider, link, `bytes=${start}-${end}`),
    redirect: 'follow',
    signal,
  });
  if (response.status !== 206) {
    await response.body?.cancel();
    throw new Error(`Direct range request returned HTTP ${response.status}`);
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  const expected = end - start + 1;
  if (buffer.length !== expected) {
    throw new Error(`Direct range length mismatch: got ${buffer.length}, expected ${expected}`);
  }
  return buffer;
}

async function parallelDirectDownload(provider, res, relPath) {
  const link = await alistFileLink(provider, relPath);
  if (!Number.isFinite(link.size) || link.size <= 0) {
    return directProxyDownload(provider, res, relPath, null);
  }

  const chunkSize = Math.max(1024 * 1024, Number(provider.downloadChunkSize || 16 * 1024 * 1024));
  const concurrency = Math.max(1, Math.min(16, Number(provider.downloadConcurrency || 4)));
  const chunkCount = Math.ceil(link.size / chunkSize);

  // Small files do not benefit from paying the setup cost for several ranges.
  if (chunkCount <= 1 || concurrency === 1) {
    return directProxyDownload(provider, res, relPath, null);
  }

  const controller = new AbortController();
  res.once('close', () => controller.abort());
  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': String(link.size),
    'Accept-Ranges': 'bytes',
  });

  const inFlight = new Map();
  let nextToLaunch = 0;
  const launch = (index) => {
    const start = index * chunkSize;
    const end = Math.min(link.size - 1, start + chunkSize - 1);
    inFlight.set(
      index,
      fetchDirectChunk(provider, link, start, end, controller.signal)
        .then((buffer) => ({ buffer, error: null }))
        .catch((error) => ({ buffer: null, error }))
    );
  };

  while (nextToLaunch < Math.min(concurrency, chunkCount)) launch(nextToLaunch++);

  try {
    for (let index = 0; index < chunkCount; index += 1) {
      const result = await inFlight.get(index);
      inFlight.delete(index);
      if (result.error) throw result.error;
      if (nextToLaunch < chunkCount) launch(nextToLaunch++);
      if (!res.write(result.buffer)) await once(res, 'drain');
    }
    res.end();
  } catch (error) {
    controller.abort();
    if (!res.destroyed) res.destroy(error);
  }
}

async function storageList(token) {
  const response = await fetch(ALIST + '/api/admin/storage/list', {
    headers: { Authorization: token },
  });
  const payload = await response.json();
  if (payload.code !== 200) throw new Error(payload.message || 'Unable to list AList storages');
  return payload.data?.content || [];
}

function publicStorageStatus(provider, storage) {
  const storageName = String(storage?.remark || '').trim() || provider.displayName;
  return {
    id: provider.id,
    displayName: storageName,
    configured: Boolean(storage),
    healthy: Boolean(storage) && !storage.disabled && (!storage.status || storage.status === 'work'),
    status: storage?.status || '',
    disabled: Boolean(storage?.disabled),
    mountPath: provider.mountPath,
  };
}

async function providerStatus(provider) {
  const token = await alistAdminToken();
  const storages = await storageList(token);
  return publicStorageStatus(provider, storages.find((storage) => storage.mount_path === provider.mountPath));
}

// --- HTTP server -------------------------------------------------------------

const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body ?? '');
};

const sendJSON = (res, code, value) => {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
};

function hasBridgeAuth(req) {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Basic ')) return false;
  let decoded = '';
  try { decoded = Buffer.from(auth.slice(6), 'base64').toString(); } catch { return false; }
  const separator = decoded.indexOf(':');
  if (!(separator > 0 && separator < decoded.length - 1)) return false;
  const remote = String(req.socket.remoteAddress || '');
  if (remote === '127.0.0.1' || remote === '::1' || remote.endsWith('::ffff:127.0.0.1')) return true;
  const normalizedRemote = remote.replace(/^::ffff:/, '');
  if (REMOTE_ALLOW_IP && normalizedRemote === REMOTE_ALLOW_IP) return true;
  if (!REMOTE_AUTH_FILE) return false;
  try { return decoded === fs.readFileSync(REMOTE_AUTH_FILE, 'utf8').trim(); } catch { return false; }
}

const server = http.createServer(async (req, res) => {
  if (!hasBridgeAuth(req)) {
    return send(res, 401, 'Authentication required', { 'WWW-Authenticate': 'Basic realm="Plinth"' });
  }

  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === CONTROL_PREFIX || url.pathname.startsWith(CONTROL_PREFIX + '/')) {
    try {
      const suffix = url.pathname.slice(CONTROL_PREFIX.length).split('/').filter(Boolean);
      if (req.method === 'GET' && suffix.length === 0) {
        const result = [];
        for (const provider of providers.values()) result.push(await providerStatus(provider));
        return sendJSON(res, 200, { providers: result });
      }
      if (req.method === 'GET' && suffix.length === 1) {
        return sendJSON(res, 200, await providerStatus(requireProvider(suffix[0])));
      }
      return sendJSON(res, 404, { error: 'Unknown control endpoint' });
    } catch (error) {
      return sendJSON(res, 400, { error: error.message });
    }
  }

  const route = davRoute(url.pathname);
  if (!route) return send(res, 404, 'Not found');
  const { provider, state, providerPath } = route;
  if (ONLY_PROVIDER && provider.id !== ONLY_PROVIDER) return send(res, 404, 'Not found');
  const found = resolve(state, providerPath);
  if (!found) return send(res, 404, 'Not found');
  const { target, parentDir, name } = found;
  console.log(`[${provider.id}]`, req.method, providerPath, '->', JSON.stringify(target));

  switch (req.method) {
    case 'PROPFIND': {
      const depth = req.headers.depth === undefined ? '1' : String(req.headers.depth);
      propfindAndRewrite(provider, state, target, depth, (xml, status, raw) => {
        if (!xml) return send(res, status, raw || 'Not found', { 'Content-Type': 'text/plain' });
        send(res, 207, xml, { 'Content-Type': 'application/xml; charset=utf-8' });
      });
      return;
    }

    case 'GET': {
      if (provider.downloadStrategy === 'parallel_direct') {
        try {
          if (req.headers.range) {
            return await directProxyDownload(provider, res, target, String(req.headers.range));
          }
          return await parallelDirectDownload(provider, res, target);
        } catch (error) {
          console.error(`[${provider.id}] direct download failed:`, error.message);
          if (!res.headersSent) {
            return forward(provider, null, res, 'GET', target, req.headers.range ? { Range: req.headers.range } : {});
          }
          if (!res.destroyed) res.destroy(error);
          return;
        }
      }
      return forward(provider, null, res, 'GET', target, req.headers.range ? { Range: req.headers.range } : {});
    }

    case 'PUT': {
      if (target === null && !(parentDir !== null && name)) return send(res, 409, 'No parent');
      const destRel = target || (parentDir ? parentDir + '/' + name : name);
      if (!destRel) return send(res, 409, 'No parent');
      if (provider.id === 'baidu') {
        try {
          await alistUpload(provider, req, destRel);
          return send(res, target === null ? 201 : 204, target === null ? 'Created' : '');
        } catch (error) {
          console.error(`[${provider.id}] upload failed:`, error.message);
          return send(res, 502, error.message);
        }
      }
      return forward(provider, req, res, 'PUT', destRel);
    }

    case 'MKCOL': {
      if (!name) return send(res, 409, 'No parent');
      const destRel = target || (parentDir ? parentDir + '/' + name : name);
      if (!destRel) return send(res, 409, 'No parent');
      if (provider.id === 'baidu') {
        try {
          await alistMkdir(provider, destRel);
          return send(res, target === null ? 201 : 204, target === null ? 'Created' : '');
        } catch (error) {
          console.error(`[${provider.id}] mkdir failed:`, error.message);
          return send(res, 502, error.message);
        }
      }
      return forward(provider, null, res, 'MKCOL', destRel);
    }

    case 'DELETE': {
      if (target === '') return send(res, 403, 'Refusing to delete the root');
      if (provider.id === 'baidu') {
        try {
          await alistRemove(provider, target);
          for (const [id, rel] of [...state.idToPath]) {
            if (rel === target || rel.startsWith(target + '/')) state.forgetID(id);
          }
          state.save();
          return send(res, 204, '');
        } catch (error) {
          console.error(`[${provider.id}] delete failed:`, error.message);
          return send(res, 502, error.message);
        }
      }
      const authorization = alistWebDAVAuthorization();
      if (!authorization) return send(res, 503, 'AList admin credential is not configured');
      const upstream = http.request(new URL(relToURL(provider, target)), {
        method: 'DELETE',
        headers: { Authorization: authorization },
      }, (downstream) => {
        if (downstream.statusCode && downstream.statusCode < 300) {
          for (const [id, rel] of [...state.idToPath]) {
            if (rel === target || rel.startsWith(target + '/')) state.forgetID(id);
          }
          state.save();
        }
        downstream.resume();
        send(res, downstream.statusCode || 204, '');
      });
      upstream.on('error', (error) => {
        if (!res.headersSent && !res.writableEnded) return send(res, 502, 'Backend error');
        if (!res.destroyed) res.destroy(error);
      });
      upstream.end();
      return;
    }

    case 'MOVE': {
      const rawDestination = req.headers.destination;
      if (!rawDestination) return send(res, 400, 'No Destination');
      const destinationURL = new URL(rawDestination, `http://${req.headers.host}`);
      const destinationRoute = davRoute(destinationURL.pathname);
      if (!destinationRoute || destinationRoute.provider.id !== provider.id) {
        return send(res, 409, 'Cross-provider move is not supported');
      }
      const destination = resolve(state, destinationRoute.providerPath);
      if (!destination) return send(res, 409, 'Bad Destination');
      const finalRel = destination.target
        || (destination.parentDir !== null
          ? (destination.parentDir ? destination.parentDir + '/' + destination.name : destination.name)
          : null);
      if (finalRel === null || finalRel === undefined) return send(res, 409, 'Bad Destination');

      const applyStateMove = () => {
        const moves = [];
        for (const [id, rel] of [...state.idToPath]) {
          if (rel === target) moves.push([id, finalRel]);
          else if (rel.startsWith(target + '/')) moves.push([id, finalRel + rel.slice(target.length)]);
        }
        for (const [id, rel] of moves) {
          const oldRel = state.idToPath.get(id);
          if (oldRel !== undefined) state.pathToId.delete(oldRel);
          state.idToPath.set(id, rel);
          state.pathToId.set(rel, id);
        }
        state.save();
      };

      if (provider.id === 'baidu') {
        try {
          await alistMove(provider, target, finalRel, (req.headers.overwrite || 'T') !== 'F');
          applyStateMove();
          return send(res, 204, '');
        } catch (error) {
          console.error(`[${provider.id}] move failed:`, error.message);
          return send(res, 502, error.message);
        }
      }

      const authorization = alistWebDAVAuthorization();
      if (!authorization) return send(res, 503, 'AList admin credential is not configured');
      const headers = {
        Authorization: authorization,
        Destination: relToURL(provider, finalRel),
        Overwrite: req.headers.overwrite || 'T',
      };
      const upstream = http.request(new URL(relToURL(provider, target)), { method: 'MOVE', headers }, (downstream) => {
        if (downstream.statusCode && downstream.statusCode < 300) applyStateMove();
        downstream.resume();
        send(res, downstream.statusCode || 204, '');
      });
      upstream.on('error', (error) => {
        if (!res.headersSent && !res.writableEnded) return send(res, 502, 'Backend error');
        if (!res.destroyed) res.destroy(error);
      });
      upstream.end();
      return;
    }

    case 'OPTIONS':
      return send(res, 200, '', { DAV: '1', Allow: 'OPTIONS,GET,PUT,DELETE,PROPFIND,MKCOL,MOVE' });

    default:
      return send(res, 405, 'Method not allowed');
  }
});

server.listen(PORT, HOST, () => {
  const routes = [...providers.keys()].filter((id) => !ONLY_PROVIDER || id === ONLY_PROVIDER).map((id) => `/dav/${id}`).join(', ');
  console.log(`alist bridge listening on ${HOST}:${PORT}; providers: ${routes}`);
});
