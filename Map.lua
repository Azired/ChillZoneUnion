local _, U = ...

-- These markers describe roster locations. Their coordinates are always the
-- centre of a map, never a character position, and require no network requests.
local Map = { dirty = true, active = {}, pool = {}, lastRefresh = -100 }
U.UnionMap = Map
local MAX_PINS, REFRESH_SECONDS = 128, 2
local byName, visited, indexReady = {}, {}, false
local pins, watcher, hookedMap
local status = { mappedZones = 0, unmappedZones = 0, unknownOnline = 0,
    visiblePins = 0, limited = 0, onlineComplete = false }
local vanillaMaps = {
    947, 946, 1414, 1415, 1411, 1412, 1413,
    1416, 1417, 1418, 1419, 1420, 1421, 1422, 1423, 1424, 1425,
    1426, 1427, 1428, 1429, 1430, 1431, 1432, 1433, 1434, 1435,
    1436, 1437, 1438, 1439, 1440, 1441, 1442, 1443, 1444, 1445,
    1446, 1447, 1448, 1449, 1450, 1451, 1452, 1453, 1454, 1455,
    1456, 1457, 1458, 1459, 1460, 1461,
}

local function Public(value) return not U.Public or U.Public(value) end
local function ZoneKey(name)
    if not Public(name) or type(name) ~= "string" or #name > 160 then return end
    local trimmed = U.Trim and U.Trim(name) or name:match("^%s*(.-)%s*$")
    if trimmed == "" then return end
    return U.Fold and U.Fold(trimmed) or trimmed:lower()
end
local function Number(value)
    return Public(value) and type(value) == "number" and value == value and value >= 0 and value < math.huge
end
local function SafeText(value)
    if U.SafeDisplay then return U.SafeDisplay(value) end
    return tostring(value or ""):gsub("|", "||")
end
local function Now() return U.clock and U.clock() or GetTime and GetTime() or 0 end
local function MapVisible()
    return WorldMapFrame and type(WorldMapFrame.IsShown) == "function" and WorldMapFrame:IsShown()
end
local function Library(name)
    if not LibStub then return end
    local ok, lib = pcall(LibStub, name, true)
    if ok and type(lib) == "table" then return lib end
end
local function AvailablePins()
    local lib = Library("HereBeDragons-Pins-2.0")
    if not C_Map or type(C_Map.GetMapInfo) ~= "function" or not WorldMapFrame
        or not lib or type(lib.AddWorldMapIconMap) ~= "function"
        or type(lib.RemoveAllWorldMapIcons) ~= "function" then return end
    return lib
end

-- Prefer a named zone over its floor/micro maps. Equal-priority homonyms are
-- deliberately ambiguous: a roster's text alone cannot identify their map.
local function AddMap(info)
    if not Public(info) or type(info) ~= "table" then return end
    local id, mapType = info.mapID, info.mapType
    if not Number(id) or id < 1 or id % 1 ~= 0 then return end
    local key = ZoneKey(info.name)
    if not key or not Number(mapType) or mapType < 3 then return end
    local rank = mapType == 3 and 3 or mapType == 4 and 2 or 1
    local current = byName[key]
    if not current or rank > current.rank then
        byName[key] = { id = id, rank = rank }
    elseif current.rank == rank and current.id ~= id then
        current.ambiguous = true
    end
end
local function MapInfo(id)
    if not C_Map or type(C_Map.GetMapInfo) ~= "function" then return end
    local ok, info = pcall(C_Map.GetMapInfo, id)
    if ok and Public(info) and type(info) == "table" then return info end
