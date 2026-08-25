#!/bin/bash
set -e
asterisk -rx 'core show version' >/dev/null 2>&1
asterisk -rx 'pjsip show endpoints' >/dev/null 2>&1
fwconsole status >/dev/null 2>&1
curl -fsS http://127.0.0.1:${HTTP_PORT:-80}/admin/config.php >/dev/null 2>&1 || curl -fsS http://127.0.0.1:${HTTP_PORT:-80}/ >/dev/null 2>&1
