-- A small stand-in for UE4SS and a Far Far West level, so the mod's logic can run outside the game.
-- It is not the game: it checks our own code paths (picker, loadout, firing, grenades, turret,
-- damage-route fallback, HUD), not Far Far West's real classes.
local M = { keys = {}, time = 0, loops = {}, delayed = {}, log = {}, texts = {}, unmapped = {}, spawned = {} }

local nextAddr = 1000
local Obj = {}
Obj.__index = function(t, k)
    local m = rawget(t, "_methods")
    if m and m[k] then return m[k] end
    local props = rawget(t, "_props")
    if props and props[k] ~= nil then return props[k] end
    return Obj[k]
end
Obj.__newindex = function(t, k, v)
    local props = rawget(t, "_props")
    if props and props[k] ~= nil then props[k] = v else rawset(t, k, v) end
end

function Obj.IsValid(self) return not rawget(self, "_destroyed") end
function Obj.GetAddress(self) return rawget(self, "_addr") end
function Obj.GetFName(self) local n = rawget(self, "_name"); return { ToString = function() return n end } end
function Obj.GetFullName(self) return rawget(self, "_name") end
function Obj.GetClass(self) return rawget(self, "_class") end
function Obj.IsA(self, what) return rawget(self, "_isa") and rawget(self, "_isa")[what] == true end

local function class(name, propList)
    local c = setmetatable({ _name = name, _addr = 0, _plist = propList or {} }, Obj)
    rawset(c, "_methods", {
        ForEachProperty = function(self, cb)
            for _, p in ipairs(self._plist) do
                local prop = { GetFName = function() return { ToString = function() return p[1] end } end,
                    GetClass = function() return { GetFName = function() return { ToString = function() return p[2] end } end } end }
                if cb(prop) then return end
            end
        end,
        GetSuperStruct = function() return setmetatable({ _destroyed = true }, Obj) end,
    })
    return c
end

function M.new(name, cls, props, methods)
    nextAddr = nextAddr + 1
    local o = setmetatable({ _name = name, _addr = nextAddr, _class = cls or class(name), _props = props or {}, _methods = methods or {} }, Obj)
    return o
end

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

-- World ------------------------------------------------------------------------------------------
M.enemies = {}
M.damageMode = "none" -- "point": ApplyPointDamage lowers Health; "none": the engine route does nothing (GAS-like)
M.level = "/Game/Maps/Run_Desert_01"

local enemyClass = class("BP_Bandit_C", { { "Health", "FloatProperty" }, { "Speed", "FloatProperty" } })
local aiClass = class("AIController")

function M.addEnemy(x, y, z, hp)
    local e
    e = M.new("Bandit" .. (#M.enemies + 1), enemyClass, { Health = hp or 100, CustomTimeDilation = 1.0, Controller = nil }, {
        K2_GetActorLocation = function(self) return self._loc end,
        IsActorBeingDestroyed = function(self) return rawget(self, "_destroyed") == true end,
        K2_GetComponentsByClass = function() return { ForEach = function() end } end,
        GetOwner = function() return nil end,
        SetLifeSpan = function() end,
        K2_DestroyActor = function(self) rawset(self, "_destroyed", true) end,
    })
    rawset(e, "_loc", vec(x, y, z))
    local ai = M.new("AIC", aiClass, {}, {})
    rawset(ai, "_isa", { ["/Script/AIModule.AIController"] = true })
    e.Controller = ai
    table.insert(M.enemies, e)
    return e
end

local cam = M.new("PCM", nil, {}, {
    GetCameraLocation = function() return vec(0, 0, 170) end,
    GetCameraRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
})
local pawnClass = class("BP_Cowboy_C", { { "Health", "FloatProperty" } })
M.pawn = M.new("Cowboy", pawnClass, { Health = 100 }, {
    GetAttachedActors = function(self, out)
        local gun = M.new("Revolver", class("BP_Revolver_Weapon_C"), {}, { SetActorHiddenInGame = function(s, h) rawset(s, "_hidden", h) end })
        M.gun = gun
        out[1] = gun
    end,
    K2_GetActorLocation = function() return vec(0, 0, 100) end,
})
M.pc = M.new("PlayerController", nil, { Pawn = M.pawn, PlayerCameraManager = cam }, {
    IsInputKeyDown = function(self, key) return M.keys[key.KeyName._s] == true end,
})

