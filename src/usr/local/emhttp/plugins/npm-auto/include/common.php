<?php
//==============================================================================
// common.php
//
// Paths and settings shared by the settings page, the Docker-tab endpoint and
// the update.php hook. The daemon reads the same files from bash.
//
// Settings follow the Unraid plugin convention: defaults in default.cfg next
// to this file, the operator's values in /boot/config/plugins/npm-auto/
// npm-auto.cfg, written by /update.php from the settings page.
//==============================================================================

const NPM_AUTO_PLUGIN   = 'npm-auto';
const NPM_AUTO_DIR      = '/usr/local/emhttp/plugins/npm-auto';
const NPM_AUTO_CFG      = '/boot/config/plugins/npm-auto/npm-auto.cfg';
const NPM_AUTO_VAR      = '/boot/config/plugins/npm-auto/var';
const NPM_AUTO_STATE    = NPM_AUTO_VAR . '/state.json';    // written by the webGui only
const NPM_AUTO_MANAGED  = NPM_AUTO_VAR . '/managed.json';  // written by the daemon only
const NPM_AUTO_CLEANUP  = NPM_AUTO_VAR . '/cleanup_request.json';
const NPM_AUTO_HOSTS    = '/var/run/npm-auto-hosts.json';  // NPM proxy hosts, published by the daemon
const NPM_AUTO_STATUS   = '/var/run/npm-auto-status.json'; // last pass, published by the daemon
const NPM_AUTO_PIDFILE  = '/var/run/npm-auto.pid';
const NPM_AUTO_RC       = NPM_AUTO_DIR . '/scripts/rc.npm-auto';

// default.cfg overlaid with the operator's npm-auto.cfg.
function npm_auto_cfg() {
    $cfg = @parse_ini_file(NPM_AUTO_DIR . '/default.cfg') ?: [];
    if (is_file(NPM_AUTO_CFG)) $cfg = array_replace($cfg, @parse_ini_file(NPM_AUTO_CFG) ?: []);
    return $cfg;
}

function npm_auto_yes($cfg, $key) {
    return ($cfg[$key] ?? '') === 'yes';
}

function npm_auto_default_domain($cfg) {
    return strtolower(trim($cfg['DEFAULT_DOMAIN'] ?? ''));
}

function npm_auto_read_json($path) {
    if (!is_file($path)) return null;
    $decoded = json_decode(file_get_contents($path), true);
    return is_array($decoded) ? $decoded : null;
}

// Write JSON via a temp file and rename, so a reader never sees half a file.
function npm_auto_write_json($path, $data) {
    $dir = dirname($path);
    if (!is_dir($dir) && !mkdir($dir, 0700, true)) return false;
    $tmp = "$path.tmp";
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT)) === false) return false;
    return rename($tmp, $path);
}

// The host's LAN IP: the forward host npm-auto writes, and the default NPM host.
function npm_auto_lan_ip() {
    return preg_match('/src (\S+)/', shell_exec('ip route get 1 2>/dev/null') ?? '', $m) ? $m[1] : '';
}

function npm_auto_running() {
    $pid = (int)@file_get_contents(NPM_AUTO_PIDFILE);
    return $pid > 0 && posix_kill($pid, 0);
}

// What the daemon reported after its last pass, or null if it has not run.
function npm_auto_status() {
    return npm_auto_read_json(NPM_AUTO_STATUS);
}

function npm_auto_version() {
    return trim(@file_get_contents('/boot/config/plugins/npm-auto/version') ?: '');
}
