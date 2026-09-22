<?php

declare(strict_types=1);

if (!function_exists('env')) {
    require_once __DIR__ . '/env.php';
}

// WordPress runs behind Caddy. Trust this header only because the application
// port is bound to loopback and cannot be reached directly from the network.
$forwardedProto = $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '';
if (strtolower(trim(explode(',', $forwardedProto)[0])) === 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = '443';
}

define('WP_CONTENT_DIR', dirname(__DIR__) . '/wp-content');

$home = (string) env('WP_HOME', '');
if ($home !== '') {
    define('WP_CONTENT_URL', rtrim($home, '/') . '/wp-content');
}

if (!defined('WP_DEFAULT_THEME')) {
    define('WP_DEFAULT_THEME', env('WP_DEFAULT_THEME', 'municipio'));
}

if (!defined('WP_POST_REVISIONS')) {
    define('WP_POST_REVISIONS', env('WP_POST_REVISIONS', 10));
}

if (!defined('AUTOSAVE_INTERVAL')) {
    define('AUTOSAVE_INTERVAL', env('AUTOSAVE_INTERVAL', 60));
}

if (!defined('EMPTY_TRASH_DAYS')) {
    define('EMPTY_TRASH_DAYS', env('EMPTY_TRASH_DAYS', 30));
}

if (!defined('DISALLOW_FILE_EDIT')) {
    define('DISALLOW_FILE_EDIT', env('DISALLOW_FILE_EDIT', true));
}

