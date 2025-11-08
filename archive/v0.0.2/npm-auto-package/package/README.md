npm-auto Unraid plugin package
==============================

This package contains the npm-auto Unraid plugin that automates adding/removing
proxy-host entries in Nginx Proxy Manager (NPM) for Docker containers.

Quick install (on Unraid):
1. Upload the zip and extract to a temporary location on Unraid, or copy the 'package' folder to /usr/local/emhttp/plugins/npm-auto
2. Make installer executable and run it, or run the included install.sh
   sudo bash install.sh
3. The installer will append a start command to /boot/config/go so the service starts on boot.
4. Configure settings via the GUI Settings page (Plugins -> npm-auto) or edit /boot/config/plugins/npm-auto/var/settings.cfg

Security:
- This package requires a local secret token for the web UI and toggle operations.
  Set NPM_AUTO_ADMIN_TOKEN in settings (the settings page will generate one on first save).
- The plugin will only accept requests bearing this token via the X-NPM-AUTO-Auth header.

Files:
- webGui/: files served by Unraid to add the Docker toggles and the Settings UI.
- scripts/: daemon and service wrapper scripts.
- var/: persistent state and configuration.

