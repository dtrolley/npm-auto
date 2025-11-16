//==============================================================================
// npm-auto.js
//
// This script is injected into the Docker tab of the Unraid UI and adds a
// toggle switch to each container to enable or disable npm-auto.
//==============================================================================

(function() {
  let dockerTable;

  //--- Functions ---#
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
      if ($(this).find('.npm-auto-toggle').length === 0) {
        const container = $(this).find('td:first-child a').text();
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

  function updateToggles() {
    $.get('/plugins/npm-auto/webGui/settings.php?action=getState', function(data) {
      console.log('updateToggles received data:', data);
      if (data.ok) {
        $('.npm-auto-toggle').each(function() {
          const container = $(this).data('container');
          const isChecked = data.state[container]?.enabled || false;
          $(this).prop('checked', isChecked);
          const switchBg = $(this).next('.npm-auto-switch-background');
          if (isChecked) {
            switchBg.addClass('checked');
            switchBg.siblings('.on').show();
            switchBg.siblings('.off').hide();
          } else {
            switchBg.removeClass('checked');
            switchBg.siblings('.on').hide();
            switchBg.siblings('.off').show();
          }
        });
      }
    });
  }

  //--- Main logic ---#
  const observer = new MutationObserver(function(mutations) {
    mutations.forEach(function(mutation) {
      if (mutation.addedNodes.length) {
        observer.disconnect();
        addColumn();
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
    const csrfToken = $('input[name="csrf_token"]').val();

    checkbox.prop('checked', enabled);
    $(this).toggleClass('checked');
    $(this).siblings('.on').toggle(enabled);
    $(this).siblings('.off').toggle(!enabled);

    $.post({
      url: '/plugins/npm-auto/webGui/settings.php?action=setToggle',
      data: { container, enabled, csrf_token: csrfToken }
    });
  });
})();
