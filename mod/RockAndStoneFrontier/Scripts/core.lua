-- sys_core: logging, clock, player, camera, keys, traces, and the DRG stats written by rsf-extract.
local UEHelpers = require("UEHelpers")
local S = require("generated.sheets")

local core = { S = S, tuning = {} }
for id, row in pairs(S.tuning) do core.tuning[id] = row.value end

local scriptPath = debug.getinfo(1, "S").source:gsub("^@", "")
core.modDir = scriptPath:match("^(.*)[/\\]Scripts[/\\]") or "."
core.dataDir = core.modDir .. "/data"

local logFile = io.open(core.dataDir .. "/rsf.log", "w")
function core.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print("[RockAndStoneFrontier] " .. msg .. "\n")
    if logFile then logFile:write(msg, "\n"); logFile:flush() end
end

-- Runs fn, logging (once per tag) instead of letting an error end the game-thread loop.
local reported = {}
function core.try(tag, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok and not reported[tag] then
        reported[tag] = true
        core.log("error in %s: %s", tag, tostring(a))
    end
    if ok then return a, b, c end
end

function core.valid(o)
    if o == nil or (type(o) ~= "userdata" and type(o) ~= "table") then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

function core.statics() return UEHelpers.GetGameplayStatics() end
function core.ksl() return UEHelpers.GetKismetSystemLibrary() end
function core.kml() return UEHelpers.GetKismetMathLibrary() end

function core.pc()
    local pc = UEHelpers.GetPlayerController()
    if core.valid(pc) then return pc end
end

function core.pawn()
    local pc = core.pc()
    if pc and core.valid(pc.Pawn) then return pc.Pawn end
end

function core.world()
    local w = UEHelpers.GetWorld()
    if core.valid(w) then return w end
end

function core.now()
    local ctx = core.pawn() or core.pc()
    if not ctx then return 0 end
    return core.statics():GetTimeSeconds(ctx)
end

function core.levelName()
    local pc = core.pc()
    if not pc then return "" end
    local name = core.statics():GetCurrentLevelName(pc, true)
    return name and name:ToString() or ""
end

-- Vectors -------------------------------------------------------------------------------------
function core.vec(x, y, z) return { X = x, Y = y, Z = z } end
function core.v(u) return { X = u.X, Y = u.Y, Z = u.Z } end
function core.add(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
function core.sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
function core.mul(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
function core.len(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
function core.norm(a)
    local l = core.len(a)
    if l < 1e-6 then return core.vec(1, 0, 0) end
    return core.mul(a, 1 / l)
end
function core.dist(a, b) return core.len(core.sub(a, b)) end

-- A direction inside a cone of half-angle deg around dir.
function core.spread(dir, deg)
    if deg <= 0 then return dir end
    local r = math.rad(deg)
    local t = core.norm(dir)
    local up = math.abs(t.Z) < 0.99 and core.vec(0, 0, 1) or core.vec(1, 0, 0)
    local right = core.norm({ X = t.Y * up.Z - t.Z * up.Y, Y = t.Z * up.X - t.X * up.Z, Z = t.X * up.Y - t.Y * up.X })
    local up2 = { X = right.Y * t.Z - right.Z * t.Y, Y = right.Z * t.X - right.X * t.Z, Z = right.X * t.Y - right.Y * t.X }
    local a = math.random() * 2 * math.pi
    local m = math.tan(r) * math.sqrt(math.random())
    return core.norm(core.add(t, core.add(core.mul(right, math.cos(a) * m), core.mul(up2, math.sin(a) * m))))
end

-- Camera (UE: centimetres, X forward, Z up) -----------------------------------------------------
function core.view()
    local pc = core.pc()
    if not pc or not core.valid(pc.PlayerCameraManager) then return nil end
    local cam = pc.PlayerCameraManager
    local loc = core.v(cam:GetCameraLocation())
    local fwd = core.v(core.kml():GetForwardVector(cam:GetCameraRotation()))
    return loc, fwd
end

-- Keys ------------------------------------------------------------------------------------------
local keyCache, prevDown = {}, {}
local function fkey(name)
    local k = keyCache[name]
    if not k then
        k = { KeyName = FName(name) }
        keyCache[name] = k
    end
    return k
end

local function liveDown(pc, name)
    return pc:IsInputKeyDown(fkey(name)) == true
end

-- Every key in the controls sheet and the class picker, read once per tick so every module sees the
-- same presses.
local watched = {}
for _, row in pairs(S.controls) do watched[row.key] = true end
for _, row in pairs(S.classes) do watched[row.picker_key] = true end
for _, row in pairs(S.deployables) do watched[row.deploy_key] = true end
local nowDown, edge = {}, {}

function core.beginTick()
    local pc = core.pc()
    for name in pairs(watched) do
        local d = pc and liveDown(pc, name) or false
        edge[name] = d and not prevDown[name]
        prevDown[name] = d
        nowDown[name] = d
    end
end

function core.down(name) return nowDown[name] == true end

-- True on the tick the key went down.
function core.pressed(name) return edge[name] == true end

-- Traces ----------------------------------------------------------------------------------------
local noColor = { R = 0, G = 0, B = 0, A = 0 }
function core.trace(from, to, ignore)
    local ctx = core.pawn() or core.pc()
    if not ctx then return nil end
    local hit = {}
    local wasHit = core.ksl():LineTraceSingle(ctx, from, to, 0, false, ignore or {}, 0, hit, true, noColor, noColor, 0.0)
    if not wasHit then return nil end
    local actor = UEHelpers.GetActorFromHitResult(hit)
    local bone = ""
    pcall(function() bone = hit.BoneName:ToString() end)
    return {
        actor = core.valid(actor) and actor or nil,
        point = core.v(hit.ImpactPoint),
        normal = core.v(hit.ImpactNormal),
        bone = bone,
        raw = hit,
    }
end

-- DRG stats -------------------------------------------------------------------------------------
-- rsf-extract writes data/drg_stats.lua from the player's own DRG install. Any stat it found replaces
-- the sheet's fallback value.
function core.loadDrgStats()
    local path = core.dataDir .. "/drg_stats.lua"
    local chunk = loadfile(path)
    if not chunk then
        core.log("no DRG stats at %s; using the sheets' fallback numbers", path)
        return { ok = false, gear = {}, error = "drg_stats.lua missing" }
    end
    local ok, stats = pcall(chunk)
    if not ok or type(stats) ~= "table" then
        core.log("DRG stats unreadable: %s", tostring(stats))
        return { ok = false, gear = {}, error = "drg_stats.lua unreadable" }
    end
    stats.gear = stats.gear or {}
    local n = 0
    for _, g in pairs(stats.gear) do
        for k in pairs(g) do if k ~= "_from" then n = n + 1 end end
    end
    core.log("DRG stats: ok=%s, %d values read from %s%s", tostring(stats.ok), n, tostring(stats.pak),
        stats.error and (" (" .. stats.error .. ")") or "")
    return stats
end

-- Sheet row merged with what the player's DRG files say.
function core.withDrg(row, drgStats)
    local merged, from = {}, {}
    for k, v in pairs(row) do merged[k] = v end
    local g = drgStats.gear[row.id]
    if g then
        for k, v in pairs(g) do
            if k ~= "_from" and merged[k] ~= nil and type(v) == "number" and v > 0 then
                merged[k] = v
                from[k] = g._from and g._from[k] or "drg"
            end
        end
    end
    merged._fromDrg = from
    return merged
end

return core
