<?php
//==============================================================================
// settings.php
//
// AJAX backend for the npm-auto Docker-tab toggles.
// Actions: getState, setToggle
//==============================================================================

$BASE           = "/boot/config/plugins/npm-auto";
$STATE_FILE     = "{$BASE}/var/state.json";
$CLEANUP_FILE   = "{$BASE}/var/cleanup_request.json";
$SETTINGS_FILE  = "{$BASE}/var/settings.json";
$MANAGED_FILE   = "{$BASE}/var/managed.json";
$HOSTS_SNAPSHOT = "/var/run/npm-auto-hosts.json";  // published by the daemon

function read_state() {
    global $STATE_FILE;
    if (!file_exists($STATE_FILE)) return [];
    $state = json_decode(file_get_contents($STATE_FILE), true);
    return (json_last_error() === JSON_ERROR_NONE && is_array($state)) ? $state : [];
}

function get_state() {
    echo json_encode(['ok' => true, 'state' => read_state()]);
}

function docker_fmt($container, $fmt) {
    $out = shell_exec("docker inspect --format " . escapeshellarg($fmt) . " "
        . escapeshellarg($container) . " 2>/dev/null");
    return trim($out ?? '');
}

function read_json_file($path) {
    if (!file_exists($path)) return null;
    $decoded = json_decode(file_get_contents($path), true);
    return is_array($decoded) ? $decoded : null;
}

// Mirror of the daemon's domain/port derivation. Returns [domain, port, error].
function compute_target($container) {
    global $SETTINGS_FILE;
    $settings  = read_json_file($SETTINGS_FILE) ?? [];
    $labels_on = ($settings['LABEL_OVERRIDES'] ?? true) === true;

    $domain = '';
    if ($labels_on) {
        $d = docker_fmt($container, '{{ index .Config.Labels "npm-auto.domain" }}');
        if ($d !== '' && $d !== '<no value>') $domain = $d;
    }
    if ($domain === '') {
        $dd = trim($settings['DEFAULT_DOMAIN'] ?? '');
        if ($dd === '') return [null, null, 'No default domain configured in npm-auto settings.'];
        $sub = preg_replace('/[^a-z0-9-]/', '', strtolower($container));
        $domain = "$sub.$dd";
    }

    $port = null;
    if ($labels_on) {
        $p = docker_fmt($container, '{{ index .Config.Labels "npm-auto.port" }}');
        if ($p !== '' && $p !== '<no value>' && ctype_digit($p)) $port = (int)$p;
    }
    $ports = json_decode(docker_fmt($container, '{{json .NetworkSettings.Ports}}'), true) ?: [];
    if ($port === null) {
        $webui = docker_fmt($container, '{{ index .Config.Labels "net.unraid.docker.webui" }}');
        if (preg_match('/\[PORT:(\d+)\]/', $webui, $m)) {
            foreach ($ports as $key => $binds) {
                if (is_array($binds) && strpos($key, $m[1] . '/') === 0 && isset($binds[0]['HostPort'])) {
                    $port = (int)$binds[0]['HostPort'];
                    break;
                }
            }
        }
    }
    if ($port === null) {
        $host_ports = [];
        foreach ($ports as $binds) {
            if (!is_array($binds)) continue;
            foreach ($binds as $b) if (isset($b['HostPort'])) $host_ports[] = (int)$b['HostPort'];
        }
        if ($host_ports) $port = min($host_ports);
    }
    if ($port === null) return [null, null, "No published port found for $container (is it running?)."];

    return [$domain, $port, null];
}