-- Ray vs enemy spheres (r=60) and the ground (z=0)
local function trace(from, to, ignore)
    local d = { X = to.X - from.X, Y = to.Y - from.Y, Z = to.Z - from.Z }
    local len = math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2)
    if len < 1e-6 then return nil end
    local n = { X = d.X / len, Y = d.Y / len, Z = d.Z / len }
    local bestT, bestActor
    for _, e in ipairs(M.enemies) do
        if not rawget(e, "_destroyed") then
            local skip = false
            for _, i in ipairs(ignore or {}) do if i == e then skip = true end end
            if not skip then
                local c = rawget(e, "_loc")
                local oc = { X = c.X - from.X, Y = c.Y - from.Y, Z = c.Z - from.Z }
                local t = oc.X * n.X + oc.Y * n.Y + oc.Z * n.Z
                if t > 0 and t < len then
                    local px, py, pz = from.X + n.X * t - c.X, from.Y + n.Y * t - c.Y, from.Z + n.Z * t - c.Z
                    if px * px + py * py + pz * pz <= 60 * 60 and (not bestT or t < bestT) then bestT, bestActor = t, e end
                end
            end
        end
    end
    if from.Z > 0 and to.Z <= 0 then
        local t = from.Z / (from.Z - to.Z) * len
        if not bestT or t < bestT then bestT, bestActor = t, nil end
    end
    if not bestT then return nil end
    return { ImpactPoint = vec(from.X + n.X * bestT, from.Y + n.Y * bestT, from.Z + n.Z * bestT), ImpactNormal = vec(0, 0, 1),
        BoneName = { ToString = function() return "spine" end }, _actor = bestActor }
end

local gameplayStatics = M.new("Default__GameplayStatics", nil, {}, {
    GetTimeSeconds = function() return M.time end,
    GetCurrentLevelName = function() return { ToString = function() return M.level end } end,
    ApplyPointDamage = function(self, target, amount)
        if M.damageMode == "point" then target.Health = target.Health - amount end
    end,
    ApplyDamage = function() end,
})
local ksl = M.new("Default__KismetSystemLibrary", nil, {}, {
    LineTraceSingle = function(self, ctx, from, to, ch, complex, ignore, dbg, out)
        local h = trace(from, to, ignore)
        if not h then return false end
        for k, v in pairs(h) do out[k] = v end
        return true
    end,
})
local kml = M.new("Default__KismetMathLibrary", nil, {}, {
    GetForwardVector = function() return vec(1, 0, 0) end,
    Conv_VectorToRotator = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
})

local world = M.new("World", nil, {}, {
    SpawnActor = function(self, cls, loc)
        local a = M.new("Prop", nil, {}, {
            K2_SetActorLocation = function(s, l) rawset(s, "_loc", l) end,
            K2_SetActorRotation = function() end,
            SetActorScale3D = function() end,
            K2_DestroyActor = function(s) rawset(s, "_destroyed", true) end,
        })
        a.StaticMeshComponent = M.new("SMC", nil, {}, { SetMobility = function() end, SetStaticMesh = function() end, SetCollisionEnabled = function() end })
        table.insert(M.spawned, a)
        return a
    end,
})

