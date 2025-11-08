//==============================================================================
// npm-auto.js
//
// This script is injected into the Docker tab of the Unraid UI and adds a
// toggle switch to each container to enable or disable npm-auto.
//==============================================================================

(function() {
  //--- Functions ---#
  function addColumn() {
    // Add header
    if ($('#npm-auto-header').length === 0) {
      $('#docker-containers thead tr').append('<th id="npm-auto-header">NPM Auto</th>');
    }

    // Add toggle switches
    $('#docker-containers tbody tr').each(function() {
      if ($(this).find('.npm-auto-toggle').length === 0) {
        const container = $(this).find('td:first-child a').text();
        $(this).append('<td><input type="checkbox" class="npm-auto-toggle" data-container="' + container + '"></td>');
      }
    });
  }

  function updateToggles() {
    $.get('/plugins/npm-auto/settings.php?action=getState', function(data) {
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
  $(document).ready(function() {
    // Add the column and toggles
    addColumn();
    updateToggles();

    // Handle toggle clicks
    $(document).on('click', '.npm-auto-toggle', function() {
      const container = $(this).data('container');
      const enabled = $(this).is(':checked');

      $.post({
        url: '/plugins/npm-auto/settings.php?action=setToggle',
        data: JSON.stringify({ container, enabled }),
        contentType: 'application/json'
      });
    });

    // Use a MutationObserver to detect when the Docker table is updated
    const observer = new MutationObserver(function(mutations) {
      mutations.forEach(function(mutation) {
        if (mutation.addedNodes.length) {
          addColumn();
          updateToggles();
        }
      });
    });

    observer.observe($('#docker-containers').get(0), {
      childList: true,
      subtree: true
    });
  });
})();
