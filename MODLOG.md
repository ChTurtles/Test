# MODLOG: Rock and Stone Frontier

## State (2026-10-10)
- Host: Far Far West (Melty `custom-far-far-west`, Steam 3124540, UE 5.8 per UE4SS's game config). Companion: Deep Rock Galactic (`deep-rock-galactic`, UE 4.27, pak `FSD/Content/Paks/FSD-WindowsNoEditor.pak`).
- Route: UE4SS experimental `v3.0.1-1164-g5e627997` + UE4SS's own Far Far West config (custom GNatives/ProcessLocalScriptFunction signatures; ProcessEvent and Actor tick hooks OFF, so the mod polls). Lua mod `RockAndStoneFrontier`.
- DRG content: `rsf-extract.exe` reads gear stats from the player's DRG pak (Melty `setup` step on first Play).
- Melty draft: modId `32052c28-6022-482e-bced-50792123f9ba`, Studio https://melty.gg/studio/32052c28-6022-482e-bced-50792123f9ba. Recipe: `recipe.draft.json` (validate_recipe valid, one_click_check yes).
- Tested: sheets preflight clean; `tests/sim_test.lua` 24/24 against a mock engine; extractor unit tests incl. a real zlib pak written by repak.
- NOT yet tested in the real games: all 17 `ffw_hooks` rows are `verified: pending`; the DRG asset globs/property names in `sheets/drg_sources.json` are unconfirmed on a real DRG pak.

## In-game test plan (on the PC with both games)
1. Unzip `dist/RockAndStoneFrontier-1.0.0.zip` over the Far Far West folder (check `FarFarWest/Binaries/Win64/FarFarWest-Win64-Shipping.exe` exists there).
2. Run `tools/rsf-extract.exe --drg "<DRG folder>" --out ".../data/drg_stats.lua"`; read `data/drg_extract.log` and fix `sheets/drg_sources.json` globs / `drg_stat_props.json` names until each gear row has DRG values.
3. Launch Far Far West, start a run. Read `ue4ss/UE4SS.log` and `data/rsf.log`: input action names, health property and damage route per enemy class. Update `ffw_hooks` targets, mark rows `in_game`.
4. Screenshot the picker and a dwarf fighting (game window only) for the listing.
