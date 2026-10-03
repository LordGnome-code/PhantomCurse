-- PhantomCurse: click-to-cleanse window for WoW: Forever (12.x UI engine).
--
-- How it works on this client:
--  * Each group member gets a secure button whose clicks cast your dispel on
--    that unit. Secure buttons cannot be created, moved, shown or re-bound in
--    combat, so every possible slot is built up front and the game itself
--    shows/hides them through visibility state drivers.
--  * The window's own visibility (closed, hide out of combat, hide when solo)
--    is also a state driver, so it can appear the instant combat starts.
--  * Aura details are "secret values" in combat, so addon code cannot read a
--    debuff's type. Instead the client is asked "does this unit have a debuff
--    I can dispel?" through an aura filter, and the debuff type colour is
--    passed straight to the texture without being inspected.

local ADDON = ...

local BTN_W, BTN_H, PAD, HEADER_H = 120, 18, 2, 16
local RAID_ROWS = 10
local FILTER = "HARMFUL|RAID_PLAYER_DISPELLABLE"
local filterOK = true

local issecret = issecretvalue or function() return false end

local TYPE_COLORS = {
    Magic   = { 0.20, 0.60, 1.00 },
    Curse   = { 0.60, 0.00, 1.00 },
    Disease = { 0.60, 0.40, 0.00 },
    Poison  = { 0.00, 0.60, 0.00 },
}
local DEFAULT_COLOR = { 1.00, 0.10, 0.10 }

-- Candidate dispels per class: spell ID, English name, and the debuff types
-- it removes. A spell counts as known if either the ID or the name is found
-- in your spellbook. Whichever ones you know are used, in this order:
-- left click, right click, middle click, shift+left click.
local CLASS_SPELLS = {
    PRIEST = {
        { 527,    "Dispel Magic",       "Magic" },
        { 528,    "Cure Disease",       "Disease" },
        { 552,    "Abolish Disease",    "Disease" },
        { 213634, "Purify Disease",     "Disease" },
    },
    PALADIN = {
        { 4987,   "Cleanse",            "Magic", "Poison", "Disease" },
        { 1152,   "Purify",             "Poison", "Disease" },
        { 213644, "Cleanse Toxins",     "Poison", "Disease" },
    },
    DRUID = {
        { 88423,  "Nature's Cure",      "Magic", "Curse", "Poison" },
        { 2782,   "Remove Curse",       "Curse" },
        { 2893,   "Abolish Poison",     "Poison" },
        { 8946,   "Cure Poison",        "Poison" },
    },
    SHAMAN = {
        { 77130,  "Purify Spirit",      "Magic", "Curse" },
        { 51886,  "Cleanse Spirit",     "Curse" },
        { 526,    "Cure Poison",        "Poison" },
        { 2870,   "Cure Disease",       "Disease" },
    },
    MAGE = {
        { 475,    "Remove Lesser Curse", "Curse" },
        { 0,      "Remove Curse",       "Curse" },
    },
    MONK = {
        { 115450, "Detox",              "Magic", "Poison", "Disease" },
        { 218164, "Detox",              "Poison", "Disease" },
    },
    EVOKER = {
        { 360823, "Naturalize",         "Magic", "Poison" },
        { 365585, "Expunge",            "Poison" },
        { 374251, "Cauterizing Flame",  "Curse", "Poison", "Disease" },
    },
    WARLOCK = {
        { 89808,  "Singe Magic",        "Magic" },
    },
}

local TYPE_IDS = { Magic = 1, Curse = 2, Disease = 3, Poison = 4 }
local N_LAYERS = 12

local CLICKS = {
    { prefix = "",       suffix = "1", label = "Left click" },
    { prefix = "",       suffix = "2", label = "Right click" },
    { prefix = "",       suffix = "3", label = "Middle click" },
    { prefix = "shift-", suffix = "1", label = "Shift + left click" },
}

local DEFAULTS = {
    locked = false,
    sound = true,
    autoHide = false,
    hideSolo = false,
    classColors = true,
    pulse = true,
    hidden = false,
    scale = 1,
    alpha = 0.85,
}