end
local function BuildIndex()
    if indexReady or not C_Map or type(C_Map.GetMapInfo) ~= "function" then return end
    byName, visited = {}, {}
    local queue, cursor, total = {}, 1, 0
    for _, id in ipairs(vanillaMaps) do queue[#queue + 1] = id end
    while cursor <= #queue and total < 4096 do
        local id = queue[cursor]
        cursor = cursor + 1
        if not visited[id] then
            visited[id], total = true, total + 1
            AddMap(MapInfo(id))
            if type(C_Map.GetMapChildrenInfo) == "function" then
                local ok, children = pcall(C_Map.GetMapChildrenInfo, id)
                if ok and Public(children) and type(children) == "table" then
                    for i = 1, math.min(#children, 512) do
                        local child = children[i]
                        AddMap(child)
                        local childID = Public(child) and type(child) == "table" and child.mapID
                        if Number(childID) and childID > 0 and not visited[childID] and #queue < 16384 then
                            queue[#queue + 1] = childID
                        end
                    end
                end
            end
        end
    end
    -- An API temporarily returning no data may become usable after login.
    indexReady = next(byName) ~= nil
end
function U.MapIDForZone(name)
    local key = ZoneKey(name)
    if not key then return end
    BuildIndex()
    local candidate = byName[key]
    if candidate and not candidate.ambiguous then return candidate.id end
end

function U.UnionMapPinsEnabled()
    return not U.db or U.db.showMapPins ~= false
end
local function Tooltip(pin)
    if not GameTooltip or not pin.zoneRow then return end
    local row, complete = pin.zoneRow, pin.onlineComplete
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    if GameTooltip.ClearLines then GameTooltip:ClearLines() end
    GameTooltip:AddLine(SafeText(pin.zoneName), 1, 0.85, 0.3)
    GameTooltip:AddLine((complete and "Сейчас в локации: " or "Подтверждено онлайн: не менее ") .. tostring(row.knownOnline), 1, 1, 1)
    for guild = 1, #U.GUILDS do
        local data = row.guilds and row.guilds[guild]
        local count = data and data.online
        GameTooltip:AddDoubleLine(SafeText(U.GUILDS[guild]), Number(count) and tostring(count) or "нет свежих данных",
            0.75, 0.85, 0.85, 1, 1, 1)
    end
    if not complete then
        GameTooltip:AddLine("Неполные данные: учтён только свежий онлайн.", 1, 0.75, 0.3, true)
    end
    GameTooltip:AddLine("Метка обозначает центр локации.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Нажмите, чтобы открыть состав в этой локации.", 0.4, 0.9, 0.8, true)
    GameTooltip:Show()
end
local function HideTooltip(pin)
    pin.hovered = nil
    if GameTooltip and (not GameTooltip.IsOwned or GameTooltip:IsOwned(pin)) then GameTooltip:Hide() end
end
local function CreatePin()
    local pin = CreateFrame("Button", nil, UIParent)
    pin:SetSize(28, 24)
    pin:EnableMouse(true)
    if pin.RegisterForClicks then pin:RegisterForClicks("LeftButtonUp") end
    local border = pin:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(0.25, 0.85, 0.75, 0.95)
    border:SetAllPoints()
    local background = pin:CreateTexture(nil, "BORDER")
    background:SetTexture("Interface\\Buttons\\WHITE8X8")
    background:SetVertexColor(0.035, 0.12, 0.14, 0.96)
    background:SetPoint("TOPLEFT", 2, -2)
    background:SetPoint("BOTTOMRIGHT", -2, 2)
    pin.count = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pin.count:SetPoint("CENTER", 0, 0)
    pin:SetScript("OnEnter", function(self) self.hovered = true; Tooltip(self) end)
    pin:SetScript("OnLeave", HideTooltip)
    pin:SetScript("OnHide", HideTooltip)
    pin:SetScript("OnClick", function(self)
        if self.zoneName and U.OpenLocationRoster then
            if WorldMapFrame then
                if HideUIPanel then pcall(HideUIPanel, WorldMapFrame)
                elseif WorldMapFrame.Hide then WorldMapFrame:Hide() end
            end
            U.OpenLocationRoster(self.zoneName)
        end
    end)
    return pin
end
local function ClearPins()
    if pins and #Map.active > 0 then pcall(pins.RemoveAllWorldMapIcons, pins, Map) end
    for i = #Map.active, 1, -1 do
        local pin = Map.active[i]
        HideTooltip(pin)
        pin:Hide()
        pin.zoneName, pin.zoneRow = nil, nil
        Map.pool[#Map.pool + 1], Map.active[i] = pin, nil
    end
    status.visiblePins = 0
    Map.signature = nil
end
local function Gather(overview)
    local rows, counts = {}, { mappedZones = 0, unmappedZones = 0, unknownOnline = 0,
        visiblePins = 0, limited = 0, onlineComplete = overview.onlineComplete == true }
    for _, row in ipairs(overview.zones or {}) do
        if Number(row.knownOnline) and row.knownOnline > 0 then
            if row.unknown or not ZoneKey(row.name) then
                counts.unknownOnline = counts.unknownOnline + row.knownOnline
            else
                local mapID = U.MapIDForZone(row.name)
                if mapID then
                    counts.mappedZones = counts.mappedZones + 1
                    rows[#rows + 1] = { row = row, mapID = mapID }
                else counts.unmappedZones = counts.unmappedZones + 1 end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.row.knownOnline ~= b.row.knownOnline then return a.row.knownOnline > b.row.knownOnline end
        return a.row.name < b.row.name
    end)
    counts.limited = math.max(0, #rows - MAX_PINS)
    return rows, counts
end
function U.UnionMapStatus(overview)
    local current = status
    if type(overview) == "table" then local _; _, current = Gather(overview) end
    local copy = {}
    for key, value in pairs(current) do copy[key] = value end
    copy.enabled, copy.available = U.UnionMapPinsEnabled(), AvailablePins() ~= nil
    if not copy.available then copy.reason = "Карта этого клиента недоступна." end
    return copy
end
local function Signature(rows, complete)
    local values = { complete and "complete" or "partial" }
    for i = 1, math.min(#rows, MAX_PINS) do
        local item, counts = rows[i], {}
        for guild = 1, #U.GUILDS do
            counts[guild] = tostring(item.row.guilds and item.row.guilds[guild] and item.row.guilds[guild].online)
        end
        values[#values + 1] = tostring(item.mapID) .. ":" .. #item.row.name .. ":" .. item.row.name .. ":"
            .. tostring(item.row.knownOnline) .. ":" .. table.concat(counts, ",")
    end
    return table.concat(values, "|")
end
function U.MarkMapDirty() Map.dirty = true end

-- Snapshot at most once every two seconds while shown. Reuse a fixed-size pool
-- and avoid touching the map provider when the displayed counts did not change.
function U.RefreshUnionMap()
    Map.dirty = true
    if not U.UnionMapPinsEnabled() then ClearPins(); return false end
    if not MapVisible() or not U.db or not U.OverviewStatistics then return false end
    local available = AvailablePins()
    if not available then ClearPins(); return false end
    if Now() - Map.lastRefresh < REFRESH_SECONDS then return false end
    Map.lastRefresh, Map.dirty = Now(), false
    if pins and pins ~= available then ClearPins() end
    pins = available
    local overview = U.OverviewStatistics()
    local rows, counts = Gather(overview)
    local signature = Signature(rows, counts.onlineComplete)
    status = counts
    if signature == Map.signature then
        status.visiblePins = #Map.active
        local byZone = {}
        for _, item in ipairs(rows) do byZone[item.row.name] = item.row end
        for _, pin in ipairs(Map.active) do
            pin.zoneRow = byZone[pin.zoneName]
            if pin.hovered and pin:IsShown() then Tooltip(pin) end
        end
        return true
    end
    local hoveredZone
    for _, pin in ipairs(Map.active) do if pin.hovered then hoveredZone = pin.zoneName end end
    ClearPins()
    local failed = false
    for i = 1, math.min(#rows, MAX_PINS) do
        local item = rows[i]
        local pin = table.remove(Map.pool) or CreatePin()
        pin.zoneName, pin.zoneRow, pin.onlineComplete = item.row.name, item.row, counts.onlineComplete
        local count = item.row.knownOnline
        pin:SetSize(count >= 100 and 34 or 28, 24)
        pin.count:SetText(count >= 1000 and string.format("%.1fk", count / 1000) or tostring(count))
        local ok, added = pcall(pins.AddWorldMapIconMap, pins, Map, pin, item.mapID, 0.5, 0.5,
            HBD_PINS_WORLDMAP_SHOW_WORLD or 3)
        if ok and added ~= false then
            Map.active[#Map.active + 1] = pin
            if hoveredZone == pin.zoneName and pin:IsShown() then pin.hovered = true; Tooltip(pin) end
        else
            failed = true
            pin:Hide()
            pin.zoneName, pin.zoneRow = nil, nil
            Map.pool[#Map.pool + 1] = pin
            status.unmappedZones = status.unmappedZones + 1
            status.mappedZones = math.max(0, status.mappedZones - 1)
        end
    end
    status.visiblePins = #Map.active
    if not failed then Map.signature = signature end
    return true
end
function U.SetUnionMapPins(enabled)
    if not U.db then return false end
    U.db.showMapPins = enabled == true
    Map.dirty = true
    if enabled then
        if watcher and MapVisible() then watcher:Show() end
        U.RefreshUnionMap()
    else
        if watcher then watcher:Hide() end
        ClearPins()
    end
    return true
end

local function InstallHooks()
    if not WorldMapFrame or type(WorldMapFrame.HookScript) ~= "function" then return end
    if hookedMap == WorldMapFrame then return end
    hookedMap = WorldMapFrame
    WorldMapFrame:HookScript("OnShow", function()
        Map.dirty = true
        if watcher and U.UnionMapPinsEnabled() then watcher:Show() end
        U.RefreshUnionMap()
    end)
    WorldMapFrame:HookScript("OnHide", function()
        Map.dirty = true
        if watcher then watcher:Hide() end
        for _, pin in ipairs(Map.active) do HideTooltip(pin) end
    end)
    if watcher and MapVisible() and U.UnionMapPinsEnabled() then watcher:Show() end
end
local function InitializeMap()
    if U.db and U.db.showMapPins == nil then U.db.showMapPins = true end
    indexReady = false
    if not watcher and type(CreateFrame) == "function" then
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnUpdate", function()
            if U.UnionMapPinsEnabled() and MapVisible() and Now() - Map.lastRefresh >= REFRESH_SECONDS then U.RefreshUnionMap() end
        end)
        watcher:SetScript("OnEvent", function(_, event, addon)
            if event == "ADDON_LOADED" and addon == "Blizzard_WorldMap" then InstallHooks() end
            Map.dirty = true
        end)
        if watcher.RegisterEvent then
            for _, event in ipairs({ "ADDON_LOADED", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
                pcall(watcher.RegisterEvent, watcher, event)
            end
        end
        watcher:Hide()
    end
    InstallHooks()
    if MapVisible() then U.RefreshUnionMap() end
end
function U.OpenUnionMap(zoneName)
    if not C_Map or type(C_Map.GetMapInfo) ~= "function" then return false end
    local mapID = 947
    if zoneName ~= nil then mapID = U.MapIDForZone(zoneName) end
    if not mapID then return false end
    if not WorldMapFrame then
        local loader = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
        if type(loader) == "function" then pcall(loader, "Blizzard_WorldMap") end
    end
    if not WorldMapFrame or type(WorldMapFrame.SetMapID) ~= "function" then return false end
    InitializeMap()
    if ShowUIPanel then pcall(ShowUIPanel, WorldMapFrame)
    elseif WorldMapFrame.Show then WorldMapFrame:Show() end
    local ok = pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID)
    if ok then U.RefreshUnionMap() end
    return ok
end

if U.On then
    U.On("PLAYER_LOGIN", InitializeMap)
    U.On("GUILD_ROSTER_UPDATE", U.MarkMapDirty)
    U.On("PLAYER_GUILD_UPDATE", U.MarkMapDirty)
end
