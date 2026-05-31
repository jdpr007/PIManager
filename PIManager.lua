-- ==========================================================
-- PI Manager v1.6.2
-- Power Infusion manager for Shadow Priests
-- Fully compatible with WoW 12.0.5 (Midnight)
-- ==========================================================
-- IRON-CLAD RULES (see IRONCLAD_RULES.md - must be followed every session):
--   1. All API calls compatible with WoW 12.0.5.
--   2. Use the latest/most-recent frame APIs, templates, Lua for 12.0.5.
--   3. No deprecated anything (prefer C_Spell/C_Item/C_Container/etc.).
--   4. Optimized for parties/raids up to 40 players.
--   5. Include a debug option (/pi debug, /pi diag).
--   6. Login alert that the addon loaded + the key command to open it.
--   7. Verify every API against Blizzard's wow-ui-source:
--      github.com/Gethe/wow-ui-source/tree/live/Interface/AddOns/
--      Blizzard_APIDocumentationGenerated
-- ==========================================================
-- Raid-safety architectural rules baked into this version:
--   * NO 4 Hz OnUpdate. Status line updates only on game events.
--   * Pool of row frames - created ONCE, reused forever (no SetParent/
--     CreateFrame churn during raid roster events).
--   * Macro book updates are gated by InCombatLockdown AND deferred to
--     PLAYER_REGEN_ENABLED if combat blocks the write at the moment.
--     EditMacro is only called when the macrotext actually changes
--     (change detection via currentMacrotext comparison).
--   * No SPELL_UPDATE_COOLDOWN event. Status line cooldown reads on
--     event-driven refreshes only.
--   * Single-pass O(n) raid scan with pre-allocated scratch tables.
--   * NO addon-owned secure cast button. PI is cast from a normal
--     Blizzard macro the user drags to their action bar.
-- ==========================================================

local ADDON_NAME = ...

-- ==========================================================
-- CONSTANTS
-- ==========================================================
local POWER_INFUSION_ID   = 10060
local POWER_INFUSION_NAME = "Power Infusion"
local TRINKET_SLOT_1      = 13
local TRINKET_SLOT_2      = 14
local VERSION             = "1.6.2"

local DEFAULT_POTIONS = {
    191383, -- Elemental Potion of Ultimate Power
    191389, -- Elemental Potion of Power
    221024, -- Tempered Potion
    212283, -- Algari Mana Potion
}

-- Row-pool capacity. WoW raids max out at 40 - we never need more rows.
local MAX_ROWS = 40

-- Blizzard macro book entry that mirrors the secure cast button.
-- See UpdateMacro for the macro body specification.
local MACRO_NAME = "PIManager"
local MACRO_ICON = "Spell_Holy_PowerInfusion"

-- Class color hex codes (avoids RAID_CLASS_COLORS global, which is nil
-- pre-PLAYER_LOGIN on some clients)
local CLASS_COLORS = {
    WARRIOR     = "C79C6E", PALADIN     = "F58CBA", HUNTER      = "ABD473",
    ROGUE       = "FFF569", PRIEST      = "FFFFFF", DEATHKNIGHT = "C41F3B",
    SHAMAN      = "0070DE", MAGE        = "40C7EB", WARLOCK     = "8787ED",
    MONK        = "00FF96", DRUID       = "FF7D0A", DEMONHUNTER = "A330C9",
    EVOKER      = "33937F",
}

-- ==========================================================
-- SAVED VARIABLES
-- ==========================================================
PIManagerDB = PIManagerDB or {}

-- ==========================================================
-- STATE
-- ==========================================================
local state = {
    assignedTarget   = nil,
    useTrinket1      = false,
    useTrinket2      = false,
    usePotion        = false,
    customPotionID   = nil,
    customPotionName = nil,
    debug            = false,
}

local mainFrame     = nil      -- main window frame
local selectedPlayer = nil     -- highlighted in player list
local macroPending  = false    -- defer macro creation if blocked in combat
local currentMacrotext = ""    -- last-built macro body, for change detection
local cachedMacroIdx   = nil   -- cached Blizzard macro index after first creation
local lastAssignedName = nil   -- assigned name baked into the current macro body
                               -- (used by the cast-event handler to decide
                               -- whether the cast landed on the assigned target)

-- Tracks the actual Blizzard-resolved target name for each in-flight PI cast.
-- Populated by UNIT_SPELLCAST_SENT (which fires with the resolved target name
-- as the game itself sees it) and consumed by UNIT_SPELLCAST_SUCCEEDED, so the
-- "Power Infusion cast on <name>" confirmation reflects the actual target.
local pendingPITargetByCastGUID = {}

