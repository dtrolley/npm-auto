<div id="npm-auto-settings">
  <h2>npm-auto Settings</h2>

  <form id="npm-auto-settings-form">
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

    <button type="submit">Save Settings</button>
  </form>
</div>

<script src="/plugins/npm-auto/npm-auto.js"></script>
<script>
  $(document).ready(function() {
    // Load settings
    $.get('/plugins/npm-auto/settings.php?action=getSettings', function(data) {
      if (data.ok) {
        for (const [key, value] of Object.entries(data.settings)) {
          const input = $(`#${key}`);
          if (input.is(':checkbox')) {
            input.prop('checked', value === 'true');
          } else {
            input.val(value);
          }
        }
      }
    });

    // Save settings
    $('#npm-auto-settings-form').submit(function(e) {
      e.preventDefault();
      const formData = $(this).serializeArray().reduce((obj, item) => {
        const input = $(`#${item.name}`);
        if (input.is(':checkbox')) {
          obj[item.name] = input.is(':checked');
        } else {
          obj[item.name] = item.value;
        }
        return obj;
      }, {});

      $.post({
        url: '/plugins/npm-auto/settings.php?action=saveSettings',
        data: JSON.stringify(formData),
        contentType: 'application/json',
        success: function(data) {
          if (data.ok) {
            alert('Settings saved successfully!');
          } else {
            alert('Error saving settings: ' + data.error);
          }
        }
      });
    });
  });
</script>
