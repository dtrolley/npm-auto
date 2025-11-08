<?php
// settings_ui.php - full Settings tab UI for npm-auto
// This file is intended to be included by Unraid's Settings area or accessed at:
// /plugins/npm-auto/settings_ui.php
?>
<div class="plugin-page" id="npm-auto-settings">
  <h1>NPM Auto — Reverse Proxy Automation</h1>
  <div class="block">
    <form id="npm-auto-form">
      <div class="form-row">
        <label>Enable plugin</label>
        <input type="checkbox" id="NPM_ENABLED" />
      </div>
      <div class="form-row">
        <label>NPM Host</label>
        <input type="text" id="NPM_HOST" placeholder="127.0.0.1" />
      </div>
      <div class="form-row">
        <label>NPM Port</label>
        <input type="text" id="NPM_PORT" placeholder="81" />
      </div>
      <div class="form-row">
        <label>NPM Username</label>
        <input type="text" id="NPM_USER" />
      </div>
      <div class="form-row">
        <label>NPM Password</label>
        <input type="password" id="NPM_PASS" />
      </div>
      <div class="form-row">
        <label>Default Domain</label>
        <input type="text" id="DEFAULT_DOMAIN" placeholder="example.com" />
      </div>
      <div class="form-row">
        <label>Allow container label overrides</label>
        <input type="checkbox" id="LABEL_OVERRIDES" />
      </div>
      <div class="form-row">
        <label>Admin token (keep secret)</label>
        <input type="text" id="NPM_AUTO_ADMIN_TOKEN" readonly />
        <button type="button" id="reveal_token">Show</button>
        <button type="button" id="regen_token">Regenerate</button>
      </div>
      <div class="form-row">
        <button id="saveBtn" type="button">Save settings</button>
        <button id="testBtn" type="button">Test connection</button>
        <span id="testResult" style="margin-left:12px"></span>
      </div>
    </form>
  </div>
</div>

<script>
const API_BASE = '/plugins/npm-auto/settings.php';
function authHeader() {
  return localStorage.getItem('npm_auto_admin_token') || '';
}
function fetchSettings() {
  return fetch(API_BASE + '?action=getSettings').then(r => r.json());
}
function saveSettings(payload) {
  return fetch(API_BASE + '?action=saveSettings', {
    method: 'POST',
    headers: {'Content-Type':'application/json','X-NPM-AUTO-Auth': authHeader()},
    body: JSON.stringify(payload)
  }).then(r => r.json());
}
function testConnection() {
  return fetch(API_BASE + '?action=testConnection', {headers:{'X-NPM-AUTO-Auth': authHeader()}}).then(r => r.json());
}

function populateForm(s) {
  document.getElementById('NPM_ENABLED').checked = (s.NPM_ENABLED === 'true');
  document.getElementById('NPM_HOST').value = s.NPM_HOST || '';
  document.getElementById('NPM_PORT').value = s.NPM_PORT || '';
  document.getElementById('NPM_USER').value = s.NPM_USER || '';
  document.getElementById('NPM_PASS').value = s.NPM_PASS || '';
  document.getElementById('DEFAULT_DOMAIN').value = s.DEFAULT_DOMAIN || '';
  document.getElementById('LABEL_OVERRIDES').checked = (s.LABEL_OVERRIDES === 'true');
  document.getElementById('NPM_AUTO_ADMIN_TOKEN').value = s.NPM_AUTO_ADMIN_TOKEN || '';
  if (s.NPM_AUTO_ADMIN_TOKEN) localStorage.setItem('npm_auto_admin_token', s.NPM_AUTO_ADMIN_TOKEN);
}

document.addEventListener('DOMContentLoaded', () => {
  fetchSettings().then(d => {
    if (d.ok) populateForm(d.settings);
  });

  document.getElementById('saveBtn').addEventListener('click', () => {
    const payload = {
      NPM_ENABLED: document.getElementById('NPM_ENABLED').checked ? 'true' : 'false',
      NPM_HOST: document.getElementById('NPM_HOST').value,
      NPM_PORT: document.getElementById('NPM_PORT').value,
      NPM_USER: document.getElementById('NPM_USER').value,
      NPM_PASS: document.getElementById('NPM_PASS').value,
      DEFAULT_DOMAIN: document.getElementById('DEFAULT_DOMAIN').value,
      LABEL_OVERRIDES: document.getElementById('LABEL_OVERRIDES').checked ? 'true' : 'false',
      NPM_AUTO_ADMIN_TOKEN: document.getElementById('NPM_AUTO_ADMIN_TOKEN').value
    };
    saveSettings(payload).then(res => {
      if (res.ok) {
        alert('Settings saved.');
        if (res.token) {
          localStorage.setItem('npm_auto_admin_token', res.token);
          document.getElementById('NPM_AUTO_ADMIN_TOKEN').value = res.token;
        }
      } else {
        alert('Failed to save settings.');
      }
    });
  });

  document.getElementById('testBtn').addEventListener('click', () => {
    document.getElementById('testResult').textContent = 'Testing...';
    testConnection().then(r => {
      if (r.ok && r.reachable) {
        document.getElementById('testResult').textContent = 'OK';
      } else {
        document.getElementById('testResult').textContent = 'Failed';
        console.log(r);
      }
    }).catch(e => {
      document.getElementById('testResult').textContent = 'Error';
    });
  });

  document.getElementById('reveal_token').addEventListener('click', () => {
    const el = document.getElementById('NPM_AUTO_ADMIN_TOKEN');
    if (el.type === 'text') { el.type = 'password'; } else { el.type = 'text'; }
  });

  document.getElementById('regen_token').addEventListener('click', () => {
    if (!confirm('Regenerate admin token? This will replace the saved token.')) return;
    document.getElementById('NPM_AUTO_ADMIN_TOKEN').value = '';
    document.getElementById('saveBtn').click();
  });
});
</script>
