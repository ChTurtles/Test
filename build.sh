#!/usr/bin/env bash
# Builds dist/RockAndStoneFrontier-<version>.zip, laid out as Far Far West's install folder.
#   ./build.sh            (Linux; needs python3, lua5.4, cargo with x86_64-pc-windows-gnu, mingw-w64, zip)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"
UE4SS_NAME="UE4SS_v3.0.1-1164-g5e627997.zip"
UE4SS_SHA="3c72142a383e25e9f9553ac9e4d5677aa572e98cb369cac57200efb2e381e603"
CONFIGS_SHA="1b2420b7deb237cd680d27306eadf26628699d992a322c89a963d80f580c9b78"
BASE="https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest"

echo "== preflight + generate from sheets"
python3 tools/sheets.py generate

echo "== mod logic against the mock engine"
lua5.4 tests/sim_test.lua

echo "== extractor tests and Windows build"
(cd extractor && cargo test --quiet && cargo build --quiet --release --target x86_64-pc-windows-gnu)

echo "== UE4SS (official experimental build + its Far Far West config)"
mkdir -p .cache
fetch() { # name sha
  if [ ! -f ".cache/$1" ] || ! echo "$2  .cache/$1" | sha256sum -c --quiet; then
    curl -sSfL -o ".cache/$1" "$BASE/$1"
  fi
  echo "$2  .cache/$1" | sha256sum -c --quiet
}
fetch "$UE4SS_NAME" "$UE4SS_SHA"
fetch zCustomGameConfigs.zip "$CONFIGS_SHA"

STAGE=dist/stage
WIN64="$STAGE/FarFarWest/Binaries/Win64"
rm -rf "$STAGE" && mkdir -p "$WIN64"
unzip -q ".cache/$UE4SS_NAME" -d .cache/ue4ss_unpacked.tmp
cp .cache/ue4ss_unpacked.tmp/dwmapi.dll "$WIN64/"
mkdir -p "$WIN64/ue4ss/Mods"
cp .cache/ue4ss_unpacked.tmp/ue4ss/UE4SS.dll .cache/ue4ss_unpacked.tmp/ue4ss/LICENSE "$WIN64/ue4ss/"
cp -r .cache/ue4ss_unpacked.tmp/ue4ss/Mods/shared "$WIN64/ue4ss/Mods/"
rm -rf .cache/ue4ss_unpacked.tmp
unzip -q .cache/zCustomGameConfigs.zip "Far Far West/*" -d .cache/cfg.tmp
cp ".cache/cfg.tmp/Far Far West/UE4SS-settings.ini" "$WIN64/ue4ss/"
cp -r ".cache/cfg.tmp/Far Far West/UE4SS_Signatures" "$WIN64/ue4ss/"
rm -rf .cache/cfg.tmp

MOD="$WIN64/ue4ss/Mods/RockAndStoneFrontier"
mkdir -p "$MOD/Scripts/generated" "$MOD/tools" "$MOD/data"
cp mod/RockAndStoneFrontier/Scripts/*.lua "$MOD/Scripts/"
cp mod/RockAndStoneFrontier/Scripts/generated/sheets.lua "$MOD/Scripts/generated/"
cp mod/RockAndStoneFrontier/data/README.txt "$MOD/data/"
cp extractor/target/x86_64-pc-windows-gnu/release/rsf-extract.exe "$MOD/tools/"
: > "$MOD/enabled.txt"
printf 'RockAndStoneFrontier : 1\n' > "$WIN64/ue4ss/Mods/mods.txt"
printf '[\n    {\n        "mod_name": "RockAndStoneFrontier",\n        "mod_enabled": true\n    }\n]\n' > "$WIN64/ue4ss/Mods/mods.json"
cp README.md "$MOD/README.md"
cp THIRD_PARTY.md "$MOD/THIRD_PARTY.md"

ZIP="dist/RockAndStoneFrontier-$VERSION.zip"
rm -f "$ZIP"
find "$STAGE" -exec touch -d "2026-10-10 00:00:00" {} +
(cd "$STAGE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -X -q -9 "../$(basename "$ZIP")" -@)
echo "== built $ZIP"
sha256sum "$ZIP"
stat -c '%s bytes' "$ZIP"
