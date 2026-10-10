-- Rock and Stone Frontier: play Far Far West as a Deep Rock Galactic dwarf.
-- sys_main wires the modules to a game-thread loop. Far Far West's UE4SS config turns off
-- ProcessEvent and Actor tick hooks, so everything here is polled.
local core = require("core")
local damage = require("damage")
local loadout = require("loadout")
local gear = require("gear")
local weapons = require("weapons")
local pure = require("pure_dwarf")
local ui = require("ui")
local S = core.S

local hubPatterns = S.ffw_hooks.level_name.targets
local controls = {}
for id, row in pairs(S.controls) do controls[id] = row.key end

local state = { picking = false, level = nil, pawnAddr = nil, lastProps = 0, inRun = false }

local drgStats = core.loadDrgStats()
loadout.setDrgStats(drgStats)

local function isHub(level)
    if level == "" then return true end
    local l = level:lower()
    for _, p in ipairs(hubPatterns) do
        if l:find(p:lower(), 1, true) then return true end
    end
    return false
end

local function openPicker()
    state.picking = true
    ui.showPicker(drgStats.ok)
end

local function choose(classId, now)
    loadout.choose(classId)
    loadout.resupply()
    state.picking = false
    ui.hidePicker()
    core.try("pure dwarf", pure.apply)
    ui.message("ROCK AND STONE!", now)
end

local function leaveRun()
    if loadout.class then core.log("left the run; back to Far Far West's own weapons") end
    loadout.clear()
    pure.restore()
    gear.reset()
    state.picking = false
    state.inRun = false
    ui.drop()
end

weapons.onHit = function(amount) ui.hit(amount, core.now()) end
gear.onHit = weapons.onHit
gear.onBoom = function(spec, hits)
    if hits > 0 then ui.message(string.format("%s: %d hit", spec.label, hits), core.now()) end
end

local function tick()
    core.beginTick()
    local pawn = core.pawn()
    local level = core.levelName()

    if level ~= state.level then
        core.log("level: %s", level)
        state.level = level
        gear.reset()
        ui.drop()
        if isHub(level) then leaveRun() end
    end
    if not pawn or isHub(level) then return end

    local addr = pawn:GetAddress()
    if addr ~= state.pawnAddr then
        state.pawnAddr = addr
        state.inRun = true
        if loadout.class then
            core.try("pure dwarf", pure.apply) -- respawned or next stage: still a dwarf
        else
            openPicker()
        end
    end

    local now = core.now()

    if core.pressed(controls.repick) then openPicker() end
    if state.picking then
        ui.ensure()
        for _, id in ipairs(S.classes_order) do
            if core.pressed(S.classes[id].picker_key) then
                choose(id, now)
                break
            end
        end
        return
    end
    if not loadout.class then return end

    if core.pressed(controls.primary) then loadout.equip("primary") end
    if core.pressed(controls.secondary) then loadout.equip("secondary") end
    if core.pressed(controls.reload) then loadout.startReload(now) end
    if core.pressed(controls.grenade) then gear.throw(loadout.grenade) end
    if loadout.deployable and core.pressed(loadout.deployable.deploy_key) then gear.deploy(loadout.deployable) end

    loadout.update(now)
    weapons.update(now)
    gear.update(now)

    if now - state.lastProps > 3 then
        state.lastProps = now
        core.try("hide props", pure.hideProps)
    end
    local turrets, turretAmmo = gear.turretAmmo()
    ui.hud(loadout, turrets, turretAmmo, now)
end

LoopInGameThreadWithDelay(core.tuning.tick_ms, function()
    core.try("tick", tick)
end)

core.log("Rock and Stone Frontier loaded (DRG stats %s)", drgStats.ok and "read from your install" or "fallback")
