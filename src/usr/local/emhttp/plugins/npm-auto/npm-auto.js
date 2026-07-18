//==============================================================================
// npm-auto.js
//
// Injected into the Docker tab of the Unraid UI. Adds an "Auto Proxy" toggle
// to each container row to enable or disable npm-auto for that container.
//==============================================================================

(function() {
  let dockerTable;

  //--- Functions ---
  function addColumn() {
    const versionHeader = $('table#docker_containers thead th:contains("Version")');
    if (versionHeader.length === 0) {
      return;
    }
    const versionIndex = versionHeader.index();

    // Add header
    if ($('#npm-auto-header').length === 0) {
      versionHeader.after('<th id="npm-auto-header">Auto Proxy</th>');
    }

    // Add toggle switches
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
      }
    });
  }

  function renderToggle(checkbox, isChecked) {
    checkbox.prop('checked', isChecked);
    const switchBg = checkbox.next('.npm-auto-switch-background');
    switchBg.toggleClass('checked', isChecked);
    switchBg.siblings('.on').toggle(isChecked);
    switchBg.siblings('.off').toggle(!isChecked);
  }

  function updateToggles() {
    $.ajax({
      url: '/plugins/npm-auto/webGui/settings.php',
      data: { action: 'getState', v: Date.now() },
      dataType: 'json',
      success: function(data) {
        if (!data.ok) {
          console.error('npm-auto getState error:', data.error);
          return;
        }
        $('.npm-auto-toggle').each(function() {
          const container = $(this).data('container');
          const isChecked = data.state[container]?.enabled || false;
          renderToggle($(this), isChecked);
        });
      },
      error: function(jqXHR, textStatus, errorThrown) {
        console.error('npm-auto getState AJAX error:', textStatus, errorThrown, jqXHR.responseText);
      }
    });
  }

  //--- Main logic ---
  const observer = new MutationObserver(function(mutations) {
    mutations.forEach(function(mutation) {
      if (mutation.addedNodes.length) {
        observer.disconnect();
        addColumn();
        updateToggles();
        observer.observe(dockerTable.get(0), {
          childList: true,
          subtree: true
        });
      }
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

  $(document).on('click', '.npm-auto-toggle + .npm-auto-switch-background', function() {
    const checkbox = $(this).prev('.npm-auto-toggle');
    const container = checkbox.data('container');
    const enabled = !checkbox.prop('checked');

    renderToggle(checkbox, enabled);

    const payload = { action: 'setToggle', container, enabled };
    // Unraid defines a global csrf_token on every webGui page.
    if (typeof csrf_token !== 'undefined') payload.csrf_token = csrf_token;

    $.post('/plugins/npm-auto/webGui/settings.php', payload, null, 'json')
      .done(function(data) {
        if (!data.ok) {
          console.error('npm-auto setToggle error:', data.error);
          renderToggle(checkbox, !enabled); // roll back on failure
          if (typeof swal === 'function') {
            swal({ title: 'npm-auto', text: data.error, type: 'error' });
          } else {
            alert('npm-auto: ' + data.error);
          }
        }
      })
      .fail(function(jqXHR, textStatus, errorThrown) {
        console.error('npm-auto setToggle AJAX error:', textStatus, errorThrown, jqXHR.responseText);
        renderToggle(checkbox, !enabled); // roll back on failure
      });
  });
})();
