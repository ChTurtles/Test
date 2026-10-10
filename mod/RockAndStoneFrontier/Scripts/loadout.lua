-- sys_loadout: the chosen dwarf's guns, grenades and turret, built from the sheets plus the player's
-- DRG stats. Tracks clips, reserve ammo, reloads and which gun is out.
local core = require("core")
local S = core.S

local loadout = { class = nil, slots = {}, active = "primary", grenade = nil, deployable = nil }

local drg = { ok = false, gear = {} }
function loadout.setDrgStats(stats) drg = stats end
function loadout.drgStats() return drg end

local function makeWeapon(id)
    local w = core.withDrg(S.weapons[id], drg)
    w.clip = w.clip_size
    w.reserve = math.max(w.max_ammo - w.clip_size, 0)
    w.nextShot = 0
    w.reloadDone = nil
    return w
end

function loadout.choose(classId)
    local c = S.classes[classId]
    loadout.class = c
    loadout.slots = { primary = makeWeapon(c.primary), secondary = makeWeapon(c.secondary) }
    loadout.active = "primary"
    local g = core.withDrg(S.grenades[c.grenade], drg)
    g.left = g.count
    loadout.grenade = g
    if c.deployable ~= "none" then
        local d = core.withDrg(S.deployables[c.deployable], drg)
        d.left = d.max_active
        loadout.deployable = d
    else
        loadout.deployable = nil
    end
    local function src(t)
        local n = 0
        for _ in pairs(t._fromDrg) do n = n + 1 end
        return n
    end
    core.log("class %s: %s (%d DRG stats) / %s (%d) / %s (%d)%s", c.display_name,
        loadout.slots.primary.display_name, src(loadout.slots.primary),
        loadout.slots.secondary.display_name, src(loadout.slots.secondary),
        g.display_name, src(g), loadout.deployable and (" / " .. loadout.deployable.display_name) or "")
end

function loadout.clear()
    loadout.class = nil
    loadout.slots = {}
    loadout.grenade = nil
    loadout.deployable = nil
end

function loadout.weapon()
    return loadout.slots[loadout.active]
end

function loadout.equip(slot)
    if loadout.slots[slot] and loadout.active ~= slot then
        local w = loadout.slots[loadout.active]
        if w then w.reloadDone = nil end -- swapping cancels a reload, as in DRG
        loadout.active = slot
    end
end

function loadout.startReload(now)
    local w = loadout.weapon()
    if not w or w.reloadDone or w.reload_time <= 0 then return end
    if w.clip >= w.clip_size or w.reserve <= 0 then return end
    w.reloadDone = now + w.reload_time
end

-- Call every tick; finishes reloads.
function loadout.update(now)
    for _, w in pairs(loadout.slots) do
        if w.reloadDone and now >= w.reloadDone then
            local take = math.min(w.clip_size - w.clip, w.reserve)
            w.clip = w.clip + take
            w.reserve = w.reserve - take
            w.reloadDone = nil
        end
    end
end

-- Spends one shot if the gun can fire now; starts an automatic reload on an empty clip.
function loadout.consume(now)
    local w = loadout.weapon()
    if not w or w.reloadDone or now < w.nextShot then return false end
    if w.clip <= 0 then
        loadout.startReload(now)
        return false
    end
    w.clip = w.clip - 1
    w.nextShot = now + 1 / math.max(w.rate_of_fire, 0.1)
    if w.clip == 0 then loadout.startReload(now) end
    return true
end

function loadout.resupply()
    for _, w in pairs(loadout.slots) do
        w.clip = w.clip_size
        w.reserve = math.max(w.max_ammo - w.clip_size, 0)
        w.reloadDone = nil
    end
    if loadout.grenade then loadout.grenade.left = loadout.grenade.count end
    if loadout.deployable then loadout.deployable.left = loadout.deployable.max_active end
end

return loadout