local db = {}
for k, v in pairs(DEFAULTS) do db[k] = v end

local buttons, byUnit = {}, {}
local activeSpells = {}
local canDispel = {}           -- debuff types your known spells remove
local pending = false          -- secure work postponed until combat ends
local lastSound = 0
local curve                    -- debuff type -> colour
local maskCurve                -- same, but invisible for types you can't remove
local settings                 -- options window, built on first use

local function Print(msg)
    print("|cff9d7dffPhantomCurse|r: " .. msg)
end

---------------------------------------------------------------------------
-- Spell detection
---------------------------------------------------------------------------
local function IsKnown(id)
    local ok, known
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok and known then return true end
    end
    if IsPlayerSpell then
        ok, known = pcall(IsPlayerSpell, id)
        if ok and known then return true end
    end
    if IsSpellKnown then
        ok, known = pcall(IsSpellKnown, id)
        if ok and known then return true end
        ok, known = pcall(IsSpellKnown, id, true) -- pet spell
        if ok and known then return true end
    end
    return false
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(id)
    elseif GetSpellInfo then
        return (GetSpellInfo(id))
    end
end

local function KnownByName(name)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        return ok and info ~= nil
    elseif GetSpellInfo then
        return GetSpellInfo(name) ~= nil
    end
    return false
end

local function FindSpells()
    local found, seen = {}, {}
    wipe(canDispel)
    local _, class = UnitClass("player")
    for _, entry in ipairs(CLASS_SPELLS[class] or {}) do
        local castName
        if entry[1] > 0 and IsKnown(entry[1]) then
            castName = SpellName(entry[1]) or entry[2]
        elseif KnownByName(entry[2]) then
            castName = entry[2]
        end
        if castName then
            for i = 3, #entry do canDispel[entry[i]] = true end
            if not seen[castName] and #found < #CLICKS then
                seen[castName] = true
                found[#found + 1] = castName
            end
        end
    end
    return found
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "PhantomCurseFrame", UIParent, "SecureHandlerBaseTemplate,BackdropTemplate")
frame:SetSize(BTN_W + PAD * 2, HEADER_H + BTN_H + PAD * 2)
frame:SetPoint("CENTER", UIParent, "CENTER", -300, 100)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
frame:SetBackdropColor(0.05, 0.03, 0.08, 0.85)
frame:SetBackdropBorderColor(0.45, 0.30, 0.75, 1)

local header = CreateFrame("Frame", nil, frame)
header:SetPoint("TOPLEFT")
header:SetPoint("TOPRIGHT")
header:SetHeight(HEADER_H)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("LEFT", 5, 0)
title:SetText("PhantomCurse")
title:SetTextColor(0.75, 0.6, 1)

header:SetScript("OnDragStart", function()
    if db.locked then return end
    if InCombatLockdown() then return end -- window holds secure buttons
    frame:StartMoving()
end)
header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    db.pos = { point, relPoint, x, y }
end)
header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("PhantomCurse")
    if #activeSpells == 0 then
        GameTooltip:AddLine("No dispel spell found. Clicking targets the player.", 1, 0.5, 0.5, true)
    else
        for i, name in ipairs(activeSpells) do
            GameTooltip:AddDoubleLine(CLICKS[i].label, name, 1, 1, 1, 0.6, 1, 0.6)
        end
    end
    GameTooltip:AddLine("Drag to move. /pc for commands.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
header:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Debuff detection
---------------------------------------------------------------------------
-- mask = true makes every type you cannot remove fully transparent, so a
-- texture coloured through the curve only shows for removable debuffs. This
-- is how the highlight works in combat, when the type itself is unreadable.
local function MakeCurve(mask)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return end
    local ok, c = pcall(function()
        local cv = C_CurveUtil.CreateColorCurve()
        if Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
            cv:SetType(Enum.LuaCurveType.Step)
        end
        local other = mask and 0 or 1
        cv:AddPoint(0, CreateColor(1.0, 0.1, 0.1, other))       -- no type
        for dtype, id in pairs(TYPE_IDS) do
            local col = TYPE_COLORS[dtype]
            local a = (not mask or canDispel[dtype]) and 1 or 0
            cv:AddPoint(id, CreateColor(col[1], col[2], col[3], a))
        end
        cv:AddPoint(5, CreateColor(1.0, 0.1, 0.1, other))       -- anything else
        return cv
    end)
    if ok then return c end
end

local function BuildCurves()
    curve = curve or MakeCurve(false)
    maskCurve = MakeCurve(true)
end

-- Returns a debuff on the unit that your class can remove, or nil.
local function FindDispellable(unit)
    -- 1) Let the client decide (works in combat, when details are secret).
    if filterOK then
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, 1, FILTER)
        if ok and aura then return aura end
    end
    -- 2) Read debuff types ourselves and match them against the types your
    --    known spells remove (only possible while the details are readable).
    local ok, found = pcall(function()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then return nil end
            local dtype = aura.dispelName
            if dtype and not issecret(dtype) and canDispel[dtype] then
                return aura
            end
        end
    end)
    if ok then return found end
