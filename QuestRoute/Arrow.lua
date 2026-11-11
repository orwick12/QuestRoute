-- QuestRoute: the on-screen arrow frame.
--
-- In:  Arrow.SetTarget(leg) where leg = { stop, point } (or nil to clear); Arrow.SetHint(text)
-- Out: a draggable frame with a rotating arrow, quest name, step text, distance, and Reroute / Skip buttons.
-- The OnUpdate only does trig against the current target (~20x/sec); it never recomputes the route.

local _, ns = ...
local Arrow = {}
ns.Arrow = Arrow

local floor = math.floor
local UPDATE_INTERVAL = 0.05
local ARRIVED_YARDS = 15

local frame, arrowTex, titleText, stepText, distText, hintText
local target -- current leg
local elapsedSince = 0

local KIND_COLOR = {
    pickup = { 1, 0.82, 0 },     -- yellow, like a "!" quest giver
    objective = { 0.4, 0.8, 1 }, -- blue
    turnin = { 0.3, 1, 0.3 },    -- green
}

local function stepLine(leg)
    local stop, who = leg.stop, leg.point and leg.point.name
    if leg.point and leg.point.drop then
        local chance = ns.Router.FormatChance(leg.point.chance)
        return "Loot " .. leg.point.drop .. " from " .. (who or "?") .. (chance and (" (" .. chance .. ")") or "")
    end
    if stop.kind == "pickup" then return "Pick up from " .. (who or "quest giver") end
    if stop.kind == "turnin" then return "Turn in to " .. (who or "quest ender") end
    if who and who ~= "" then return stop.step .. "  (" .. who .. ")" end
    return stop.step
end

local function onUpdate(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < UPDATE_INTERVAL then return end
    elapsedSince = 0
    if not target or not target.point then return end

    local HBD = ns.Collect.HBD
    local px, py, instance = HBD:GetPlayerWorldPosition()
    local facing = GetPlayerFacing()
    local p = target.point
    if not px or not facing or instance ~= p.instance then
        -- No position (e.g. inside an instance) or target on another continent.
        arrowTex:Hide()
        distText:SetText(not px and "position unavailable here" or "on another continent")
        return
    end

    local angle, dist = HBD:GetWorldVector(instance, px, py, p.x, p.y)
    if not angle then return end
    arrowTex:Show()
    arrowTex:SetRotation(angle - facing)
    if dist <= ARRIVED_YARDS then
        arrowTex:SetVertexColor(0.3, 1, 0.3)
        distText:SetText("here")
    else
        local c = KIND_COLOR[target.stop.kind] or KIND_COLOR.objective
        arrowTex:SetVertexColor(c[1], c[2], c[3])
        distText:SetText(floor(dist + 0.5) .. " yd")
    end
end

local function makeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

function Arrow.Create(db, handlers)
    if frame then return frame end
    frame = CreateFrame("Frame", "QuestRouteFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(240, 150)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.6)
    end

    if db.point then
        frame:SetPoint(db.point[1], UIParent, db.point[3], db.point[4], db.point[5])
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.point = { point, "UIParent", relPoint, x, y }
    end)

    arrowTex = frame:CreateTexture(nil, "ARTWORK")
    arrowTex:SetTexture("Interface\\AddOns\\QuestRoute\\arrow")
    arrowTex:SetSize(48, 48)
    arrowTex:SetPoint("TOP", frame, "TOP", 0, -6)

    titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", arrowTex, "BOTTOM", 0, -2)
    titleText:SetWidth(228)
    titleText:SetWordWrap(false)

    stepText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stepText:SetPoint("TOP", titleText, "BOTTOM", 0, -2)
    stepText:SetWidth(228)
    stepText:SetWordWrap(false)

    distText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    distText:SetPoint("TOP", stepText, "BOTTOM", 0, -2)

    hintText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintText:SetPoint("TOP", distText, "BOTTOM", 0, -2)
    hintText:SetWidth(228)
    hintText:SetWordWrap(false)

    local reroute = makeButton(frame, "Reroute", 80, handlers.reroute)
    reroute:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 6)
    local skip = makeButton(frame, "Skip", 80, handlers.skip)
    skip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)
    skip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Skip this quest")
        GameTooltip:AddLine("Leaves it out of the route until you /qr unskip it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    skip:SetScript("OnLeave", GameTooltip_Hide)

    frame:SetScript("OnUpdate", onUpdate)
    Arrow.SetTarget(nil)
    if db.hidden then frame:Hide() end
    return frame
end

function Arrow.SetTarget(leg)
    target = leg
    if not frame then return end
    if not leg then
        arrowTex:Hide()
        titleText:SetText("QuestRoute")
        stepText:SetText("No quests to route")
        distText:SetText("")
        return
    end
    local stop = leg.stop
    local level = stop.level and stop.level > 0 and ("[" .. stop.level .. "] ") or ""
    titleText:SetText(level .. (stop.questName or ("Quest " .. stop.questId)))
    stepText:SetText(stepLine(leg))
    elapsedSince = UPDATE_INTERVAL -- redraw on the next frame
end

function Arrow.SetHint(text)
    if hintText then hintText:SetText(text or "") end
end

function Arrow.Toggle(db)
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
    db.hidden = not frame:IsShown()
    return frame:IsShown()
end
