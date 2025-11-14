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
    if (file_exists($STATE_FILE)) {
        $state = json_decode(file_get_contents($STATE_FILE), true);
        file_put_contents("/tmp/npm-auto-debug.log", "State: " . print_r($state, true) . "\n", FILE_APPEND);
        echo json_encode(['ok' => true, 'state' => $state]);
    } else {
        file_put_contents("/tmp/npm-auto-debug.log", "State file not found, creating it.\n", FILE_APPEND);
        file_put_contents($STATE_FILE, "{}");
        chmod($STATE_FILE, 0666);
        echo json_encode(['ok' => true, 'state' => []]);
    }
}

function set_toggle($data) {
    file_put_contents("/tmp/npm-auto-debug.log", "set_toggle called\n", FILE_APPEND);
    file_put_contents("/tmp/npm-auto-debug.log", "Data: " . print_r($data, true) . "\n", FILE_APPEND);

    $container = $data['container'];
    $enabled = $data['enabled'];

    $dir = dirname($STATE_FILE);
    if (!file_exists($dir)) {
        if (mkdir($dir, 0777, true)) {
            file_put_contents("/tmp/npm-auto-debug.log", "Directory created: $dir\n", FILE_APPEND);
            chmod($dir, 0777);
        } else {
            file_put_contents("/tmp/npm-auto-debug.log", "Failed to create directory: $dir\n", FILE_APPEND);
        }
    }

    $state = json_decode(file_get_contents($STATE_FILE), true) ?: [];
    file_put_contents("/tmp/npm-auto-debug.log", "Old State: " . print_r($state, true) . "\n", FILE_APPEND);

    $state[$container] = ['enabled' => $enabled];

    file_put_contents($STATE_FILE, json_encode($state, JSON_PRETTY_PRINT));
    file_put_contents("/tmp/npm-auto-debug.log", "New State: " . print_r($state, true) . "\n", FILE_APPEND);
    echo json_encode(['ok' => true]);
}

//--- Main logic ---#
header('Content-Type: application/json');

$action = $_REQUEST['action'] ?? '';

switch ($action) {
    case 'getSettings':
        get_settings();
        break;
    case 'saveSettings':
        $json = file_get_contents('php://input');
        $data = json_decode($json, true);
        save_settings($data);
        break;
    case 'getState':
        get_state();
        break;
    case 'setToggle':
        $json = file_get_contents('php://input');
        $data = json_decode($json, true);
        set_toggle($data);
        break;
    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}