end

-- Colours the texture by debuff type. The colour may be a secret value, so it
-- is handed to SetVertexColor without being read.
local function ColorGlow(tex, unit, aura)
    if aura and curve and C_UnitAuras.GetAuraDispelTypeColor then
        local ok = pcall(function()
            local c = C_UnitAuras.GetAuraDispelTypeColor(unit, aura.auraInstanceID, curve)
            tex:SetVertexColor(c:GetRGB())
        end)
        if ok then return end
    end
    local c = DEFAULT_COLOR
    local dtype = aura and aura.dispelName
    if dtype and not issecret(dtype) and TYPE_COLORS[dtype] then
        c = TYPE_COLORS[dtype]
    end
    tex:SetVertexColor(c[1], c[2], c[3])
end

local function HideLayers(b)
    for i = 1, N_LAYERS do b.layers[i]:Hide() end
end

-- One texture per debuff, coloured through the mask curve: removable types
-- show in their colour, everything else is transparent. Nothing is read here,
-- so it keeps working when aura details are secret.
local function UpdateLayers(b, unit)
    if not (maskCurve and C_UnitAuras.GetAuraDispelTypeColor) then
        HideLayers(b)
        return false
    end
    local n = 0
    pcall(function()
        for i = 1, N_LAYERS do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            local tex = b.layers[i]
            local ok = pcall(function()
                local c = C_UnitAuras.GetAuraDispelTypeColor(unit, aura.auraInstanceID, maskCurve)
                tex:SetVertexColor(c:GetRGBA())
            end)
            tex:SetShown(ok)
            n = i
        end
    end)
    for i = n + 1, N_LAYERS do b.layers[i]:Hide() end
    return n > 0
end

local function SetEdges(b, on)
    for _, e in ipairs(b.edges) do e:SetShown(on) end
end

local function ClearHighlight(b)
    b.afflicted = false
    b.pulse:Stop()
    b.glow:Hide()
    SetEdges(b, false)
    HideLayers(b)
end

local function UpdateButton(b)
    local unit = b.unit
    if not UnitExists(unit) then
        ClearHighlight(b)
        return
    end

    b.name:SetText(GetUnitName(unit, false) or unit)

    local aura = FindDispellable(unit)
    local testing = b.testUntil and GetTime() < b.testUntil
    local detected = aura or testing
    local layered = false

    if detected then
        HideLayers(b)
        ColorGlow(b.glow, unit, aura)
        b.glow:Show()
        SetEdges(b, true)
        b.name:SetTextColor(1, 1, 1)
        if not b.afflicted then
            b.afflicted = true
            if db.sound and GetTime() - lastSound > 2 then
                lastSound = GetTime()
                PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
            end
        end
    else
        b.afflicted = false
        b.glow:Hide()
        SetEdges(b, false)
        layered = UpdateLayers(b, unit)
        local _, class = UnitClass(unit)
        local cc = db.classColors and class and not issecret(class)
            and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if cc then
            b.name:SetTextColor(cc.r, cc.g, cc.b)
        else
            b.name:SetTextColor(0.9, 0.9, 0.9)
        end
    end

    if (detected or layered) and db.pulse then
        if not b.pulse:IsPlaying() then b.pulse:Play() end
    else
        b.pulse:Stop()
    end
