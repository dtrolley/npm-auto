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
        $(this).find('td').eq(versionIndex).after('<td><input type="checkbox" class="npm-auto-toggle" data-container="' + container + '"></td>');
      }
    });
  }

  function updateToggles() {
    $.get('/plugins/npm-auto/webGui/settings.php?action=getState', function(data) {
      if (data.ok) {
        $('.npm-auto-toggle').each(function() {
          const container = $(this).data('container');
          if (data.state[container] && data.state[container].enabled) {
            $(this).prop('checked', true);
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

  // Handle toggle clicks
  $(document).on('click', '.npm-auto-toggle', function() {
    const container = $(this).data('container');
    const enabled = $(this).is(':checked');

    $.post({
      url: '/plugins/npm-auto/webGui/settings.php?action=setToggle',
      data: JSON.stringify({ container, enabled }),
      contentType: 'application/json'
    });
  });
})();
