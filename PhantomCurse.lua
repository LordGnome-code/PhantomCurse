-- PhantomCurse: click-to-cleanse window for WoW: Forever (12.x UI engine).
--
-- How it works on this client:
--  * Each group member gets a secure button whose clicks cast your dispel on
--    that unit. Secure buttons cannot be created, moved, shown or re-bound in
--    combat, so every possible slot is built up front and the game itself
--    shows/hides them through visibility state drivers.
--  * The window's own visibility (closed, hide out of combat, hide when solo)
--    is also a state driver, so it can appear the instant combat starts.
--  * In combat the client hides all aura data from addon code ("secret
--    values"), so an addon cannot see who has which debuff. The highlight is
--    therefore drawn by the game itself: every row holds an AuraContainer
--    with aura slots that only accept debuffs of the types your dispels
--    remove. The game shows a slot the moment a matching debuff lands and
--    hides it when it is gone, in or out of combat.
--  * Addon-side detection (reading debuff types directly) still runs for the
--    alert sound, and as a fallback on clients without AuraContainer.

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
-- it removes. A spell counts as known if its ID is in your spellbook, or (only
-- when that ID doesn't exist on this client) if its name is. Whichever ones
-- you know are used, in this order: left click, right click, middle click,
-- shift+left click.
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
        { 412113, "Remove Greater Curse", "Curse", "Magic" },
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
local TYPE_ORDER = { "Magic", "Curse", "Disease", "Poison" }
local N_LAYERS = 16

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
    allTypes = false,          -- highlight every typed debuff, removable or not
    onlyAfflicted = true,      -- Decursive-style: names only when removable
    scale = 1,
    alpha = 0.85,
}

local db = {}
for k, v in pairs(DEFAULTS) do db[k] = v end

local buttons, byUnit = {}, {}
local activeSpells = {}
local canDispel = {}           -- debuff types your known spells remove
local spellTypes = {}          -- per click: the debuff types that click's spell removes
local playerClass
local pending = false          -- secure work postponed until combat ends
local spellsDirty = true       -- spellbook needs rescanning on next secure refresh
local lastDriver               -- last window visibility driver registered
local lastSound = 0
local curve                    -- debuff type -> colour
local maskCurve                -- same, but invisible for types you can't remove
local settings                 -- options window, built on first use
local useContainers = true     -- game-drawn highlight available?
local containerError           -- why not, if it isn't
local flusher, Relayout        -- defined further down
local layoutDirty = false      -- lit rows need moving to the top (out of combat)

local function MarkLayout()
    layoutDirty = true
    if flusher then flusher:Show() end
end

local function Print(msg)
    print("|cff9d7dffPhantomCurse|r: " .. msg)
end

---------------------------------------------------------------------------
-- Spell detection
---------------------------------------------------------------------------
local function IsKnown(id)
    local ok, known
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook then
        local banks = Enum and Enum.SpellBookSpellBank
        for _, bank in ipairs({ banks and banks.Player or 0, banks and banks.Pet or 1 }) do
            ok, known = pcall(C_SpellBook.IsSpellKnownOrInSpellBook, id, bank, true)
            if ok and known then return true end
        end
    end
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
    if id <= 0 then return nil end
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(id)
    elseif GetSpellInfo then
        return (GetSpellInfo(id))
    end
end

-- Name lookup is only a fallback for IDs this client doesn't have. Without
-- that check, two spells sharing a name (Monk "Detox" is two different
-- spells) would both count as known and add types you can't remove.
local function KnownByName(name, id)
    local spellID
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        if not (ok and info) then return false end
        spellID = info.spellID
    elseif GetSpellInfo then
        local n, _, _, _, _, _, sid = GetSpellInfo(name)
        if not n then return false end
        spellID = sid
    else
        return false
    end
    if id > 0 and spellID and spellID ~= id and SpellName(id) then
        return false
    end
    return true
end

local function FindSpells()
    local found, seen = {}, {}
    wipe(canDispel)
    wipe(spellTypes)
    for _, entry in ipairs(CLASS_SPELLS[playerClass] or {}) do
        local castName
        if entry[1] > 0 and IsKnown(entry[1]) then
            castName = SpellName(entry[1]) or entry[2]
        elseif KnownByName(entry[2], entry[1]) then
            castName = entry[2]
        end
        if castName then
            local idx = seen[castName]
            if not idx and #found < #CLICKS then
                idx = #found + 1
                seen[castName] = idx
                found[idx] = castName
                spellTypes[idx] = {}
            end
            for i = 3, #entry do
                canDispel[entry[i]] = true
                if idx then spellTypes[idx][entry[i]] = true end
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

header.bg = header:CreateTexture(nil, "BACKGROUND")
header.bg:SetAllPoints()
header.bg:SetColorTexture(0.05, 0.03, 0.08, 0.85)
header.bg:Hide()

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
-- Is this debuff type one to highlight? Classes with no dispel at all get
-- nothing. If a dispel class's spells couldn't be detected, it falls back to
-- all four types rather than silently showing nothing.
local function Removable(dtype)
    if not TYPE_IDS[dtype] then return false end
    if db.allTypes or canDispel[dtype] then return true end
    return next(canDispel) == nil and CLASS_SPELLS[playerClass] ~= nil
end

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
        for _, dtype in ipairs(TYPE_ORDER) do
            local col = TYPE_COLORS[dtype]
            local a = (not mask or Removable(dtype)) and 1 or 0
            cv:AddPoint(TYPE_IDS[dtype], CreateColor(col[1], col[2], col[3], a))
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
            if dtype and not issecret(dtype) and Removable(dtype) then
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

-- IDs of every debuff on the unit. IDs are never secret, so this works in
-- combat. Tries the bulk call first, then walks the debuffs one by one.
local function HarmfulIDs(unit)
    if C_UnitAuras.GetUnitAuraInstanceIDs then
        local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, "HARMFUL")
        if ok and type(ids) == "table" and #ids > 0 then return ids, "bulk" end
    end
    local ids = {}
    pcall(function()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            ids[#ids + 1] = aura.auraInstanceID
        end
    end)
    return ids, "one by one"
end

local function HideLayers(b)
    for i = 1, N_LAYERS do
        b.layers[i]:Hide()
        b.layerNames[i]:Hide()
    end
end

-- Fallback highlight (no AuraContainer): one texture per debuff, coloured
-- through the mask curve: removable types show in their colour, everything
-- else is transparent. Nothing is read here, so it works with secret values.
local function UpdateLayers(b, unit, text)
    if not (maskCurve and C_UnitAuras.GetAuraDispelTypeColor) then
        HideLayers(b)
        return false
    end
    local n = 0
    local ids = HarmfulIDs(unit)
    pcall(function()
        for i = 1, math.min(#ids, N_LAYERS) do
            local id = ids[i]
            local tex, fs = b.layers[i], b.layerNames[i]
            local c
            local ok = pcall(function()
                c = C_UnitAuras.GetAuraDispelTypeColor(unit, id, maskCurve)
                tex:SetVertexColor(c:GetRGBA())
            end)
            tex:SetShown(ok)
            -- "Only when removable" mode: a copy of the name whose visibility
            -- follows the same hidden value as the fill.
            local okName = ok and db.onlyAfflicted and pcall(function()
                local _, _, _, a = c:GetRGBA()
                fs:SetText(text)
                fs:SetVertexColor(1, 1, 1, a)
            end)
            fs:SetShown(okName and true or false)
            n = i
        end
    end)
    for i = n + 1, N_LAYERS do
        b.layers[i]:Hide()
        b.layerNames[i]:Hide()
    end
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

---------------------------------------------------------------------------
-- Alert sound and click-through
---------------------------------------------------------------------------
local function PlayAlert()
    if not db.sound then return end
    local now = GetTime()
    if now - lastSound < 2 then return end
    lastSound = now
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
end

-- Is a name actually lit up on this row right now? With the game-drawn
-- highlight that means one of its aura slots is showing, which is exactly
-- what you see, so the sound and the clickable area can never disagree with
-- the window.
local function RowLit(b)
    if b.testUntil and GetTime() < b.testUntil then return true end
    if b.container then
        for _, btn in pairs(b.auraParts.btns) do
            -- IsVisible (not IsShown) so a slot inside a hidden parent doesn't count.
            local ok, lit = pcall(btn.IsVisible, btn)
            if ok and lit then return true end
        end
        return false
    end
    return b.afflicted and true or false
end

-- Rows never react to hovering (no highlight box, no mouseover capture).
-- Clicks are switched off for blank rows, but only out of combat: the game
-- doesn't allow it in combat, so every row is made clickable again the moment
-- combat starts, letting names that light up in combat be clicked.
local function SetRowClickable(b, on)
    if b.clickable == on or InCombatLockdown() then return end
    if not pcall(b.SetMouseClickEnabled, b, on) then
        pcall(b.EnableMouse, b, on)
    end
    pcall(b.SetMouseMotionEnabled, b, false)
    b.clickable = on
    MarkLayout() -- a row lit up or went blank: restack the names
end

-- Out of combat a row only takes clicks while a name is actually lit on it.
-- Hidden rows and rows with nobody in them are switched off too, so they
-- don't come back clickable before UpdateButton has looked at them.
local function UpdateClickable(b)
    if InCombatLockdown() then return end
    local on = not db.onlyAfflicted
        or (b:IsVisible() and UnitExists(b.unit) and RowLit(b))
    SetRowClickable(b, on and true or false)
end

-- Called when one of the game's aura slots on a row appears or disappears.
-- OnShow also fires when the window or row reappears, so the sound only plays
-- when the slot itself has just turned on and the row wasn't already lit.
local function SlotChanged(b, btn)
    local ok, own = pcall(btn.IsShown, btn)
    own = ok and own or false
    local fresh = own and not btn.pcWasShown
    btn.pcWasShown = own
    local wasLit = b.lit
    b.lit = RowLit(b)
    if fresh and not wasLit and btn:IsVisible() then
        PlayAlert()
    end
    UpdateClickable(b)
end

local function UpdateButton(b)
    -- Rows the game has hidden (party rows in a raid, empty raid slots, or
    -- the whole window) are skipped; OnShow refreshes them when they return.
    if not b:IsVisible() then return end

    local unit = b.unit
    if not UnitExists(unit) then
        ClearHighlight(b)
        UpdateClickable(b)
        return
    end

    local text = GetUnitName(unit, false) or unit
    b.displayName = text
    b.name:SetText(text)

    -- Rows with the game-drawn highlight don't need the addon's own scan.
    local aura = not b.container and FindDispellable(unit)
    local testing = b.testUntil and GetTime() < b.testUntil
    -- When the game draws the highlight, the addon only draws its own for
    -- the "Test highlight" button.
    local detected = testing or (not b.container and aura)
    local layered = false

    -- Names inside the game-drawn highlight. Only rewritten when they change,
    -- and only out of combat (the game locks those frames in combat).
    if b.auraParts and b.slotText ~= text and not InCombatLockdown() then
        for _, fs in pairs(b.auraParts.names) do
            pcall(fs.SetText, fs, text)
        end
        b.slotText = text
    end

    -- Fallback rows only; game-drawn rows play the sound from SlotChanged.
    if not b.container then
        if aura and not b.afflicted then PlayAlert() end
        b.afflicted = aura and true or false
    end

    if detected then
        HideLayers(b)
        ColorGlow(b.glow, unit, aura)
        b.glow:Show()
        SetEdges(b, true)
        b.name:SetTextColor(1, 1, 1)
    else
        b.glow:Hide()
        SetEdges(b, false)
        layered = not b.container and UpdateLayers(b, unit, text)
        local _, class = UnitClass(unit)
        local cc = db.classColors and class and not issecret(class)
            and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if cc then
            b.name:SetTextColor(cc.r, cc.g, cc.b)
        else
            b.name:SetTextColor(0.9, 0.9, 0.9)
        end
    end

    -- Display mode: in "only when removable" the row is blank unless afflicted.
    local showRow = detected or not db.onlyAfflicted
    b.bg:SetShown(showRow and true or false)
    b.name:SetShown(showRow and true or false)

    if (detected or layered) and db.pulse then
        if not b.pulse:IsPlaying() then b.pulse:Play() end
    else
        b.pulse:Stop()
    end

    UpdateClickable(b)
end

local function UpdateAll()
    for _, b in ipairs(buttons) do UpdateButton(b) end
end

---------------------------------------------------------------------------
-- Batched aura updates
---------------------------------------------------------------------------
-- UNIT_AURA can fire dozens of times per second in a raid, often several
-- times for the same unit in one frame. Units are collected and processed
-- once on the next frame, so each row is updated at most once per frame.
local dirty = {}
local flushAll = false
local stamp = 0

local function Touch(b)
    if b.stamp ~= stamp then
        b.stamp = stamp
        UpdateButton(b)
    end
end

flusher = CreateFrame("Frame")
flusher:Hide()
flusher:SetScript("OnUpdate", function(self)
    self:Hide()
    stamp = stamp + 1
    if flushAll then
        flushAll = false
        wipe(dirty)
        UpdateAll()
    else
        for unit in pairs(dirty) do
            local b = byUnit[unit]
            if b:IsVisible() then
                Touch(b)
            else
                -- e.g. "player" or "party2" while in a raid: their rows are hidden,
                -- so find the raid row showing the same person.
                for _, rb in ipairs(buttons) do
                    if rb:IsVisible() and UnitIsUnit(rb.unit, unit) then Touch(rb) end
                end
            end
        end
        wipe(dirty)
    end
    if layoutDirty and not InCombatLockdown() and Relayout then Relayout() end
end)

local function MarkDirty(unit)
    if not byUnit[unit] then return end -- target, nameplates, etc.
    dirty[unit] = true
    flusher:Show()
end

local function MarkAllDirty()
    flushAll = true
    flusher:Show()
end

---------------------------------------------------------------------------
-- Secure unit buttons
---------------------------------------------------------------------------
-- The game-drawn highlight has one aura slot per click (left, right, middle,
-- shift+left) plus a spare. Each slot only accepts the debuff types that
-- click's spell removes, so the letter on the highlight tells you which click
-- to use. A type is given to the first click that can remove it. The spare
-- slot takes whatever is left when "highlight all types" is on or no dispel
-- spell could be detected.
local N_SLOTS = 5
local SLOT_LETTERS = { "L", "R", "M", "S", "" }

local function LetterFor(slot)
    return #activeSpells > 1 and SLOT_LETTERS[slot] or ""
end

local function SlotTypeSets()
    local sets, keys, covered = {}, {}, {}
    for i = 1, N_SLOTS - 1 do
        local set, key = {}, ""
        for _, dtype in ipairs(TYPE_ORDER) do
            if spellTypes[i] and spellTypes[i][dtype] and not covered[dtype] then
                set[dtype] = true
                covered[dtype] = true
                key = key .. dtype
            end
        end
        sets[i], keys[i] = set, key
    end
    local set, key = {}, ""
    for _, dtype in ipairs(TYPE_ORDER) do
        if not covered[dtype] and Removable(dtype) then
            set[dtype] = true
            key = key .. dtype
        end
    end
    sets[N_SLOTS], keys[N_SLOTS] = set, key
    return sets, keys
end

-- Builds the game-drawn highlight for one row: an AuraContainer watching the
-- row's unit. Each slot's button fills the row and is shown/hidden by the
-- game, so it works in combat. Everything drawn inside it (fill, outline,
-- name, click letter) appears and disappears with it.
--
-- initializeFrame may run lazily, the first time a debuff actually lands,
-- which can be mid-combat. So it fills in the name, letter and pulse itself
-- from what is already known, instead of waiting for an out-of-combat update.
-- The game's aura frames sit on top of the row. Aura buttons normally take
-- the mouse (for tooltips), and the game can switch that back on whenever a
-- debuff appears. If they did, they would swallow the click meant for the
-- secure row underneath, so a lit name couldn't be clicked. Force them
-- click-through, and keep forcing it if anything turns the mouse back on.
local function MakeClickThrough(f)
    if f.pcForcing then return end
    f.pcForcing = true
    pcall(f.SetMouseClickEnabled, f, false)
    pcall(f.SetMouseMotionEnabled, f, false)
    pcall(f.EnableMouse, f, false)
    f.pcForcing = false
    if not f.pcHooked then
        f.pcHooked = true
        local function reForce(self, on)
            if on and not self.pcForcing then MakeClickThrough(self) end
        end
        for _, m in ipairs({ "EnableMouse", "SetMouseClickEnabled", "SetMouseMotionEnabled" }) do
            if f[m] then pcall(hooksecurefunc, f, m, reForce) end
        end
    end
end

local function AttachContainer(b)
    local ok, err = pcall(function()
        local c = CreateFrame("AuraContainer", nil, b, "CustomAuraContainerTemplate")
        c:SetAllPoints(b)
        c:SetFrameLevel(b:GetFrameLevel() + 3)
        c:SetUnit(b.unit)
        MakeClickThrough(c)

        local parts = { names = {}, letters = {}, pulses = {}, btns = {} }
        local sets, keys = SlotTypeSets()
        local styles = Enum and Enum.CustomAuraButtonDispelTypeTextureStyle
        local preserve = styles and styles.PreserveAsset or 3

        for slot = 1, N_SLOTS do
            c:AddAuraSlot("dispel" .. slot, "HARMFUL", {
                candidateFilters = { includeDispelTypes = sets[slot] },
                initializeFrame = function(btn)
                    btn:ClearAllPoints()
                    btn:SetAllPoints(c)
                    MakeClickThrough(btn) -- clicks must reach the row

                    -- Fill, tinted by the game in the debuff type's colour.
                    local fill = btn:CreateTexture(nil, "BACKGROUND")
                    fill:SetAllPoints()
                    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
                    fill:SetVertexColor(1, 0.1, 0.1)
                    pcall(btn.AddDispelTypeTexture, btn, fill, { style = preserve })

                    for i = 1, 4 do
                        local e = btn:CreateTexture(nil, "BORDER")
                        e:SetColorTexture(1, 1, 1, 0.9)
                        if i == 1 then e:SetPoint("TOPLEFT"); e:SetPoint("TOPRIGHT"); e:SetHeight(1)
                        elseif i == 2 then e:SetPoint("BOTTOMLEFT"); e:SetPoint("BOTTOMRIGHT"); e:SetHeight(1)
                        elseif i == 3 then e:SetPoint("TOPLEFT"); e:SetPoint("BOTTOMLEFT"); e:SetWidth(1)
                        else e:SetPoint("TOPRIGHT"); e:SetPoint("BOTTOMRIGHT"); e:SetWidth(1) end
                    end

                    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    fs:SetPoint("LEFT", 4, 0)
                    fs:SetPoint("RIGHT", -14, 0)
                    fs:SetJustifyH("LEFT")
                    fs:SetWordWrap(false)
                    fs:SetText(b.displayName or GetUnitName(b.unit, false) or "")
                    parts.names[slot] = fs

                    -- Which click removes it. Each slot's letter has its own
                    -- spot so two can show at once.
                    local letter = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    letter:SetPoint("RIGHT", -3 - (slot - 1) * 9, 0)
                    letter:SetTextColor(1, 1, 0.4)
                    letter:SetText(LetterFor(slot))
                    parts.letters[slot] = letter

                    local ag = fill:CreateAnimationGroup()
                    local fade = ag:CreateAnimation("Alpha")
                    fade:SetFromAlpha(1)
                    fade:SetToAlpha(0.4)
                    fade:SetDuration(0.45)
                    ag:SetLooping("BOUNCE")
                    if db.pulse then
                        pcall(btn.AddAuraShownAnimation, btn, ag)
                    end
                    parts.pulses[slot] = { btn = btn, ag = ag, on = db.pulse }

                    -- Sound and clickability follow this slot appearing.
                    parts.btns[slot] = btn
                    btn.pcWasShown = false
                    btn:HookScript("OnShow", function(self)
                        MakeClickThrough(self)
                        SlotChanged(b, self)
                    end)
                    btn:HookScript("OnHide", function(self) SlotChanged(b, self) end)
                    if btn:IsVisible() then SlotChanged(b, btn) end
                end,
            })
        end

        b.container = c
        b.auraParts = parts
        b.filterKeys = keys
    end)
    if not ok then
        b.container = nil
        useContainers = false
        containerError = tostring(err)
    end
end

-- Keeps the game-drawn highlight in step with your spells and settings.
-- Out of combat only: the game locks these frames while aura data is secret.
local function UpdateContainers()
    local sets, keys = SlotTypeSets()
    for _, b in ipairs(buttons) do
        if b.container then
            local parts = b.auraParts
            for slot = 1, N_SLOTS do
                if b.filterKeys[slot] ~= keys[slot] then
                    local ok = pcall(b.container.SetAuraSlotCandidateFilters, b.container,
                        "dispel" .. slot, { includeDispelTypes = sets[slot] })
                    if ok then b.filterKeys[slot] = keys[slot] end
                end
                local letter = parts.letters[slot]
                if letter then
                    pcall(letter.SetText, letter, LetterFor(slot))
                end
                local pulse = parts.pulses[slot]
                if pulse and pulse.on ~= db.pulse then
                    pcall(pulse.btn.RemoveAuraShownAnimation, pulse.btn, pulse.ag)
                    pcall(pulse.ag.Stop, pulse.ag)
                    if db.pulse then
                        pcall(pulse.btn.AddAuraShownAnimation, pulse.btn, pulse.ag)
                    end
                    pulse.on = db.pulse
                end
            end
        end
    end
end

-- Makes every row re-read its unit's debuffs. Needed when the group changes,
-- because "raid3" may now be a different person.
local function RefreshContainers()
    for _, b in ipairs(buttons) do
        if b.container then
            pcall(b.container.UpdateAllAuras, b.container)
        end
    end
end

local function CreateUnitButton(unit, visibility)
    local b = CreateFrame("Button", "PhantomCurseButton_" .. unit, frame, "SecureActionButtonTemplate")
    b:SetSize(BTN_W, BTN_H)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("unit", unit)
    b.unit = unit

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.10, 0.16, 0.9)
    b.bg = bg

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

    b.layerNames = {}
    for i = 1, N_LAYERS do
        local fs = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 4, 0)
        fs:SetPoint("RIGHT", -4, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:Hide()
        b.layerNames[i] = fs
    end

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

    -- No hover highlight, and no mouseover at all: blank rows stay invisible.
    pcall(b.SetMouseMotionEnabled, b, false)

    local name = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", 4, 0)
    name:SetPoint("RIGHT", -4, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    b.name = name

    if useContainers then AttachContainer(b) end

    b:SetScript("OnShow", UpdateButton)
    b:HookScript("OnHide", UpdateClickable)
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

-- Stacks lit names from the top, straight under the title bar, each new one
-- below the last. Every row keeps a slot of its own (lit first, then the
-- rest in group order) so nothing can ever overlap.
--
-- Secure rows can only be moved out of combat. In combat the game hides who
-- has which debuff and locks the rows in place, so a name that lights up
-- mid-fight shows in the slot it already had; the list restacks as soon as
-- combat ends.
local function Ordered(first, last)
    local lit, rest, gone = {}, {}, {}
    for i = first, last do
        local b = buttons[i]
        if not UnitExists(b.unit) then
            gone[#gone + 1] = b
        elseif db.onlyAfflicted and RowLit(b) then
            lit[#lit + 1] = b
        else
            rest[#rest + 1] = b
        end
    end
    for _, b in ipairs(rest) do lit[#lit + 1] = b end
    for _, b in ipairs(gone) do lit[#lit + 1] = b end
    return lit
end

Relayout = function()
    if InCombatLockdown() then layoutDirty = true return end
    layoutDirty = false
    if #buttons == 0 then return end
    -- buttons 1-5: player + party1-4; buttons 6-45: raid1-40
    for i, b in ipairs(Ordered(1, 5)) do Place(b, 0, i - 1) end
    for i, b in ipairs(Ordered(6, #buttons)) do
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
    if driver ~= lastDriver then
        lastDriver = driver
        RegisterStateDriver(frame, "visibility", driver)
    end
end

-- Everything that touches secure frames. Postponed while in combat. The
-- spellbook is only rescanned when something actually changed it.
local function SecureRefresh()
    if InCombatLockdown() then
        pending = true
        return
    end
    pending = false
    if spellsDirty then
        spellsDirty = false
        ApplySpells()
    end
    UpdateContainers()
    ResizeWindow()
    frame:SetScale(db.scale or 1)
    ApplyVisibility()
    MarkLayout() -- group or display mode changed: restack on the next frame
end

local function ApplySettings()
    -- In "only when removable" mode the window body is see-through and only
    -- the title bar keeps a background.
    BuildCurves()
    local compact = db.onlyAfflicted
    frame:SetBackdropColor(0.05, 0.03, 0.08, compact and 0 or (db.alpha or 0.85))
    frame:SetBackdropBorderColor(0.45, 0.30, 0.75, compact and 0 or 1)
    header.bg:SetShown(compact and true or false)
    SecureRefresh()
    MarkAllDirty()
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
    if not frame:IsShown() then
        Print("the window is hidden right now, so the test highlight can't be seen.")
        return
    end
    b.testUntil = GetTime() + 5
    if db.sound then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    end
    UpdateButton(b)
    C_Timer.After(5.1, MarkAllDirty)
end

---------------------------------------------------------------------------
-- Settings window
---------------------------------------------------------------------------
local function VersionInfo()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMeta and getMeta(ADDON, "Version") or "?"
    local game, build, _, toc = GetBuildInfo()
    return "PhantomCurse version " .. tostring(version),
        "Game " .. tostring(game) .. " (build " .. tostring(build) .. "), interface " .. tostring(toc),
        useContainers and "Highlight: drawn by the game (works in combat)"
            or "Highlight: fallback (out of combat only)"
end

local function BuildSettings()
    local f = CreateFrame("Frame", "PhantomCurseSettings", UIParent, "BackdropTemplate")
    f:SetSize(250, 490)
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

    local v1, v2, v3 = VersionInfo()
    local info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOP", 0, -26)
    info:SetText(v1 .. "\n" .. v2 .. "\n" .. v3)

    local y = -72
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
    Check("Highlight all debuff types", "allTypes")

    y = y - 6
    local ml = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ml:SetPoint("TOPLEFT", 14, y)
    ml:SetText("Display mode (click to change):")
    y = y - 16
    local mode = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mode:SetSize(222, 22)
    mode:SetPoint("TOPLEFT", 12, y)
    mode.Refresh = function()
        mode:SetText(db.onlyAfflicted and "Names only when removable" or "Names always shown")
    end
    mode:SetScript("OnClick", function()
        db.onlyAfflicted = not db.onlyAfflicted
        mode.Refresh()
        ApplySettings()
    end)
    f.mode = mode
    y = y - 24

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
    note:SetText("Show and scale changes made in combat apply when combat ends.")

    f:SetScript("OnShow", function()
        f.mode.Refresh()
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
-- The close button hides the window through a secure snippet, which the game
-- allows even in combat. (Making it see-through instead would leave invisible
-- cast buttons on screen that still catch clicks.)
local close = CreateFrame("Button", nil, header, "SecureHandlerClickTemplate")
close:SetSize(14, 14)
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -1)
close:SetFrameLevel(header:GetFrameLevel() + 2)
close:SetFrameRef("window", frame)
close:SetAttribute("_onclick", [[ self:GetFrameRef("window"):Hide() ]])
local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
closeText:SetPoint("CENTER")
closeText:SetText("X")
local closeHL = close:CreateTexture(nil, "HIGHLIGHT")
closeHL:SetAllPoints()
closeHL:SetColorTexture(1, 0.3, 0.3, 0.35)
close:HookScript("OnClick", function()
    db.hidden = true
    SecureRefresh() -- postponed automatically if in combat
    Print("window closed. Type /pc show (or /pc config) to bring it back.")
end)
close:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Close")
    GameTooltip:AddLine("/pc show brings it back.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
close:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    local v1, v2, v3 = VersionInfo()
    Print(v1 .. " | " .. v2)
    Print(v3 .. (containerError and (" - " .. containerError) or ""))
    for i, name in ipairs(activeSpells) do
        local types = {}
        for _, t in ipairs(TYPE_ORDER) do
            if spellTypes[i] and spellTypes[i][t] then types[#types + 1] = t end
        end
        Print("  " .. CLICKS[i].label .. ": " .. name .. " -> " .. table.concat(types, ", "))
    end
    local types = {}
    for t in pairs(canDispel) do types[#types + 1] = t end
    Print("class " .. tostring(playerClass)
        .. " | spells: " .. (#activeSpells > 0 and table.concat(activeSpells, ", ") or "NONE FOUND")
        .. " | removes: " .. (#types > 0 and table.concat(types, ", ") or "nothing"))
    Print("game filter " .. (filterOK and "ok" or "rejected")
        .. " | colour curve " .. (curve and "ok" or "missing")
        .. " | mask curve " .. (maskCurve and "ok" or "missing")
        .. " | in combat: " .. tostring(InCombatLockdown() and true or false))
    local shown = {}
    for _, t in ipairs(TYPE_ORDER) do
        if Removable(t) then shown[#shown + 1] = t end
    end
    local ids, how = HarmfulIDs("player")
    Print("highlighting types: " .. (#shown > 0 and table.concat(shown, ", ") or "none")
        .. " | debuffs the addon can see on you: " .. #ids .. " (" .. how .. ")")
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
    elseif msg == "mode" then
        db.onlyAfflicted = not db.onlyAfflicted
        ApplySettings()
        if settings then settings.mode.Refresh() end
        Print("display mode: " .. (db.onlyAfflicted and "names only when removable." or "names always shown."))
    elseif msg == "version" then
        local v1, v2, v3 = VersionInfo()
        Print(v1 .. " | " .. v2 .. " | " .. v3)
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
        Print("commands: /pc config | show | hide | toggle | lock | sound | combat | mode | reset | test | spells | version | debug")
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
    if event == "UNIT_AURA" then
        MarkDirty(arg1)

    elseif event == "ADDON_LOADED" then
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
        local _, class = UnitClass("player")
        playerClass = class
        -- Skip the client-side filter if this client rejects it.
        filterOK = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, FILTER)
        spellsDirty = true
        CreateButtons()
        ApplySettings()

        -- Safety net in case an aura change arrives without an event. Only
        -- visible rows are touched.
        C_Timer.NewTicker(0.5, function()
            if frame:IsVisible() then MarkAllDirty() end
        end)

        SafeRegister("UNIT_AURA")
        SafeRegister("GROUP_ROSTER_UPDATE")
        SafeRegister("PLAYER_ENTERING_WORLD")
        SafeRegister("PLAYER_REGEN_ENABLED")
        SafeRegister("PLAYER_REGEN_DISABLED")
        SafeRegister("SPELLS_CHANGED")
        SafeRegister("PLAYER_TALENT_UPDATE")
        SafeRegister("PLAYER_SPECIALIZATION_CHANGED")
        SafeRegister("UNIT_PET")

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Last moment before the combat lock: make every row clickable so a
        -- name that lights up mid-fight can be clicked.
        for _, b in ipairs(buttons) do SetRowClickable(b, true) end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then SecureRefresh() end
        -- Combat made every row clickable; switch blank ones off right away,
        -- including rows that are hidden now (UpdateButton skips those).
        for _, b in ipairs(buttons) do UpdateClickable(b) end
        MarkAllDirty()

    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if event == "PLAYER_ENTERING_WORLD" then spellsDirty = true end
        RefreshContainers()
        SecureRefresh()
        MarkAllDirty()

    elseif event == "UNIT_PET" then
        -- Fires for every raid member's pet; only yours can change your spells.
        if arg1 ~= "player" then return end
        spellsDirty = true
        SecureRefresh()

    else -- spell / talent changes
        spellsDirty = true
        SecureRefresh()
    end
end)
