<?php
// settings.php - settings and state endpoint for npm-auto
$BASE = "/boot/config/plugins/npm-auto";
$SETTINGS = "{$BASE}/var/settings.cfg";
$STATE = "{$BASE}/var/state.json";

header('Content-Type: application/json');

// helper to load settings file into array
function load_settings() {
  global $SETTINGS;
  $out = array();
  if (!file_exists($SETTINGS)) return $out;
  $lines = file($SETTINGS, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  foreach ($lines as $l) {
    if (strpos($l,'=') === false) continue;
    list($k,$v) = explode('=',$l,2);
    $v = trim($v, " \t\n\r\0\x0B\"");
    $out[$k] = $v;
  }
  return $out;
}

function save_settings($data) {
  global $SETTINGS;
  $out = array();
  foreach ($data as $k=>$v) {
    $kv = $k . '="' . str_replace('"','\\"',$v) . '"';
    $out[] = $kv;
  }
  file_put_contents($SETTINGS, implode("\n", $out) . "\n");
  chmod($SETTINGS, 0600);
  return true;
}

// require auth header matching admin token in settings
$action = $_REQUEST['action'] ?? '';
$settings = load_settings();
$admin_token = $settings['NPM_AUTO_ADMIN_TOKEN'] ?? '';

// local helper to validate requests
function require_auth() {
  global $admin_token;
  // allow if token empty and request from same origin (local UI)
  $hc = $_SERVER['HTTP_X_NPM_AUTO_AUTH'] ?? '';
  $origin_ok = strpos($_SERVER['HTTP_REFERER'] ?? '', $_SERVER['HTTP_HOST']) !== false;
  if ($admin_token) {
    if (!$hc || $hc !== $admin_token) {
      http_response_code(403); echo json_encode(['ok'=>false,'error'=>'auth']); exit;
    }
  } else {
    // no token set: only allow same-origin local requests (best-effort)
    if (! $origin_ok ) { http_response_code(403); echo json_encode(['ok'=>false,'error'=>'auth']); exit; }
  }
}

if ($action === 'getSettings') {
  echo json_encode(['ok'=>true,'settings'=> $settings]);
  exit;
}

if ($action === 'saveSettings') {
  require_auth();
  $payload = json_decode(file_get_contents('php://input'), true);
  if (!is_array($payload)) { echo json_encode(['ok'=>false]); exit; }
  // ensure a token exists; if not, generate one
  if (empty($payload['NPM_AUTO_ADMIN_TOKEN'])) {
    $payload['NPM_AUTO_ADMIN_TOKEN'] = bin2hex(random_bytes(16));
  }
  save_settings($payload);
  echo json_encode(['ok'=>true,'token'=>$payload['NPM_AUTO_ADMIN_TOKEN']]);
  exit;
}

if ($action === 'getState') {
  require_auth();
  $container = $_REQUEST['container'] ?? '';
  if (!file_exists($STATE)) file_put_contents($STATE, json_encode(new stdClass()));
  $s = json_decode(file_get_contents($STATE), true) ?? array();
  $entry = $s[$container] ?? ['enabled'=>false];
  echo json_encode(['ok'=>true,'state'=>$entry]);
  exit;
}

if ($action === 'setToggle') {
  require_auth();
  $payload = json_decode(file_get_contents('php://input'), true);
  if (!$payload || !isset($payload['container'])) { echo json_encode(['ok'=>false]); exit; }
  $container = $payload['container'];
  $enabled = ($payload['enabled'] === 'true');
  if (!file_exists($STATE)) file_put_contents($STATE, json_encode(new stdClass()));
  $s = json_decode(file_get_contents($STATE), true) ?? array();
  if ($enabled) {
    $s[$container] = ['enabled'=>true, 'updated_at'=>time()];
  } else {
    if (isset($s[$container])) unset($s[$container]);
  }
  file_put_contents($STATE, json_encode($s, JSON_PRETTY_PRINT));
  echo json_encode(['ok'=>true]);
  exit;
}

if ($action === 'testConnection') {
  require_auth();
  // server-side NPM connectivity test using settings
  $host = $settings['NPM_HOST'] ?? '127.0.0.1';
  $port = $settings['NPM_PORT'] ?? '81';
  $user = $settings['NPM_USER'] ?? '';
  $pass = $settings['NPM_PASS'] ?? '';
  $base = "http://{$host}:{$port}";
  // attempt token endpoint (/api/tokens) then /api/login fallback
  $ch = curl_init();
  curl_setopt($ch, CURLOPT_URL, $base . '/api/tokens');
  curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
  curl_setopt($ch, CURLOPT_POST, true);
  curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode(['identity'=>$user,'secret'=>$pass]));
  curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
  curl_setopt($ch, CURLOPT_TIMEOUT, 8);
  $resp = curl_exec($ch);
  $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  curl_close($ch);
  $ok = false;
  if ($code >= 200 && $code < 300) {
    $j = json_decode($resp, true);
    if (!empty($j['token'])) $ok = true;
  }
  echo json_encode(['ok'=>true,'reachable'=>$ok,'http_code'=>$code,'response'=>$resp]);
  exit;
}

echo json_encode(['ok'=>false,'error'=>'unknown action']);
