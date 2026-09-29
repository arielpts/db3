#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -f Vendor/PostgreSQL/lib/libpq.5.dylib ]]; then
  python3 Scripts/prepare-postgres.py
fi
python3 Scripts/generate-project.py
xcodebuild -project App/DB3.xcodeproj -scheme db3 -configuration Release -derivedDataPath build/DerivedData build CODE_SIGN_IDENTITY=-
print "Built: $PWD/build/DerivedData/Build/Products/Release/db3.app"
