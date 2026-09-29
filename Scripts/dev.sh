#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" != "--locked" ]]; then
  exec python3 Scripts/with-build-lock.py /bin/zsh "${0:A}" --locked
fi

./Scripts/build.sh
app_bundle="$PWD/build/DerivedData/Build/Products/Release/db3.app"
python3 Scripts/verify-bundle.py "$app_bundle"

# Use the app's normal quit path so unsaved work and active sessions keep their
# usual protection. A cancelled quit fails this command before reopening.
osascript <<'APPLESCRIPT'
if application id "app.db3.workbench" is running then
    with timeout of 60 seconds
        tell application id "app.db3.workbench" to quit
    end timeout
    repeat with attempt from 1 to 100
        if not (application id "app.db3.workbench" is running) then exit repeat
        delay 0.1
    end repeat
    if application id "app.db3.workbench" is running then
        error "db3 is still closing. Run make dev again after it quits."
    end if
end if
APPLESCRIPT

open "$app_bundle"
print "Started: $app_bundle"
