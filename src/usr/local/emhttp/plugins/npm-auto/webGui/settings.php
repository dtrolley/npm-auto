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
        echo json_encode(['ok' => true, 'state' => $state]);
    } else {
        echo json_encode(['ok' => false, 'error' => 'State file not found.']);
    }
}

function set_toggle($data) {
    $container = $data['container'];
    $enabled = $data['enabled'];

    if (!file_exists($STATE_FILE)) {
        file_put_contents($STATE_FILE, "{}");
    }

    $state = json_decode(file_get_contents($STATE_FILE), true);

    if ($enabled) {
        $state[$container] = ['enabled' => true];
    } else {
        unset($state[$container]);
    }

    file_put_contents($STATE_FILE, json_encode($state, JSON_PRETTY_PRINT));
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

