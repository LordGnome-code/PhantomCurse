-- PhantomCurse: click-to-cleanse window for WoW: Forever (12.x UI engine).
--
-- How it works on this client:
--  * Each group member gets a secure button whose clicks cast your dispel on
--    that unit. Secure buttons cannot be created, moved, shown or re-bound in
--    combat, so every possible slot is built up front and the game itself
--    shows/hides them through visibility state drivers.
--  * Aura details are "secret values" in combat, so addon code cannot read a
--    debuff's type. Instead the client is asked "does this unit have a debuff
--    I can dispel?" through an aura filter, and the debuff type colour is
--    passed straight to the texture without being inspected.

local ADDON = ...

local BTN_W, BTN_H, PAD, HEADER_H = 96, 18, 2, 16
local RAID_ROWS = 10
local FILTER = "HARMFUL|RAID_PLAYER_DISPELLABLE"
local FALLBACK_FILTER = "HARMFUL|RAID"

local issecret = issecretvalue or function() return false end

local TYPE_COLORS = {
    Magic   = { 0.20, 0.60, 1.00 },
    Curse   = { 0.60, 0.00, 1.00 },
    Disease = { 0.60, 0.40, 0.00 },
    Poison  = { 0.00, 0.60, 0.00 },
}
local DEFAULT_COLOR = { 1.00, 0.10, 0.10 }

-- Candidate dispels per class (spell IDs). Whichever ones your character
-- actually knows are used, in this order: left click, right click, middle
-- click, shift+left click. Add IDs here if Forever introduces new ones.
local CLASS_SPELLS = {
    PRIEST  = { 527, 528, 552, 213634 },          -- Dispel Magic/Purify, Cure Disease, Abolish Disease, Purify Disease
    PALADIN = { 4987, 1152, 213644 },             -- Cleanse, Purify, Cleanse Toxins
    DRUID   = { 88423, 2782, 2893, 8946 },        -- Nature's Cure, Remove Curse/Corruption, Abolish Poison, Cure Poison
    SHAMAN  = { 77130, 51886, 526, 2870 },        -- Purify Spirit, Cleanse Spirit, Cure Poison, Cure Disease
    MAGE    = { 475 },                            -- Remove (Lesser) Curse
    MONK    = { 115450, 218164 },                 -- Detox
    EVOKER  = { 360823, 365585, 374251 },         -- Naturalize, Expunge, Cauterizing Flame
    WARLOCK = { 89808 },                          -- Singe Magic (pet)
}

local CLICKS = {
    { prefix = "",       suffix = "1", label = "Left click" },
    { prefix = "",       suffix = "2", label = "Right click" },
    { prefix = "",       suffix = "3", label = "Middle click" },
    { prefix = "shift-", suffix = "1", label = "Shift + left click" },
}

local db
local buttons, byUnit = {}, {}
local activeSpells = {}
local pending = false          -- secure work postponed until combat ends
local lastSound = 0
local curve

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

local function FindSpells()
    local found, seen = {}, {}
    local _, class = UnitClass("player")
    for _, id in ipairs(CLASS_SPELLS[class] or {}) do
        if IsKnown(id) then
            local name = SpellName(id)
            if name and not seen[name] then
                seen[name] = true
                found[#found + 1] = name
                if #found == #CLICKS then break end
            end
        end
    end
    return found
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "PhantomCurseFrame", UIParent, "BackdropTemplate")
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
title:SetPoint("CENTER")
title:SetText("PhantomCurse")
title:SetTextColor(0.75, 0.6, 1)

header:SetScript("OnDragStart", function()
    if db and db.locked then return end
    if InCombatLockdown() then return end -- window holds secure buttons
    frame:StartMoving()
end)
header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    if db then
        local point, _, relPoint, x, y = frame:GetPoint(1)
        db.pos = { point, relPoint, x, y }
    end
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
    GameTooltip:AddLine("Drag to move. /pc for options.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
header:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Debuff detection
---------------------------------------------------------------------------
local function BuildCurve()
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return end
    local ok, c = pcall(function()
        local cv = C_CurveUtil.CreateColorCurve()
        if Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
            cv:SetType(Enum.LuaCurveType.Step)
        end
        cv:AddPoint(0, CreateColor(1.0, 0.1, 0.1, 1))  -- none
        cv:AddPoint(1, CreateColor(0.2, 0.6, 1.0, 1))  -- magic
        cv:AddPoint(2, CreateColor(0.6, 0.0, 1.0, 1))  -- curse
        cv:AddPoint(3, CreateColor(0.6, 0.4, 0.0, 1))  -- disease
        cv:AddPoint(4, CreateColor(0.0, 0.6, 0.0, 1))  -- poison
        cv:AddPoint(5, CreateColor(1.0, 0.1, 0.1, 1))  -- anything else
        return cv
    end)
    if ok then curve = c end
end

local function FindDispellable(unit)
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, 1, FILTER)
    if ok then return aura end
