<?php
//==============================================================================
// settings.php
//
// AJAX backend for the npm-auto Docker-tab toggles.
// Actions: getState, setToggle
//==============================================================================

$BASE         = "/boot/config/plugins/npm-auto";
$STATE_FILE   = "{$BASE}/var/state.json";
$CLEANUP_FILE = "{$BASE}/var/cleanup_request.json";

function read_state() {
    global $STATE_FILE;
    if (!file_exists($STATE_FILE)) return [];
    $state = json_decode(file_get_contents($STATE_FILE), true);
    return (json_last_error() === JSON_ERROR_NONE && is_array($state)) ? $state : [];
}

function get_state() {
    echo json_encode(['ok' => true, 'state' => read_state()]);
}

function set_toggle($data) {
    global $STATE_FILE;
    $container = trim($data['container'] ?? '');
    if ($container === '') {
        echo json_encode(['ok' => false, 'error' => 'Missing container name.']);
        return;
    }
    $enabled = ($data['enabled'] ?? '') === 'true';

    $dir = dirname($STATE_FILE);
    if (!is_dir($dir) && !mkdir($dir, 0755, true)) {
        echo json_encode(['ok' => false, 'error' => 'Cannot create state directory.']);
        return;
    }

    $state = read_state();
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