-- Forward-declared addon table. Closures created before the addon.* methods
-- are populated (e.g. the minimap button's click handler) reference this
-- table by upvalue, so the table identity must exist early.
local addon = {}

-- Forward-declared so the minimap button's OnClick closure can capture it
-- as an upvalue (the closure is created in BuildMinimapButton, well before
-- ToggleWindow's definition further down in the file).
local ToggleWindow

-- Pre-allocated row pool for player list
-- Created ONCE on first window show. Hidden/shown thereafter; never destroyed.
local rowPool       = {}

-- Pre-allocated scratch tables for FindCastTarget()
-- Reused across calls so we don't allocate fresh tables during raid scans.
local SCRATCH_DPS   = {}
local SCRATCH_ANY   = {}

-- ==========================================================
-- CHAT OUTPUT
-- ==========================================================
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffaa77ff[PIManager]|r " .. tostring(msg))
end

local function Debug(msg)
    if state.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[PIManager debug]|r " .. tostring(msg))
    end
end

-- ==========================================================
-- 12.0.5 API WRAPPERS (with legacy fallback safety net)
-- ==========================================================
local APIGetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local APIGetItemInfo        = (C_Item and C_Item.GetItemInfo)        or GetItemInfo
local APIGetItemCount       = (C_Item and C_Item.GetItemCount)       or GetItemCount

local APIGetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots)
                                or function() return 0 end
local APIGetContainerItemID   = (C_Container and C_Container.GetContainerItemID)
                                or function() return nil end

local function APIGetSpellCooldown(spellID)
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then return info.startTime, info.duration, info.isEnabled end
        return 0, 0, true
    end
    if GetSpellCooldown then return GetSpellCooldown(spellID) end
    return 0, 0, true
end

local function APIIsSpellInRange(spellID, unit)
    if C_Spell and C_Spell.IsSpellInRange then
        return C_Spell.IsSpellInRange(spellID, unit)
    end
    if IsSpellInRange then
        local r = IsSpellInRange(POWER_INFUSION_NAME, unit)
        if r == 1 then return true
        elseif r == 0 then return false
        else return nil end
    end
    return nil
end

-- ==========================================================
-- CAST TARGET RESOLUTION (single-pass O(n) raid scan)
-- ==========================================================
-- Returns three things used to build the multi-conditional cast macro:
--   assignedUnit  - unit token for the user's assigned target if they're
--                   in the group at all (no eligibility filtering - the
--                   macro's [help,nodead] conditional handles momentary
--                   range/dead/phase issues at cast time)
--   fallbackUnit  - unit token for a currently-castable DPS (or any
--                   non-DPS if no DPS available), or "player" as last
--                   resort. Used as the second branch of the macro.
--   assignedName  - the assigned player's name (for our own tracking)
--
-- The macro becomes:
--   /cast [@<assignedUnit>,help,nodead][@<fallbackUnit>,help,nodead][@player] PI
-- so the game evaluates the actual cast target live at keypress time -
-- no staleness from our pre-cast resolution.
local function FindCastTarget()
    local assignedName = state.assignedTarget
    local assignedUnit = nil
    local dpsCount, anyCount = 0, 0

    local groupType, endIdx
    if IsInRaid() then
        groupType = "raid"
        endIdx = GetNumGroupMembers()
    elseif IsInGroup() then
        groupType = "party"
        endIdx = 4  -- party1..party4 (player isn't in there)
    end

    if groupType then
        for i = 1, endIdx do
            local unit = groupType .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local name = UnitName(unit)
                if name then
                    -- ASSIGNED target match - no eligibility filters applied.
                    -- The macro [help,nodead] conditional decides at cast
                    -- time whether they're actually castable. If not, the
                    -- next macro branch (fallbackUnit) is tried instead.
                    if assignedName and name == assignedName then
                        assignedUnit = unit
                    end

                    -- FALLBACK pool eligibility - skip dead, disconnected,
                    -- phased, or out-of-range players. These are picked for
                    -- the second macro branch only.
                    if not UnitIsDeadOrGhost(unit)
                        and UnitIsConnected(unit)
                        and not (UnitPhaseReason and UnitPhaseReason(unit)) then
                        local inRange = APIIsSpellInRange(POWER_INFUSION_ID, unit)
                        if inRange == nil or inRange == true then
                            local role = UnitGroupRolesAssigned(unit)
                            if role == "DAMAGER" or role == "NONE" or role == "" then
                                dpsCount = dpsCount + 1
                                SCRATCH_DPS[dpsCount] = unit
                            end
                            anyCount = anyCount + 1
                            SCRATCH_ANY[anyCount] = unit
                        end
                    end
                end
            end
        end
    end

    -- Clear unused tail entries
    for i = dpsCount + 1, #SCRATCH_DPS do SCRATCH_DPS[i] = nil end
    for i = anyCount + 1, #SCRATCH_ANY do SCRATCH_ANY[i] = nil end

    -- Pick a fallback unit (DPS preferred, then any non-DPS, then self)
    local fallbackUnit = "player"
    if dpsCount > 0 then
        fallbackUnit = SCRATCH_DPS[math.random(dpsCount)]
    elseif anyCount > 0 then
        fallbackUnit = SCRATCH_ANY[math.random(anyCount)]
    end

    return assignedUnit, fallbackUnit, assignedName
end

-- ==========================================================
-- POTION BAG LOOKUP
-- ==========================================================
local function FindPotionBagSlot(itemID)
    if not itemID then return nil, nil end
    for bag = 0, 4 do
        local numSlots = APIGetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            if APIGetContainerItemID(bag, slot) == itemID then
                return bag, slot
            end
        end
    end
    return nil, nil
end

-- ==========================================================
-- LEGACY GLOBAL (no-op safety net)
-- ==========================================================
-- Earlier versions of this addon called /run PIManagerSendWhisper() from
-- the cast macro to send the whisper. That approach was abandoned (taint
-- issues in instanced content); the whisper now fires from
-- UNIT_SPELLCAST_SUCCEEDED instead. The macro body is regenerated on
-- every UpdateMacro, so users will pick up the new (no /run) macro
-- automatically. This empty global remains as a safety net in case any
-- stale macro still has the /run line - calling it just does nothing
-- instead of throwing "attempt to call a nil value".
_G.PIManagerSendWhisper = function() end

-- ==========================================================
-- MACRO BODY BUILDER
-- ==========================================================
-- Architecture:
--   * The macro body is a self-contained set of slash commands:
--       /cast [@<assigned>,help,nodead][@<fallback>,help,nodead][@player] PI
--       /use 13  (if trinket1 enabled and equipped)
--       /use 14  (if trinket2 enabled and equipped)
--       /use <bag> <slot>  (if potion enabled and found)
--   * This body is written to the Blizzard macro book entry named
--     "PIManager", which the user drags to an action bar and binds to
--     any key they like.
--   * The macro is a NORMAL Blizzard macro - the player casting it is a
--     clean (untainted) action. This is what allows the whisper to fire
--     from UNIT_SPELLCAST_SUCCEEDED without hitting taint. (An earlier
--     design used an addon-owned SecureActionButton, which tainted the
--     spellcast events and blocked SendChatMessage - that button has
--     been removed.)
local function UpdateMacro()
    if InCombatLockdown() then
        Debug("UpdateMacro: in combat lockdown - skipping")
        return
    end

    local assignedUnit, fallbackUnit, assignedName = FindCastTarget()
    local lines = {}

    -- 1. Cast Power Infusion. Multi-conditional macro so the game evaluates
    --    the actual target LIVE at keypress time, not at refresh time:
    --      a) [@<assigned>,help,nodead] - try the user's assigned target
    --      b) [@<fallback>,help,nodead] - try a currently-castable DPS
    --      c) [@player] - guaranteed cast on self (don't waste cooldown)
    --    This is robust against the assigned player briefly going out of
    --    range / dead / phased between our last refresh and the keypress.
    local castLine
    if assignedUnit then
        castLine = "/cast [@" .. assignedUnit .. ",help,nodead]" ..
                   "[@" .. fallbackUnit .. ",help,nodead]" ..
                   "[@player] " .. POWER_INFUSION_NAME
    else
        -- No assigned target in the group - fall back chain without first branch
        castLine = "/cast [@" .. fallbackUnit .. ",help,nodead]" ..
                   "[@player] " .. POWER_INFUSION_NAME
    end
    lines[#lines + 1] = castLine

    -- 2. Trinkets (only emit lines for equipped slots)
    if state.useTrinket1 and GetInventoryItemLink("player", TRINKET_SLOT_1) then
        lines[#lines + 1] = "/use " .. TRINKET_SLOT_1
    end
    if state.useTrinket2 and GetInventoryItemLink("player", TRINKET_SLOT_2) then
        lines[#lines + 1] = "/use " .. TRINKET_SLOT_2
    end

    -- 3. Potion (custom first, then defaults). Bag/slot syntax most reliable.
    if state.usePotion then
        local potionID = state.customPotionID
        local bag, slot
        if potionID then
            bag, slot = FindPotionBagSlot(potionID)
        end
        if not bag then
            for _, id in ipairs(DEFAULT_POTIONS) do
                if (APIGetItemCount(id) or 0) > 0 then
                    bag, slot = FindPotionBagSlot(id)
                    if bag then break end
                end
            end
        end
        if bag and slot then
            lines[#lines + 1] = "/use " .. bag .. " " .. slot
        end
    end

    local macrotext = table.concat(lines, "\n")
    local macroChanged = (macrotext ~= currentMacrotext)
    currentMacrotext = macrotext

    -- Remember who the macro is currently aimed at, so the cast-event
    -- handler can decide whether the cast landed on the assigned target.
    -- The game itself resolves the actual cast target via the macro
    -- conditionals; we only use this to compare against it.
    lastAssignedName = assignedName

    -- Sync to the Blizzard macro book entry. Only write when text has
    -- actually changed (avoids unnecessary EditMacro calls).
    if macroChanged then
        -- Only edit when we have a verified index from EnsureMacro's
        -- authoritative duplicate-aware scan. We deliberately do NOT call
        -- GetMacroIndexByName here: it finds only the first same-named macro
        -- and can return a stale/early-load value, which is how duplicate
        -- "PIManager" macros got created and edited inconsistently. If we
        -- don't have a known-good index yet, defer to EnsureMacro (which
        -- runs at PLAYER_ENTERING_WORLD and on /pi macro) to resolve it.
        if cachedMacroIdx then
            EditMacro(cachedMacroIdx, MACRO_NAME, nil, macrotext)
            Debug("Wrote macro body to PIManager (index " .. cachedMacroIdx .. ")")
        else
            macroPending = true
            Debug("PIManager macro index not resolved yet - deferring to EnsureMacro")
        end
    end

    Debug("Macro updated. Assigned=" .. tostring(assignedName) ..
          " assignedUnit=" .. tostring(assignedUnit) ..
          " fallback=" .. tostring(fallbackUnit))
end


-- ==========================================================
-- BLIZZARD MACRO (drag-to-action-bar)
-- ==========================================================
-- Creates or updates a "PIManager" macro in the player's macro book so it
-- can be dragged to any action bar slot and bound to any key. The macro
-- body is built by UpdateMacro, which keeps it current automatically.
--
-- DUPLICATE-PREVENTION (fixes the "3 PIManager macros" bug):
--   * We never trust GetMacroIndexByName alone - it only finds the FIRST
--     match and can return 0 during early load before the macro cache is
--     populated, causing the addon to create a fresh duplicate each login.
--   * Instead we scan ALL macros with GetNumMacros + GetMacroInfo and count
--     how many are named "PIManager". We only CreateMacro when the count is
--     exactly 0 AND the macro system is confirmed ready. If duplicates
--     already exist we warn the player and refuse to add more.

-- True once the macro UI cache is populated and safe to query/create against.
local function MacroSystemReady()
    if not GetNumMacros then return false end
    local general, char = GetNumMacros()
    -- GetNumMacros returns two numbers once the cache is live. During the
    -- very early load window it can return nil/garbage; guard for that.
    return type(general) == "number" and type(char) == "number"
end

-- Scans every macro slot and returns (count, firstIndex) of macros named
-- exactly MACRO_NAME. Searches both the general (1..120) and per-character
-- (121..138) ranges so account/character duplicates are both seen.
local function ScanPIManagerMacros()
    local count, firstIndex = 0, nil
    local general, char = GetNumMacros()
    general = tonumber(general) or 0
    char = tonumber(char) or 0
    -- General macros occupy indices 1..120; per-character 121..(120+char).
    local ranges = { {1, general}, {121, 120 + char} }
    for _, r in ipairs(ranges) do
        for i = r[1], r[2] do
            local name = GetMacroInfo(i)
            if name == MACRO_NAME then
                count = count + 1
                if not firstIndex then firstIndex = i end
            end
        end
    end
    return count, firstIndex
end

local duplicateWarningShown = false

local function EnsureMacro(silent)
    if InCombatLockdown() then
        macroPending = true
        if not silent then
            Print("|cffff9966Can't update macro in combat - will retry after combat ends.|r")
        end
        Debug("EnsureMacro skipped: in combat lockdown")
        return false
    end

    -- RACE GUARD: never touch macros until the macro system is ready. Calling
    -- this too early (e.g. at PLAYER_LOGIN before the cache populates) is what
    -- made GetMacroIndexByName return 0 and spawn duplicate macros each login.
    if not MacroSystemReady() then
        macroPending = true
        Debug("EnsureMacro deferred: macro system not ready yet")
        return false
    end

    -- Authoritative duplicate-aware scan (NOT GetMacroIndexByName).
    local count, firstIndex = ScanPIManagerMacros()

    if count > 1 then
        -- Duplicates already exist - DO NOT create another. Point the addon
        -- at the first one for editing, and warn the player once.
        cachedMacroIdx = firstIndex
        EditMacro(firstIndex, MACRO_NAME, MACRO_ICON, currentMacrotext)
        if not duplicateWarningShown then
            duplicateWarningShown = true
            Print("|cffff6666You have " .. count .. " macros named '" .. MACRO_NAME ..
                  "'.|r Open |cffffd700/macro|r and delete the extras, keeping just one. " ..
                  "(PI Manager updated the first one and will not create more.)")
        end
        Debug("EnsureMacro: found " .. count .. " duplicates; edited first at " .. firstIndex)
        macroPending = false
        return true
    end

    if count == 1 then
        -- Exactly one exists - sync its body. Use the freshly-scanned index
        -- (don't rely on a possibly-stale cachedMacroIdx).
        cachedMacroIdx = firstIndex
        EditMacro(firstIndex, MACRO_NAME, MACRO_ICON, currentMacrotext)
        Debug("EnsureMacro: updated existing PIManager macro at index " .. firstIndex)
        if not silent then
            Print("Macro |cffffd700" .. MACRO_NAME .. "|r updated at slot " ..
                  firstIndex .. ". Open |cffffd700/macro|r to find it; drag " ..
                  "to your action bar if you haven't already.")
        end
        macroPending = false
        return true
    end

    -- count == 0: safe to create exactly one.
    local newIdx = CreateMacro(MACRO_NAME, MACRO_ICON, currentMacrotext, false)
    if newIdx and newIdx > 0 then
        cachedMacroIdx = newIdx
        Debug("EnsureMacro: created new PIManager macro at index " .. newIdx)
        if not silent then
            Print("Created macro |cffffd700" .. MACRO_NAME .. "|r at slot " .. newIdx ..
                  ". Open |cffffd700/macro|r and drag it onto an action bar.")
        end
        macroPending = false
        return true
    end
    Debug("EnsureMacro: CreateMacro returned " .. tostring(newIdx) .. " - failed")
    if not silent then
        Print("|cffff6666Could not create macro - likely at the 120-macro limit.|r")
    end
    return false
end

-- ==========================================================
-- CLASS COLOR HELPER
-- ==========================================================
local function ClassColorHex(unit)
    local _, classFile = UnitClass(unit)
    return CLASS_COLORS[classFile] or "AAAAAA"
end

-- Returns a short colored faction tag for a unit: a blue [A] for Alliance,
-- a red [H] for Horde, or empty for Neutral/unknown. Used as an inline
-- prefix on player rows so cross-faction situations are visible at a glance.
-- (In most grouped content you'll only ever be with your own faction, but
-- this makes mercenary-mode / cross-faction instances and edge cases clear.)
local function FactionTag(unit)
    local fac = UnitFactionGroup(unit)
    if fac == "Alliance" then
        return "|cff4060ff[A]|r "
    elseif fac == "Horde" then
        return "|cffff3333[H]|r "
    end
    return ""
end

-- ==========================================================
-- ROW POOL (player list)
-- ==========================================================
-- Creates up to MAX_ROWS button frames ONCE at PLAYER_LOGIN.
-- Subsequent refreshes only update the existing rows' text/colors and
-- hide unused tail rows. NO CreateFrame or SetParent calls during gameplay,
-- which is critical because CreateFrame in combat can cause UI taint and
-- new group members might join while in combat.
local function GetOrCreateRow(index, parent, width)
    if rowPool[index] then return rowPool[index] end

    -- If we somehow get here during combat (e.g. someone joined a 40-man
    -- raid mid-fight and the preallocation didn't run), bail safely instead
    -- of risking a protected-function error. The next refresh out of combat
    -- will pick them up.
    if InCombatLockdown() then return nil end

    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, 22)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * 22)
    row:Hide()  -- created hidden; RefreshList shows them as needed

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row.bg = bg

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.nameText = nameText

    local marker = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    marker:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    marker:SetText("")
    row.marker = marker

    row:SetScript("OnClick", function(self)
        if not self.memberName then return end
        selectedPlayer = self.memberName
        for _, r in ipairs(rowPool) do
            if r:IsShown() then
                if state.assignedTarget == r.memberName then
                    r.bg:SetColorTexture(1, 0.82, 0, 0.20)
                else
                    r.bg:SetColorTexture(0, 0, 0, 0)
                end
            end
        end
        self.bg:SetColorTexture(0.5, 0.2, 0.8, 0.5)
    end)

    rowPool[index] = row
    return row
end

-- Pre-create all MAX_ROWS rows up front (called once after BuildMainFrame
-- at PLAYER_LOGIN). This avoids any CreateFrame calls during combat or
-- when new raid members join mid-fight, which was previously causing
-- new joiners to not appear in the list until /reload.
local function PreallocateRows()
    if not mainFrame or not mainFrame.listContent then return end
    local content = mainFrame.listContent
    local width = content:GetWidth() or 250
    for i = 1, MAX_ROWS do
        GetOrCreateRow(i, content, width)
    end
end

-- ==========================================================
-- REFRESH LIST (no allocations, no CreateFrame)
-- ==========================================================
function addon.RefreshList()
    if not mainFrame or not mainFrame.listContent then return end
    selectedPlayer = nil
    local content = mainFrame.listContent
    local width   = content:GetWidth() or 250

    local count = 0

    -- Helper: populate row at index `count` with this unit's info.
    -- Stays inside RefreshList (closure over `count`/`content`/`width`) so
    -- it can be used uniformly for both group members and the solo-player
    -- fallback case.
    local function fillRow(unit, name)
        count = count + 1
        local row = GetOrCreateRow(count, content, width)
        if not row then return end  -- combat lockdown blocked row creation
        row.memberName = name

        -- Name (faction tag + class-colored name)
        row.nameText:SetText(FactionTag(unit) ..
                             "|cff" .. ClassColorHex(unit) .. name .. "|r")

        -- Background + assignment marker
        if state.assignedTarget == name then
            row.bg:SetColorTexture(1, 0.82, 0, 0.20)
            row.marker:SetText("|cffFFD700[PI]|r")
        elseif count % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.04)
            row.marker:SetText("")
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
            row.marker:SetText("")
        end

        row:Show()
    end

    local groupType, endIdx
    if IsInRaid() then
        groupType, endIdx = "raid", GetNumGroupMembers()
    elseif IsInGroup() then
        groupType, endIdx = "party", 4
    end

    if groupType then
        -- In a group/raid: list everyone EXCEPT yourself
        for i = 1, endIdx do
            local unit = groupType .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local name = UnitName(unit)
                if name then fillRow(unit, name) end
            end
        end
    else
        -- Solo: show yourself so the list isn't empty and you can test
        -- assignments. (FindCastTarget will still fall back to self
        -- naturally when there are no other candidates.)
        local name = UnitName("player")
        if name then fillRow("player", name) end
    end

    -- Hide unused tail rows (don't destroy them)
    for i = count + 1, MAX_ROWS do
        local r = rowPool[i]
        if r then r:Hide() end
    end

    content:SetHeight(math.max(count * 22, 1))
end

-- ==========================================================
-- REFRESH TRINKET LABELS
-- ==========================================================
function addon.RefreshTrinketLabels()
    if not mainFrame or not mainFrame.trinket1Label then return end
    local function trinketName(slot, fallback)
        local link = GetInventoryItemLink("player", slot)
        if not link then return fallback end
        local n = link:match("|h%[(.-)%]|h")
        if not n then return fallback end
        if #n > 22 then n = n:sub(1, 21) .. "…" end
        return n
    end
    mainFrame.trinket1Label:SetText(trinketName(TRINKET_SLOT_1, "Trinket 13"))
    mainFrame.trinket2Label:SetText(trinketName(TRINKET_SLOT_2, "Trinket 14"))
end

-- ==========================================================
-- REFRESH STATUS LINE (called only on events, NOT OnUpdate)
-- ==========================================================
function addon.RefreshStatusLine()
    if not mainFrame or not mainFrame.statusLabel then return end

    -- C_Spell.GetSpellCooldown can return "secret values" in Midnight 12.0+
    -- inside instanced content. Direct comparison on a secret value
    -- (duration > 1.5) throws "execution tainted by 'PIManager'" and
    -- prevents the window from opening. Use the global issecretvalue
    -- guard (nil pre-Midnight, present in Midnight+) and treat secrets
    -- as "unknown - assume ready" so we don't block the GUI.
    local start, duration = APIGetSpellCooldown(POWER_INFUSION_ID)
    local cdText = "|cff66ff66Ready|r"

    local secretGuard = _G.issecretvalue
    local isSecret = secretGuard and (
        (start    and secretGuard(start))    or
        (duration and secretGuard(duration))
    )

    if not isSecret and start and duration and duration > 1.5 then
        local remaining = start + duration - GetTime()
        if remaining > 0 then
            cdText = string.format("|cffff6666CD %ds|r", math.ceil(remaining))
        end
    end

    -- FindCastTarget returns (assignedUnit, fallbackUnit, assignedName).
    -- For the status line, show who the macro will TRY first - the
    -- assigned player if they're in the group, else the fallback. The
    -- game decides at cast time whether the [help,nodead] conditional
    -- passes; we just preview the intent.
    local assignedUnit, fallbackUnit, assignedName = FindCastTarget()
    local previewText
    if assignedUnit then
        previewText = "|cffffffff" .. assignedName .. "|r"
    elseif fallbackUnit and fallbackUnit ~= "player" then
        previewText = "|cffffcc66" .. (UnitName(fallbackUnit) or "?") .. " (fallback)|r"
    else
        previewText = "|cffff6666self only|r"
    end

    mainFrame.statusLabel:SetText(cdText .. "  →  " .. previewText)
end

-- ==========================================================
-- REFRESH ASSIGNED LABEL
-- ==========================================================
function addon.RefreshAssignedLabel()
    if not mainFrame or not mainFrame.assignedLabel then return end
    if state.assignedTarget then
        mainFrame.assignedLabel:SetText("Assigned: |cffffffff" .. state.assignedTarget .. "|r")
    else
        mainFrame.assignedLabel:SetText("Assigned: |cff888888(none)|r")
    end
end

-- ==========================================================
-- MAIN WINDOW BUILDER
-- ==========================================================
local function BuildMainFrame()
    if mainFrame then return end

    mainFrame = CreateFrame("Frame", "PIManagerMainFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(300, 430)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop",  mainFrame.StopMovingOrSizing)
    mainFrame:SetClampedToScreen(true)
    mainFrame:Hide()

    mainFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    mainFrame:SetBackdropColor(1, 1, 1, 1)
    mainFrame:SetBackdropBorderColor(1, 1, 1, 1)

    -- Title banner
    local titleBg = mainFrame:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(200)
    titleBg:SetHeight(40)
    titleBg:SetPoint("TOP", mainFrame, "TOP", 0, 12)

    local titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleBg, "CENTER", 0, 4)
    titleText:SetText("PI Manager")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -4, -4)

    -- Assigned label
    mainFrame.assignedLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mainFrame.assignedLabel:SetPoint("TOP", mainFrame, "TOP", 0, -28)

    -- Status line
    mainFrame.statusLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.statusLabel:SetPoint("TOP", mainFrame, "TOP", 0, -44)
    mainFrame.statusLabel:SetText("...")

    -- Player list inside an inset
    local listInset = CreateFrame("Frame", nil, mainFrame, "InsetFrameTemplate")
    listInset:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  8, -60)
    listInset:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -8, 220)
    -- (list bottom stays 290px up from window bottom; window shortened from
    -- 600->500 after removing the notification section, so the bottom control
    -- band is now more compact.)

    local listHost = CreateFrame("Frame", nil, listInset)
    listHost:SetPoint("TOPLEFT",     listInset, "TOPLEFT",  4, -4)
    listHost:SetPoint("BOTTOMRIGHT", listInset, "BOTTOMRIGHT", -4, 4)
    listHost:SetClipsChildren(true)

    local listContent = CreateFrame("Frame", nil, listHost)
    listContent:SetPoint("TOPLEFT", listHost, "TOPLEFT", 0, 0)
    listContent:SetSize(listHost:GetWidth() or 240, 1)
    mainFrame.listContent = listContent

    local scrollOffset = 0
    listHost:EnableMouseWheel(true)
    listHost:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, listContent:GetHeight() - self:GetHeight())
        scrollOffset = math.max(0, math.min(maxScroll, scrollOffset - delta * 20))
        listContent:SetPoint("TOPLEFT", self, "TOPLEFT", 0, scrollOffset)
    end)

    -- Assign / Clear buttons
    local assignBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    assignBtn:SetSize(110, 24)
    assignBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 16, 190)
    assignBtn:SetText("Assign PI")
    assignBtn:SetScript("OnClick", function()
        if selectedPlayer then
            state.assignedTarget = selectedPlayer
            PIManagerDB.assignedTarget = selectedPlayer
            Print("Assigned to: |cffffffff" .. selectedPlayer .. "|r")
            addon.RefreshList()
            addon.RefreshAssignedLabel()
            addon.RefreshStatusLine()
            UpdateMacro()
        else
            Print("Click a player name first.")
        end
    end)

    local clearBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 24)
    clearBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -16, 190)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        state.assignedTarget = nil
        PIManagerDB.assignedTarget = nil
        selectedPlayer = nil
        Print("Assignment cleared.")
        addon.RefreshList()
        addon.RefreshAssignedLabel()
        addon.RefreshStatusLine()
        UpdateMacro()
    end)

    -- "Use Trinket on cast:" section
    local trinketLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    trinketLbl:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 18, 172)
    trinketLbl:SetText("Use Trinket on cast:")

    local function MakeCheckbox(xOff, yOff, labelText, stateKey, dbKey)
        local chk = CreateFrame("CheckButton", nil, mainFrame, "UICheckButtonTemplate")
        chk:SetSize(22, 22)
        chk:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", xOff, yOff)
        chk:SetChecked(state[stateKey])

        local lbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", chk, "RIGHT", 2, 0)
        lbl:SetText(labelText)

        chk:SetScript("OnClick", function(self)
            state[stateKey] = self:GetChecked() and true or false
            PIManagerDB[dbKey] = state[stateKey]
            UpdateMacro()
        end)
        return chk, lbl
    end

    local _, trinket1Label = MakeCheckbox(16, 150, "Trinket 13", "useTrinket1", "useTrinket1")
    local _, trinket2Label = MakeCheckbox(16, 128, "Trinket 14", "useTrinket2", "useTrinket2")
    mainFrame.trinket1Label = trinket1Label
    mainFrame.trinket2Label = trinket2Label

    -- "Use Potion on cast:" section
    local potLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    potLbl:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 18, 106)
    potLbl:SetText("Use Potion on cast:")

    MakeCheckbox(16, 84, "Combat Potion", "usePotion", "usePotion")

    -- Potion drag-and-drop edit (aligned with whisper edit below)
    local potionEdit = CreateFrame("EditBox", "PIManagerPotionEdit", mainFrame, "InputBoxTemplate")
    potionEdit:SetSize(252, 18)
    potionEdit:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 26, 62)
    potionEdit:SetAutoFocus(false)
    potionEdit:SetFontObject("ChatFontNormal")
    potionEdit:SetText(state.customPotionName or "")

    local function ExtractItemNameFromLink(text)
        if not text or text == "" then return text end
        local n = text:match("|h%[(.-)%]|h")
        if n then return n end
        local stripped = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                             :gsub("|H.-|h", ""):gsub("|h", "")
        return stripped:match("^%s*(.-)%s*$")
    end

    local function SavePotion(self)
        local raw = self:GetText() or ""
        local name = ExtractItemNameFromLink(raw)
        local linkID = raw:match("|Hitem:(%d+)")
        local itemID = tonumber(linkID)
        if not itemID and name and name ~= "" then
            itemID = APIGetItemInfoInstant(name)
        end
        self:SetText(name or "")
        local prevName = state.customPotionName or ""
        local newName  = name or ""
        if newName == "" then
            if prevName ~= "" then
                state.customPotionID, state.customPotionName = nil, nil
                PIManagerDB.customPotionID, PIManagerDB.customPotionName = nil, nil
                Print("Custom potion cleared.")
            end
        else
            if newName ~= prevName then
                state.customPotionID, state.customPotionName = itemID, name
                PIManagerDB.customPotionID, PIManagerDB.customPotionName = itemID, name
                if itemID then
                    Print("Custom potion: |cffffd700" .. name .. "|r (ID " .. itemID .. ")")
                else
                    Print("Custom potion: |cffffd700" .. name .. "|r |cffff6666(no ID resolved)|r")
                end
            end
        end
        self:ClearFocus()
        UpdateMacro()
    end
    potionEdit:SetScript("OnEnterPressed", SavePotion)
    potionEdit:SetScript("OnEditFocusLost", SavePotion)
    potionEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(state.customPotionName or ""); self:ClearFocus()
    end)
    potionEdit:SetScript("OnReceiveDrag", function(self)
        local infoType, _, link = GetCursorInfo()
        if infoType == "item" and link then
            self:SetText(link); SavePotion(self); ClearCursor()
        end
    end)
    potionEdit:SetScript("OnMouseUp", function(self)
        local infoType, _, link = GetCursorInfo()
        if infoType == "item" and link then
            self:SetText(link); SavePotion(self); ClearCursor()
        end
    end)

    -- Bottom hint - anchored under the potion edit box so it sits directly
    -- below the last control (no dependence on window-bottom offsets).
    local hintLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintLabel:SetPoint("TOP", potionEdit, "BOTTOM", 0, -14)
    hintLabel:SetJustifyH("CENTER")
    hintLabel:SetText("Press your keybind to cast PI")

    local hintSub = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintSub:SetPoint("TOP", hintLabel, "BOTTOM", 0, -4)
    hintSub:SetJustifyH("CENTER")
    hintSub:SetText("Type /pi help for commands")
