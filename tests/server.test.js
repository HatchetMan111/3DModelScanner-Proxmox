import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createServer } from '../server/server.js';

let rootDir;
let outsideDir;
let server;
let baseUrl;

before(async () => {
  rootDir = await mkdtemp(path.join(tmpdir(), '3dma-site-'));
  outsideDir = await mkdtemp(path.join(tmpdir(), '3dma-outside-'));

  await writeFile(path.join(rootDir, 'index.html'), '<!doctype html><title>3D Model Anything</title><h1>viewer</h1>');
  await writeFile(path.join(outsideDir, 'secret.txt'), 'top-secret');
  await writeFile(path.join(rootDir, '.env'), 'SECRET-DOTFILE');
  await mkdir(path.join(rootDir, 'assets'));
  await writeFile(path.join(rootDir, 'assets', 'index-abc12345.js'), 'console.log("viewer");');
  await mkdir(path.join(rootDir, 'rooms'));
  await writeFile(path.join(rootDir, 'rooms', 'index.html'), '<h1>rooms</h1>');
  await writeFile(path.join(rootDir, 'model.glb'), Buffer.from([0x67, 0x6c, 0x54, 0x46]));
  await symlink(path.join(outsideDir, 'secret.txt'), path.join(rootDir, 'link.txt'));
  await symlink(outsideDir, path.join(rootDir, 'linkdir'), 'dir');

  server = createServer({ rootDir });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await rm(rootDir, { recursive: true, force: true });
  await rm(outsideDir, { recursive: true, force: true });
});

function rawRequest(pathname, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port: server.address().port, path: pathname, method },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve({
          status: res.statusCode,
          body: Buffer.concat(chunks).toString('utf8'),
        }));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

test('health endpoint returns JSON', async () => {
  const response = await fetch(`${baseUrl}/api/health`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /application\/json/);
  const body = await response.json();
  assert.equal(body.status, 'ok');
  assert.equal(body.app, '3d-model-anything');
  assert.equal(typeof body.uptimeSeconds, 'number');
});

test('serves index.html at root', async () => {
  const response = await fetch(`${baseUrl}/`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);
  assert.match(await response.text(), /3D Model Anything/);
});

test('serves javascript with correct MIME type', async () => {
  const response = await fetch(`${baseUrl}/assets/index-abc12345.js`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/javascript/);
});

test('serves binary glb with correct MIME type', async () => {
  const response = await fetch(`${baseUrl}/model.glb`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'model/gltf-binary');
});

test('returns 404 for missing file', async () => {
  const response = await fetch(`${baseUrl}/does-not-exist.html`);
  assert.equal(response.status, 404);
});

test('redirects directory requests to trailing slash', async () => {
  const response = await fetch(`${baseUrl}/rooms`, { redirect: 'manual' });
  assert.equal(response.status, 301);
  assert.equal(response.headers.get('location'), '/rooms/');
});

test('blocks path traversal with raw HTTP paths', async () => {
  for (const attempt of [
    '/..%2fsecret.txt',
    '/%2e%2e/secret.txt',
    '/%2e%2e%2fsecret.txt',
    '/..//secret.txt',
    '/rooms/..%2f..%2fsecret.txt',
  ]) {
    const { status, body } = await rawRequest(attempt);
    assert.notEqual(status, 200, `traversal not blocked: ${attempt}`);
    assert.ok(!body.includes('top-secret'), `secret leaked: ${attempt}`);
  }
});

test('blocks symlink escape outside root', async () => {
  for (const attempt of ['/link.txt', '/linkdir/secret.txt']) {
    const response = await fetch(`${baseUrl}${attempt}`);
    assert.notEqual(response.status, 200, `symlink not blocked: ${attempt}`);
    if (response.status === 200) {
      assert.doesNotMatch(await response.text(), /top-secret/);
    }
  }
});

test('blocks dotfiles', async () => {
  const response = await fetch(`${baseUrl}/.env`);
  assert.notEqual(response.status, 200);
  assert.doesNotMatch(await response.text(), /SECRET-DOTFILE/);
});

test('rejects non-GET/HEAD methods', async () => {
  const response = await fetch(`${baseUrl}/api/health`, { method: 'POST' });
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'GET, HEAD');
});

test('HEAD returns headers without body', async () => {
  const response = await fetch(`${baseUrl}/`, { method: 'HEAD' });
  assert.equal(response.status, 200);
  assert.ok(Number(response.headers.get('content-length')) > 0);
  assert.equal(await response.text(), '');
});

test('hashed assets are cached immutably', async () => {
  const response = await fetch(`${baseUrl}/assets/index-abc12345.js`);
  assert.match(response.headers.get('cache-control'), /immutable/);
});

test('html is not cached', async () => {
  const response = await fetch(`${baseUrl}/`);
  assert.equal(response.headers.get('cache-control'), 'no-cache');
});
