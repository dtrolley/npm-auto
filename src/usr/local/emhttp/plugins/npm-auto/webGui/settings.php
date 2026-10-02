<?php
//==============================================================================
// settings.php
//
// AJAX backend for the npm-auto Docker-tab columns, and for unraid-mobile,
// which reads and drives the same actions:
//   GET  getState                          everything the columns show
//   POST setToggle    container, enabled   the Auto Proxy switch
//   POST setSubdomain container, subdomain an override; empty clears it
//   POST cleanup      mode                 disable|delete every managed host
// Every answer is JSON with ok: true, or ok: false and an error to show.
//==============================================================================

require_once '/usr/local/emhttp/plugins/npm-auto/include/common.php';

$MANAGED_FILE   = NPM_AUTO_MANAGED;
$HOSTS_SNAPSHOT = NPM_AUTO_HOSTS;

function read_state() {
    return npm_auto_read_json(NPM_AUTO_STATE) ?? [];
}

// Read-modify-write of state.json under a lock, so a toggle from the Docker
// tab and one from unraid-mobile cannot drop each other's change.
// $fn receives the state and returns [new state or null for no write, reply].
function with_state($fn) {
    $lock = fopen('/var/run/npm-auto-state.lock', 'c');
    flock($lock, LOCK_EX);
    [$state, $reply] = $fn(read_state());
    if ($state !== null && !npm_auto_write_json(NPM_AUTO_STATE, (object)$state)) {
        $reply = ['ok' => false, 'error' => 'Failed to write the state file.'];
    }
    flock($lock, LOCK_UN);
    fclose($lock);
    echo json_encode($reply);
}

function lan_ip() {
    return npm_auto_lan_ip();
}

// Docker's own name grammar, and the container has to exist.
function valid_container($container) {
    if (!preg_match('/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/', $container)) return false;
    return docker_fmt($container, '{{.Name}}') !== '';
}

// NPM entries npm-auto does not manage, matched to the container they serve so
// the Docker tab shows every proxied container, not only the automated ones.
// Best evidence first: the entry carries the container's default name, then it
// forwards to the container by name, then to one of its published ports.
function match_unmanaged($containers, $managed, $dd) {
    global $HOSTS_SNAPSHOT;
    $hosts = read_json_file($HOSTS_SNAPSHOT) ?? [];
    $fh = lan_ip();
    $claimed = [];
    foreach ($managed as $e) if (isset($e['id'])) $claimed[(int)$e['id']] = true;

    $score = function ($name, $ports, $h) use ($dd, $fh) {
        $want  = $dd === '' ? '' : default_subdomain($name) . ".$dd";
        $names = array_map('strtolower', $h['domain_names'] ?? []);
        $fhost = strtolower($h['forward_host'] ?? '');
        if ($want !== '' && in_array($want, $names, true)) return 3;
        if ($fhost === strtolower($name)) return 2;
        if ($fh !== '' && $fhost === $fh && in_array((int)($h['forward_port'] ?? 0), $ports, true)) return 1;
        return 0;
    };

    // An entry named for, or forwarding to, one container is not also
    // another's just because they share a port (e.g. a replacement container).
    $strong = [];
    foreach ($containers as $name => $ports) {
        foreach ($hosts as $h) {
            if ($score($name, $ports, $h) >= 2) $strong[(int)($h['id'] ?? 0)] = $name;
        }
    }

    $out = [];
    foreach ($containers as $name => $ports) {
        if (isset($managed[$name])) continue;
        $matches = [];
        foreach ($hosts as $h) {
            $id = (int)($h['id'] ?? 0);
            if (isset($claimed[$id])) continue;
            $sc = $score($name, $ports, $h);
            if ($sc === 0) continue;
            if ($sc === 1 && isset($strong[$id]) && $strong[$id] !== $name) continue;
            $matches[] = [$sc, $id, $h];
        }
        if (!$matches) continue;
        usort($matches, fn($a, $b) => [$b[0], $a[1]] <=> [$a[0], $b[1]]);
        $best = $matches[0][2];
        $out[$name] = [
            'id'      => (int)$best['id'],
            'domain'  => strtolower($best['domain_names'][0] ?? ''),
            'enabled' => !in_array($best['enabled'] ?? true, [false, 0, '0'], true),
            'also'    => array_values(array_map(fn($m) => strtolower($m[2]['domain_names'][0] ?? ''), array_slice($matches, 1))),
        ];
    }
    return $out;
}

