# Rock and Stone Frontier

Play **Far Far West** as a **Deep Rock Galactic** dwarf.

When a Far Far West run starts, a "Choose your dwarf" picker opens: Scout, Driller, Engineer or
Gunner. Your cowboy's own guns and spells are put away and you fight with that class's DRG loadout
instead. Gun damage, pellets, clip sizes, ammo, fire rates and reload times, grenade damage and
radius, and the Engineer turret's stats are read from **your own Deep Rock Galactic install** the
first time you play.

- **Scout**: Deepcore GK2 (full auto), Jury-Rigged Boomstick (8-pellet double barrel), Cryo Grenade (freezes enemies in place)
- **Driller**: CRSPR Flamethrower (short-range stream), Subata 120, High Explosive Grenade
- **Engineer**: "Warthog" Auto 210 shotgun, Deepcore 40mm PGL (explosive rounds), Plasma Burster Missile, LMG Gun Platform turret that shoots the nearest enemy it can see
- **Gunner**: "Lead Storm" Powered Minigun, "Bulldog" Heavy Revolver, Sticky Grenade

Single player (solo runs). Your dwarf's guns, grenades and turret damage Far Far West's enemies;
headshots get each gun's weakpoint bonus.

## Controls

| Key | Action |
|---|---|
| 1 2 3 4 | pick Scout / Driller / Engineer / Gunner in the picker |
| Left mouse | fire (hold for GK2, minigun, flamethrower) |
| 1 / 2 | primary / secondary |
| R | reload (empty clips reload by themselves) |
| G | throw grenade |
| T | deploy the LMG Gun Platform (Engineer) |
| F6 | open the class picker again |

Back in the hub, Far Far West's own weapons return.

## You need

- Far Far West (the game you play in) and Deep Rock Galactic (its stats are read from your copy), both installed.
- Nothing else: the package carries UE4SS (the experimental build with UE4SS's own Far Far West config) and the stat reader.

## How it works

- `sheets/*.json` are the design: one row per class, gun, grenade, turret, DRG source, Far Far West hook
  and system. `tools/sheets.py preflight` lists every unfilled cell and broken reference;
  `tools/sheets.py generate` turns each row into a Lua struct (`Scripts/generated/sheets.lua`) and the
  extractor's target list.
- `extractor/` (Rust) is `rsf-extract.exe`: it opens `FSD/Content/Paks/FSD-WindowsNoEditor.pak` in
  your DRG folder, finds each gear blueprint by the globs in `sheets/drg_sources.json`, reads the
  numbers from its tagged properties and writes `data/drg_stats.lua`. Nothing from DRG is shipped;
  stats it cannot find fall back to the sheet values (the picker tells you which you got).
- `mod/RockAndStoneFrontier/Scripts` is the UE4SS Lua mod inside Far Far West: class picker, HUD,
  hitscan/shotgun/stream/projectile firing, grenades, turret, and a damage system that tries
  `ApplyPointDamage`, then `ApplyDamage`, then the enemy's health attribute, and keeps whichever
  actually lowers health.
- `./build.sh` checks the sheets, runs the mock-engine tests (`tests/sim_test.lua`) and the extractor
  tests, builds the Windows exe and packages `dist/RockAndStoneFrontier-<version>.zip`.

Logs: `FarFarWest/Binaries/Win64/ue4ss/Mods/RockAndStoneFrontier/data/` (`rsf.log`, `drg_extract.log`).

## Credits

- Built with Claude Code (AI) for Melty.
- UE4SS (RE-UE4SS team, MIT) and its Far Far West signature config; repak (trumank, spuds; MIT/Apache-2.0). See THIRD_PARTY.md.
- Deep Rock Galactic is by Ghost Ship Games; Far Far West is by its developers. This mod ships none of either game's files.
