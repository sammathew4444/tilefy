#!/bin/zsh
# CI only: grants Accessibility to the given binaries by editing the system permission database.
# It works on GitHub's macOS runners, which have System Integrity Protection off. It would fail on
# a normal Mac, and shouldn't be used on one.
set -uo pipefail

[[ "${CI:-}" == "true" ]] || { echo "This is only for CI."; exit 1; }

db="/Library/Application Support/com.apple.TCC/TCC.db"
csrutil status || true
now=$(date +%s)
columns=$(sudo sqlite3 "$db" "select count(*) from pragma_table_info('access');")
echo "TCC access table has $columns columns"

for client in "$@" /bin/zsh /bin/bash; do
    case "$columns" in
        17) values="'kTCCServiceAccessibility','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED',$now" ;;
        16) values="'kTCCServiceAccessibility','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED'" ;;
        *)  values="'kTCCServiceAccessibility','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$now" ;;
    esac
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access VALUES($values);" && echo "Granted: $client"
done
sudo sqlite3 "$db" "select client,auth_value from access where service='kTCCServiceAccessibility';"
