<?php
//==============================================================================
// settings.php
//
// This script handles the backend logic for the npm-auto settings page.
//==============================================================================

//--- Configuration ---#
$BASE = "/boot/config/plugins/npm-auto";
$SETTINGS_FILE = "{$BASE}/var/settings.cfg";
$STATE_FILE = "{$BASE}/var/state.json";
$DEBUG_LOG_FILE = "{$BASE}/var/npm-auto-settings-debug.log";

//--- Functions ---#
function write_log($message) {
    global $DEBUG_LOG_FILE;
    $timestamp = date("Y-m-d H:i:s");
    file_put_contents($DEBUG_LOG_FILE, "[$timestamp] " . print_r($message, true) . "\n", FILE_APPEND);
}

function get_settings() {
    $default_settings = [
        'npm_enabled' => 'on',
        'npm_host' => '192.168.8.8',
        'npm_port' => '81',
        'npm_user' => 'admin@example.com',
        'npm_pass' => 'changeme',
        'default_domain' => 'example.com',
        'label_overrides' => 'off'
    ];
    write_log("get_settings called, returning default settings");
    echo json_encode(['ok' => true, 'settings' => $default_settings]);
}

function get_state() {
    global $STATE_FILE;
    write_log("get_state called");
    if (file_exists($STATE_FILE)) {
        $state = json_decode(file_get_contents($STATE_FILE), true);
        write_log("get_state: state found: " . print_r($state, true));
        echo json_encode(['ok' => true, 'state' => $state]);
    } else {
        write_log("get_state: state file not found");
        echo json_encode(['ok' => true, 'state' => []]);
    }
}

function set_toggle($data) {
    global $STATE_FILE;
    write_log("set_toggle called with data: " . print_r($data, true));
    $container = $data['container'];
    $enabled = $data['enabled'] === 'true';

    if (!file_exists(dirname($STATE_FILE))) {
        mkdir(dirname($STATE_FILE), 0755, true);
    }

    if (!is_writable(dirname($STATE_FILE))) {
        $error = "State file directory is not writable.";
        write_log("set_toggle: error: " . $error);
        echo json_encode(['ok' => false, 'error' => $error]);
        return;
    }

    $state = [];
    if (file_exists($STATE_FILE)) {
        $stateJson = file_get_contents($STATE_FILE);
        $state = json_decode($stateJson, true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            $state = [];
        }
    }

    if (!isset($state[$container])) {
        $state[$container] = [];
    }
    $state[$container]['enabled'] = $enabled;

    if (file_put_contents($STATE_FILE, json_encode($state, JSON_PRETTY_PRINT))) {
        write_log("set_toggle: successfully wrote to state file.");
        echo json_encode(['ok' => true]);
    } else {
        $error = "Failed to write to state file.";
        write_log("set_toggle: error: " . $error);
        echo json_encode(['ok' => false, 'error' => $error]);
    }
}

//--- Main logic ---#
header('Content-Type: application/json');

$action = $_REQUEST['action'] ?? '';
write_log("Request received with action: " . $action);

switch ($action) {
    case 'getSettings':
        get_settings();
        break;
    case 'getState':
        get_state();
        break;
    case 'setToggle':
        set_toggle($_POST);
        break;
    default:
        write_log("Unknown action: " . $action);
        echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}