// Returns an error string if enabling this container would collide with a
// pre-existing NPM entry, null if it is safe (or checkable data is missing).
function find_conflict($container) {
    global $HOSTS_SNAPSHOT, $MANAGED_FILE;

    list($domain, $port, $err) = compute_target($container);
    if ($err !== null) return $err;

    $hosts = read_json_file($HOSTS_SNAPSHOT);
    if ($hosts === null) return null; // daemon hasn't published yet; it re-checks anyway

    $fh = '';
    if (preg_match('/src (\S+)/', shell_exec("ip route get 1 2>/dev/null") ?? '', $m)) $fh = $m[1];
    if ($fh === '') return null;

    // Map NPM entry id -> owning container. Only THIS container's own entry
    // is exempt from conflicts (re-toggling); entries managed for another
    // container are hard conflicts even on an exact match.
    $claimed_by = [];
    foreach ((read_json_file($MANAGED_FILE) ?? []) as $owner => $entry) {
        if (isset($entry['id'])) $claimed_by[(int)$entry['id']] = $owner;
    }
    $own_id = array_search($container, $claimed_by, true);
    if ($own_id === false) $own_id = null;

    $domain_match = null;
    $target_match = null;
    foreach ($hosts as $h) {
        $hid = (int)($h['id'] ?? 0);
        if ($hid === $own_id) continue;
        $names = $h['domain_names'] ?? [];
        if ($domain_match === null && in_array($domain, $names)) $domain_match = $h;
        if ($target_match === null && ($h['forward_host'] ?? '') === $fh
            && (int)($h['forward_port'] ?? 0) === $port) $target_match = $h;
    }

    if ($domain_match !== null) {
        $mid = (int)$domain_match['id'];
        if (isset($claimed_by[$mid])) {
            return "Conflict: NPM entry #$mid ($domain) is already managed for container '{$claimed_by[$mid]}'.";
        }
        $t = ($domain_match['forward_host'] ?? '?') . ':' . ($domain_match['forward_port'] ?? '?');
        if ($t === "$fh:$port") return null; // exact match, unclaimed: adoptable
        if (($domain_match['meta']['npm_auto'] ?? false) === true) return null; // stamped: auto-adoptable
        return "Domain conflict: $domain is already proxied to $t by NPM entry #{$domain_match['id']}.";
    }
    if ($target_match !== null) {
        $mid = (int)$target_match['id'];
        $d = ($target_match['domain_names'][0] ?? '?');
        if (isset($claimed_by[$mid])) {
            return "Conflict: target $fh:$port is already managed for container '{$claimed_by[$mid]}' (NPM entry #$mid, $d).";
        }
        if (($target_match['meta']['npm_auto'] ?? false) === true) return null; // stamped: auto-adoptable
        return "Target conflict: $fh:$port is already proxied by $d (NPM entry #{$target_match['id']}).";
    }
    return null;
}

function set_toggle($data) {
    global $STATE_FILE;
    $container = trim($data['container'] ?? '');
    if ($container === '') {
        echo json_encode(['ok' => false, 'error' => 'Missing container name.']);
        return;
    }
    $enabled = ($data['enabled'] ?? '') === 'true';

    if ($enabled) {
        $conflict = find_conflict($container);
        if ($conflict !== null) {
            echo json_encode(['ok' => false, 'error' => $conflict]);
            return;
        }
    }

    $dir = dirname($STATE_FILE);
    if (!is_dir($dir) && !mkdir($dir, 0755, true)) {
        echo json_encode(['ok' => false, 'error' => 'Cannot create state directory.']);
        return;
    }

    $state = read_state();

    // Skip no-op writes: state.json lives on the flash device
    if (($state[$container]['enabled'] ?? null) === $enabled) {
        echo json_encode(['ok' => true, 'state' => $state]);
        return;
    }
    $state[$container]['enabled'] = $enabled;

    if (file_put_contents($STATE_FILE, json_encode($state, JSON_PRETTY_PRINT)) !== false) {
        echo json_encode(['ok' => true, 'state' => $state]);
    } else {
        echo json_encode(['ok' => false, 'error' => 'Failed to write state file.']);
    }
}

function request_cleanup($data) {
    global $CLEANUP_FILE;
    $mode = $data['mode'] ?? '';
    if (!in_array($mode, ['disable', 'delete'])) {
        echo json_encode(['ok' => false, 'error' => 'Invalid cleanup mode.']);
        return;
    }
    $dir = dirname($CLEANUP_FILE);
    if (!is_dir($dir) && !mkdir($dir, 0755, true)) {
        echo json_encode(['ok' => false, 'error' => 'Cannot create var directory.']);
        return;
    }
    if (file_put_contents($CLEANUP_FILE, json_encode(['action' => $mode])) !== false) {
        echo json_encode(['ok' => true]);
    } else {
        echo json_encode(['ok' => false, 'error' => 'Failed to write cleanup request.']);
    }
}

//--- Main ---
header('Content-Type: application/json');

switch ($_REQUEST['action'] ?? '') {
    case 'getState':
        get_state();
        break;
    case 'setToggle':
        set_toggle($_POST);
        break;
    case 'cleanup':
        request_cleanup($_POST);
        break;
    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}