// Everything the Docker tab needs in one request: the toggles' desired state,
// the entries the daemon manages (the domain in use), hand-made NPM entries
// for the rest, and enough to predict the domain of a container not yet proxied.
function get_state() {
    global $MANAGED_FILE;
    $cfg       = npm_auto_cfg();
    $labels_on = npm_auto_yes($cfg, 'LABEL_OVERRIDES');
    $dd        = npm_auto_default_domain($cfg);

    $managed_raw = read_json_file($MANAGED_FILE) ?? [];
    $managed = [];
    foreach ($managed_raw as $c => $e) {
        $managed[$c] = ['domain' => $e['domain'] ?? null, 'disabled' => (bool)($e['disabled'] ?? false)];
    }

    // Labels and host ports for every container, in one docker call rather
    // than one per row. Configured bindings, not live ones, so a stopped
    // container still shows the entry that serves it.
    $fmt = '{{.Name}}|{{index .Config.Labels "npm-auto.domain"}}|{{json .HostConfig.PortBindings}}';
    $out = shell_exec('docker ps -aq | xargs -r docker inspect --format ' . escapeshellarg($fmt) . ' 2>/dev/null') ?? '';
    $labels = [];
    $containers = [];
    foreach (explode("\n", trim($out)) as $line) {
        $parts = explode('|', $line, 3);
        if (count($parts) !== 3) continue;
        $name = ltrim($parts[0], '/');
        $d = trim($parts[1]);
        if ($labels_on && $d !== '' && $d !== '<no value>') $labels[$name] = $d;
        $ports = [];
        foreach ((json_decode($parts[2], true) ?: []) as $binds) {
            if (!is_array($binds)) continue;
            foreach ($binds as $b) if (($b['HostPort'] ?? '') !== '') $ports[] = (int)$b['HostPort'];
        }
        $containers[$name] = array_values(array_unique($ports));
    }

    echo json_encode([
        'ok'             => true,
        'state'          => read_state(),
        'managed'        => (object)$managed,
        'unmanaged'      => (object)match_unmanaged($containers, $managed_raw, $dd),
        'labels'         => (object)$labels,
        'default_domain' => $dd,
        // Added 2026.10: whether anything will act on the switches, and how
        // the last pass against NPM went.
        'service'        => ($cfg['SERVICE'] ?? '') === 'enable',
        'running'        => npm_auto_running(),
        'health'         => npm_auto_status(),
        'version'        => npm_auto_version(),
    ]);
}

function docker_fmt($container, $fmt) {
    $out = shell_exec("docker inspect --format " . escapeshellarg($fmt) . " "
        . escapeshellarg($container) . " 2>/dev/null");
    return trim($out ?? '');
}

function read_json_file($path) {
    return npm_auto_read_json($path);
}

// What the daemon names a container when nothing overrides it.
function default_subdomain($container) {
    return preg_replace('/[^a-z0-9-]/', '', strtolower($container));
}

// One or more lowercase DNS labels.
function valid_subdomain($sub) {
    $label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
    return strlen($sub) <= 190 && preg_match("/^$label(?:\\.$label)*\$/", $sub) === 1;
}