end

-- ==========================================================
-- MINIMAP BUTTON + ADDON COMPARTMENT
-- ==========================================================
-- Two redundant entry points so the user always has a way to open the
-- window from the minimap area:
--
--   1. LibDBIcon button on the minimap rim. This is what most users
--      will click. Other addons (Leatrix Plus, ElvUI, HidingBar, MBB,
--      etc.) sometimes "collect" LibDBIcon buttons into a separate tray
--      that can become unresponsive after dungeon entry - so we don't
--      rely on it alone.
--
--   2. AddonCompartmentFrame entry. This is Blizzard's native
--      addon-button dropdown attached to the minimap (the small menu
--      icon). Collector addons generally don't touch this because it
--      IS the Blizzard collector. This entry remains accessible even
--      when the LibDBIcon button has been collected/hidden.
local function BuildMinimapButton()
    local function openClick(_, button)
        Debug("Minimap entry clicked (button=" .. tostring(button) .. ")")
        if button == nil or button == "LeftButton" then
            ToggleWindow()
        end
    end

    local function tooltipBuilder(tooltip)
        tooltip:AddLine("PI Manager")
        tooltip:AddLine(" ")
        if state.assignedTarget then
            tooltip:AddLine("Assigned to:", 0.8, 0.8, 0.8)
            tooltip:AddLine(state.assignedTarget, 1, 0.82, 0)
        else
            tooltip:AddLine("No player assigned", 1, 0.4, 0.4)
        end
        tooltip:AddLine(" ")
        tooltip:AddLine("Left-click: open window", 0.5, 0.7, 1)
    end

    -- 1. Blizzard AddonCompartmentFrame entry (always-available fallback)
    if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
        AddonCompartmentFrame:RegisterAddon({
            text                = "PI Manager",
            icon                = "Interface\\Icons\\Spell_Holy_PowerInfusion",
            notCheckable        = true,
            registerForAnyClick = true,
            func                = function(_, _, _, _, mouseButton)
                openClick(nil, mouseButton or "LeftButton")
            end,
            funcOnEnter         = function(button)
                if not button then return end
                GameTooltip:SetOwner(button, "ANCHOR_LEFT")
                tooltipBuilder(GameTooltip)
                GameTooltip:Show()
            end,
            funcOnLeave         = function() GameTooltip:Hide() end,
        })
    end

    -- 2. LibDBIcon minimap-rim button (primary path)
    local LDB    = LibStub and LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not LDBIcon then
        Debug("LibDataBroker / LibDBIcon not loaded - skipping minimap rim button " ..
              "(AddonCompartment entry still available)")
        return
    end

    local dataObj = LDB:NewDataObject("PIManager", {
        type    = "launcher",
        text    = "PI Manager",
        icon    = "Interface\\Icons\\Spell_Holy_PowerInfusion",
        OnClick = openClick,
        OnTooltipShow = tooltipBuilder,
    })

    PIManagerDB.minimapIcon = PIManagerDB.minimapIcon or { hide = false }
    LDBIcon:Register("PIManager", dataObj, PIManagerDB.minimapIcon)
