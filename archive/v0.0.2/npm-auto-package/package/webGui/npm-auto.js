// npm-auto.js - injects NPM column into the Docker tab and wires toggles to settings.php
(function() {
  const AUTH_HEADER = () => {
    try {
      return localStorage.getItem('npm_auto_admin_token') || '';
    } catch(e){ return ''; }
  };

  function sendAuthFetch(url, options) {
    options = options || {};
    options.headers = options.headers || {};
    const token = AUTH_HEADER();
    if (token) options.headers['X-NPM-AUTO-Auth'] = token;
    options.credentials = 'same-origin';
    return fetch(url, options);
  }

  function addColumn() {
    // Attempt to locate Docker table used by Unraid
    const table = document.querySelector('#dockerTable') || document.querySelector('table.dynamix-table');
    if (!table) return;

    const header = table.querySelector('thead tr');
    if (header && !document.querySelector('#npm-auto-header')) {
      const th = document.createElement('th');
      th.id = 'npm-auto-header';
      th.textContent = 'NPM';
      header.appendChild(th);
    }

    const rows = table.querySelectorAll('tbody tr');
    rows.forEach(row => {
      if (row.querySelector('.npm-auto-cell')) return;
      const td = document.createElement('td');
      td.className = 'npm-auto-cell';
      td.style.textAlign = 'center';
      // get container name heuristically
      const nameEl = row.querySelector('.table-item-name, .name') || row.querySelector('td:first-child');
      const cname = nameEl ? nameEl.textContent.trim().split('\n')[0].trim() : '';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.dataset.container = cname;
      input.className = 'npm-auto-toggle';
      input.style.width = '18px';
      input.style.height = '18px';
      // load state
      sendAuthFetch('/plugins/npm-auto/settings.php?action=getState&container=' + encodeURIComponent(cname))
        .then(r => r.json())
        .then(js => {
          if (js && js.state && js.state.enabled) input.checked = true;
        }).catch(()=>{});
      input.addEventListener('change', (ev) => {
        const enabled = ev.target.checked ? "true":"false";
        const payload = { container: ev.target.dataset.container, enabled: enabled };
        sendAuthFetch('/plugins/npm-auto/settings.php?action=setToggle', {
          method: 'POST',
          headers: {'Content-Type':'application/json'},
          body: JSON.stringify(payload)
        }).then(()=> {
          // optional feedback
        }).catch(()=>{ alert('Failed to update toggle'); });
      });
      td.appendChild(input);
      row.appendChild(td);
    });
  }

  const obs = new MutationObserver(() => addColumn());
  obs.observe(document.body, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', addColumn);
  setTimeout(addColumn, 1500);
})();
