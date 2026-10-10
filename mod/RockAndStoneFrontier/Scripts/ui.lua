-- sys_ui: the "Choose your dwarf" picker that opens when a run starts, and the ammo/grenade/turret HUD.
-- Built from engine UMG classes at runtime (UserWidget + WidgetTree + CanvasPanel + TextBlocks).
local core = require("core")
local S = core.S

local ui = {}
local widget, texts = nil, {}

local function cls(path)
    local c = StaticFindObject(path)
    if not core.valid(c) then error("missing class " .. path) end
    return c
end

local function newText(tree, canvas, name, anchorX, anchorY, x, y, size, align)
    local t = StaticConstructObject(cls("/Script/UMG.TextBlock"), tree, FName(name))
    local slot = canvas:AddChildToCanvas(t)
    slot:SetAnchors({ Minimum = { X = anchorX, Y = anchorY }, Maximum = { X = anchorX, Y = anchorY } })
    slot:SetAlignment({ X = anchorX, Y = anchorY })
    slot:SetPosition({ X = x, Y = y })
    slot:SetAutoSize(true)
    pcall(function()
        local f = t.Font
        f.Size = size
        t:SetFont(f)
    end)
    pcall(function() t:SetJustification(align or 0) end)
    pcall(function() t:SetShadowOffset({ X = 2, Y = 2 }) end)
    pcall(function() t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
    t:SetText(FText(""))
    return t
end

local function build()
    local gi = FindFirstOf("GameInstance")
    if not core.valid(gi) then error("no GameInstance yet") end
    local w = StaticConstructObject(cls("/Script/UMG.UserWidget"), gi, FName("RSF_Overlay"))
    local tree = StaticConstructObject(cls("/Script/UMG.WidgetTree"), w, FName("RSF_Tree"))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree, FName("RSF_Canvas"))
    tree.RootWidget = canvas
    texts.title = newText(tree, canvas, "RSF_Title", 0.5, 0.3, 0, 0, 40, 1)
    texts.options = newText(tree, canvas, "RSF_Options", 0.5, 0.3, 0, 70, 24, 1)
    texts.weapon = newText(tree, canvas, "RSF_Weapon", 1.0, 1.0, -40, -110, 26, 2)
    texts.ammo = newText(tree, canvas, "RSF_Ammo", 1.0, 1.0, -40, -70, 30, 2)
    texts.gear = newText(tree, canvas, "RSF_Gear", 1.0, 1.0, -40, -30, 20, 2)
    texts.hit = newText(tree, canvas, "RSF_Hit", 0.5, 0.5, 30, -30, 22, 0)
    texts.note = newText(tree, canvas, "RSF_Note", 0.0, 1.0, 40, -30, 16, 0)
    pcall(function() w:SetOwningPlayer(core.pc()) end)
    w:AddToViewport(50)
    widget = w
    core.log("overlay ready")
end

function ui.ensure()
    if widget and core.valid(widget) then return true end
    widget = nil
    core.try("ui build", build)
    return widget ~= nil
end

function ui.drop()
    if widget and core.valid(widget) then pcall(function() widget:RemoveFromParent() end) end
    widget, texts = nil, {}
end

local function set(name, s, color)
    local t = texts[name]
    if not t or not core.valid(t) then return end
    pcall(function() t:SetText(FText(s)) end)
    if color then
        pcall(function() t:SetColorAndOpacity({ SpecifiedColor = { R = color[1], G = color[2], B = color[3], A = 1 }, ColorUseRule = 0 }) end)
    end
end

function ui.showPicker(drgOk)
    if not ui.ensure() then return end
    set("title", core.tuning.picker_title, { 1, 0.85, 0.3 })
    local lines = {}
    for _, id in ipairs(S.classes_order) do
        local c = S.classes[id]
        local key = c.picker_key:gsub("One", "1"):gsub("Two", "2"):gsub("Three", "3"):gsub("Four", "4")
        table.insert(lines, string.format("[%s]  %s  -  %s + %s, %s%s", key, c.display_name,
            S.weapons[c.primary].display_name, S.weapons[c.secondary].display_name,
            S.grenades[c.grenade].display_name,
            c.deployable ~= "none" and (", " .. S.deployables[c.deployable].display_name) or ""))
    end
    set("options", table.concat(lines, "\n"), { 1, 1, 1 })
    set("weapon", ""); set("ammo", ""); set("gear", "")
    set("note", drgOk and "Stats read from your Deep Rock Galactic install" or
        "Deep Rock Galactic stats not found - using built-in numbers", { 0.8, 0.8, 0.8 })
end

function ui.hidePicker()
    set("title", ""); set("options", "")
end

local hitUntil = 0
function ui.hit(amount, now)
    set("hit", string.format("%d", math.floor(amount + 0.5)), { 1, 0.9, 0.3 })
    hitUntil = now + 0.35
end

function ui.message(s, now)
    set("hit", s, { 0.7, 0.9, 1 })
    hitUntil = now + 1.5
end

function ui.hud(loadout, turrets, turretAmmo, now)
    if not ui.ensure() then return end
    local w = loadout.weapon()
    if not w then return end
    local c = loadout.class.hud_color
    set("weapon", string.format("%s  -  %s", loadout.class.display_name, w.display_name), c)
    if w.reloadDone then
        set("ammo", string.format("RELOADING   %d", w.reserve), { 1, 0.6, 0.3 })
    else
        set("ammo", string.format("%d / %d", w.clip, w.reserve), { 1, 1, 1 })
    end
    local g = loadout.grenade
    local line = string.format("[G] %s x%d", g.display_name, g.left)
    if loadout.deployable then
        local d = loadout.deployable
        if turrets > 0 then
            line = line .. string.format("    %s: %d rounds", d.display_name, turretAmmo)
        else
            line = line .. string.format("    [T] %s", d.display_name)
        end
    end
    set("gear", line .. "    [1][2] swap  [R] reload  [F6] class", { 0.85, 0.85, 0.85 })
    if now > hitUntil then set("hit", "") end
end

return ui