end

local function UpdateAll()
    for _, b in ipairs(buttons) do UpdateButton(b) end
end

---------------------------------------------------------------------------
-- Secure unit buttons
---------------------------------------------------------------------------
local function CreateUnitButton(unit, visibility)
    local b = CreateFrame("Button", "PhantomCurseButton_" .. unit, frame, "SecureActionButtonTemplate")
    b:SetSize(BTN_W, BTN_H)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("unit", unit)
    b.unit = unit

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.10, 0.16, 0.9)

    -- Highlight: coloured fill that pulses, plus a bright outline. The fill
    -- lives in its own frame so the whole thing can pulse together.
    local hlf = CreateFrame("Frame", nil, b)
    hlf:SetAllPoints()
    hlf:SetFrameLevel(b:GetFrameLevel() + 1)

    local glow = hlf:CreateTexture(nil, "BORDER")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\WHITE8x8")
    glow:SetAlpha(0.85)
    glow:Hide()
    b.glow = glow

    b.layers = {}
    for i = 1, N_LAYERS do
        local l = hlf:CreateTexture(nil, "BORDER")
        l:SetAllPoints()
        l:SetTexture("Interface\\Buttons\\WHITE8x8")
        l:SetAlpha(0.85)
        l:Hide()
        b.layers[i] = l
    end

    local pulse = hlf:CreateAnimationGroup()
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.4)
    fade:SetDuration(0.45)
    pulse:SetLooping("BOUNCE")
    b.pulse = pulse

    -- Text and outline sit above the fill.
    local top = CreateFrame("Frame", nil, b)
    top:SetAllPoints()
    top:SetFrameLevel(b:GetFrameLevel() + 2)

    b.edges = {}
    for i = 1, 4 do
        local e = top:CreateTexture(nil, "ARTWORK")
        e:SetColorTexture(1, 1, 1, 0.9)
        e:Hide()
        b.edges[i] = e
    end
    b.edges[1]:SetPoint("TOPLEFT");    b.edges[1]:SetPoint("TOPRIGHT");    b.edges[1]:SetHeight(1)
    b.edges[2]:SetPoint("BOTTOMLEFT"); b.edges[2]:SetPoint("BOTTOMRIGHT"); b.edges[2]:SetHeight(1)
    b.edges[3]:SetPoint("TOPLEFT");    b.edges[3]:SetPoint("BOTTOMLEFT");  b.edges[3]:SetWidth(1)
    b.edges[4]:SetPoint("TOPRIGHT");   b.edges[4]:SetPoint("BOTTOMRIGHT"); b.edges[4]:SetWidth(1)

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)

    local name = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", 4, 0)
    name:SetPoint("RIGHT", -4, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    b.name = name

    b:SetScript("OnShow", UpdateButton)
    RegisterStateDriver(b, "visibility", visibility)

    buttons[#buttons + 1] = b
    byUnit[unit] = b
    return b
end

local function Place(b, col, row)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", frame, "TOPLEFT",
        PAD + col * (BTN_W + PAD),
        -(HEADER_H + PAD + row * (BTN_H + PAD)))
end

local function CreateButtons()
    -- Solo / party: you plus party1-4 in one column.
    Place(CreateUnitButton("player", "[group:raid] hide; show"), 0, 0)
    for i = 1, 4 do
        local unit = "party" .. i
        Place(CreateUnitButton(unit, "[group:raid] hide; [@" .. unit .. ",exists] show; hide"), 0, i)
    end
    -- Raid: columns of ten.
    for i = 1, 40 do
        local unit = "raid" .. i
        local b = CreateUnitButton(unit, "[@" .. unit .. ",exists] show; hide")
        Place(b, math.floor((i - 1) / RAID_ROWS), (i - 1) % RAID_ROWS)
    end
end

local function ApplySpells()
    activeSpells = FindSpells()
    BuildCurves()
    for _, b in ipairs(buttons) do
        for i, click in ipairs(CLICKS) do
            local name = activeSpells[i]
            b:SetAttribute(click.prefix .. "type" .. click.suffix, name and "spell" or nil)
            b:SetAttribute(click.prefix .. "spell" .. click.suffix, name)
        end
        if #activeSpells == 0 then
            b:SetAttribute("type1", "target")
        end
    end
end

local function ResizeWindow()
    local cols, rows
    if IsInRaid() then
        local n = math.max(GetNumGroupMembers(), 1)
        cols = math.ceil(n / RAID_ROWS)
        rows = math.min(n, RAID_ROWS)
    else
        cols = 1
        rows = math.max(GetNumGroupMembers(), 1)
    end
    frame:SetSize(PAD + cols * (BTN_W + PAD), HEADER_H + PAD + rows * (BTN_H + PAD))
end

-- Hands window visibility to the game so it can change during combat.
local function ApplyVisibility()
    local driver
    if db.hidden then
        driver = "hide"
    else
        local conds = {}
        if db.autoHide then conds[#conds + 1] = "combat" end
        if db.hideSolo then conds[#conds + 1] = "group" end
        if #conds == 0 then
            driver = "show"
        else
            driver = "[" .. table.concat(conds, ",") .. "] show; hide"
        end
    end
    RegisterStateDriver(frame, "visibility", driver)
end

-- Everything that touches secure frames. Postponed while in combat.
local function SecureRefresh()
    if InCombatLockdown() then
        pending = true
        return
    end
    pending = false
    ApplySpells()
    ResizeWindow()
    frame:SetScale(db.scale or 1)
    ApplyVisibility()
end

local function ApplySettings()
    frame:SetBackdropColor(0.05, 0.03, 0.08, db.alpha or 0.85)
    UpdateAll()
    SecureRefresh()
end

local function ResetPosition()
    if InCombatLockdown() then
        Print("can't move the window in combat.")
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", -300, 100)
    db.pos = nil
end

local function TestHighlight()
    local b = byUnit[IsInRaid() and "raid1" or "player"]
    if not b then return end
    b.testUntil = GetTime() + 5
    b.afflicted = false -- so the alert sound plays too
    UpdateButton(b)
    C_Timer.After(5.1, UpdateAll)
    if not frame:IsShown() then
        Print("the window is hidden right now, so the test highlight can't be seen.")
    end
end

---------------------------------------------------------------------------
-- Settings window
---------------------------------------------------------------------------
local function BuildSettings()
    local f = CreateFrame("Frame", "PhantomCurseSettings", UIParent, "BackdropTemplate")
    f:SetSize(250, 372)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.05, 0.03, 0.08, 0.95)
    f:SetBackdropBorderColor(0.45, 0.30, 0.75, 1)
    tinsert(UISpecialFrames, "PhantomCurseSettings") -- Escape closes it
    f:Hide()

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", 0, -8)
    t:SetText("PhantomCurse Settings")
    t:SetTextColor(0.75, 0.6, 1)

    local x = CreateFrame("Button", nil, f)
    x:SetSize(16, 16)
    x:SetPoint("TOPRIGHT", -4, -4)
    local xt = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    xt:SetPoint("CENTER")
    xt:SetText("X")
    x:SetScript("OnClick", function() f:Hide() end)

    local y = -30
    f.checks = {}
    local function Check(label, key, invert)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", 10, y)
        local l = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        l:SetText(label)
        cb.key, cb.invert = key, invert
        cb:SetScript("OnClick", function(self)
            local v = self:GetChecked() and true or false
            if invert then v = not v end
            db[key] = v
            ApplySettings()
        end)
        f.checks[#f.checks + 1] = cb
        y = y - 24
    end

    Check("Show window", "hidden", true)
    Check("Lock position", "locked")
    Check("Hide when out of combat", "autoHide")
    Check("Hide when not in a group", "hideSolo")
    Check("Alert sound", "sound")
    Check("Pulse the highlight", "pulse")
    Check("Class-coloured names", "classColors")

    f.sliders = {}
    local function Slider(label, key, minV, maxV, step, fmt)
        y = y - 8
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 14, y)
        y = y - 16

        local s = CreateFrame("Slider", nil, f)
        s:SetOrientation("HORIZONTAL")
        s:SetSize(220, 14)
        s:SetPoint("TOPLEFT", 14, y)
        s:SetMinMaxValues(minV, maxV)
        s:SetValueStep(step)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        local track = s:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT")
        track:SetPoint("RIGHT")
        track:SetHeight(4)
        track:SetColorTexture(0.3, 0.25, 0.4, 1)
        s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

        s.key = key
        s.Refresh = function()
            l:SetText(label .. ": " .. fmt(db[key]))
        end
        s:SetScript("OnValueChanged", function(self, value)
            if self.loading then return end
            value = math.floor(value / step + 0.5) * step
            if db[key] == value then return end
            db[key] = value
            self.Refresh()
            ApplySettings()
        end)
        f.sliders[#f.sliders + 1] = s
        y = y - 20
    end

    local function pct(v) return math.floor((v or 1) * 100 + 0.5) .. "%" end
    Slider("Window scale", "scale", 0.6, 2, 0.05, pct)
    Slider("Background opacity", "alpha", 0, 1, 0.05, pct)

    y = y - 8
    local test = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    test:SetSize(108, 22)
    test:SetPoint("TOPLEFT", 12, y)
    test:SetText("Test highlight")
    test:SetScript("OnClick", TestHighlight)

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(108, 22)
    reset:SetPoint("LEFT", test, "RIGHT", 6, 0)
    reset:SetText("Reset position")
    reset:SetScript("OnClick", ResetPosition)

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 12, 8)
    note:SetPoint("BOTTOMRIGHT", -12, 8)
    note:SetJustifyH("LEFT")
    note:SetText("Show/hide and scale changes made in combat apply when combat ends.")

    f:SetScript("OnShow", function()
        for _, cb in ipairs(f.checks) do
            local v = db[cb.key] and true or false
            if cb.invert then v = not v end
            cb:SetChecked(v)
        end
        for _, s in ipairs(f.sliders) do
            s.loading = true
            s:SetValue(db[s.key] or DEFAULTS[s.key])
            s.loading = false
            s.Refresh()
        end
    end)

    return f
end

local function ToggleSettings()
    settings = settings or BuildSettings()
    settings:SetShown(not settings:IsShown())
end

---------------------------------------------------------------------------
-- Title bar buttons: settings cog and close
---------------------------------------------------------------------------
-- Close is a secure button so it can hide the window even in combat.
local close = CreateFrame("Button", "PhantomCurseClose", frame, "SecureHandlerClickTemplate")
close:SetSize(14, 14)
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -1)
close:SetFrameLevel(header:GetFrameLevel() + 2)
close:RegisterForClicks("AnyUp")
local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
closeText:SetPoint("CENTER")
closeText:SetText("X")
local closeHL = close:CreateTexture(nil, "HIGHLIGHT")
closeHL:SetAllPoints()
closeHL:SetColorTexture(1, 0.3, 0.3, 0.35)
SecureHandlerSetFrameRef(close, "main", frame)
close:SetAttribute("_onclick", [[ self:GetFrameRef("main"):Hide() ]])
close:HookScript("OnClick", function()
    db.hidden = true
    SecureRefresh()
    Print("window closed. Type /pc show (or /pc config) to bring it back.")
end)
close:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Close")
    GameTooltip:AddLine("/pc show brings it back.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
close:HookScript("OnLeave", function() GameTooltip:Hide() end)

local cog = CreateFrame("Button", nil, header)
cog:SetSize(14, 14)
cog:SetPoint("RIGHT", close, "LEFT", -2, 0)
cog:SetFrameLevel(header:GetFrameLevel() + 2)
cog:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
local cogHL = cog:CreateTexture(nil, "HIGHLIGHT")
cogHL:SetAllPoints()
cogHL:SetColorTexture(1, 1, 1, 0.25)
cog:SetScript("OnClick", ToggleSettings)
cog:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Settings")
    GameTooltip:Show()
end)
cog:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Debug()
    local _, class = UnitClass("player")
    local types = {}
    for t in pairs(canDispel) do types[#types + 1] = t end
    Print("class " .. tostring(class)
        .. " | spells: " .. (#activeSpells > 0 and table.concat(activeSpells, ", ") or "NONE FOUND")
        .. " | removes: " .. (#types > 0 and table.concat(types, ", ") or "nothing"))
    Print("game filter " .. (filterOK and "ok" or "rejected")
        .. " | colour curve " .. (curve and "ok" or "missing")
        .. " | mask curve " .. (maskCurve and "ok" or "missing")
        .. " | in combat: " .. tostring(InCombatLockdown() and true or false))
    local okF, hit = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, FILTER)
    Print("game says you have something you can remove: " .. ((okF and hit) and "yes" or "no"))
    local count = 0
    pcall(function()
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HARMFUL")
            if not a then break end
            count = i
            local n, d = a.name, a.dispelName
            if issecret(n) then n = "(secret)" end
            if issecret(d) then d = "(secret)" elseif d == nil or d == "" then d = "no type" end
            Print("  debuff " .. i .. ": " .. tostring(n) .. " - " .. tostring(d))
        end
    end)
    if count == 0 then Print("  no debuffs on you right now.") end
end

local function SetHidden(hidden)
    db.hidden = hidden
    SecureRefresh()
    if InCombatLockdown() then
        Print("that will apply when combat ends.")
    end
end

SLASH_PHANTOMCURSE1 = "/phantomcurse"
SLASH_PHANTOMCURSE2 = "/pc"
SlashCmdList.PHANTOMCURSE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "config" or msg == "options" or msg == "settings" then
        ToggleSettings()
    elseif msg == "show" then
        SetHidden(false)
    elseif msg == "hide" then
        SetHidden(true)
    elseif msg == "toggle" then
        SetHidden(not db.hidden)
    elseif msg == "lock" then
        db.locked = not db.locked
        Print(db.locked and "window locked." or "window unlocked.")
    elseif msg == "sound" then
        db.sound = not db.sound
        Print("alert sound " .. (db.sound and "on." or "off."))
    elseif msg == "combat" then
        db.autoHide = not db.autoHide
        SecureRefresh()
        Print("hide out of combat " .. (db.autoHide and "on." or "off."))
    elseif msg == "reset" then
        ResetPosition()
    elseif msg == "test" then
        TestHighlight()
    elseif msg == "debug" then
        Debug()
    elseif msg == "spells" then
        if #activeSpells == 0 then
            Print("no dispel spell found for your class.")
        else
            for i, name in ipairs(activeSpells) do
                Print(CLICKS[i].label .. ": " .. name)
            end
        end
    else
        Print("commands: /pc config | show | hide | toggle | lock | sound | combat | reset | test | spells | debug")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")

local function SafeRegister(event)
    pcall(events.RegisterEvent, events, event) -- some events don't exist on every client
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        PhantomCurseDB = PhantomCurseDB or {}
        for k, v in pairs(DEFAULTS) do
            if PhantomCurseDB[k] == nil then PhantomCurseDB[k] = v end
        end
        db = PhantomCurseDB
        if db.pos then
            frame:ClearAllPoints()
            frame:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
        end

    elseif event == "PLAYER_LOGIN" then
        -- Skip the client-side filter if this client rejects it.
        filterOK = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, FILTER)
        CreateButtons()
        ApplySettings()

        SafeRegister("UNIT_AURA")
        SafeRegister("GROUP_ROSTER_UPDATE")
        SafeRegister("PLAYER_ENTERING_WORLD")
        SafeRegister("PLAYER_REGEN_ENABLED")
        SafeRegister("SPELLS_CHANGED")
        SafeRegister("PLAYER_TALENT_UPDATE")
        SafeRegister("PLAYER_SPECIALIZATION_CHANGED")
        SafeRegister("UNIT_PET")

    elseif event == "UNIT_AURA" then
        local b = byUnit[arg1]
        if b then UpdateButton(b) end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then SecureRefresh() end
        UpdateAll()

    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        SecureRefresh()
        UpdateAll()

    else -- spell / talent / pet changes
        SecureRefresh()
    end
end)
