# npm-auto

**Automatic Nginx Proxy Manager proxy hosts for Unraid Docker containers**

![Unraid](https://img.shields.io/badge/Unraid-Plugin-ff6600?logo=unraid&logoColor=white)
![License](https://img.shields.io/github/license/dtrolley/npm-auto)
![Build](https://img.shields.io/github/actions/workflow/status/dtrolley/npm-auto/release.yml?label=Build)

> **Status: testing.** npm-auto works day to day on its author's server, but it has
> not been tested widely. It writes to your Nginx Proxy Manager. Back up NPM's
> data directory before you try it.

## What it does

npm-auto adds two columns to the Unraid **Docker** tab:

- **Auto Proxy**: a switch for each container. Switch it on and npm-auto
  creates a proxy host in Nginx Proxy Manager (NPM) for that container. Switch
  it off and npm-auto keeps, disables or deletes that entry, depending on your
  settings.
- **Subdomain**: the hostname the container is served at, or will be. Click
  it to pick a different subdomain. You don't need to recreate the container.
  NPM entries you made by hand also show here, greyed out, matched to their
  container by name, forward host or published port. npm-auto never changes
  those entries.

A background daemon checks every 15 seconds and makes NPM match the switches.
It talks to NPM's REST API at `/api/tokens`, `/api/nginx/proxy-hosts` and
`/api/nginx/certificates`.

For each container that is switched on, npm-auto sets up the proxy host like
this:

| Field | Value |
|---|---|
| Domain | override from the Subdomain column → `npm-auto.domain` label → `<container-name>.<default domain>` (lowercased, characters outside `a-z0-9-` dropped) |
| Forward | `http://<Unraid LAN IP>:<host port>` |
| Host port | `npm-auto.port` label → the port in the container's Unraid **WebUI** setting → the lowest published host port |
| SSL | if **Auto-attach** is on: the NPM certificate covering the domain (exact or single-level wildcard, not expired) with the latest expiry, and Force SSL turned on. If none matches, the entry is created without SSL. npm-auto never requests certificates. |
| Other | Block common exploits and WebSocket support on; caching, HTTP/2 and HSTS off |

Once npm-auto manages an entry, it keeps the domain, forward host, port and
certificate in line with the table above. If you change one of those in NPM,
npm-auto changes it back. If Unraid's LAN IP changes, every managed entry is
updated.

**Existing entries.** If NPM already has an entry with the same domain and the
same forward target, npm-auto adopts it and manages it from then on. If an
entry has the same domain *or* the same target but differs in the other, that's
a conflict. The switch refuses to turn on and tells you which entry is in the
way. Entries npm-auto created carry an `npm_auto` marker in their NPM `meta`
field. That lets npm-auto pick them up again after a container rename or a
plugin reinstall.

## Requirements

- **Unraid 7.0.0 or later.** The `.plg` enforces this with `min="7.0.0"`.
- **Nginx Proxy Manager v2** on a host that Unraid can reach over HTTP. It can
  run on the Unraid server itself, which is the usual setup.
- NPM must be able to reach `<Unraid LAN IP>:<port>` for each proxied
  container. In practice the container needs a **published host port**.
  Containers on `br0`/macvlan with their own IP and no published port are not
  supported. npm-auto skips them and logs "No published port".
- `curl` and `jq`, from the base Unraid OS.
- An NPM login (email and password).

## Install

Go to **Plugins → Install Plugin** in the Unraid webGUI and paste this URL:

```
https://raw.githubusercontent.com/dTrolley/npm-auto/main/npm-auto.plg
```

Updates come from the same URL through Unraid's normal **Check for Updates**.

## Configure

Open **Settings → User Utilities → npm-auto**. It is an ordinary Unraid
settings page (Apply/Done, inline help, settings in `npm-auto.cfg`), and it
shows the service's status at the top:

| Setting | Notes |
|---|---|
| Enable npm-auto | Starts or stops the background service. Turning it off leaves NPM untouched. |
| NPM host / admin port | Where NPM's admin interface answers. Leave the host blank for this server's own LAN IP; the port defaults to `81`. |
| NPM user / password | An NPM login. The password is never sent back to the browser: the field stays empty, and leaving it blank keeps the saved one. |
| Default domain | e.g. `example.com`. Containers become `<name>.example.com`. |
| Use container labels | Honour the `npm-auto.domain` / `npm-auto.port` labels (on by default) |
| Attach SSL certificates | See the SSL row above |
| When Auto Proxy is switched off | **Keep**: leave the entry in NPM and stop managing it. **Disable**: switch the entry off in NPM (the default; reversible). **Delete**: remove the entry from NPM. |

Below the settings, **Disable all** and **Delete all** act on every managed
entry at once (they work with the service off, too), and **View log** opens
the daemon's log.

If the service is off or cannot reach NPM, the Docker tab marks the Auto
Proxy column header with a warning sign; hover it for the reason.

About the NPM account: npm-auto reads certificates and creates, edits and
deletes proxy hosts. A dedicated NPM user works. If you limit that user's item
visibility to its own items, entries made by other users are invisible to
npm-auto: they can't be adopted, shown or checked for conflicts.

### Container labels

When Label Overrides is on, add the labels under a container's
**Extra Parameters**:

```
-l npm-auto.domain=media.example.com   # full hostname, any domain
-l npm-auto.port=8181                  # host port NPM forwards to
```

A subdomain set from the Docker tab takes priority over `npm-auto.domain`.

## Files and logs

| Path | What |
|---|---|
| `/boot/config/plugins/npm-auto/npm-auto.cfg` | Settings, **including the NPM password in plain text**. Before 2026.10 this was `var/settings.json`; upgrading converts it once and keeps the old file as `settings.json.migrated`. |
| `/boot/config/plugins/npm-auto/var/state.json` | Auto Proxy switches and subdomain overrides |
| `/boot/config/plugins/npm-auto/var/managed.json` | NPM entries the daemon manages |
| `/var/log/npm-auto.log` | Daemon log. A repeated line is written at most once an hour, and the file is trimmed past 5 MB. |

The daemon starts with the array (when enabled), stops with it, and restarts
on Apply and on plugin upgrade. To control it by hand:
`/usr/local/emhttp/plugins/npm-auto/scripts/rc.npm-auto {start|stop|restart|status}`

### For other tools

`/plugins/npm-auto/webGui/settings.php` is a small JSON API on the webGUI
(session cookie and, for POSTs, the webGUI `csrf_token` required).
[unraid-mobile](https://github.com/dtrolley/unraid-mobile) uses it to show
and drive the same switches from a phone:

| Request | Does |
|---|---|
| `GET ?action=getState` | Switches, overrides, managed and hand-made entries, labels, default domain; since 2026.10 also `service`, `running`, `health` (the daemon's last pass) and `version` |
| `POST action=setToggle&container=…&enabled=true\|false` | The Auto Proxy switch |
| `POST action=setSubdomain&container=…&subdomain=…` | Set an override; empty clears it |
| `POST action=cleanup&mode=disable\|delete` | Every managed entry |

Every answer is `{"ok": true, …}` or `{"ok": false, "error": "…"}`.

## Uninstall

Remove the plugin under **Plugins**. Uninstalling stops the daemon and deletes
`/boot/config/plugins/npm-auto`, which holds your settings, switches and
overrides. **It never touches NPM.** If you want the managed entries gone, use
**Disable all / Delete all** on the settings page *before*
uninstalling.

## Known limitations

- The NPM password is stored in plain text on the flash drive
  (`npm-auto.cfg`), as Unraid stores its own passwords. It cannot contain a
  double quote. Anyone who can read the flash can read it, including
  through the `flash` SMB share if you export it. Use a dedicated NPM account.
- The connection to NPM is plain `http://`. Forward targets are always `http`.
- One domain name per container.
- The daemon polls every 15 seconds. Changes are not instant, and Docker events
  don't trigger anything.
- An entry is only *created* for a running container. Stopping a container does
  not remove its entry. Switching it off, or deleting the container, does.
- Renaming a container counts as deleting the old one: the toggle-off action
  applies to the old entry, and the new name starts with Auto Proxy off.
- Tested only on the author's setup: Unraid 7.x and a single NPM instance on the
  same server.

## Reporting issues

Open an issue at <https://github.com/dTrolley/npm-auto/issues> and include:

- the plugin version (on the **Plugins** page) and your Unraid and NPM versions
- the relevant part of `/var/log/npm-auto.log`
- what you expected to happen and what happened instead

The log contains your domain names and internal IPs. Redact them if you need
to. It never contains your NPM password.

## Building from source

Releases are served straight from `main`. `npm-auto.plg` names a version and
an MD5, and Unraid downloads `archive/npm-auto-<version>.txz` from
`raw.githubusercontent.com`. There are no GitHub Releases. To cut a version:

```bash
./pkg_build.sh            # builds archive/npm-auto-<YYYY.MM.DD[-NN]>.txz and updates the .plg
# add a <CHANGES> entry for the new version in npm-auto.plg, then:
git add npm-auto.plg archive/ && git commit
```

`./pkg_build.sh --check` builds into a temporary directory and verifies the
package without touching `archive/` or the `.plg`. CI runs it on every push,
along with `shellcheck` and `php -l`. The build runs from a clean checkout on
macOS or Linux and needs bash, tar, xz and md5sum.

**Never delete or rename the `archive/` package that `npm-auto.plg` on `main`
currently names.** Installed servers download it from that exact path.

## License

See [LICENSE](LICENSE).