end

-- ==========================================================
-- MINIMAP BUTTON RE-ATTACHMENT
-- ==========================================================
-- Workaround for LibDBIcon buttons becoming unresponsive after dungeon /
-- raid entry. In WoW 12.0+ the Minimap frame and its children can be
-- restructured during loading-screen transitions, leaving the button
-- visible but with severed mouse-event propagation.
--
-- This function aggressively resets everything that might be wrong, then
-- runs LibDBIcon's own Refresh. It's safe to call any time and idempotent.
local function ReattachMinimapButton(verbose)
    local ok, err = pcall(function()
        local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
        if not LDBIcon then
            if verbose then Print("|cffff6666LibDBIcon not loaded.|r") end
            return
        end

        local button = LDBIcon:GetMinimapButton("PIManager")
        if not button then
            if verbose then Print("|cffff6666Minimap button not found.|r") end
            return
        end

        -- 1. Re-parent only if Minimap still exists
        if Minimap then button:SetParent(Minimap) end

        -- 2. Force frame strata + level back to LibDBIcon's defaults
        button:SetFrameStrata("MEDIUM")
        button:SetFrameLevel(8)

        -- 3. Re-enable mouse and re-register click/drag - core fix for the
        -- "icon visible but doesn't respond" symptom
        button:EnableMouse(true)
        button:RegisterForClicks("anyUp")
        button:RegisterForDrag("LeftButton")

        -- 4. Make sure the button is shown (unless user explicitly hid it)
        if not PIManagerDB.minimapIcon or not PIManagerDB.minimapIcon.hide then
            button:Show()
        end

        -- 5. Bring the button's strata above the Minimap itself
        if Minimap then
            button:SetFrameStrata(Minimap:GetFrameStrata())
            button:SetFrameLevel(Minimap:GetFrameLevel() + 5)
        end

        -- 6. Run LibDBIcon's Refresh to reset position and drag scripts
        LDBIcon:Refresh("PIManager", PIManagerDB.minimapIcon)

        local msg = "Minimap button reattached. Strata=" .. button:GetFrameStrata() ..
                    " Level=" .. button:GetFrameLevel() ..
                    " MouseEnabled=" .. tostring(button:IsMouseEnabled()) ..
                    " Shown=" .. tostring(button:IsShown())
        if verbose then Print(msg) else Debug(msg) end
    end)
    if not ok and verbose then
        Print("|cffff6666Reattach error:|r " .. tostring(err))
    end
