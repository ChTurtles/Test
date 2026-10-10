-- sys_pure_dwarf: while you are a dwarf, Far Far West's own guns and spells stop answering their
-- buttons (their Enhanced Input actions are unmapped in memory, never on disk) and their props are
-- hidden. Choosing no class (or leaving the run) puts everything back.
local core = require("core")
local S = core.S

local pure = {}

local block = S.ffw_hooks.block_ffw_weapons.targets
local keep = S.ffw_hooks.keep_ffw_actions.targets
local hidePatterns = S.ffw_hooks.hide_ffw_weapon.targets

local function matchesAny(name, list)
    local lower = name:lower()
    for _, p in ipairs(list) do
        if lower:find(p:lower(), 1, true) then return true end
    end
    return false
end

local function shouldBlock(actionName)
    return matchesAny(actionName, block) and not matchesAny(actionName, keep)
end

local removed = {} -- { context, action, key } triples we unmapped, to restore later
local hidden = {}
local reported = false

-- Mappings live in DefaultKeyMappings.Mappings on UE 5.4+ and in Mappings before that.
local function mappingsOf(ctx)
    local arr
    pcall(function() arr = ctx.DefaultKeyMappings.Mappings end)
    if not arr or not pcall(function() return arr:GetArrayNum() end) then
        pcall(function() arr = ctx.Mappings end)
    end
    return arr
end

local function rebuild()
    pcall(function()
        local subsys = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
        if core.valid(subsys) then subsys:RequestRebuildControlMappings({}, 0) end
    end)
end

function pure.apply()
    local contexts = FindAllOf("InputMappingContext") or {}
    local seen, blockedNames = {}, {}
    for _, ctx in ipairs(contexts) do
        if core.valid(ctx) then
            local arr = mappingsOf(ctx)
            local toUnmap = {}
            if arr then
                pcall(function()
                    arr:ForEach(function(_, m)
                        local mapping = m:get()
                        local action = mapping.Action
                        if core.valid(action) then
                            local an = action:GetFName():ToString()
                            if not reported then seen[an] = true end
                            if shouldBlock(an) then
                                table.insert(toUnmap, { action = action, key = mapping.Key, name = an })
                            end
                        end
                    end)
                end)
            end
            for _, u in ipairs(toUnmap) do
                local ok = pcall(function() ctx:UnmapKey(u.action, u.key) end)
                if ok then
                    table.insert(removed, { ctx = ctx, action = u.action, key = { KeyName = u.key.KeyName } })
                    blockedNames[u.name] = true
                end
            end
        end
    end
    if not reported then
        reported = true
        local all = {}
        for n in pairs(seen) do table.insert(all, n) end
        table.sort(all)
        core.log("Far Far West input actions: %s", table.concat(all, ", "))
    end
    local b = {}
    for n in pairs(blockedNames) do table.insert(b, n) end
    table.sort(b)
    if #b > 0 then core.log("pure dwarf: unmapped %s", table.concat(b, ", ")) end
    rebuild()
    pure.hideProps()
end

function pure.hideProps()
    local pawn = core.pawn()
    if not pawn then return end
    pcall(function()
        local attached = {}
        pawn:GetAttachedActors(attached, true, true)
        for _, a in ipairs(attached) do
            local actor = type(a) == "userdata" and a.get and a:get() or a
            if core.valid(actor) then
                local cn = actor:GetClass():GetFName():ToString()
                if matchesAny(cn, hidePatterns) then
                    actor:SetActorHiddenInGame(true)
                    hidden[actor:GetAddress()] = actor
                end
            end
        end
    end)
end

function pure.restore()
    for _, r in ipairs(removed) do
        pcall(function()
            if core.valid(r.ctx) and core.valid(r.action) then r.ctx:MapKey(r.action, r.key) end
        end)
    end
    removed = {}
    for _, a in pairs(hidden) do
        if core.valid(a) then pcall(function() a:SetActorHiddenInGame(false) end) end
    end
    hidden = {}
    rebuild()
end

function pure.active() return #removed > 0 end

return pure
