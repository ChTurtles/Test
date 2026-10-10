-- Runs the real mod scripts against tests/mock_ue4ss.lua.
--   lua5.4 tests/sim_test.lua            (from the repo root)
local root = arg and arg[0]:match("^(.*)/tests/") or "."
package.path = root .. "/mod/RockAndStoneFrontier/Scripts/?.lua;" .. root .. "/tests/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
    if cond then
        io.stdout:write("  ok   ", what, "\n")
    else
        failures = failures + 1
        io.stdout:write("  FAIL ", what, "\n")
    end
end

local function fresh()
    for _, m in ipairs({ "core", "damage", "loadout", "gear", "weapons", "pure_dwarf", "ui", "generated.sheets", "UEHelpers", "mock_ue4ss" }) do
        package.loaded[m] = nil
    end
    local M = require("mock_ue4ss")
    M.install()
    return M
end

local function writeStats(text)
    local f = assert(io.open(root .. "/mod/RockAndStoneFrontier/data/drg_stats.lua", "w"))
    f:write(text)
    f:close()
end
local function removeStats() os.remove(root .. "/mod/RockAndStoneFrontier/data/drg_stats.lua") end

---------------------------------------------------------------------------------------------------
io.stdout:write("scenario 1: Far Far West ignores engine damage (attribute fallback), Engineer, DRG stats present", "\n")
writeStats([[return { ok = true, pak = "test.pak", gear = { warthog = { damage = 9, clip_size = 6, _from = { damage = "x", clip_size = "y" } } } }]])
local M = fresh()
M.damageMode = "none"
local near = M.addEnemy(500, 0, 170, 100)   -- straight ahead
local far = M.addEnemy(900, 300, 50, 100)   -- off to the side, for the turret
dofile(root .. "/mod/RockAndStoneFrontier/Scripts/main.lua")
M.step(0.1)
check(M.texts.RSF_Title == "CHOOSE YOUR DWARF", "class picker opens when the run starts")
check(M.texts.RSF_Options and M.texts.RSF_Options:find("Engineer"), "picker lists the Engineer")
M.tap("Three")
check(M.texts.RSF_Title == "", "picker closes after choosing")
check(M.texts.RSF_Weapon and M.texts.RSF_Weapon:find("Warthog"), "HUD shows the Warthog")
local blocked = table.concat(M.unmapped, ",")
check(blocked:find("IA_Fire") and blocked:find("IA_CastSpell"), "Far Far West fire and spell actions unmapped")
check(not blocked:find("IA_Move") and not blocked:find("IA_Jump"), "movement and jump kept")
check(M.gun and rawget(M.gun, "_hidden") == true, "cowboy's revolver hidden")
M.tap("LeftMouseButton")
check(near.Health < 100, "Warthog damaged the enemy in front (health " .. near.Health .. ")")
check(near.Health <= 100 - 8 * 9 * 0.8 or near.Health <= 100 - 9, "damage uses the DRG value 9 per pellet")
check(M.texts.RSF_Ammo == "5 / 84", "one shell spent from a 6-shell clip (" .. tostring(M.texts.RSF_Ammo) .. ")")
-- empty the clip: auto reload
for _ = 1, 6 do M.tap("LeftMouseButton"); M.step(0.5) end
check(M.texts.RSF_Ammo and (M.texts.RSF_Ammo:find("RELOADING") or M.texts.RSF_Ammo:find("/ 7")), "empty clip reloads (" .. tostring(M.texts.RSF_Ammo) .. ")")
M.step(2.5)
-- turret
M.tap("T")
M.step(8)
check(far.Health < 100 or rawget(far, "_destroyed"), "LMG Gun Platform shot the side enemy (health " .. far.Health .. ")")
-- grenade at a new enemy
local g = M.addEnemy(700, 0, 20, 300)
M.step(1)
M.tap("G")
M.step(2)
check(g.Health < 300, "Plasma Burster hurt the enemy it landed near (health " .. g.Health .. ")")
local log = table.concat(M.log, "")
check(log:find("damage route for BP_Bandit_C: damage_attr"), "fell back to the attribute route and logged it")

---------------------------------------------------------------------------------------------------
io.stdout:write("scenario 2: engine damage works, Scout, no DRG stats (fallback numbers)", "\n")
removeStats()
M = fresh()
M.damageMode = "point"
local e = M.addEnemy(800, 0, 170, 1000)
dofile(root .. "/mod/RockAndStoneFrontier/Scripts/main.lua")
M.step(0.1)
check(M.texts.RSF_Note and M.texts.RSF_Note:find("not found"), "picker says DRG stats were not found")
M.tap("One")
check(M.texts.RSF_Weapon and M.texts.RSF_Weapon:find("GK2"), "Scout gets the GK2")
M.keys.LeftMouseButton = true
M.step(1.0)
M.keys.LeftMouseButton = false
M.step(0.05)
local dealt = 1000 - e.Health
check(dealt >= 15 * 6 and dealt <= 15 * 8, "GK2 held for 1s fires about 7 rounds of 15 (" .. dealt .. ")")
log = table.concat(M.log, "")
check(log:find("damage route for BP_Bandit_C: damage_point"), "point damage chosen when it works")
M.tap("Two")
check(M.texts.RSF_Weapon and M.texts.RSF_Weapon:find("Boomstick"), "swap to the Boomstick")
local before = e.Health
M.tap("LeftMouseButton")
check(before - e.Health >= 12, "Boomstick pellets hit (" .. (before - e.Health) .. ")")
-- cryo grenade freezes
local c = M.addEnemy(600, 0, 20, 500)
M.step(0.6)
M.tap("G")
M.step(2)
check(c.CustomTimeDilation < 1, "cryo grenade froze the enemy (dilation " .. c.CustomTimeDilation .. ")")
M.step(6)
check(c.CustomTimeDilation == 1, "freeze wears off")
-- leaving to the hub restores Far Far West's weapons
M.level = "/Game/Maps/Hub_Saloon"
M.step(0.1)
check(M.viewport == false, "HUD removed in the hub")
M.level = "/Game/Maps/Run_Canyon_02"
M.step(0.1)
check(M.texts.RSF_Title == nil or M.texts.RSF_Title == "" or M.texts.RSF_Title == "CHOOSE YOUR DWARF", "new run")

removeStats()
io.stdout:write(failures == 0 and "ALL PASSED" or (failures .. " FAILED"), "\n")
os.exit(failures == 0 and 0 or 1)