end

-- ==========================================================
-- DIAGNOSTICS
-- ==========================================================
local function PrintDiagnostics()
    Print("|cffffd700=== Diagnostics ===|r")
    DEFAULT_CHAT_FRAME:AddMessage("  WoW build: " .. tostring(select(4, GetBuildInfo())))
    DEFAULT_CHAT_FRAME:AddMessage("  Addon version: " .. VERSION)
    DEFAULT_CHAT_FRAME:AddMessage("  InCombatLockdown: " .. tostring(InCombatLockdown()))
    DEFAULT_CHAT_FRAME:AddMessage("  UnitAffectingCombat: " .. tostring(UnitAffectingCombat("player")))
    DEFAULT_CHAT_FRAME:AddMessage(" ")
    DEFAULT_CHAT_FRAME:AddMessage("  mainFrame exists: " .. tostring(mainFrame ~= nil))
    if mainFrame then
        DEFAULT_CHAT_FRAME:AddMessage("  mainFrame:IsShown(): " .. tostring(mainFrame:IsShown()))
        DEFAULT_CHAT_FRAME:AddMessage("  row pool size: " .. #rowPool)
    end
    DEFAULT_CHAT_FRAME:AddMessage("  Macro target (assigned name): " ..
        tostring(lastAssignedName))
    DEFAULT_CHAT_FRAME:AddMessage("  Current macro body (built):")
    for line in (currentMacrotext or ""):gmatch("[^\n]+") do
        DEFAULT_CHAT_FRAME:AddMessage("    |cffaaaaaa" .. line .. "|r")
    end
    -- Show the live Blizzard macro(s). Report the COUNT so duplicate
    -- "PIManager" macros (the cause of the 3-macro bug) are immediately
    -- visible here. Uses the authoritative scan, not GetMacroIndexByName.
    local count, firstIndex = ScanPIManagerMacros()
    if count == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  Blizzard macro 'PIManager': |cffff6666not found|r")
    else
        local colour = (count > 1) and "ff6666" or "aaaaaa"
        DEFAULT_CHAT_FRAME:AddMessage("  Blizzard macros named 'PIManager': |cff" ..
            colour .. count .. "|r" .. (count > 1 and " |cffff6666(DUPLICATES - delete extras in /macro)|r" or ""))
        DEFAULT_CHAT_FRAME:AddMessage("  cachedMacroIdx=" .. tostring(cachedMacroIdx) ..
            ", firstIndex=" .. tostring(firstIndex))
        local _, _, body = GetMacroInfo(firstIndex)
        DEFAULT_CHAT_FRAME:AddMessage("  First macro body:")
        for line in (body or ""):gmatch("[^\n]+") do
            DEFAULT_CHAT_FRAME:AddMessage("    |cffaaaaaa" .. line .. "|r")
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(" ")
    DEFAULT_CHAT_FRAME:AddMessage("  Assigned: " .. tostring(state.assignedTarget))
    DEFAULT_CHAT_FRAME:AddMessage("  Trinket 13: " .. tostring(state.useTrinket1))
    DEFAULT_CHAT_FRAME:AddMessage("  Trinket 14: " .. tostring(state.useTrinket2))
    DEFAULT_CHAT_FRAME:AddMessage("  Potion: " .. tostring(state.usePotion))
    DEFAULT_CHAT_FRAME:AddMessage("  Custom potion: " .. tostring(state.customPotionName) ..
                                  " (ID " .. tostring(state.customPotionID) .. ")")
    DEFAULT_CHAT_FRAME:AddMessage("  Debug mode: " .. tostring(state.debug))
    DEFAULT_CHAT_FRAME:AddMessage(" ")
    -- Instance / zone context (critical for diagnosing dungeon-specific issues)
    local inInstance, instanceType = IsInInstance()
    DEFAULT_CHAT_FRAME:AddMessage("  IsInInstance: " .. tostring(inInstance) ..
                                  " (" .. tostring(instanceType) .. ")")
    DEFAULT_CHAT_FRAME:AddMessage("  Zone: " .. tostring(GetZoneText()))
    if mainFrame then
        DEFAULT_CHAT_FRAME:AddMessage("  Window state: IsShown=" ..
            tostring(mainFrame:IsShown()) ..
            " Strata=" .. tostring(mainFrame:GetFrameStrata()) ..
            " Level=" .. tostring(mainFrame:GetFrameLevel()) ..
            " Alpha=" .. tostring(mainFrame:GetAlpha()))
        local cx, cy = mainFrame:GetCenter()
        DEFAULT_CHAT_FRAME:AddMessage("  Window center: (" ..
            tostring(cx and math.floor(cx)) .. ", " ..
            tostring(cy and math.floor(cy)) .. ")")
    end
end

-- ==========================================================
-- HELP / STATUS / LIST
-- ==========================================================
local function PrintHelp()
    Print("|cffffd700PI Manager v" .. VERSION .. " - Commands:|r")
    local function cmd(c, desc)
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/pi " .. c .. "|r - " .. desc)
    end
    cmd("",                     "toggle the window")
    cmd("hide",                 "close the window")
    cmd("assign <name>",        "assign PI to a player")
    cmd("clear",                "clear the assignment")
    cmd("trinket1 [on|off]",    "toggle/set Trinket slot 13 usage")
    cmd("trinket2 [on|off]",    "toggle/set Trinket slot 14 usage")
    cmd("potion [on|off]",      "toggle/set combat potion usage")
    cmd("setpotion <id|name>",  "set custom potion by item ID or exact name")
    cmd("clearpotion",          "clear custom potion (revert to defaults)")
    cmd("macro",                "create/update the Blizzard macro for action bars")
    cmd("fix",                  "re-attach minimap button if it stopped responding")
    cmd("diag",                 "print full diagnostic info")
    cmd("debug [on|off]",       "toggle/set debug logging")
    cmd("reset",                "wipe all saved settings")
    cmd("help",                 "this help message")
end

-- ==========================================================
-- SLASH COMMAND HANDLERS
-- ==========================================================
local function ParseBool(s)
    if not s or s == "" then return nil end
    s = s:lower()
    if s == "on" or s == "1" or s == "true" or s == "yes" then return true end
    if s == "off" or s == "0" or s == "false" or s == "no" then return false end
    return nil
end

local function CmdAssign(arg)
    if not arg or arg == "" then Print("Usage: /pi assign <name>"); return end
    local name = arg:sub(1, 1):upper() .. arg:sub(2)
    state.assignedTarget = name
    PIManagerDB.assignedTarget = name
    Print("Assigned to: |cffffffff" .. name .. "|r")
    if mainFrame and mainFrame:IsShown() then
        addon.RefreshList(); addon.RefreshAssignedLabel(); addon.RefreshStatusLine()
    end
    UpdateMacro()
end

local function CmdClear()
    state.assignedTarget = nil
    PIManagerDB.assignedTarget = nil
    Print("Assignment cleared.")
    if mainFrame and mainFrame:IsShown() then
        addon.RefreshList(); addon.RefreshAssignedLabel(); addon.RefreshStatusLine()
    end
    UpdateMacro()
end

local function CmdToggleTrinket(slot, key, arg)
    local desired = ParseBool(arg)
    if desired == nil then desired = not state[key] end
    state[key] = desired
    PIManagerDB[key] = desired
    Print("Trinket " .. slot .. ": " .. (desired and "|cff66ff66ON|r" or "|cff888888off|r"))
    UpdateMacro()
end

local function CmdTogglePotion(arg)
    local desired = ParseBool(arg)
    if desired == nil then desired = not state.usePotion end
    state.usePotion = desired
    PIManagerDB.usePotion = desired
    Print("Combat potion: " .. (desired and "|cff66ff66ON|r" or "|cff888888off|r"))
    UpdateMacro()
end

local function CmdSetPotion(arg)
    if not arg or arg == "" then Print("Usage: /pi setpotion <itemID|name>"); return end
    local asNumber = tonumber(arg)
    if asNumber then
        local itemID = APIGetItemInfoInstant(asNumber)
        if itemID then
            local name = APIGetItemInfo(asNumber)
            state.customPotionID = asNumber
            state.customPotionName = name or ("ItemID:" .. asNumber)
            PIManagerDB.customPotionID = state.customPotionID
            PIManagerDB.customPotionName = state.customPotionName
            Print("Custom potion set: |cffffd700" .. state.customPotionName ..
                  "|r (ID " .. asNumber .. ")")
            UpdateMacro()
        else
            Print("|cffff6666Item ID " .. arg .. " not recognized.|r")
        end
    else
        local id = APIGetItemInfoInstant(arg)
        if id then
            state.customPotionID = id
            state.customPotionName = arg
            PIManagerDB.customPotionID = id
            PIManagerDB.customPotionName = arg
            Print("Custom potion set: |cffffd700" .. arg .. "|r (ID " .. id .. ")")
            UpdateMacro()
        else
            Print("|cffff6666Could not resolve item name '" .. arg ..
                  "'. Try the item ID instead.|r")
        end
    end
end

local function CmdClearPotion()
    state.customPotionID = nil
    state.customPotionName = nil
    PIManagerDB.customPotionID = nil
    PIManagerDB.customPotionName = nil
    Print("Custom potion cleared.")
    UpdateMacro()
end

local function CmdDebug(arg)
    local desired = ParseBool(arg)
    if desired == nil then desired = not state.debug end
    state.debug = desired
    PIManagerDB.debug = desired
    Print("Debug mode: " .. (desired and "|cff66ff66ON|r" or "|cff888888off|r"))
end

local function CmdReset()
    PIManagerDB = {}
    state.assignedTarget = nil
    state.useTrinket1 = false
    state.useTrinket2 = false
    state.usePotion = false
    state.customPotionID = nil
    state.customPotionName = nil
    state.debug = false
    if mainFrame and mainFrame:IsShown() then
        addon.RefreshList(); addon.RefreshAssignedLabel(); addon.RefreshStatusLine()
    end
    UpdateMacro()
    Print("All saved settings cleared.")
end

ToggleWindow = function()
    -- Wrap everything in pcall so any error inside RefreshList /
    -- RefreshStatusLine / etc. surfaces to chat instead of silently
    -- preventing the window from showing.
    local ok, err = pcall(function()
        Debug("ToggleWindow called. mainFrame exists=" .. tostring(mainFrame ~= nil) ..
              ", IsShown=" .. tostring(mainFrame and mainFrame:IsShown()))
        if not mainFrame then BuildMainFrame() end
        if mainFrame:IsShown() then
            mainFrame:Hide()
            Debug("Window hidden.")
        else
            -- Defensive: re-anchor to screen center if the frame somehow ended
            -- up offscreen (can happen if SetClampedToScreen wasn't enforced
            -- across a UI reload, or if drag-saved coords are corrupt).
            local cx, cy = mainFrame:GetCenter()
            local sw, sh = UIParent:GetSize()
            if not cx or not cy or cx < 0 or cy < 0 or cx > sw or cy > sh then
                mainFrame:ClearAllPoints()
                mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                Debug("Window was offscreen - re-centered.")
            end

            -- Show FIRST so the window opens even if any refresh fails.
            -- Each refresh is wrapped in its own pcall so a single refresh
            -- erroring (e.g. Midnight secret-value taint) doesn't block
            -- the others from running.
            mainFrame:Show()
            mainFrame:Raise()
            Debug("Show() called. IsShown afterwards=" .. tostring(mainFrame:IsShown()) ..
                  " Strata=" .. tostring(mainFrame:GetFrameStrata()) ..
                  " Level=" .. tostring(mainFrame:GetFrameLevel()))

            local refreshes = {
                { name = "RefreshList",          fn = addon.RefreshList },
                { name = "RefreshTrinketLabels", fn = addon.RefreshTrinketLabels },
                { name = "RefreshAssignedLabel", fn = addon.RefreshAssignedLabel },
                { name = "RefreshStatusLine",    fn = addon.RefreshStatusLine },
            }
            for _, r in ipairs(refreshes) do
                local rok, rerr = pcall(r.fn)
                if not rok then
                    Debug(r.name .. " failed: " .. tostring(rerr))
                end
            end
        end
    end)
    if not ok then
        Print("|cffff6666Error opening window:|r " .. tostring(err))
    end
end

SLASH_PIMANAGER1 = "/pi"
SLASH_PIMANAGER2 = "/pimanager"
SlashCmdList["PIMANAGER"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S+)%s*(.*)$")
    if cmd then cmd = cmd:lower() end
    rest = rest or ""

    if not cmd or cmd == "" or cmd == "show" or cmd == "toggle" then
        Print("Opening window...")
        ToggleWindow()
    elseif cmd == "hide" or cmd == "close" then
        if mainFrame then mainFrame:Hide() end
    elseif cmd == "help" or cmd == "?" then PrintHelp()
    elseif cmd == "diag" or cmd == "diagnose" or cmd == "diagnostics" then PrintDiagnostics()
    elseif cmd == "debug"  then CmdDebug(rest)
    elseif cmd == "reset"  then CmdReset()
    elseif cmd == "assign" then CmdAssign(rest)
    elseif cmd == "clear" or cmd == "unassign" then CmdClear()
    elseif cmd == "trinket1" then CmdToggleTrinket(13, "useTrinket1", rest)
    elseif cmd == "trinket2" then CmdToggleTrinket(14, "useTrinket2", rest)
    elseif cmd == "potion"      then CmdTogglePotion(rest)
    elseif cmd == "setpotion"   then CmdSetPotion(rest)
    elseif cmd == "clearpotion" then CmdClearPotion()
    elseif cmd == "macro"       then EnsureMacro(false)
    elseif cmd == "fix" or cmd == "fixbutton" then ReattachMinimapButton(true)
    else
        Print("Unknown command: |cffff6666" .. cmd .. "|r. Type |cffffd700/pi help|r")
    end
end

-- ==========================================================
-- AUTO-CLEAR ASSIGNMENT HELPER
-- ==========================================================
-- Tracks whether the player was previously in a group so we can clear
-- the assignment when leaving. Also clears assignment if the assigned
-- player is no longer in the roster (someone left, kicked, etc.) but
-- the player remained.
local prevInGroup = false

local function CheckAutoClearAssignment()
    local inGroup = IsInGroup() or IsInRaid()

    -- Case 1: player just left a group entirely (or had no group on login)
    --   - clear assignment so it doesn't carry across raids
    if prevInGroup and not inGroup then
        if state.assignedTarget then
            Debug("Player left group - clearing PI assignment (was: " ..
                  tostring(state.assignedTarget) .. ")")
            state.assignedTarget = nil
            PIManagerDB.assignedTarget = nil
            selectedPlayer = nil
        end

    -- Case 2: player just joined a group from nothing
    --   - also clear stale assignment from a previous group
    elseif inGroup and not prevInGroup then
        if state.assignedTarget then
            Debug("Player joined group - clearing stale PI assignment (was: " ..
                  tostring(state.assignedTarget) .. ")")
            state.assignedTarget = nil
            PIManagerDB.assignedTarget = nil
            selectedPlayer = nil
        end

    -- Case 3: still in a group, but the assigned target left the roster
    --   - clear assignment so it doesn't silently fall back to random
    elseif inGroup and state.assignedTarget then
        local assignedName = state.assignedTarget
        local found = false
        local groupType = IsInRaid() and "raid" or "party"
        local endIdx = IsInRaid() and GetNumGroupMembers() or 4
        for i = 1, endIdx do
            local unit = groupType .. i
            if UnitExists(unit) then
                local n = UnitName(unit)
                if n == assignedName then found = true; break end
            end
        end
        if not found then
            Debug("Assigned player left the group - clearing PI assignment (was: " ..
                  assignedName .. ")")
            Print("|cffff9966" .. assignedName ..
                  " left the group - PI assignment cleared.|r")
            state.assignedTarget = nil
            PIManagerDB.assignedTarget = nil
            selectedPlayer = nil
        end
    end

    prevInGroup = inGroup
end

-- ==========================================================
-- KEYBINDING METADATA
-- ==========================================================
_G.BINDING_HEADER_PIMANAGER                          = "PI Manager"
_G.BINDING_NAME_CLICK_PIMANAGERCASTBUTTON_LEFTBUTTON = "Cast Power Infusion"

-- ==========================================================
-- EVENT DISPATCHER
-- ==========================================================
-- Critical raid-safety design:
--   * NO SPELL_UPDATE_COOLDOWN (too high-frequency, not needed)
--   * Status line / list refresh ONLY fires when window is visible
--   * UpdateMacro and EnsureMacro (the EditMacro/CreateMacro call sites)
--     are gated by InCombatLockdown - any roster/equipment/bag event during
--     combat is a no-op until PLAYER_REGEN_ENABLED fires.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
-- Additional roster catch-up events. When someone joins a raid, the initial
-- GROUP_ROSTER_UPDATE may fire before their UnitName is resolvable. These
-- secondary events fire shortly after with full info, ensuring late joiners
-- always show up without requiring a /reload.
eventFrame:RegisterEvent("UNIT_NAME_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBER_ENABLE")
eventFrame:RegisterEvent("PARTY_MEMBER_DISABLE")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
-- UNIT_PHASE fires when a group member's phase changes (entering/leaving
-- a phased zone, scenario, warmode mismatch, shard, etc.). Phased players
-- can't be targeted by PI - we treat them as invalid and want the list
-- to reflect their unavailability immediately.
eventFrame:RegisterEvent("UNIT_PHASE")
-- Listen for player-cast successes so we can print "PI cast on <name>"
-- confirmation after Power Infusion lands. Filtered to the player unit.
-- Also listen for UNIT_SPELLCAST_SENT so we capture the actual target
-- name from the game itself (Blizzard-resolved, always correct), rather
-- than relying on the addon's pre-cast target resolution which can go
-- stale between UpdateMacro calls.
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    -- Handler is intentionally NOT wrapped in a pcall(function() ... end):
    -- a closure created by addon code carries taint, which can taint the
    -- execution path of secure/protected operations. Running the body
    -- directly keeps the spellcast event path clean.
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        PIManagerDB = PIManagerDB or {}
        state.assignedTarget   = PIManagerDB.assignedTarget   or nil
        state.useTrinket1      = PIManagerDB.useTrinket1      or false
        state.useTrinket2      = PIManagerDB.useTrinket2      or false
        state.usePotion        = PIManagerDB.usePotion        or false
        state.customPotionID   = PIManagerDB.customPotionID   or nil
        state.customPotionName = PIManagerDB.customPotionName or nil
        state.debug            = PIManagerDB.debug            or false

    elseif event == "PLAYER_LOGIN" then
        BuildMainFrame()
        PreallocateRows()  -- pre-create all 40 row frames so we never CreateFrame in combat
        BuildMinimapButton()
        addon.RefreshAssignedLabel()
        addon.RefreshTrinketLabels()
        UpdateMacro()
        -- NOTE: We intentionally do NOT create the macro here. PLAYER_LOGIN
        -- fires before the macro UI cache is reliably populated; calling
        -- EnsureMacro now would risk the duplicate-creation race. We mark it
        -- pending and let the first PLAYER_ENTERING_WORLD (below) create it
        -- once MacroSystemReady() confirms the cache is live.
        macroPending = true
        Print("|cff66ff66v" .. VERSION .. " loaded.|r " ..
              "Type |cffffd700/pi|r to open or |cffffd700/pi help|r for commands.")
        if state.assignedTarget then
            Print("Currently assigned to: |cffffffff" .. state.assignedTarget .. "|r")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize prevInGroup state on first world entry without auto-clear
        -- (avoid clearing on initial login when we already have a saved assignment)
        prevInGroup = IsInGroup() or IsInRaid()
        UpdateMacro()
        -- Create/resolve the Blizzard macro now that the macro cache is
        -- reliably populated. EnsureMacro's MacroSystemReady guard + duplicate
        -- scan make this safe and idempotent - it creates exactly one macro
        -- if none exists, edits the existing one if present, and refuses to
        -- add more if duplicates are found.
        if macroPending then EnsureMacro(true) end
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshList(); addon.RefreshTrinketLabels(); addon.RefreshStatusLine()
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        CheckAutoClearAssignment()
        UpdateMacro()
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshList(); addon.RefreshAssignedLabel(); addon.RefreshStatusLine()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        UpdateMacro()
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshTrinketLabels()
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        UpdateMacro()

    elseif event == "PLAYER_REGEN_ENABLED" then
        UpdateMacro()
        if macroPending then EnsureMacro(true) end
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshStatusLine()  -- update Ready/CD state once after combat
        end

    elseif event == "UNIT_NAME_UPDATE"
        or event == "PARTY_MEMBER_ENABLE"
        or event == "PARTY_MEMBER_DISABLE"
        or event == "RAID_ROSTER_UPDATE" then
        -- Catch-up refreshes for late-arriving roster info. Cheap when the
        -- window is closed (RefreshList early-exits). When open, just rebuild
        -- the list to pick up the new info. We do NOT call UpdateMacro
        -- here to avoid macro churn from rapid name-update bursts.
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshList(); addon.RefreshAssignedLabel(); addon.RefreshStatusLine()
        end

    elseif event == "UNIT_PHASE" then
        -- A group member's phase changed. Phased players are excluded from
        -- target selection in FindCastTarget (UnitPhaseReason check), so we
        -- refresh the cast button macro to pick a new target if the current
        -- one just phased away.
        UpdateMacro()
        if mainFrame and mainFrame:IsShown() then
            addon.RefreshList(); addon.RefreshStatusLine()
        end

    elseif event == "UNIT_SPELLCAST_SENT" then
        -- arg1=unit ("player"), arg2=target name (game-resolved),
        -- arg3=castGUID, arg4=spellID
        -- This fires the instant the cast goes out, with the actual
        -- target name as the game resolved it (including macro
        -- conditional fallbacks). Store it indexed by castGUID; the
        -- matching SUCCEEDED event picks it up.
        if arg4 == POWER_INFUSION_ID and arg3 then
            pendingPITargetByCastGUID[arg3] = arg2
        end

    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- Clean up the pending entry so it doesn't leak
        -- arg1=unit, arg2=castGUID, arg3=spellID
        if arg3 == POWER_INFUSION_ID and arg2 then
            pendingPITargetByCastGUID[arg2] = nil
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1=unit, arg2=castGUID, arg3=spellID
        if arg3 == POWER_INFUSION_ID then
            -- Get the actual target the game cast on (from the SENT event)
            local actualTarget = arg2 and pendingPITargetByCastGUID[arg2] or nil
            if arg2 then pendingPITargetByCastGUID[arg2] = nil end

            -- Fall back to the assigned name if SENT didn't fire for some
            -- reason (e.g. very rare ordering issues with instant casts).
            local target = actualTarget or
                           lastAssignedName or
                           UnitName("player")

            if target and target ~= "" then
                -- Determine whether this was on the assigned target, on
                -- self, or on a fallback - for the confirmation label.
                local shortName = Ambiguate(target, "short")
                local castOnAssigned = false
                if state.assignedTarget then
                    castOnAssigned =
                        shortName == Ambiguate(state.assignedTarget, "short")
                end
                local castOnSelf = (shortName == Ambiguate(UnitName("player"), "short"))

                local label
                if castOnAssigned then
                    label = "|cffffd700" .. shortName .. "|r |cff888888(assigned)|r"
                elseif castOnSelf then
                    label = "|cffffd700self|r"
                else
                    label = "|cffffd700" .. shortName .. "|r |cff888888(fallback)|r"
                end
                Print("|cff66ff66Power Infusion cast on|r " .. label)
            end

            -- Refresh the status line's cooldown display after the cast.
            if mainFrame and mainFrame:IsShown() and addon.RefreshStatusLine then
                addon.RefreshStatusLine()
            end
        end
    end
end)
