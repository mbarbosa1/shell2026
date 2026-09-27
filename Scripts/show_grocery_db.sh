#!/usr/bin/env bash
# Prints ShellApp's grocery database: every list, item, and history event.
#
#   ./Scripts/show_grocery_db.sh           # the connected iPhone (run the app from Xcode first)
#   ./Scripts/show_grocery_db.sh --sim     # the booted simulator
#   ./Scripts/show_grocery_db.sh --status  # just the last change and item counts (works with --sim)
#
# Set DEVICE to a device's identifier to pick a phone when more than one is connected.
# It reads a copy of the database, so it never changes the app's data.
set -euo pipefail

BUNDLE_ID="com.camilabarbosa.ShellApp"
STORE_DIR="Library/Application Support"
FILES=(default.store default.store-wal default.store-shm)

SIM=false
STATUS=false
for arg in "$@"; do
    case "$arg" in
        --sim) SIM=true ;;
        --status) STATUS=true ;;
        *) echo "Unknown option: $arg (use --sim and/or --status)" >&2; exit 1 ;;
    esac
done

if $SIM; then
    container=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null) || {
        echo "No booted simulator with ShellApp installed." >&2
        exit 1
    }
    DB="$container/$STORE_DIR/default.store"
    echo "Simulator database"
else
    if [[ -z "${DEVICE:-}" ]]; then
        json=$(mktemp)
        xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
        DEVICE=$(python3 -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("reality") == "physical"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
print(phones[0]["identifier"] if phones else "")
' "$json")
        rm -f "$json"
    fi
    if [[ -z "$DEVICE" ]]; then
        echo "No paired iPhone found. Connect it, or use --sim for the simulator." >&2
        exit 1
    fi

    # Copy the store and its -wal file, which holds the newest changes. The phone connection
    # sometimes drops on the first request, so each file gets a few tries.
    copy=$(mktemp -d)
    trap 'rm -rf "$copy"' EXIT
    for file in "${FILES[@]}"; do
        for attempt in 1 2 3; do
            error=$(xcrun devicectl device copy from --device "$DEVICE" \
                --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
                --source "$STORE_DIR/$file" --destination "$copy/$file" 2>&1 >/dev/null) && break
            [[ $attempt == 3 && $file == default.store ]] && {
                echo "Couldn't copy the database from the iPhone:" >&2
                echo "$error" | grep -iE "error|valid|found" | head -3 >&2
                exit 1
            }
        done
    done
    DB="$copy/default.store"
    echo "iPhone database (copied $(date '+%-I:%M %p'))"
fi

if [[ ! -f "$DB" ]]; then
    echo "No database yet. Open the app once so it can create one." >&2
    exit 1
fi

# SwiftData stores dates as seconds since 2001-01-01; 978307200 converts them to Unix time.
query() { sqlite3 -header -column -nullvalue NULL "$DB" "$1"; }

if $STATUS; then
    sqlite3 "$DB" "
    select 'Last change:  ' || coalesce(
        (select datetime(e.ZDATE + 978307200, 'unixepoch', 'localtime') || ' - ' || e.ZKINDRAW
                || coalesce(' ' || e.ZITEMNAME, '') || ' (' || e.ZSOURCERAW || ')'
         from ZLISTEVENT e order by e.ZDATE desc limit 1),
        'nothing yet');
    select 'Open list:    #' || l.ZNUMBER || ', '
           || (select count(*) from ZGROCERYITEM i where i.ZLIST = l.Z_PK) || ' items, '
           || (select count(*) from ZGROCERYITEM i where i.ZLIST = l.Z_PK and i.ZISCOLLECTED = 1) || ' in cart'
    from ZGROCERYLIST l where l.ZCOMPLETEDAT is null order by l.ZNUMBER desc limit 1;
    select 'All lists:    ' || count(*) || ' total, ' || count(ZCOMPLETEDAT) || ' finished' from ZGROCERYLIST;
    select 'All items:    ' || count(*) from ZGROCERYITEM;"
    exit 0
fi

echo
echo "== LISTS"
query "
select ZNUMBER as list,
       datetime(ZDATE + 978307200, 'unixepoch', 'localtime') as started,
       ZSTORE as store,
       datetime(ZCOMPLETEDAT + 978307200, 'unixepoch', 'localtime') as finished
from ZGROCERYLIST order by ZNUMBER;"

echo
echo "== ITEMS"
query "
select l.ZNUMBER as list, i.ZNAME as name, i.ZQUANTITY as qty, i.ZLABEL as label,
       i.ZBRAND as brand, i.ZSIZE as size, i.ZAISLE as aisle, i.ZBLOCK as block, i.ZPRICE as price, i.ZTCIN as tcin,
       case i.ZISCOLLECTED when 1 then 'yes' else 'no' end as in_cart,
       datetime(i.ZADDEDAT + 978307200, 'unixepoch', 'localtime') as added
from ZGROCERYITEM i left join ZGROCERYLIST l on i.ZLIST = l.Z_PK
order by l.ZNUMBER, i.ZADDEDAT;"

echo
echo "== HISTORY"
query "
select l.ZNUMBER as list,
       datetime(e.ZDATE + 978307200, 'unixepoch', 'localtime') as time,
       e.ZKINDRAW as event, e.ZITEMNAME as item, e.ZSOURCERAW as source
from ZLISTEVENT e left join ZGROCERYLIST l on e.ZLIST = l.Z_PK
order by e.ZDATE;"
