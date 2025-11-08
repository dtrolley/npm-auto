// npm-auto.js
(function() {
  // Wait for Docker table to appear
  function addColumn() {
    // Unraid uses table rows with class ".dynamix-dockertable__row" or similar; be robust
    const table = document.querySelector('#dockerTable, table.dynamix-table');
    if (!table) return;

    // Add header if not present
    const headerRow = table.querySelector('thead tr');
    if (headerRow && !document.querySelector('#npm-auto-header')) {
      const th = document.createElement('th');
      th.id = 'npm-auto-header';
      th.textContent = 'NPM';
      headerRow.appendChild(th);
    }

    // Add a cell per row if missing
    const rows = table.querySelectorAll('tbody tr');
    rows.forEach(row => {
      if (row.querySelector('.npm-auto-cell')) return;
      const td = document.createElement('td');
      td.className = 'npm-auto-cell';
      // clone the autostart toggle markup if available; otherwise basic checkbox
      const cname = row.querySelector('.table-item-name, .name') ? (row.querySelector('.table-item-name') || row.querySelector('.name')).textContent.trim() : null;
      let input = document.createElement('input');
      input.type = 'checkbox';
      input.dataset.container = cname || '';
      input.className = 'npm-auto-toggle';
      // load saved state via fetch to settings endpoint
      fetch('/plugins/npm-auto/settings.php?action=getState&container=' + encodeURIComponent(input.dataset.container))
        .then(r => r.json())
        .then(js => {
          if (js.state && js.state.enabled) input.checked = true;
        })
        .catch(()=>{});
      input.addEventListener('change', (ev) => {
        const enabled = ev.target.checked ? "true":"false";
        const payload = { container: ev.target.dataset.container, enabled: enabled };
        fetch('/plugins/npm-auto/settings.php?action=setToggle', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        }).then(()=> {
          // Optionally show a small toast
        }).catch(()=>{});
      });
      td.appendChild(input);
      row.appendChild(td);
    });
  }

  // Observe DOM changes and add column whenever Docker table appears or updates
  const bodyObserver = new MutationObserver((mutations) => {
    addColumn();
  });
  bodyObserver.observe(document.body, { childList: true, subtree: true });

  // run once
  document.addEventListener('DOMContentLoaded', addColumn);
})();

