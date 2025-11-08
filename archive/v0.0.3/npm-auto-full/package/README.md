npm-auto Unraid plugin - full package
This package contains:
- npm-auto.plg installer (simple .plg shell script)
- package/: files to be installed under /usr/local/emhttp/plugins/npm-auto
- webGui/: settings UI and front-end integration
- scripts/: daemon and service wrapper
- var/: settings and state files

After installing run:
  /usr/local/emhttp/plugins/npm-auto/scripts/npm-auto-service.sh start
Then open Unraid web UI and navigate to Plugins -> npm-auto settings (or open /plugins/npm-auto/settings_ui.php)
