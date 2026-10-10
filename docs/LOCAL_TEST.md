# In-game test (run on the Windows PC with both games)

For a Claude Code session running on the PC that has **Far Far West** (Steam 3124540) and **Deep Rock Galactic** installed.
Branch: `claude/drg-far-west-mashup-a4ptc6`. Read `README.md` and `MODLOG.md` first. All rows in `sheets/ffw_hooks.json`
are `verified: "pending"`: the job is to confirm them in the running game. The mod has passed its mock-engine tests but has
never run in the real games.

1. Find both install folders (Steam `libraryfolders.vdf`). Confirm Far Far West has `FarFarWest/Binaries/Win64/FarFarWest-Win64-Shipping.exe`; note any difference (recipe and build assume that path).
2. Back up Far Far West's saves (`%LOCALAPPDATA%\FarFarWest\Saved\SaveGames` or wherever they are) and note any existing `dwmapi.dll` / `ue4ss` in Win64.
3. Extract `release/RockAndStoneFrontier-1.0.0.zip` (check `release/SHA256SUMS`) into the Far Far West folder (its paths start at `FarFarWest/`).
4. Run the stat reader as Melty will:
   `<FFW>\FarFarWest\Binaries\Win64\ue4ss\Mods\RockAndStoneFrontier\tools\rsf-extract.exe --drg "<DRG folder>" --out "<that mod>\data\drg_stats.lua"`
   Read `data\drg_extract.log`; fix `sheets/drg_sources.json` globs and `sheets/drg_stat_props.json` names until gear rows get DRG values.
5. Launch Far Far West via Steam, start a solo run. Read `ue4ss\UE4SS.log` and `...\RockAndStoneFrontier\data\rsf.log` (level names, input action names, enemy health property, damage route). Check: picker appears; picking works; Far Far West weapons/spells stop while movement works; every class's guns hurt and kill enemies; grenades explode; Engineer turret fires; HUD shows ammo.
6. Fix failures sheet-first (e.g. `ffw_hooks.level_name.targets`, `block_ffw_weapons` / `keep_ffw_actions`, health names), then Lua in `mod/RockAndStoneFrontier/Scripts`; `python tools/sheets.py generate`; copy changed Lua (incl. `Scripts/generated/sheets.lua`) into the installed mod to retest. Mark rows `"verified": "in_game"` once seen working. Same failure 3 times: stop and write it up in MODLOG.md.
7. Screenshots of the game window only (no desktop, other windows or secrets): `media/picker.png` (class picker) and `media/combat.png` (a dwarf fighting, HUD visible), PNG under 15 MB.
8. Commit source changes, `media/*.png` and MODLOG.md updates (tested / works / doesn't); push to the same branch. Never commit game files, extracted DRG assets or `drg_stats.lua`. The cloud session rebuilds the package (`build.sh`, Linux), re-uploads it to the Melty draft and adds the screenshots.
9. Tell the user what works in game, what doesn't, and that the cloud session can take it from here.

Ask before anything that costs money. Solo play only; never touch anti-cheat.