// Mirror of the daemon's domain/port derivation. Returns [domain, port, error].
// $sub is a candidate subdomain override; null means "whatever state.json holds".
function compute_target($container, $sub = null) {
    $cfg       = npm_auto_cfg();
    $labels_on = npm_auto_yes($cfg, 'LABEL_OVERRIDES');
    $dd        = npm_auto_default_domain($cfg);

    if ($sub === null) $sub = read_state()[$container]['subdomain'] ?? '';

    $domain = '';
    if ($sub !== '') {
        if ($dd === '') return [null, null, 'No default domain configured in npm-auto settings.'];
        $domain = "$sub.$dd";
    }
    if ($domain === '' && $labels_on) {
        $d = docker_fmt($container, '{{ index .Config.Labels "npm-auto.domain" }}');
        if ($d !== '' && $d !== '<no value>') $domain = $d;
    }
    if ($domain === '') {
        if ($dd === '') return [null, null, 'No default domain configured in npm-auto settings.'];
        $domain = default_subdomain($container) . ".$dd";
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
function find_conflict($container, $sub = null) {
    global $HOSTS_SNAPSHOT, $MANAGED_FILE;

    list($domain, $port, $err) = compute_target($container, $sub);
    if ($err !== null) return $err;

    $hosts = read_json_file($HOSTS_SNAPSHOT);
    if ($hosts === null) return null; // daemon hasn't published yet; it re-checks anyway

    $fh = lan_ip();
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
    $container = trim($data['container'] ?? '');
    if (!valid_container($container)) {
        echo json_encode(['ok' => false, 'error' => 'No such container.']);
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

    with_state(function ($state) use ($container, $enabled) {
        // Skip no-op writes: state.json lives on the flash device
        if (($state[$container]['enabled'] ?? false) === $enabled) {
            return [null, ['ok' => true, 'state' => $state]];
        }
        $state[$container]['enabled'] = $enabled;
        return [$state, ['ok' => true, 'state' => $state]];
    });
}

// Set or clear a container's subdomain override. An empty value, or one equal
// to the name the container would get anyway, clears it. The daemon renames a
// live NPM entry on its next pass.
function set_subdomain($data) {
    global $MANAGED_FILE;
    $container = trim($data['container'] ?? '');
    if (!valid_container($container)) {
        echo json_encode(['ok' => false, 'error' => 'No such container.']);
        return;
    }

    $dd = npm_auto_default_domain(npm_auto_cfg());
    if ($dd === '') {
        echo json_encode(['ok' => false, 'error' => 'Set a default domain in npm-auto settings first.']);
        return;
    }

    $sub = strtolower(trim($data['subdomain'] ?? ''));
    // Accept a pasted full name under the default domain.
    if (str_ends_with($sub, ".$dd")) $sub = substr($sub, 0, -strlen(".$dd"));
    if ($sub === default_subdomain($container)) $sub = '';
    if ($sub !== '' && !valid_subdomain($sub)) {
        echo json_encode(['ok' => false, 'error' => "\"$sub\" is not a valid subdomain: use lowercase letters, digits and hyphens."]);
        return;
    }

    $state = read_state();
    if ($sub !== '') {
        foreach ($state as $other => $s) {
            if ($other !== $container && ($s['subdomain'] ?? '') === $sub) {
                echo json_encode(['ok' => false, 'error' => "$sub.$dd is already the override for container '$other'."]);
                return;
            }
        }
    }

    if (($state[$container]['enabled'] ?? false) === true) {
        // Live: the rename must not collide with anything in NPM.
        $conflict = find_conflict($container, $sub);
        if ($conflict !== null) {
            echo json_encode(['ok' => false, 'error' => $conflict]);
            return;
        }
    } elseif ($sub !== '') {
        // Not live yet: only refuse a name another container already holds.
        // Anything subtler is checked when the switch is turned on.
        foreach ((read_json_file($MANAGED_FILE) ?? []) as $owner => $entry) {
            if ($owner !== $container && ($entry['domain'] ?? '') === "$sub.$dd") {
                echo json_encode(['ok' => false, 'error' => "$sub.$dd is already proxied for container '$owner'."]);
                return;
            }
        }
    }

    with_state(function ($state) use ($container, $sub) {
        // Skip no-op writes: state.json lives on the flash device
        if (($state[$container]['subdomain'] ?? '') === $sub) {
            return [null, ['ok' => true, 'state' => $state]];
        }
        if ($sub === '') {
            unset($state[$container]['subdomain']);
            if (empty($state[$container])) unset($state[$container]);
        } else {
            $state[$container]['subdomain'] = $sub;
        }
        return [$state, ['ok' => true, 'state' => $state]];
    });
}

function request_cleanup($data) {
    $mode = $data['mode'] ?? '';
    if (!in_array($mode, ['disable', 'delete'], true)) {
        echo json_encode(['ok' => false, 'error' => 'Invalid cleanup mode.']);
        return;
    }
    if (!npm_auto_write_json(NPM_AUTO_CLEANUP, ['action' => $mode])) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write cleanup request.']);
        return;
    }
    // The daemon picks the request up on its next pass; with the service
    // disabled there is no daemon, so run it once in the background.
    if (!npm_auto_running()) {
        exec(escapeshellarg(NPM_AUTO_RC) . ' cleanup >/dev/null 2>&1 &');
    }
    echo json_encode(['ok' => true]);
}

//--- Main ---
header('Content-Type: application/json');

$action = $_REQUEST['action'] ?? '';
$is_post = ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST';

if ($action === 'getState') {
    get_state();
} elseif (!$is_post && in_array($action, ['setToggle', 'setSubdomain', 'cleanup'], true)) {
    echo json_encode(['ok' => false, 'error' => 'Use POST.']);
} elseif ($action === 'setToggle') {
    set_toggle($_POST);
} elseif ($action === 'setSubdomain') {
    set_subdomain($_POST);
} elseif ($action === 'cleanup') {
    request_cleanup($_POST);
} else {
    echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}
