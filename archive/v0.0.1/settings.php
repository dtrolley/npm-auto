<?php
// settings.php
$BASE="/boot/config/plugins/npm-auto";
$SETTINGS="$BASE/var/settings.cfg";
$STATE="$BASE/var/state.json";

header('Content-Type: application/json');

// quick and dirty: ensure only local requests are allowed (browser is local UI)
$action = $_REQUEST['action'] ?? '';

if ($action == 'getSettings') {
    if (file_exists($SETTINGS)) {
        $cfg = file_get_contents($SETTINGS);
        // convert KEY=VALUE into JSON
        $out = [];
        foreach (explode("\n",$cfg) as $line) {
            if (strpos($line,'=')!==false) {
                list($k,$v)=explode('=',$line,2);
                $out[$k]=trim($v,'"');
            }
        }
        echo json_encode(['ok'=>true,'settings'=>$out]);
    } else {
        echo json_encode(['ok'=>false,'error'=>'no settings']);
    }
    exit;
}

if ($action == 'saveSettings') {
    $json = file_get_contents('php://input');
    $data = json_decode($json,true);
    if (!is_array($data)) { echo json_encode(['ok'=>false]); exit; }
    $out="";
    foreach ($data as $k=>$v) {
        $out .= $k . "=\"" . addslashes($v) . "\"\n";
    }
    file_put_contents($SETTINGS,$out);
    echo json_encode(['ok'=>true]);
    exit;
}

if ($action == 'getState') {
    $container = $_REQUEST['container'] ?? '';
    if (!file_exists($STATE)) file_put_contents($STATE,"{}");
    $s = json_decode(file_get_contents($STATE),true);
    $entry = $s[$container] ?? ['enabled'=>false];
    echo json_encode(['ok'=>true,'state'=>$entry]);
    exit;
}

if ($action == 'setToggle') {
    $json = file_get_contents('php://input');
    $data = json_decode($json,true);
    if (!$data || !isset($data['container'])) { echo json_encode(['ok'=>false]); exit; }
    $container = $data['container'];
    $enabled = ($data['enabled'] === 'true');
    if (!file_exists($STATE)) file_put_contents($STATE,"{}");
    $s = json_decode(file_get_contents($STATE),true);
    if ($enabled) {
        $s[$container]=['enabled'=>true];
    } else {
        unset($s[$container]);
    }
    file_put_contents($STATE,json_encode($s, JSON_PRETTY_PRINT));
    echo json_encode(['ok'=>true]);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'unknown action']);

