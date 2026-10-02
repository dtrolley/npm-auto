<?php
//==============================================================================
// update.php hook (#include)
//
// Runs inside Unraid's /update.php before it writes npm-auto.cfg, with $_POST
// holding the submitted fields and $save deciding whether anything is written.
// update.php merges: keys absent from the POST keep their stored value.
//==============================================================================

$npm_auto_allowed = [
    'SERVICE'           => '/^(enable|disable)$/',
    'NPM_HOST'          => '/^[A-Za-z0-9]([A-Za-z0-9.:-]{0,251}[A-Za-z0-9])?$|^$/',
    'NPM_PORT'          => '/^[0-9]{1,5}$/',
    'NPM_USER'          => '/^[^"\r\n]*$/',
    'NPM_PASS'          => '/^[^"\r\n]*$/',
    'DEFAULT_DOMAIN'    => '/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$|^$/',
    'LABEL_OVERRIDES'   => '/^(yes|no)$/',
    'AUTO_SSL'          => '/^(yes|no)$/',
    'TOGGLE_OFF_ACTION' => '/^(keep|disable|delete)$/',
];

foreach (array_keys($_POST) as $npm_auto_key) {
    if ($npm_auto_key[0] === '#') continue;
    if (!isset($npm_auto_allowed[$npm_auto_key])) {
        unset($_POST[$npm_auto_key]);
        continue;
    }
    $npm_auto_value = trim((string)$_POST[$npm_auto_key]);
    if ($npm_auto_key === 'DEFAULT_DOMAIN') $npm_auto_value = strtolower(rtrim($npm_auto_value, '.'));
    $_POST[$npm_auto_key] = $npm_auto_value;
}

// The stored password is never rendered, so a browser posts the field empty
// unless a new one was typed. Empty means "keep".
if (($_POST['NPM_PASS'] ?? null) === '') unset($_POST['NPM_PASS']);

foreach ($npm_auto_allowed as $npm_auto_key => $npm_auto_rule) {
    if (!array_key_exists($npm_auto_key, $_POST)) continue;
    if (!preg_match($npm_auto_rule, $_POST[$npm_auto_key])) {
        // A value with a double quote would corrupt the ini file; anything
        // else here is a typo that would only fail later, in the daemon.
        syslog(LOG_WARNING, "npm-auto: settings not saved, invalid $npm_auto_key");
        $save = false;
    }
}
