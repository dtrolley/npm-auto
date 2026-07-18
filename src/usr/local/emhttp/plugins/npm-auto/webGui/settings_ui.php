<div id="npm-auto-settings">
  <h2>npm-auto Settings</h2>

  <form id="npm-auto-settings-form" method="post">
    <div class="form-group">
      <label for="npm_enabled">Enable npm-auto</label>
      <input type="checkbox" id="npm_enabled" name="npm_enabled">
    </div>

    <div class="form-group">
      <label for="npm_host">NPM Host</label>
      <input type="text" id="npm_host" name="npm_host" required>
    </div>

    <div class="form-group">
      <label for="npm_port">NPM Port</label>
      <input type="number" id="npm_port" name="npm_port" required>
    </div>

    <div class="form-group">
      <label for="npm_user">NPM User</label>
      <input type="text" id="npm_user" name="npm_user" required>
    </div>

    <div class="form-group">
      <label for="npm_pass">NPM Password</label>
      <input type="password" id="npm_pass" name="npm_pass" required>
    </div>

    <div class="form-group">
      <label for="default_domain">Default Domain</label>
      <input type="text" id="default_domain" name="default_domain" required>
    </div>

    <div class="form-group">
      <label for="label_overrides">Enable Label Overrides</label>
      <input type="checkbox" id="label_overrides" name="label_overrides">
    </div>

    <div class="form-group">
      <label for="auto_ssl">Auto-attach matching SSL certificate</label>
      <input type="checkbox" id="auto_ssl" name="auto_ssl" checked>
    </div>

    <div class="form-group">
      <label for="toggle_off_action">When a toggle is switched off</label>
      <select id="toggle_off_action" name="toggle_off_action">
        <option value="keep">Keep - leave the NPM entry as-is</option>
        <option value="disable" selected>Disable - switch the NPM entry off (reversible)</option>
        <option value="delete">Delete - remove plugin-created entries from NPM</option>
      </select>
    </div>

    <input type="hidden" id="cleanup_action" name="cleanup_action" value="">

    <input id="btnApply" type="submit" name="#apply" value="Apply">
    <input type="button" value="Done" onClick="done()">
  </form>

  <h3>Container label overrides</h3>
  <p>When Label Overrides is enabled, these Docker labels take priority over the derived values
     (add them under a container's Extra Parameters, e.g. <code>-l npm-auto.port=8181</code>):</p>
  <ul>
    <li><code>npm-auto.domain</code> &mdash; full domain for this container (e.g. <code>media.example.com</code>);
        default is <code>&lt;container-name&gt;.&lt;default-domain&gt;</code></li>
    <li><code>npm-auto.port</code> &mdash; host port NPM forwards to (e.g. <code>8181</code>);
        default is the port from the container's WebUI setting, else its lowest published port</li>
  </ul>

  <h3>Managed proxy hosts</h3>
  <p>
    Apply an action now to every proxy host the plugin currently manages
    (created and adopted entries are treated identically).
    Note: <em>uninstalling</em> the plugin never touches NPM; run a cleanup
    here first if you want one.
  </p>
  <input type="button" id="npm-auto-cleanup-disable" value="Disable all managed hosts">
  <input type="button" id="npm-auto-cleanup-delete" value="Delete all managed hosts">
  <span id="npm-auto-cleanup-status"></span>
</div>

<script>
  $(function() {
    // Prompt when the plugin is being disabled: what to do with managed hosts?
    $('#npm-auto-settings-form').on('submit', function() {
      const form = $(this);
      const wasEnabled = form.data('was-enabled') === true;
      const nowEnabled = $('#npm_enabled').prop('checked');
      $('#cleanup_action').val('');
      if (wasEnabled && !nowEnabled) {
        if (confirm('You are disabling npm-auto.\n\nDelete all plugin-created proxy hosts from NPM?\n(OK = delete them, Cancel = decide next)')) {
          $('#cleanup_action').val('delete');
        } else if (confirm('Disable the managed proxy hosts in NPM instead?\n(OK = disable them, Cancel = keep everything as-is)')) {
          $('#cleanup_action').val('disable');
        }
      }
      return true;
    });

    function requestCleanup(mode, label) {
      if (!confirm(label + '\n\nProceed?')) return;
      const payload = { action: 'cleanup', mode: mode };
      if (typeof csrf_token !== 'undefined') payload.csrf_token = csrf_token;
      $.post('/plugins/npm-auto/webGui/settings.php', payload, null, 'json')
        .done(function(data) {
          $('#npm-auto-cleanup-status').text(data.ok
            ? 'Requested - the daemon will apply it within ~15 seconds.'
            : 'Error: ' + data.error);
        })
        .fail(function() {
          $('#npm-auto-cleanup-status').text('Request failed.');
        });
    }

    $('#npm-auto-cleanup-disable').on('click', function() {
      requestCleanup('disable', 'Disable every proxy host currently managed by npm-auto.');
    });
    $('#npm-auto-cleanup-delete').on('click', function() {
      requestCleanup('delete', 'Delete every proxy host currently managed by npm-auto (created and adopted alike).');
    });
  });
</script>
