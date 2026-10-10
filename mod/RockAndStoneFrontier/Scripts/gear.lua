-- sys_gear: grenades (and PGL rounds) flying, sticking, freezing and exploding, plus the Engineer's
-- LMG Gun Platform. Bodies are engine basic shapes; all numbers come from the loadout (DRG stats).
local core = require("core")
local damage = require("damage")

local gear = { onHit = nil, onBoom = nil }
local flying, turrets, frozen = {}, {}, {}

local meshPaths = {}
for _, p in ipairs(core.S.ffw_hooks.spawn_prop.targets) do
    local short = p:match("BasicShapes/(%w+)%.")
    if short then meshPaths[short] = p end
end

local function loadMesh(short)
    local path = meshPaths[short]
    if not path then return nil end
    local m = StaticFindObject(path)
    if not core.valid(m) then
        pcall(function() LoadAsset(path:gsub("%.%w+$", "")) end)
        m = StaticFindObject(path)
    end
    return core.valid(m) and m or nil
end

-- A visible prop (sphere/cylinder/cube) scaled to `scale`; returns nil if the world refuses.
local function spawnProp(short, loc, scale)
    local world = core.world()
    if not world then return nil end
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local actor = world:SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not core.valid(actor) then return nil end
    core.try("prop setup", function()
        local smc = actor.StaticMeshComponent
        smc:SetMobility(2) -- Movable
        local mesh = loadMesh(short)
        if mesh then smc:SetStaticMesh(mesh) end
        smc:SetCollisionEnabled(0)
        actor:SetActorScale3D(scale)
    end)
    return actor
end

local function destroy(actor)
    if core.valid(actor) then pcall(function() actor:K2_DestroyActor() end) end
end

local function move(actor, loc)
    if core.valid(actor) then pcall(function() actor:K2_SetActorLocation(loc, false, {}, false) end) end
end

-- Grenades -------------------------------------------------------------------------------------
-- spec: from, velocity (cm/s), damage, radius_m, fuse_s (0 = on impact), freeze_s, sticks, label
function gear.launch(spec)
    local g = {
        spec = spec, pos = spec.from, vel = spec.velocity, born = core.now(), landedAt = nil,
        stuckTo = nil, stuckOffset = nil,
        body = spawnProp("Sphere", spec.from, core.vec(0.15, 0.15, 0.15)),
    }
    table.insert(flying, g)
    return g
end

local function freeze(actor, seconds, now)
    pcall(function() actor.CustomTimeDilation = core.tuning.freeze_dilation end)
    frozen[actor:GetAddress()] = { actor = actor, untilT = now + seconds }
end

local function explode(g, now)
    local s = g.spec
    local hits = damage.radial(g.pos, s.damage, s.radius_m * 100, function(e)
        if s.freeze_s > 0 then freeze(e, s.freeze_s, now) end
    end)
    core.log("%s went off: %d enemy(s) hit", s.label, hits)
    if gear.onBoom then gear.onBoom(s, hits) end
    destroy(g.body)
    local flash = spawnProp("Sphere", g.pos, core.mul(core.vec(1, 1, 1), s.radius_m * 2))
    if flash then
        core.try("flash", function() ExecuteInGameThreadWithDelay(150, function() destroy(flash) end) end)
    end
end

local function stepGrenade(g, now, dt)
    local s = g.spec
    if g.stuckTo then
        if core.valid(g.stuckTo) then g.pos = core.add(core.v(g.stuckTo:K2_GetActorLocation()), g.stuckOffset) end
        move(g.body, g.pos)
    elseif not g.landedAt then
        local gravity = core.tuning.grenade_gravity_mps2 * 100
        local nextVel = core.add(g.vel, core.vec(0, 0, -gravity * dt))
        local nextPos = core.add(g.pos, core.mul(nextVel, dt))
        local hit = core.trace(g.pos, nextPos, { core.pawn() })
        if hit then
            g.pos = core.add(hit.point, core.mul(hit.normal, 5))
            if s.fuse_s <= 0 then
                return true
            end
            if s.sticks or (hit.actor and damage.isEnemy(hit.actor)) then
                if s.sticks and hit.actor then
                    g.stuckTo = hit.actor
                    g.stuckOffset = core.sub(g.pos, core.v(hit.actor:K2_GetActorLocation()))
                end
                g.landedAt = now
            else
                -- bounce, losing most of the speed
                local n = hit.normal
                local vn = nextVel.X * n.X + nextVel.Y * n.Y + nextVel.Z * n.Z
                g.vel = core.mul(core.sub(nextVel, core.mul(n, 2 * vn)), 0.35)
                if core.len(g.vel) < 150 then g.landedAt = now end
            end
        else
            g.pos, g.vel = nextPos, nextVel
        end
        move(g.body, g.pos)
    end
    if s.sticks then
        -- a sticky grenade's fuse starts when it sticks
        if g.landedAt and now - g.landedAt >= s.fuse_s then return true end
    elseif now - g.born >= s.fuse_s then
        return true
    end
    if now - g.born > 12 then return true end -- lost in the sky
    return false
