#!/usr/bin/env node
/*
 * Temporary configuration web UI for deployCore bootstrap.
 *
 * Started by scripts/bootstrap.sh, typically inside a node:20-alpine docker
 * container with the repo bind-mounted at /work. Listens on 0.0.0.0:<port>
 * (default 8888). Renders a single HTML form letting the operator pick
 * what to install and fill in domains, emails, and tokens. On submit, writes:
 *
 *     <repo>/.env
 *     <repo>/projects/max/.env          (only if "Configure max" checked)
 *     <repo>/shared/mail/mailserver.env (only if "Install mail" checked)
 *     <repo>/.install-ui-result.json    (sidecar: which optionals were picked)
 *
 * Then exits with code 0. The shell script picks up where the UI left off.
 *
 * Node stdlib only — no npm install needed.
 */

'use strict';

const http = require('node:http');
const fs   = require('node:fs');
const path = require('node:path');
const dgram = require('node:dgram');

// ─── HTML ────────────────────────────────────────────────────────────────

const HTML_FORM = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>deployCore — installer</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    font: 14px/1.45 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif;
    margin: 0; padding: 32px 16px;
    background: #f5f6f8; color: #1c1f24;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #15181d; color: #d8dde4; }
    .card { background: #1f242c !important; border-color: #2c3340 !important; }
    input, select { background: #15181d !important; color: #d8dde4 !important; border-color: #2c3340 !important; }
    .muted { color: #94a0b1 !important; }
    .group-body { background: #181c22 !important; }
    .err { background: #3a1818 !important; border-color: #5c2828 !important; color: #ffb6b6 !important; }
  }
  .container { max-width: 760px; margin: 0 auto; }
  h1 { margin: 0 0 4px; font-size: 22px; }
  .lead { margin: 0 0 24px; color: #5a6675; }
  .muted { color: #5a6675; font-size: 12px; }
  .card {
    background: #fff; border: 1px solid #e1e4ea; border-radius: 10px;
    padding: 20px 22px; margin-bottom: 16px;
  }
  label { display: block; font-weight: 600; margin: 12px 0 4px; }
  label.row { display: flex; align-items: center; gap: 8px; font-weight: 500; }
  input[type=text], input[type=email], input[type=password], select {
    width: 100%; padding: 8px 10px; font: inherit;
    border: 1px solid #d0d4dc; border-radius: 6px;
    background: #fff;
  }
  input[type=checkbox] { width: 16px; height: 16px; }
  .group-body {
    background: #fafbfc; border-left: 3px solid #4a90e2;
    padding: 8px 16px 16px; margin: 8px 0 0; border-radius: 0 6px 6px 0;
    display: none;
  }
  .group-body.open { display: block; }
  .help { margin-top: 4px; font-size: 12px; color: #5a6675; }
  .actions { display: flex; gap: 12px; margin-top: 24px; }
  button {
    font: inherit; font-weight: 600;
    padding: 10px 20px; border-radius: 6px; border: 0; cursor: pointer;
  }
  .primary { background: #2a6df4; color: #fff; }
  .primary:hover { background: #1d5cd8; }
  .secondary { background: transparent; color: #5a6675; }
  .err {
    background: #fdeaea; border: 1px solid #f5c2c2; color: #80201f;
    padding: 10px 14px; border-radius: 6px; margin-bottom: 16px;
    white-space: pre-wrap; font-family: ui-monospace, monospace; font-size: 13px;
  }
  .gen-row { display: flex; gap: 8px; align-items: center; }
  .gen-row input { flex: 1; }
  .pill {
    display: inline-block; font-size: 11px; padding: 1px 8px; border-radius: 999px;
    background: #e8eaef; color: #5a6675; margin-left: 6px; vertical-align: middle;
  }
</style>
</head>
<body>
  <div class="container">
    <h1>deployCore — installer</h1>
    <p class="lead">Pick what to install and fill in the values. The bootstrap will continue once you submit.</p>

    {{ERR}}

    <form method="post" action="/" id="f">
      <div class="card">
        <h3 style="margin:0 0 8px">Global</h3>
        <p class="muted" style="margin:0 0 8px">These go into the repo's top-level <code>.env</code>.</p>

        <label for="LETSENCRYPT_EMAIL">Let's Encrypt email <span class="pill">required</span></label>
        <input type="email" id="LETSENCRYPT_EMAIL" name="LETSENCRYPT_EMAIL" required value="{{LETSENCRYPT_EMAIL}}">
        <div class="help">Used by Let's Encrypt to notify about expiring certs.</div>

        <label for="TZ">Timezone</label>
        <input type="text" id="TZ" name="TZ" value="{{TZ}}">

        <label class="row" style="margin-top:16px">
          <input type="checkbox" name="ACME_STAGING" value="1" {{ACME_STAGING_CHECKED}}>
          Use Let's Encrypt staging (untrusted certs, no rate limit — for testing)
        </label>
      </div>

      <div class="card">
        <label class="row" style="margin:0">
          <input type="checkbox" name="install_portainer" id="install_portainer" value="1" {{PORT_CHECKED}}>
          <strong>Install Portainer</strong> (admin UI, exposed on a dedicated subdomain)
        </label>
        <div class="group-body {{PORT_OPEN}}" id="portainer_body">
          <label for="PORTAINER_DOMAIN">Portainer domain</label>
          <input type="text" id="PORTAINER_DOMAIN" name="PORTAINER_DOMAIN" placeholder="portainer.example.com" value="{{PORTAINER_DOMAIN}}">
          <div class="help">Must have a DNS A record pointing at this server before installation.</div>
        </div>
      </div>

      <div class="card">
        <label class="row" style="margin:0">
          <input type="checkbox" name="install_mail" id="install_mail" value="1" {{MAIL_CHECKED}}>
          <strong>Install mail server</strong> (docker-mailserver, opt-in)
        </label>
        <div class="group-body {{MAIL_OPEN}}" id="mail_body">
          <label for="MAIL_DOMAIN">Mail domain</label>
          <input type="text" id="MAIL_DOMAIN" name="MAIL_DOMAIN" placeholder="example.com" value="{{MAIL_DOMAIN}}">

          <label for="MAIL_HOSTNAME">Mail hostname (subdomain part)</label>
          <input type="text" id="MAIL_HOSTNAME" name="MAIL_HOSTNAME" value="{{MAIL_HOSTNAME}}">

          <label for="LETSENCRYPT_DOMAIN">Let's Encrypt domain for mail</label>
          <input type="text" id="LETSENCRYPT_DOMAIN" name="LETSENCRYPT_DOMAIN" placeholder="smtp.example.com" value="{{LETSENCRYPT_DOMAIN}}">

          <label for="POSTMASTER_ADDRESS">Postmaster address</label>
          <input type="email" id="POSTMASTER_ADDRESS" name="POSTMASTER_ADDRESS" placeholder="admin@example.com" value="{{POSTMASTER_ADDRESS}}">

          <div class="help" style="margin-top:8px">
            Port 25 must be unblocked at your hosting provider. DNS records (MX, SPF, DKIM, DMARC, PTR) are NOT configured by this installer.
          </div>
        </div>
      </div>

      <div class="card">
        <label class="row" style="margin:0">
          <input type="checkbox" name="install_max" id="install_max" value="1" {{MAX_CHECKED}}>
          <strong>Configure the <code>max</code> project</strong> (Spring Boot + Next.js + MongoDB)
        </label>
        <div class="group-body {{MAX_OPEN}}" id="max_body">
          <label for="MAX_DOMAIN">max domain</label>
          <input type="text" id="MAX_DOMAIN" name="MAX_DOMAIN" placeholder="max.example.com" value="{{MAX_DOMAIN}}">

          <label for="MONGO_PASSWORD">MongoDB root password</label>
          <div class="gen-row">
            <input type="text" id="MONGO_PASSWORD" name="MONGO_PASSWORD" value="{{MONGO_PASSWORD}}" placeholder="generate or paste">
            <button type="button" class="secondary" onclick="genPwd()">Generate</button>
          </div>
          <div class="help">A 32-byte URL-safe random secret is generated client-side when you click Generate.</div>

          <label for="BACKEND_JAR_DIR">Backend jar directory (host path)</label>
          <input type="text" id="BACKEND_JAR_DIR" name="BACKEND_JAR_DIR" value="{{BACKEND_JAR_DIR}}">

          <label for="FRONTEND_DIR">Frontend sources directory (host path)</label>
          <input type="text" id="FRONTEND_DIR" name="FRONTEND_DIR" value="{{FRONTEND_DIR}}">

          <label for="STATIC_DIR">Static files directory (host path)</label>
          <input type="text" id="STATIC_DIR" name="STATIC_DIR" value="{{STATIC_DIR}}">
        </div>
      </div>

      <div class="actions">
        <button type="submit" class="primary">Save and continue installation</button>
        <button type="button" class="secondary" onclick="if(confirm('Cancel? bootstrap will stop.')) location.href='/cancel'">Cancel</button>
      </div>

      <p class="muted" style="margin-top:16px">
        Submitting writes <code>.env</code> files to the repo on the server and starts the rest of bootstrap.
        You can close this tab once you see the confirmation page.
      </p>
    </form>
  </div>

<script>
  function toggle(id, body) {
    const cb = document.getElementById(id);
    const b = document.getElementById(body);
    function up() { b.classList.toggle('open', cb.checked); }
    cb.addEventListener('change', up);
    up();
  }
  toggle('install_portainer', 'portainer_body');
  toggle('install_mail', 'mail_body');
  toggle('install_max', 'max_body');

  function genPwd() {
    const buf = new Uint8Array(32);
    crypto.getRandomValues(buf);
    const b64 = btoa(String.fromCharCode(...buf))
      .replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
    document.getElementById('MONGO_PASSWORD').value = b64;
  }
</script>
</body>
</html>`;

const HTML_DONE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><title>deployCore — installing</title>
<style>
  body { font: 14px/1.45 -apple-system, system-ui, sans-serif; padding: 48px; max-width: 600px; margin: 0 auto; }
  h1 { margin-top: 0; }
  pre { background: #f5f6f8; padding: 12px; border-radius: 6px; overflow: auto; }
</style></head>
<body>
  <h1>✓ Configuration saved</h1>
  <p>The web UI has shut down. <strong>Switch back to your terminal</strong> — the rest of the bootstrap is running there:
     installing nginx, certbot, syncing configs, optionally bringing up Portainer / mail / projects.</p>
  <p>You can close this tab now.</p>
  <h3>What was written</h3>
  <pre>{{SUMMARY}}</pre>
</body>
</html>`;

const HTML_CANCEL = `<!doctype html>
<html><head><meta charset="utf-8"><title>Cancelled</title></head>
<body style="font:14px sans-serif;padding:48px;max-width:520px;margin:auto">
  <h1>Bootstrap cancelled</h1>
  <p>No files were written. The bootstrap script has exited.</p>
</body></html>`;

// ─── helpers ─────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function loadDefaults(repoRoot) {
  const defaults = {
    LETSENCRYPT_EMAIL: '',
    TZ: 'Europe/Moscow',
    ACME_STAGING: '0',
    PORTAINER_DOMAIN: '',
    MAIL_DOMAIN: '',
    MAIL_HOSTNAME: 'smtp',
    LETSENCRYPT_DOMAIN: '',
    POSTMASTER_ADDRESS: '',
    MAX_DOMAIN: '',
    MONGO_PASSWORD: '',
    BACKEND_JAR_DIR: '/home/maxAgent/backend/target',
    FRONTEND_DIR:    '/home/maxAgent/frontend/sources',
    STATIC_DIR:      '/home/static',
  };
  const envPath = path.join(repoRoot, '.env');
  if (fs.existsSync(envPath)) {
    const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq < 0) continue;
      const k = line.slice(0, eq).trim();
      const v = line.slice(eq + 1).trim();
      if (k in defaults) defaults[k] = v;
    }
  }
  return defaults;
}

function renderForm(state, error = '', form = {}) {
  const v = (key) => escapeHtml(form[key] ?? state.defaults[key] ?? '');
  const checked = (key, want = '1') =>
    (form[key] ?? state.defaults[key] ?? '') === want ? 'checked' : '';
  const open_ = (key) => (checked(key) ? 'open' : '');

  const errBlock = error ? `<div class="err">${escapeHtml(error)}</div>` : '';

  const repl = {
    ERR: errBlock,
    LETSENCRYPT_EMAIL: v('LETSENCRYPT_EMAIL'),
    TZ: v('TZ'),
    ACME_STAGING_CHECKED: checked('ACME_STAGING'),
    PORT_CHECKED:        checked('install_portainer'),
    PORT_OPEN:           open_('install_portainer'),
    PORTAINER_DOMAIN:    v('PORTAINER_DOMAIN'),
    MAIL_CHECKED:        checked('install_mail'),
    MAIL_OPEN:           open_('install_mail'),
    MAIL_DOMAIN:         v('MAIL_DOMAIN'),
    MAIL_HOSTNAME:       v('MAIL_HOSTNAME'),
    LETSENCRYPT_DOMAIN:  v('LETSENCRYPT_DOMAIN'),
    POSTMASTER_ADDRESS:  v('POSTMASTER_ADDRESS'),
    MAX_CHECKED:         checked('install_max'),
    MAX_OPEN:            open_('install_max'),
    MAX_DOMAIN:          v('MAX_DOMAIN'),
    MONGO_PASSWORD:      v('MONGO_PASSWORD'),
    BACKEND_JAR_DIR:     v('BACKEND_JAR_DIR'),
    FRONTEND_DIR:        v('FRONTEND_DIR'),
    STATIC_DIR:          v('STATIC_DIR'),
  };
  let html = HTML_FORM;
  for (const [k, val] of Object.entries(repl)) {
    html = html.split('{{' + k + '}}').join(val);
  }
  return html;
}

function writeFileSecure(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents, { encoding: 'utf8', mode: 0o600 });
  // Re-chmod in case the file pre-existed with looser perms.
  try { fs.chmodSync(filePath, 0o600); } catch { /* no-op */ }
}

function validateAndWrite(state, form) {
  const errors = [];
  const trim = (k) => (form[k] || '').trim();

  const email = trim('LETSENCRYPT_EMAIL');
  if (!email.includes('@') || !email.includes('.')) {
    errors.push('LETSENCRYPT_EMAIL must look like an email');
  }

  const installPortainer = form.install_portainer === '1';
  const installMail      = form.install_mail      === '1';
  const installMax       = form.install_max       === '1';

  if (installPortainer) {
    const d = trim('PORTAINER_DOMAIN');
    if (!d || !d.includes('.')) errors.push('PORTAINER_DOMAIN required when Portainer is enabled');
  }
  if (installMail) {
    for (const k of ['MAIL_DOMAIN', 'LETSENCRYPT_DOMAIN', 'POSTMASTER_ADDRESS']) {
      if (!trim(k)) errors.push(`${k} required when mail is enabled`);
    }
  }
  if (installMax) {
    if (!trim('MAX_DOMAIN'))     errors.push('MAX_DOMAIN required when max project is enabled');
    if (!trim('MONGO_PASSWORD')) errors.push('MONGO_PASSWORD required (use Generate button)');
  }

  if (errors.length) throw new Error(errors.join('\n'));

  const tz   = trim('TZ') || 'Europe/Moscow';
  const acme = form.ACME_STAGING === '1' ? '1' : '0';

  // Top-level .env
  const envBody = [
    `LETSENCRYPT_EMAIL=${email}`,
    `TZ=${tz}`,
    `ACME_STAGING=${acme}`,
    `PORTAINER_DOMAIN=${trim('PORTAINER_DOMAIN')}`,
  ].join('\n') + '\n';
  writeFileSecure(path.join(state.repoRoot, '.env'), envBody);
  const summary = ['.env'];

  if (installMax) {
    const maxEnv = [
      `MAX_DOMAIN=${trim('MAX_DOMAIN')}`,
      'MONGO_USER=root',
      `MONGO_PASSWORD=${trim('MONGO_PASSWORD')}`,
      `BACKEND_JAR_DIR=${trim('BACKEND_JAR_DIR') || '/home/maxAgent/backend/target'}`,
      `FRONTEND_DIR=${trim('FRONTEND_DIR') || '/home/maxAgent/frontend/sources'}`,
      `STATIC_DIR=${trim('STATIC_DIR') || '/home/static'}`,
      `TZ=${tz}`,
    ].join('\n') + '\n';
    writeFileSecure(path.join(state.repoRoot, 'projects', 'max', '.env'), maxEnv);
    summary.push('projects/max/.env');
  }

  if (installMail) {
    const mailEnv = [
      `MAIL_DOMAIN=${trim('MAIL_DOMAIN')}`,
      `MAIL_HOSTNAME=${trim('MAIL_HOSTNAME') || 'smtp'}`,
      `LETSENCRYPT_DOMAIN=${trim('LETSENCRYPT_DOMAIN')}`,
      'ENABLE_SSL=1',
      'SSL_TYPE=letsencrypt',
      `LETSENCRYPT_EMAIL=${email}`,
      `POSTMASTER_ADDRESS=${trim('POSTMASTER_ADDRESS')}`,
      'ENABLE_SPAMASSASSIN=1',
      'ENABLE_CLAMAV=1',
      'ENABLE_FAIL2BAN=1',
      'ENABLE_POSTGREY=1',
    ].join('\n') + '\n';
    writeFileSecure(path.join(state.repoRoot, 'shared', 'mail', 'mailserver.env'), mailEnv);
    summary.push('shared/mail/mailserver.env');
  }

  // Sidecar so bootstrap.sh knows what to do without re-parsing .env.
  const sidecar = JSON.stringify({
    install_portainer: installPortainer,
    install_mail:      installMail,
    install_max:       installMax,
  }) + '\n';
  writeFileSecure(path.join(state.repoRoot, '.install-ui-result.json'), sidecar);
  summary.push('.install-ui-result.json');

  return summary.join('\n');
}

// Best-effort outbound IP for the operator's "open this URL" hint.
function publicIpHint() {
  try {
    const sock = dgram.createSocket('udp4');
    sock.connect(53, '8.8.8.8');
    return new Promise((resolve) => {
      sock.once('connect', () => {
        try { resolve(sock.address().address); }
        catch { resolve('<server-ip>'); }
        finally { sock.close(); }
      });
      sock.once('error', () => { try { sock.close(); } catch {} resolve('<server-ip>'); });
    });
  } catch {
    return Promise.resolve('<server-ip>');
  }
}

// ─── server ──────────────────────────────────────────────────────────────

function parseForm(body) {
  const out = {};
  if (!body) return out;
  for (const part of body.split('&')) {
    if (!part) continue;
    const eq = part.indexOf('=');
    const k = decodeURIComponent((eq >= 0 ? part.slice(0, eq) : part).replace(/\+/g, ' '));
    const v = decodeURIComponent((eq >= 0 ? part.slice(eq + 1) : '').replace(/\+/g, ' '));
    out[k] = v;
  }
  return out;
}

function send(res, code, body, ct = 'text/html; charset=utf-8') {
  res.writeHead(code, {
    'Content-Type': ct,
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

async function main(argv) {
  const repoRoot = path.resolve(argv[0] || '.');
  const port = parseInt(process.env.INSTALL_UI_PORT || argv[1] || '8888', 10);

  if (!fs.existsSync(repoRoot)) {
    console.error(`repo root does not exist: ${repoRoot}`);
    process.exit(2);
  }

  const state = { repoRoot, defaults: loadDefaults(repoRoot) };

  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && (req.url === '/' || req.url.startsWith('/?'))) {
      send(res, 200, renderForm(state));
      return;
    }
    if (req.method === 'GET' && req.url.startsWith('/cancel')) {
      send(res, 200, HTML_CANCEL);
      console.log('[ui] cancelled by operator');
      setImmediate(() => process.exit(130));
      return;
    }
    if (req.method === 'POST' && (req.url === '/' || req.url.startsWith('/?'))) {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        const form = parseForm(body);
        try {
          const summary = validateAndWrite(state, form);
          const html = HTML_DONE.replace('{{SUMMARY}}', escapeHtml(summary));
          send(res, 200, html);
          console.log('[ui] form submitted, files written');
          // Give the response a moment to flush before exiting.
          setTimeout(() => process.exit(0), 150);
        } catch (e) {
          send(res, 400, renderForm(state, e.message, form));
        }
      });
      return;
    }
    send(res, 404, 'not found', 'text/plain; charset=utf-8');
  });

  const ip = await publicIpHint();
  server.listen(port, '0.0.0.0', () => {
    console.log(`[ui] listening on 0.0.0.0:${port}`);
    console.log(`[ui] open in your browser:  http://${ip}:${port}`);
    console.log(`[ui] (or  http://localhost:${port}  if you SSH-tunneled the port)`);
    console.log('[ui] waiting for form submission... (Ctrl-C to abort)');
  });

  process.on('SIGINT', () => {
    console.log('\n[ui] aborted by Ctrl-C');
    process.exit(130);
  });
}

main(process.argv.slice(2)).catch((e) => {
  console.error('[ui] fatal:', e);
  process.exit(1);
});