end

-- Colours the texture by debuff type. The colour may be a secret value, so it
-- is handed to SetVertexColor without being read.
local function ColorGlow(tex, unit, aura)
    if curve and C_UnitAuras.GetAuraDispelTypeColor then
        local ok = pcall(function()
            local c = C_UnitAuras.GetAuraDispelTypeColor(unit, aura.auraInstanceID, curve)
            tex:SetVertexColor(c:GetRGB())
        end)
        if ok then return end
    end
    local c = DEFAULT_COLOR
    local dtype = aura.dispelName
    if dtype and not issecret(dtype) and TYPE_COLORS[dtype] then
        c = TYPE_COLORS[dtype]
    end
    tex:SetVertexColor(c[1], c[2], c[3])
end

local function UpdateButton(b)
    local unit = b.unit
    if not UnitExists(unit) then
        b.afflicted = false
        b.glow:Hide()
        return
    end

    b.name:SetText(GetUnitName(unit, false) or unit)
    local _, class = UnitClass(unit)
    local cc = class and not issecret(class) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if cc then
        b.name:SetTextColor(cc.r, cc.g, cc.b)
    else
        b.name:SetTextColor(0.9, 0.9, 0.9)
    end

    local aura = FindDispellable(unit)
    if aura then
        ColorGlow(b.glow, unit, aura)
        b.glow:Show()
        if not b.afflicted then
            b.afflicted = true
            if db and db.sound and GetTime() - lastSound > 2 then
                lastSound = GetTime()
                PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
            end
        end
    else
        b.afflicted = false
        b.glow:Hide()
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

    local glow = b:CreateTexture(nil, "BORDER")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\WHITE8x8")
    glow:SetAlpha(0.8)
    glow:Hide()
    b.glow = glow

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)

    local name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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

-- Everything that touches secure frames. Postponed while in combat.
local function SecureRefresh()
    if InCombatLockdown() then
        pending = true
        return
    end
    pending = false
    ApplySpells()
    ResizeWindow()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function ResetPosition()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", -300, 100)
    db.pos = nil
end

SLASH_PHANTOMCURSE1 = "/phantomcurse"
SLASH_PHANTOMCURSE2 = "/pc"
SlashCmdList.PHANTOMCURSE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "lock" then
        db.locked = not db.locked
        Print(db.locked and "window locked." or "window unlocked.")
    elseif msg == "sound" then
        db.sound = not db.sound
        Print("alert sound " .. (db.sound and "on." or "off."))
    elseif msg == "reset" or msg == "show" or msg == "hide" or msg == "toggle" then
        if InCombatLockdown() then
            Print("can't do that in combat.")
            return
        end
        if msg == "reset" then
            ResetPosition()
            Print("position reset.")
        else
            local show = msg == "show" or (msg == "toggle" and not frame:IsShown())
            frame:SetShown(show)
            db.hidden = not show
        end
    elseif msg == "spells" then
        if #activeSpells == 0 then
            Print("no dispel spell found for your class.")
        else
            for i, name in ipairs(activeSpells) do
                Print(CLICKS[i].label .. ": " .. name)
            end
        end
    else
        Print("commands: /pc toggle | show | hide | lock | sound | reset | spells")
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
        db = PhantomCurseDB
        if db.sound == nil then db.sound = true end
        if db.pos then
            frame:ClearAllPoints()
            frame:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
        end
        if db.hidden then frame:Hide() end

    elseif event == "PLAYER_LOGIN" then
        db = db or {}
        -- Use the plain raid filter if this client rejects the newer one.
        if not pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, FILTER) then
            FILTER = FALLBACK_FILTER
        end
        BuildCurve()
        CreateButtons()
        SecureRefresh()
        UpdateAll()

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