-- Input mapping contexts: one with fire/spell/move actions.
local function action(name) return M.new(name, nil, {}, {}) end
local imc = M.new("IMC_Default", nil, {}, {})
local mappings = {
    { Action = action("IA_Fire"), Key = { KeyName = { _s = "LeftMouseButton" } } },
    { Action = action("IA_CastSpell"), Key = { KeyName = { _s = "Q" } } },
    { Action = action("IA_Move"), Key = { KeyName = { _s = "W" } } },
    { Action = action("IA_Jump"), Key = { KeyName = { _s = "SpaceBar" } } },
}
imc.DefaultKeyMappings = { Mappings = {
    GetArrayNum = function() return #mappings end,
    ForEach = function(self, cb) for i, m in ipairs(mappings) do cb(i, { get = function() return m end }) end end,
} }
rawget(imc, "_methods").UnmapKey = function(self, a) table.insert(M.unmapped, a:GetFName():ToString()) end
rawget(imc, "_methods").MapKey = function() end

-- UMG
local function textBlock(name)
    local t = M.new(name, nil, { Font = { Size = 10 } }, {})
    local m = rawget(t, "_methods")
    m.SetText = function(s, ft) M.texts[name] = ft._s end
    m.SetFont = function() end
    m.SetJustification = function() end
    m.SetShadowOffset = function() end
    m.SetShadowColorAndOpacity = function() end
    m.SetColorAndOpacity = function() end
    return t
end

-- Globals UE4SS provides -------------------------------------------------------------------------
function M.install()
    _G.FName = function(s) return { _s = s, ToString = function() return s end } end
    _G.FText = function(s) return { _s = s } end
    _G.print = function(s) table.insert(M.log, s) end
    _G.LoadAsset = function() end
    _G.StaticFindObject = function(path)
        return M.new(path, nil, {}, {})
    end
    _G.FindFirstOf = function(name)
        if name == "GameInstance" then return M.new("GI", nil, {}, {}) end
        if name == "EnhancedInputLocalPlayerSubsystem" then return M.new("EI", nil, {}, { RequestRebuildControlMappings = function() end }) end
        return setmetatable({ _destroyed = true }, Obj)
    end
    _G.FindAllOf = function(name)
        if name == "Character" then
            local list = { M.pawn }
            for _, e in ipairs(M.enemies) do table.insert(list, e) end
            return list
        end
        if name == "InputMappingContext" then return { imc } end
        return nil
    end
    _G.StaticConstructObject = function(cls, outer, fname)
        local n = fname._s
        if n:find("^RSF_Canvas") then
            local c = M.new(n, nil, {}, {})
            rawget(c, "_methods").AddChildToCanvas = function()
                return M.new("slot", nil, {}, { SetAnchors = function() end, SetAlignment = function() end, SetPosition = function() end, SetAutoSize = function() end })
            end
            return c
        elseif n == "RSF_Overlay" then
            return M.new(n, nil, { WidgetTree = false }, { AddToViewport = function() M.viewport = true end, SetOwningPlayer = function() end, RemoveFromParent = function() M.viewport = false end })
        elseif n == "RSF_Tree" then
            return M.new(n, nil, { RootWidget = false }, {})
        end
        return textBlock(n)
    end
    _G.LoopInGameThreadWithDelay = function(ms, fn) table.insert(M.loops, fn) end
    _G.ExecuteInGameThreadWithDelay = function(ms, fn) table.insert(M.delayed, { at = M.time + ms / 1000, fn = fn }) end
    package.preload["UEHelpers"] = function()
        return {
            GetGameplayStatics = function() return gameplayStatics end,
            GetKismetSystemLibrary = function() return ksl end,
            GetKismetMathLibrary = function() return kml end,
            GetPlayerController = function() return M.pc end,
            GetWorld = function() return world end,
            GetActorFromHitResult = function(h) return h._actor end,
        }
    end
end

function M.step(seconds)
    local n = math.max(1, math.floor(seconds / 0.016 + 0.5))
    for _ = 1, n do
        M.time = M.time + 0.016
        for _, fn in ipairs(M.loops) do fn() end
        for i = #M.delayed, 1, -1 do
            if M.time >= M.delayed[i].at then M.delayed[i].fn(); table.remove(M.delayed, i) end
        end
    end
end

function M.tap(key)
    M.keys[key] = true; M.step(0.032); M.keys[key] = false; M.step(0.032)
end

return M
