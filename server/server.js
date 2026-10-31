import http from 'node:http';
import path from 'node:path';
import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const APP_NAME = '3d-model-anything';
const APP_VERSION = process.env.APP_VERSION || '1.0.0';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
  '.bin': 'application/octet-stream',
  '.wasm': 'application/wasm',
  '.ktx2': 'image/ktx2',
  '.hdr': 'image/vnd.radiance',
  '.exr': 'image/x-exr',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
};

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'SAMEORIGIN',
};

function resolveRequestPath(root, pathname) {
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (decoded.includes('\0')) return null;
  const segments = decoded.split('/');
  if (segments.includes('..')) return null;
  if (segments.some((segment) => segment.startsWith('.'))) return null;
  const relative = decoded.replace(/^\/+/, '');
  const absolute = path.resolve(root, relative);
  if (absolute !== root && !absolute.startsWith(root + path.sep)) return null;
  return absolute;
}

async function resolveWithinRoot(root, absolute) {
  const rootReal = await realpath(root).catch(() => null);
  const real = await realpath(absolute).catch(() => null);
  if (!rootReal || !real) return null;
  if (real !== rootReal && !real.startsWith(rootReal + path.sep)) return null;
  return real;
}

function cacheControl(pathname, isHtml) {
  if (pathname.startsWith('/assets/')) {
    return 'public, max-age=31536000, immutable';
  }
  if (isHtml) return 'no-cache';
  return 'public, max-age=86400';
}

function sendText(res, status, text, extraHeaders = {}) {
  const body = Buffer.from(text, 'utf8');
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    ...extraHeaders,
  });
  res.end(body);
}

function sendJson(res, status, value) {
  const body = Buffer.from(JSON.stringify(value), 'utf8');
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

export function createServer({ rootDir }) {
  const root = path.resolve(rootDir);

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', 'http://localhost');

      if (url.pathname === '/api/health') {
        if (req.method !== 'GET' && req.method !== 'HEAD') {
          sendText(res, 405, 'Method Not Allowed\n', { Allow: 'GET, HEAD' });
          return;
        }
        sendJson(res, 200, {
          status: 'ok',
          app: APP_NAME,
          version: APP_VERSION,
          uptimeSeconds: Math.round(process.uptime()),
        });
        return;
      }

      if (req.method !== 'GET' && req.method !== 'HEAD') {
        sendText(res, 405, 'Method Not Allowed\n', { Allow: 'GET, HEAD' });
        return;
      }

      if (url.pathname === '/api/health/') {
        res.writeHead(308, { Location: '/api/health' });
        res.end();
        return;
      }

      let filePath = resolveRequestPath(root, url.pathname);
      if (!filePath) {
        sendText(res, 400, 'Bad Request\n');
        return;
      }

      filePath = await resolveWithinRoot(root, filePath);
      if (!filePath) {
        sendText(res, 404, 'Not Found\n');
        return;
      }

      let fileStat = await stat(filePath).catch(() => null);

      if (fileStat?.isDirectory()) {
        if (!url.pathname.endsWith('/')) {
          res.writeHead(301, { Location: `${url.pathname}/` });
          res.end();
          return;
        }
        filePath = await resolveWithinRoot(root, path.join(filePath, 'index.html'));
        if (!filePath) {
          sendText(res, 404, 'Not Found\n');
          return;
        }
        fileStat = await stat(filePath).catch(() => null);
      }

      if (!fileStat?.isFile()) {
        sendText(res, 404, 'Not Found\n');
        return;
      }

      const extension = path.extname(filePath).toLowerCase();
      const contentType = MIME[extension] || 'application/octet-stream';
      const isHtml = contentType.startsWith('text/html');

      res.writeHead(200, {
        ...SECURITY_HEADERS,
        'Content-Type': contentType,
        'Content-Length': fileStat.size,
        'Cache-Control': cacheControl(url.pathname, isHtml),
        'Last-Modified': fileStat.mtime.toUTCString(),
      });

      if (req.method === 'HEAD') {
        res.end();
        return;
      }

      const stream = createReadStream(filePath);
      res.on('close', () => {
        stream.destroy();
      });
      stream.on('error', () => {
        if (!res.headersSent) {
          sendText(res, 500, 'Internal Server Error\n');
        } else {
          res.destroy();
        }
      });
      stream.pipe(res);
    } catch (error) {
      console.error(`[${APP_NAME}] request failed:`, error);
      if (!res.headersSent) {
        sendText(res, 500, 'Internal Server Error\n');
      } else {
        res.destroy();
      }
    }
  });
}

const isMain =
  Boolean(process.argv[1]) &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  const rootDir = process.env.APP_DIR || path.resolve(import.meta.dirname, '..', 'dist');
  const port = Number.parseInt(process.env.PORT || '5188', 10);
  const host = process.env.HOST || '0.0.0.0';

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`[${APP_NAME}] invalid PORT: ${process.env.PORT}`);
    process.exit(1);
  }

  const indexPath = path.join(rootDir, 'index.html');
  try {
    const indexStat = await stat(indexPath);
    if (!indexStat.isFile()) throw new Error('not a file');
  } catch {
    console.error(`[${APP_NAME}] ${indexPath} fehlt - Deployment unvollstaendig, beende Service.`);
    process.exit(1);
  }

  const server = createServer({ rootDir });

  server.on('error', (error) => {
    console.error(`[${APP_NAME}] server error:`, error);
    process.exit(1);
  });

  server.listen(port, host, () => {
    console.log(`[${APP_NAME}] v${APP_VERSION} serving ${rootDir} on http://${host}:${port}`);
  });

  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
      console.log(`[${APP_NAME}] received ${signal}, shutting down`);
      server.close(() => process.exit(0));
      setTimeout(() => process.exit(1), 5000).unref();
    });
  }
}
