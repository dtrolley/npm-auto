//==============================================================================
// npm-auto.js
//
// Injected into the Docker tab of the Unraid UI. Adds two columns to each
// container row:
//   Auto Proxy - toggle npm-auto for that container
//   Subdomain  - the name it is (or will be) proxied at; click to override
//==============================================================================

(function() {
  const ENDPOINT = '/plugins/npm-auto/webGui/settings.php';
  let dockerTable;
  let lastData = null;
  let refreshTimers = [];

  //--- Columns ---
  // Returns how many rows gained cells, so callers only refetch state when the
  // table actually changed rather than on every live CPU/memory update.
  function addColumn() {
    const versionHeader = $('table#docker_containers thead th:contains("Version")');
    if (versionHeader.length === 0) {
      return 0;
    }
    const versionIndex = versionHeader.index();

    // Add headers
    if ($('#npm-auto-header').length === 0) {
      versionHeader.after('<th id="npm-auto-header">Auto Proxy</th>');
    }
    if ($('#npm-auto-sub-header').length === 0) {
      $('#npm-auto-header').after('<th id="npm-auto-sub-header">Subdomain</th>');
    }

    let added = 0;
    $('table#docker_containers tbody tr').each(function() {
      const container = $(this).find('.ct-name .appname').text().trim();
      if (!container) return; // not a container row
      if ($(this).find('.npm-auto-toggle').length === 0) {
        const newCell = `
          <td class="ct-autostart">
            <input type="checkbox" class="autostart npm-auto-toggle" data-container="${container}" style="display: none;">
            <div class="npm-auto-switch-background">
              <div class="npm-auto-switch-button"></div>
            </div>
            <span class="npm-auto-switch-label off">Off</span>
            <span class="npm-auto-switch-label on" style="display: none;">On</span>
          </td>
        `;
        $(this).find('td').eq(versionIndex).after(newCell);
        added++;
      }
      if ($(this).find('.npm-auto-sub').length === 0) {
        const subCell = $('<td class="npm-auto-sub"></td>').attr('data-container', container);
        $(this).find('.npm-auto-toggle').closest('td').after(subCell);
        if (lastData) renderSubdomain(subCell, lastData);
        added++;
      }
    });
    return added;
  }

  //--- Rendering ---
  function renderToggle(checkbox, isChecked) {
    checkbox.prop('checked', isChecked);
    const switchBg = checkbox.next('.npm-auto-switch-background');
    switchBg.toggleClass('checked', isChecked);
    switchBg.siblings('.on').toggle(isChecked);
    switchBg.siblings('.off').toggle(!isChecked);
  }

  function defaultSubdomain(container) {
    return container.toLowerCase().replace(/[^a-z0-9-]/g, '');
  }

  // Mirrors the daemon: override > npm-auto.domain label > <name>.<default>.
  function desiredDomain(container, data) {
    const dd = data.default_domain;
    const override = data.state[container]?.subdomain || '';
    if (override && dd) return override + '.' + dd;
    if (data.labels[container]) return data.labels[container];
    return dd ? defaultSubdomain(container) + '.' + dd : '';
  }

  // Show the part under the default domain; anything else in full.
  function shortName(domain, data) {
    const suffix = '.' + data.default_domain;
    return data.default_domain && domain.endsWith(suffix) ? domain.slice(0, -suffix.length) : domain;
  }

  function renderSubdomain(cell, data) {
    const container = cell.data('container');
    const enabled = data.state[container]?.enabled === true;
    const override = data.state[container]?.subdomain || '';
    const managed = data.managed[container];
    const desired = desiredDomain(container, data);

    let text, title, cls;
    if (enabled && managed && managed.domain === desired) {
      text = shortName(desired, data);
      cls = 'live';
      title = `Proxied at https://${desired}`;
    } else if (enabled && desired) {
      text = shortName(desired, data);
      cls = 'pending';
      title = managed?.domain
        ? `Changing from ${managed.domain} to ${desired} - npm-auto applies it within ~15 seconds`
        : `Creating https://${desired} - npm-auto applies it within ~15 seconds`;
    } else if (override) {
      text = override;
      cls = 'idle';
      title = `Will be proxied at https://${desired} when Auto Proxy is switched on`;
    } else {
      text = '—';
      cls = 'unset';
      title = 'Not proxied';
    }
    if (override) cls += ' override';
    else if (data.labels[container] && text !== '—') title += ' (from the npm-auto.domain label)';
    title += '. Click to change.';

    const name = $('<span class="npm-auto-sub-name"></span>').addClass(cls).text(text).attr('title', title);
    cell.empty().append(name);
    if (cls.startsWith('live')) {
      cell.append(
        $('<a class="npm-auto-sub-open" target="_blank" rel="noopener"><i class="fa fa-external-link"></i></a>')
          .attr('href', 'https://' + desired)
          .attr('title', 'Open https://' + desired)
      );
    }
  }

  function renderAll(data) {
    $('.npm-auto-toggle').each(function() {
      const container = $(this).data('container');
      renderToggle($(this), data.state[container]?.enabled || false);
    });
    $('td.npm-auto-sub').each(function() {
      if ($(this).find('input').length) return; // mid-edit: leave it alone
      renderSubdomain($(this), data);
    });
  }

  //--- Data ---
  function updateToggles() {
    $.ajax({
      url: ENDPOINT,
      data: { action: 'getState', v: Date.now() },
      dataType: 'json',
      success: function(data) {
        if (!data.ok) {
          console.error('npm-auto getState error:', data.error);
          return;
        }
        data.managed = data.managed || {};
        data.labels = data.labels || {};
        data.default_domain = data.default_domain || '';
        lastData = data;
        renderAll(data);
      },
      error: function(jqXHR, textStatus, errorThrown) {
        console.error('npm-auto getState AJAX error:', textStatus, errorThrown, jqXHR.responseText);
      }
    });
  }

  // The daemon reconciles every 15 seconds; look again once it has had a
  // pass or two, so "pending" settles into "live" without a page reload.
  function refreshSoon() {
    refreshTimers.forEach(clearTimeout);
    updateToggles();
    refreshTimers = [17000, 35000].map(ms => setTimeout(updateToggles, ms));
  }

  function showError(text) {
    if (typeof swal === 'function') {
      swal({ title: 'npm-auto', text: text, type: 'error' });
    } else {
      alert('npm-auto: ' + text);
    }
  }

  function post(payload) {
    // Unraid defines a global csrf_token on every webGui page.
    if (typeof csrf_token !== 'undefined') payload.csrf_token = csrf_token;
    return $.post(ENDPOINT, payload, null, 'json');
  }

  //--- Main logic ---
  const observer = new MutationObserver(function(mutations) {
    if (!mutations.some(m => m.addedNodes.length)) return;
    observer.disconnect();
    if (addColumn() > 0) updateToggles();
    observer.observe(dockerTable.get(0), {
      childList: true,
      subtree: true
    });
  });

  const interval = setInterval(function() {
    dockerTable = $('table#docker_containers');
    if (dockerTable.length) {
      clearInterval(interval);
      addColumn();
      updateToggles();
      observer.observe(dockerTable.get(0), {
        childList: true,
        subtree: true
      });
    }
  }, 100);

  //--- Auto Proxy toggle ---
  $(document).on('click', '.npm-auto-toggle + .npm-auto-switch-background', function() {
    const checkbox = $(this).prev('.npm-auto-toggle');
    const container = checkbox.data('container');
    const enabled = !checkbox.prop('checked');

    renderToggle(checkbox, enabled);

    post({ action: 'setToggle', container, enabled })
      .done(function(data) {
        if (!data.ok) {
          console.error('npm-auto setToggle error:', data.error);
          renderToggle(checkbox, !enabled); // roll back on failure
          showError(data.error);
          return;
        }
        refreshSoon();
      })
      .fail(function(jqXHR, textStatus, errorThrown) {
        console.error('npm-auto setToggle AJAX error:', textStatus, errorThrown, jqXHR.responseText);
        renderToggle(checkbox, !enabled); // roll back on failure
      });
  });

  //--- Subdomain editing ---
  $(document).on('click', 'td.npm-auto-sub .npm-auto-sub-name', function() {
    if (!lastData) return;
    const cell = $(this).closest('td');
    const container = cell.data('container');
    const current = lastData.state[container]?.subdomain
      || shortName(desiredDomain(container, lastData), lastData);

    if (!lastData.default_domain) {
      showError('Set a default domain in Settings → npm-auto first.');
      return;
    }

    const input = $('<input type="text" class="npm-auto-sub-input" spellcheck="false" autocomplete="off">')
      .val(current)
      .attr('placeholder', defaultSubdomain(container))
      .attr('title', 'Enter to save, Esc to cancel. Clear it to go back to the default name.');
    const suffix = $('<span class="npm-auto-sub-suffix"></span>').text('.' + lastData.default_domain);
    cell.empty().append(input, suffix);
    input.trigger('focus').trigger('select');

    let done = false;
    function finish(save) {
      if (done) return;
      done = true;
      const value = input.val().trim().toLowerCase();
      if (!save || value === current) {
        renderSubdomain(cell, lastData);
        return;
      }
      input.prop('disabled', true);
      post({ action: 'setSubdomain', container, subdomain: value })
        .done(function(data) {
          if (!data.ok) {
            renderSubdomain(cell, lastData);
            showError(data.error);
            return;
          }
          lastData.state = data.state;
          renderSubdomain(cell, lastData);
          refreshSoon();
        })
        .fail(function(jqXHR, textStatus, errorThrown) {
          console.error('npm-auto setSubdomain AJAX error:', textStatus, errorThrown, jqXHR.responseText);
          renderSubdomain(cell, lastData);
          showError('Could not save the subdomain.');
        });
    }

    input.on('keydown', function(e) {
      if (e.key === 'Enter') { e.preventDefault(); finish(true); }
      else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
    });
    input.on('blur', function() { finish(true); });
  });
})();