end

-- Throws the loadout's grenade from the camera.
function gear.throw(grenade)
    if not grenade or grenade.left <= 0 then return false end
    local origin, dir = core.view()
    if not origin then return false end
    grenade.left = grenade.left - 1
    local aim = core.norm(core.add(dir, core.vec(0, 0, 0.15)))
    gear.launch({
        from = core.add(origin, core.mul(dir, 60)),
        velocity = core.mul(aim, grenade.throw_speed_mps * 100),
        damage = grenade.damage, radius_m = grenade.radius_m, fuse_s = grenade.fuse_s,
        freeze_s = grenade.freeze_s, sticks = grenade.sticks, label = grenade.display_name,
    })
    return true
end

-- Turret ---------------------------------------------------------------------------------------
function gear.deploy(d)
    if not d or d.left <= 0 then return false end
    local origin, dir = core.view()
    if not origin then return false end
    local flat = core.norm(core.vec(dir.X, dir.Y, 0))
    local want = core.add(origin, core.mul(flat, d.deploy_distance_m * 100))
    local ground = core.trace(want, core.add(want, core.vec(0, 0, -2000)), { core.pawn() })
    local base = ground and ground.point or want
    d.left = d.left - 1
    local t = {
        def = d, pos = core.add(base, core.vec(0, 0, 60)), ammo = d.ammo, nextShot = 0,
        body = spawnProp("Cylinder", core.add(base, core.vec(0, 0, 30)), core.vec(0.4, 0.4, 0.6)),
        head = spawnProp("Cube", core.add(base, core.vec(0, 0, 75)), core.vec(0.35, 0.2, 0.2)),
    }
    table.insert(turrets, t)
    core.log("%s deployed with %d rounds", d.display_name, t.ammo)
    return true
end

local function stepTurret(t, now)
    if t.ammo <= 0 then return true end
    if now < t.nextShot then return false end
    local rangeCm = t.def.range_m * 100
    local best, bestD
    for _, e in ipairs(damage.enemies()) do
        if core.valid(e) then
            local loc = core.v(e:K2_GetActorLocation())
            local d = core.dist(loc, t.pos)
            if d <= rangeCm and (not bestD or d < bestD) then
                local los = core.trace(t.pos, loc, { t.body, t.head, core.pawn() })
                if not los or not los.actor or los.actor:GetAddress() == e:GetAddress() then
                    best, bestD = e, d
                end
            end
        end
    end
    if not best then
        t.nextShot = now + 0.25
        return false
    end
    t.ammo = t.ammo - 1
    t.nextShot = now + 1 / math.max(t.def.rate_of_fire, 0.1)
    local loc = core.v(best:K2_GetActorLocation())
    local dir = core.norm(core.sub(loc, t.pos))
    if core.valid(t.head) then
        pcall(function() t.head:K2_SetActorRotation(core.kml():Conv_VectorToRotator(dir), false) end)
    end
    if damage.deal(best, t.def.damage, dir, nil) and gear.onHit then gear.onHit(t.def.damage) end
    return false
end

function gear.turretAmmo()
    local n = 0
    for _, t in ipairs(turrets) do n = n + t.ammo end
    return #turrets, n
end

-- Every tick ------------------------------------------------------------------------------------
local last = nil
function gear.update(now)
    local dt = last and math.min(math.max(now - last, 0), 0.1) or 0.016
    last = now
    for i = #flying, 1, -1 do
        local g = flying[i]
        if core.try("grenade", stepGrenade, g, now, dt) then
            core.try("explode", explode, g, now)
            table.remove(flying, i)
        end
    end
    for i = #turrets, 1, -1 do
        local t = turrets[i]
        if core.try("turret", stepTurret, t, now) then
            core.log("%s out of ammo", t.def.display_name)
            destroy(t.body)
            destroy(t.head)
            table.remove(turrets, i)
            if t.def.left < t.def.max_active then t.def.left = t.def.left + 1 end
        end
    end
    for addr, f in pairs(frozen) do
        if now >= f.untilT or not core.valid(f.actor) then
            pcall(function() f.actor.CustomTimeDilation = 1.0 end)
            frozen[addr] = nil
        end
    end
end

-- Level change: everything spawned belongs to the old world.
function gear.reset()
    for _, g in ipairs(flying) do destroy(g.body) end
    for _, t in ipairs(turrets) do destroy(t.body); destroy(t.head) end
    flying, turrets, frozen, last = {}, {}, {}, nil
end

return gear
