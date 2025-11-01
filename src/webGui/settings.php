<?php
$BASE = "/boot/config/plugins/npm-auto";
$SETTINGS = "{$BASE}/var/settings.cfg";
$STATE = "{$BASE}/var/state.json";
header('Content-Type: application/json');
echo json_encode(['ok'=>true,'msg'=>'placeholder implemented']);
?>