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

    <input id="btnApply" type="submit" name="#apply" value="Apply">
<input type="button" value="Done" onClick="done()">
  </form>
</div>

<script src="/plugins/npm-auto/npm-auto.js"></script>

