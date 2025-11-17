<?php
//==============================================================================
// settings.php
//
// This script handles the backend logic for the npm-auto settings page.
//==============================================================================

file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Request received: " . print_r($_REQUEST, true) . "\n", FILE_APPEND);

//--- Configuration ---#
$BASE = "/boot/config/plugins/npm-auto";
$SETTINGS_FILE = "{$BASE}/var/settings.cfg";
$STATE_FILE = "{$BASE}/var/state.json";

//--- Functions ---#
function get_settings() {
    if (file_exists($SETTINGS_FILE)) {
        $settings = parse_ini_file($SETTINGS_FILE);
        echo json_encode(['ok' => true, 'settings' => $settings]);
    } else {
        echo json_encode(['ok' => false, 'error' => 'Settings file not found.']);
    }
}

function save_settings($data) {
    if (!is_writable($SETTINGS_FILE)) {
        echo json_encode(['ok' => false, 'error' => 'Settings file is not writable.']);
        return;
    }
    $out = "";
    foreach ($data as $key => $value) {
        $out .= "$key = \"$value\"\n";
    }
    file_put_contents($SETTINGS_FILE, $out);
    echo json_encode(['ok' => true]);
}

function get_state() {
    global $STATE_FILE;
    if (file_exists($STATE_FILE)) {
        $state = json_decode(file_get_contents($STATE_FILE), true);
        echo json_encode(['ok' => true, 'state' => $state]);
    } else {
        echo json_encode(['ok' => true, 'state' => []]);
    }
}

function set_toggle($data) {
    global $STATE_FILE;
    $container = $data['container'];
    $enabled = $data['enabled'] === 'true';

    if (!file_exists(dirname($STATE_FILE))) {
        mkdir(dirname($STATE_FILE), 0755, true);
    }

    if (!is_writable(dirname($STATE_FILE))) {
        echo json_encode(['ok' => false, 'error' => 'State file directory is not writable.']);
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
        echo json_encode(['ok' => true]);
    } else {
        echo json_encode(['ok' => false, 'error' => 'Failed to write to state file.']);
    }
}

//--- Main logic ---#
header('Content-Type: application/json');

$action = $_REQUEST['action'] ?? '';

switch ($action) {
    case 'getSettings':
        get_settings();
        break;
    case 'saveSettings':
        save_settings($_POST);
        break;
    case 'getState':
        get_state();
        break;
    case 'setToggle':
        set_toggle($_POST);
        break;
    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}