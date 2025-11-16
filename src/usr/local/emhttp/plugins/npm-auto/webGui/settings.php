<?php
//==============================================================================
// settings.php
//
// This script handles the backend logic for the npm-auto settings page.
//==============================================================================

//--- Debugging ---#
file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "--- New Request ---\n", FILE_APPEND);
file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Request: " . print_r($_REQUEST, true) . "\n", FILE_APPEND);
file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Post: " . print_r($_POST, true) . "\n", FILE_APPEND);
file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Input: " . file_get_contents('php://input') . "\n", FILE_APPEND);

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
    file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Inside set_toggle function.\n", FILE_APPEND);

    $container = $data['container'];
    $enabled = $data['enabled'] === 'true';
    file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Container: $container, Enabled: " . ($enabled ? 'true' : 'false') . "\n", FILE_APPEND);

    $dir = dirname($STATE_FILE);
    if (!file_exists($dir)) {
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Directory $dir does not exist, creating it.\n", FILE_APPEND);
        mkdir($dir, 0755, true);
    }

    if (!is_writable($dir)) {
        $error = "State file directory $dir is not writable.";
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Error: $error\n", FILE_APPEND);
        echo json_encode(['ok' => false, 'error' => $error]);
        return;
    } else {
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Directory $dir is writable.\n", FILE_APPEND);
    }

    $state = [];
    if (file_exists($STATE_FILE)) {
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "State file exists, reading it.\n", FILE_APPEND);
        $stateJson = file_get_contents($STATE_FILE);
        $state = json_decode($stateJson, true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            $error = "Error decoding state.json: " . json_last_error_msg();
            file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Error: $error\n", FILE_APPEND);
            // Don't exit, just start with an empty state
            $state = [];
        }
    }

    if (!isset($state[$container])) {
        $state[$container] = [];
    }
    $state[$container]['enabled'] = $enabled;

    $newStateJson = json_encode($state, JSON_PRETTY_PRINT);
    file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "New state to write: $newStateJson\n", FILE_APPEND);

    if (file_put_contents($STATE_FILE, $newStateJson)) {
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Successfully wrote to state file.\n", FILE_APPEND);
        echo json_encode(['ok' => true]);
    } else {
        $error = "Failed to write to state file.";
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Error: $error\n", FILE_APPEND);
        echo json_encode(['ok' => false, 'error' => $error]);
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
        file_put_contents("/mnt/user/gemini/npm-auto-debug.log", "Entering setToggle case.\n", FILE_APPEND);
        set_toggle($_POST);
        break;
    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action.']);
}

