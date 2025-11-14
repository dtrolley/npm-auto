//==============================================================================
// npm-auto.js
//
// This script is injected into the Docker tab of the Unraid UI and adds a
// toggle switch to each container to enable or disable npm-auto.
//==============================================================================

(function() {
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
            <div class="switch-button-background" style="width:25px;height:11px">
              <div class="switch-button-button" style="width:12px;height:11px;left:-1px"></div>
            </div>
            <span class="switch-button-label off">Off</span>
            <span class="switch-button-label on" style="display: none;">On</span>
          </td>
        `;
        $(this).find('td').eq(versionIndex).after(newCell);
      }
    });
  }

  function updateToggles() {
    $.get('/plugins/npm-auto/webGui/settings.php?action=getState', function(data) {
      if (data.ok) {
        $('.npm-auto-toggle').each(function() {
          const container = $(this).data('container');
          const isChecked = data.state[container]?.enabled || false;
          $(this).prop('checked', isChecked);
          const switchBg = $(this).next('.switch-button-background');
          const switchButton = switchBg.find('.switch-button-button');
          if (isChecked) {
            switchBg.addClass('checked');
            switchButton.css('left', '12px');
            switchBg.siblings('.on').show();
            switchBg.siblings('.off').hide();
          } else {
            switchBg.removeClass('checked');
            switchButton.css('left', '-1px');
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
        addColumn();
        updateToggles();
      }
    });
  });

  const interval = setInterval(function() {
    const dockerTable = $('table#docker_containers');
    if (dockerTable.length) {
      clearInterval(interval);
      observer.observe(dockerTable.get(0), {
        childList: true,
        subtree: true
      });
      addColumn();
      updateToggles();
    }
  }, 100);

  $(document).on('click', '.npm-auto-toggle + .switch-button-background', function() {
    console.log('npm-auto: Toggle clicked');
    const checkbox = $(this).prev('.npm-auto-toggle');
    const container = checkbox.data('container');
    const enabled = !checkbox.prop('checked');
    const switchButton = $(this).find('.switch-button-button');

    checkbox.prop('checked', enabled);
    $(this).toggleClass('checked');
    switchButton.css('left', enabled ? '12px' : '-1px');
    $(this).siblings('.on').toggle(enabled);
    $(this).siblings('.off').toggle(!enabled);

    console.log('npm-auto: Sending setToggle request with:', { container, enabled });
    $.post({
      url: '/plugins/npm-auto/webGui/settings.php?action=setToggle',
      data: JSON.stringify({ container, enabled }),
      contentType: 'application/json'
    });
  });
})();
