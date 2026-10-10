-- sys_weapons: fires the equipped DRG gun at its stats' fire rate.
--   auto       hold to fire (GK2, Lead Storm)
--   semi       one shot per click (Boomstick, Subata, Warthog, Bulldog); pellets > 1 = shotgun
--   stream     short-range cone that burns everything in front of you (CRSPR Flamethrower)
--   projectile lobbed explosive round (Deepcore 40mm PGL)
local core = require("core")
local damage = require("damage")
local loadout = require("loadout")
local gear = require("gear")

local weapons = { onHit = nil }

local function hitscan(w, origin, dir, pawn)
    local landed, total = 0, 0
    for _ = 1, math.max(w.pellets, 1) do
        local d = core.spread(dir, w.spread_deg)
        local hit = core.trace(origin, core.add(origin, core.mul(d, w.range_m * 100)), { pawn })
        if hit and hit.actor then
            local amount = w.damage
            if hit.bone:lower():find("head") then amount = amount * w.weakpoint_mult end
            if damage.deal(hit.actor, amount, d, hit) then
                landed = landed + 1
                total = total + amount
            end
        end
    end
    return landed, total
end

local function stream(w, origin, dir)
    local landed, total = 0, 0
    local cosMax = math.cos(math.rad(math.max(w.spread_deg, 1) * 2))
    local rangeCm = w.range_m * 100
    local pawn = core.pawn()
    for _, e in ipairs(damage.enemies()) do
        if core.valid(e) then
            local to = core.sub(core.v(e:K2_GetActorLocation()), origin)
            local d = core.len(to)
            if d <= rangeCm + w.aoe_radius_m * 100 then
                local n = core.mul(to, 1 / math.max(d, 1))
                if n.X * dir.X + n.Y * dir.Y + n.Z * dir.Z >= cosMax then
                    local los = core.trace(origin, core.v(e:K2_GetActorLocation()), { pawn })
                    if not los or not los.actor or los.actor:GetAddress() == e:GetAddress() or damage.isEnemy(los.actor) then
                        if damage.deal(e, w.damage, n, nil) then
                            landed = landed + 1
                            total = total + w.damage
                        end
                    end
                end
            end
        end
    end
    return landed, total
end

function weapons.update(now)
    local w = loadout.weapon()
    local pawn = core.pawn()
    if not w or not pawn then return end
    local want
    if w.fire_mode == "auto" or w.fire_mode == "stream" then
        want = core.down("LeftMouseButton")
    else
        want = core.pressed("LeftMouseButton")
    end
    if not want then return end
    if not loadout.consume(now) then return end
    local origin, dir = core.view()
    if not origin then return end
    local landed, total = 0, 0
    if w.fire_mode == "stream" then
        landed, total = stream(w, origin, dir)
    elseif w.fire_mode == "projectile" then
        gear.launch({
            from = core.add(origin, core.mul(dir, 60)),
            velocity = core.mul(core.spread(dir, w.spread_deg), w.projectile_speed_mps * 100),
            damage = w.aoe_damage, radius_m = w.aoe_radius_m, fuse_s = 0, freeze_s = 0, sticks = false,
            label = w.display_name,
        })
    else
        landed, total = hitscan(w, origin, dir, pawn)
    end
    if landed > 0 and weapons.onHit then weapons.onHit(total) end
end

return weapons
