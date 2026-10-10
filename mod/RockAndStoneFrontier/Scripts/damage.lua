-- sys_damage: find Far Far West's enemies, read their health, and hurt them with the first damage
-- route that actually lowers it (ffw_hooks: damage_point -> damage_any -> damage_attr). The route
-- that works is remembered per enemy class and written to the log.
local core = require("core")
local S = core.S

local damage = {}

local healthNames = {}
for _, n in ipairs(S.ffw_hooks.health_probe.targets) do healthNames[n:lower()] = true end
local routeOrder = {}
do
    local id = "damage_point"
    while id and id ~= "none" do
        table.insert(routeOrder, id)
        id = S.ffw_hooks[id].fallback
    end
end

local enemies, enemiesAt = {}, -1
local routeByClass = {} -- class name -> route id that worked
local probeByClass = {} -- class name -> probe descriptor or false
local stats = { hits = 0, kills = 0 }
damage.stats = stats

local function className(actor)
    local ok, n = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

-- Health probe --------------------------------------------------------------------------------
-- Looks for a float/double/GameplayAttributeData property whose name is in health_probe.targets on
-- (1) the actor, (2) its AbilitySystemComponent's attribute sets, (3) its other components.
local function findHealthProp(obj)
    local found
    pcall(function()
        local cls = obj:GetClass()
        while cls and cls:IsValid() and not found do
            cls:ForEachProperty(function(prop)
                local name = prop:GetFName():ToString()
                if healthNames[name:lower()] then
                    local kind = prop:GetClass():GetFName():ToString()
                    if kind == "FloatProperty" or kind == "DoubleProperty" or kind == "IntProperty" or kind == "StructProperty" then
                        found = { name = name, kind = kind }
                        return true
                    end
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    return found
end

local function readProp(holder, p)
    local v = holder[p.name]
    if p.kind == "StructProperty" then
        local ok, cur = pcall(function() return v.CurrentValue end)
        return ok and type(cur) == "number" and cur or nil
    end
    return type(v) == "number" and v or nil
end

local function components(actor)
    local list = {}
    pcall(function()
        local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
        comps:ForEach(function(_, c) table.insert(list, c:get()) end)
    end)
    return list
end

local function findHealthUncached(actor)
    local p = findHealthProp(actor)
    if p then return actor, p, "actor" end
    for _, comp in ipairs(components(actor)) do
        if className(comp):find("AbilitySystem") then
            local sets = {}
            pcall(function() comp.SpawnedAttributes:ForEach(function(_, s) table.insert(sets, s:get()) end) end)
            for _, set in ipairs(sets) do
                local sp = findHealthProp(set)
                if sp then return set, sp, "attr", className(set) end
            end
        end
    end
    for _, comp in ipairs(components(actor)) do
        local cp = findHealthProp(comp)
        if cp then return comp, cp, "comp", className(comp) end
    end
end

-- Reflection runs once per enemy class; later lookups only walk to the remembered holder.
local healthCache = {}
local function locateHealth(actor)
    local cn = className(actor)
    local c = healthCache[cn]
    if c == nil then
        local holder, p, where, holderClass = findHealthUncached(actor)
        c = holder and { p = p, where = where, holderClass = holderClass } or false
        healthCache[cn] = c
        if holder then return holder, p, where .. (holderClass and (":" .. holderClass) or "") end
        return nil
    end
    if not c then return nil end
    if c.where == "actor" then return actor, c.p, "actor" end
    for _, comp in ipairs(components(actor)) do
        if c.where == "comp" and className(comp) == c.holderClass then return comp, c.p, "comp" end
        if c.where == "attr" and className(comp):find("AbilitySystem") then
            local holder
            pcall(function()
                comp.SpawnedAttributes:ForEach(function(_, s)
                    local set = s:get()
                    if className(set) == c.holderClass then holder = set; return true end
                end)
            end)
            if holder then return holder, c.p, "attr" end
        end
    end
end

-- Returns current health or nil when the enemy has no health we can see.
function damage.health(actor)
    local holder, p = locateHealth(actor)
    if not holder then return nil end
    return readProp(holder, p), holder, p
end

local function describeOnce(actor)
    local cn = className(actor)
    if probeByClass[cn] ~= nil then return end
    local holder, p, where = locateHealth(actor)
    probeByClass[cn] = holder and { name = p.name, kind = p.kind, where = where } or false
    if holder then
        core.log("enemy %s: health is %s (%s) on %s = %s", cn, p.name, p.kind, where, tostring(readProp(holder, p)))
    else
        core.log("enemy %s: no health property found; components:", cn)
        for _, comp in ipairs(components(actor)) do core.log("  - %s", className(comp)) end
    end
end

function damage.alive(actor)
    if not core.valid(actor) then return false end
    local ok, dying = pcall(function() return actor:IsActorBeingDestroyed() end)
    if ok and dying then return false end
    local hp = damage.health(actor)
    return hp == nil or hp > 0
end

-- Enemies ----------------------------------------------------------------------------------------
function damage.enemies()
    local now = core.now()
    if now - enemiesAt < core.tuning.enemy_refresh_s and now >= enemiesAt then return enemies end
    enemiesAt = now
    enemies = {}
    local me = core.pawn()
    local all = FindAllOf("Character") or {}
    for _, ch in ipairs(all) do
        if core.valid(ch) and (not me or ch:GetAddress() ~= me:GetAddress()) then
            local ok, isAI = pcall(function()
                local c = ch.Controller
                return core.valid(c) and c:IsA("/Script/AIModule.AIController")
            end)
            if ok and isAI and damage.alive(ch) then table.insert(enemies, ch) end
        end
    end
    return enemies
end

function damage.isEnemy(actor)
    if not core.valid(actor) then return false end
    local addr = actor:GetAddress()
    for _, e in ipairs(damage.enemies()) do
        if e:GetAddress() == addr then return true end
    end
    return false
end

-- Damage routes -----------------------------------------------------------------------------------
local routes = {}

routes.damage_point = function(target, amount, dir, hit)
    local pc, pawn = core.pc(), core.pawn()
    core.statics():ApplyPointDamage(target, amount, dir, hit and hit.raw or {}, pc, pawn, nil)
end

routes.damage_any = function(target, amount)
    local pc, pawn = core.pc(), core.pawn()
    core.statics():ApplyDamage(target, amount, pc, pawn, nil)
end

routes.damage_attr = function(target, amount)
    local holder, p = locateHealth(target)
    if not holder then return end
    local cur = readProp(holder, p) or 0
    local new = cur - amount
    if p.kind == "StructProperty" then
        holder[p.name].CurrentValue = new
        holder[p.name].BaseValue = new
    elseif p.kind == "IntProperty" then
        holder[p.name] = math.floor(new)
    else
        holder[p.name] = new
    end
    if new <= 0 then
        pcall(function() target:SetLifeSpan(0.1) end)
        pcall(function() target:K2_DestroyActor() end)
    end
end

-- Deals amount (already in DRG units) to target. Returns true when the hit landed on an enemy.
function damage.deal(target, amount, dir, hit)
    if not core.valid(target) or amount <= 0 then return false end
    if not damage.isEnemy(target) then
        -- Bullets often hit a child actor or attached prop; credit its owner if that is an enemy.
        local ok, owner = pcall(function() return target:GetOwner() end)
        if ok and core.valid(owner) and damage.isEnemy(owner) then target = owner else return false end
    end
    amount = amount * core.tuning.damage_scale
    describeOnce(target)
    local cn = className(target)
    local before = damage.health(target)
    local known = routeByClass[cn]
    local order = known and { known } or routeOrder
    for _, id in ipairs(order) do
        core.try("route " .. id, routes[id], target, amount, dir or core.vec(1, 0, 0), hit)
        local after = damage.health(target)
        local landed = before == nil or (after ~= nil and after < before) or not core.valid(target)
        if landed then
            if not known then
                routeByClass[cn] = id
                core.log("damage route for %s: %s (health %s -> %s)", cn, id, tostring(before), tostring(after))
            end
            stats.hits = stats.hits + 1
            if after ~= nil and after <= 0 then stats.kills = stats.kills + 1 end
            return true
        end
    end
    if not known then
        core.log("no damage route lowered %s's health (still %s)", cn, tostring(before))
    end
    return false
end

-- Damage to every enemy within radius (cm) of center, falling off to 25% at the edge.
function damage.radial(center, amount, radiusCm, onHit)
    local n = 0
    for _, e in ipairs(damage.enemies()) do
        if core.valid(e) then
            local loc = core.v(e:K2_GetActorLocation())
            local d = core.dist(loc, center)
            if d <= radiusCm then
                local falloff = 1 - 0.75 * (d / math.max(radiusCm, 1))
                if damage.deal(e, amount * falloff, core.norm(core.sub(loc, center)), nil) then
                    n = n + 1
                    if onHit then onHit(e) end
                end
            end
        end
    end
    return n
end

return damage
