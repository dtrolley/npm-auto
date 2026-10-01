# Changelog

Released versions and their notes live in the `<CHANGES>` section of
[`npm-auto.plg`](npm-auto.plg); that is what Unraid shows on update. This file
tracks changes on `main` that have not been packaged into a release yet.

## Unreleased

Plugin (takes effect once a new package is built with `./pkg_build.sh`):

- Settings page no longer sends the saved NPM password to the browser; a blank
  password field keeps the saved one
- "Enable Label Overrides" defaults to on, matching the daemon (a fresh
  install's first Apply used to turn it off silently)
- Daemon skips NPM login with a clear log line until credentials are set,
  handles passwords containing quotes/backslashes, and keeps the password off
  the command line
- Daemon refuses domains that are not plain hostnames instead of sending them
  to NPM

Repository:

- `pkg_build.sh` works with GNU tar (CI had been failing), normalises file
  modes, verifies package contents, zero-pads same-day build numbers so
  Unraid's string comparison orders them correctly, and has a `--check` mode
- CI lints shell and PHP, checks the `.plg`'s package and MD5, and runs a
  check build
- README rewritten for testers; `.plg` CHANGES headings now match real
  version numbers
- Removed committed `.DS_Store` files, stale `tmp/` build dirs and the
  unused `copy_to_git.sh`
