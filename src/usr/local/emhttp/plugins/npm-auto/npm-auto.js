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
      $('table.docker-containers thead tr').append('<th id="npm-auto-header">Auto Proxy</th>');
    }

    // Add toggle switches
    $('table.docker-containers tbody tr').each(function() {
      if ($(this).find('.npm-auto-toggle').length === 0) {
        const container = $(this).find('td:first-child a').text();
        $(this).append('<td><input type="checkbox" class="npm-auto-toggle" data-container="' + container + '"></td>');
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
  // Patch listview to add the column after the table is loaded
  const original_listview = window.listview;
  window.listview = function() {
    original_listview.apply(this, arguments);
    addColumn();
    updateToggles();
  };

  // Patch loadlist to add the column after the table is reloaded
  const original_loadlist = window.loadlist;
  window.loadlist = function() {
    original_loadlist.apply(this, arguments);
    addColumn();
    updateToggles();
  };

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
