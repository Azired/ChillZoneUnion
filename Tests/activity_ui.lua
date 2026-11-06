-- Inactivity UI regressions against actual native roster reads, authenticated
-- roster/activity synchronization and production UI responders. Only the WoW
-- API fixture supplies last-online tuples; no activity decision is mocked.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation fixture missing")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true))
source = source:sub(1, boundary - 1)
local altered
source, altered = source:gsub('rankName = p%.rankName, online = p%.live, level = 35',
    'rankName = p.rankName, online = p.live, level = p.level or 35, zone = p.zone, class = p.class')
assert(altered == 1, "native roster fixture projection changed")
source, altered = source:gsub('r%.online, nil, "PRIEST"', 'r.online, nil, r.class or "PRIEST"')
assert(altered == 1, "native class fixture changed")
source, altered = source:gsub("    local U = {}", [[
    E.GetGuildRosterLastOnline = function(index)
        c.lastOnlineCalls = (c.lastOnlineCalls or 0) + 1
        local row = c.rows[index]
        local tuple = row and (c.lastOnlineMap or {})[row.name]
        if tuple == "error" then error("native last-online unavailable") end
        if type(tuple) ~= "table" then return nil end
        return unpack(tuple, 1, 4)
    end
    local U = {}]])
assert(altered == 1, "native API fixture injection point changed")
local H = assert(loadstring(source .. "\n" .. [[
return { NewClient = NewClient, SetRosters = SetRosters, Step = Step,
    FrameVisible = FrameVisible, SelectChoice = SelectChoice,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    Advance = function(seconds) time = time + seconds end,
    Sent = function() return sent end, ProtectedCalls = function() return protectedCalls end }
]]))()
assert(type(H.SelectChoice) == "function", "shared real choice callback helper missing")
local failed, ran = 0, 0
local function eq(a, b, message) assert(a == b, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Scenario(name, run)
    ran = ran + 1
    local ok, reason = pcall(run)
    if ok then print("PASS activity UI: " .. name)
    else failed = failed + 1; print("FAIL activity UI: " .. name .. ": " .. tostring(reason)) end
end
local function Event(c, name, ...) c.U.frame.scripts.OnEvent(c.U.frame, name, ...) end
local function BeginVisual(c)
    c.queueCalls, c.requestCalls = 0, 0
    c.sentBefore, c.lastOnlineBefore = H.Sent(), c.lastOnlineCalls or 0
end
local function NoNetwork(c)
    eq(c.queueCalls, 0, "activity UI queued addon messages")
    eq(c.requestCalls, 0, "activity UI requested the guild roster")
    eq(H.Sent(), c.sentBefore, "activity UI sent network packets")
    eq(c.lastOnlineCalls or 0, c.lastOnlineBefore, "activity UI bypassed cached native last-online data")
end
local function World()
    H.Reset()
    local own = H.NewClient("Own Gateway", 1, 0)
    local other = H.NewClient("Other Gateway", 2, 0)
    local c = H.NewClient("Activity Reader", 1, 2)
    local clients, records, tuples = { own, other, c }, {}, {}
    own.zone, other.zone, c.zone = "Focus Zone", "Focus Zone", "Focus Zone"
    local function Member(name, guild, days, class, rank, zone, tuple)
        local member = H.NewClient(name, guild, rank or 3)
        member.live, member.officer = false, false
        member.class, member.zone, member.rankName = class or "PRIEST", zone or "Focus Zone", rank == 4 and "Новичок" or "Рейдер"
        clients[#clients + 1] = member
        records[name] = { name = name, guild = guild, days = days, class = member.class,
            rankName = member.rankName, zone = member.zone, online = false }
        tuples[name] = tuple or (days and { 0, 0, days, 0 })
    end
    Member("Own Seven", 1, 7, "MAGE", 3)
    Member("Own Fourteen", 1, 14, "PRIEST", 3, "Other Zone")
    Member("Own Thirty", 1, 30, "MAGE", 4, "Dark Zone")
    Member("Own Six", 1, 6, "MAGE", 3)
    Member("Own Unknown", 1, nil, "MAGE", 3)
    Member("Own Invalid", 1, nil, "PRIEST", 3, "Other Zone", "error")
    Member("Own Zero", 1, 0, "PRIEST", 3)
    Member("Remote Seven", 2, 7, "MAGE", 3)
    Member("Remote Fourteen", 2, 14, "PRIEST", 3, "Other Zone")
    Member("Remote Thirty", 2, 30, "MAGE", 4, "Dark Zone")
    Member("Remote Unknown", 2, nil, "MAGE", 3)
    Member("Remote Recent", 2, 2, "PRIEST", 3)
    for i = 1, 18 do Member(("Own Batch%02d"):format(i), 1, 45, i % 2 == 0 and "MAGE" or "PRIEST", 3,
        i % 2 == 0 and "Dark Zone" or "Focus Zone", { 0, 1, 17, 0 }) end
    for i = 1, 12 do Member(("Remote Batch%02d"):format(i), 2, 45, i % 2 == 0 and "MAGE" or "PRIEST", 3,
        i % 2 == 0 and "Dark Zone" or "Focus Zone", { 0, 1, 17, 0 }) end
    for _, client in ipairs(clients) do client.lastOnlineMap = tuples end
    H.SetRosters(0)
    for _, client in ipairs({ own, other, c }) do Event(client, "PLAYER_LOGIN") end
    assert(own.U.Link(other.name), "fixture guild pairing failed"); H.Step(70)
    assert(c.U.Connected() and c.U.RosterFresh(1) and c.U.RosterFresh(2), "fixture has no fresh authenticated rosters")
    assert(type(c.U.ActivityInfo) == "function" and type(c.U.MatchesInactivity) == "function", "activity backend missing")
    local ownInfo = c.U.ActivityInfo(assert(c.U.own["Own Seven"]))
    local foreign = c.U.db.rosters[2].rows
    local remoteInfo = c.U.ActivityInfo(assert(foreign["Remote Seven"]))
    assert(ownInfo.known and ownInfo.fresh and remoteInfo.known and remoteInfo.fresh,
        "native last-online fixture did not synchronize activity metadata")
    eq(ownInfo.minDays, 7, "own native seven-day tuple changed")
    eq(remoteInfo.minDays, 7, "foreign native seven-day tuple changed")
    c.E.MenuUtil = nil
    local queue, batch, request = c.U.Queue, c.U.QueueBatch, c.U.RequestRoster
    c.U.Queue = function(...) c.queueCalls = c.queueCalls + 1; return queue(...) end
    c.U.QueueBatch = function(...) c.queueCalls = c.queueCalls + 1; return batch(...) end
    c.U.RequestRoster = function(...) c.requestCalls = c.requestCalls + 1; return request(...) end
    c.records = records
    BeginVisual(c); c.U.OpenRoster()
    return c
end
local function Button(c, key) return assert(c.U.choiceButtons[key], "missing selector " .. key) end
local function Choose(c, key, value) H.SelectChoice(c, Button(c, key), value) end
local function Click(frame)
    assert(frame and H.FrameVisible(frame) and frame:IsEnabled() and frame.scripts.OnClick, "missing visible enabled action")
    frame.scripts.OnClick(frame, "LeftButton")
end
local function Rows(c)
    local rows = {}
    for _, frame in ipairs(c.allFrames) do if frame.row and H.FrameVisible(frame) then rows[#rows + 1] = frame end end
    return rows
end
local function Search(c, text)
    local box = assert(c.E.ChillZoneUnionWindow.czuRosterSearch, "roster search marker missing")
    box:SetText(text); box.scripts.OnTextChanged(box, true)
end
local function Offline(c, checked)
    local box = assert(c.E.ChillZoneUnionWindow.czuRosterOffline, "offline marker missing")
    box:SetChecked(checked); Click(box)
end
local function Collect(c)
    local result, seen = {}, {}
    local first = Rows(c)[1]
    if not first then return result end
    local parent, previous = first.parent, nil
    for _ = 1, 80 do
        local current = Rows(c)
        local key = current[1] and current[1].row.name .. "@" .. current[1].row.guild
        if key == previous then break end
        previous = key
        for _, frame in ipairs(current) do
            local id = frame.row.name .. "@" .. frame.row.guild
            if not seen[id] then result[#result + 1], seen[id] = frame.row, true end
        end
        parent.scripts.OnMouseWheel(parent, -1)
    end
    return result
end
local function Expected(c, days, guild, predicate)
    local set = {}
    for name, record in pairs(c.records) do
        if record.days and record.days >= days and (guild == nil or guild == record.guild)
            and (not predicate or predicate(record)) then set[name .. "@" .. record.guild] = true end
    end
    return set
end
local function SameMembers(actual, expected, message)
    local count, wanted, seen = 0, 0, {}
    for id in pairs(expected) do wanted = wanted + 1 end
    for _, row in ipairs(actual) do
        local id = row.name .. "@" .. row.guild
        assert(expected[id], message .. ": unexpected " .. id)
        assert(not seen[id], message .. ": duplicate " .. id)
        seen[id], count = true, count + 1
    end
    eq(count, wanted, message .. ": missing members")
end
local function TooltipText(c)
    local lines = { c.E.GameTooltip:GetText() }
    for _, line in ipairs(c.E.GameTooltip.lines or {}) do
        for _, text in ipairs(line) do if type(text) == "string" then lines[#lines + 1] = text end end
    end
    return table.concat(lines, "\n")
end

Scenario("seven columns expose cached native last-online for members without the addon", function()
    local c = World()
    local header = c.E.ChillZoneUnionColumnlastSeen
    assert(header and header.scripts.OnClick, "last-online sort column missing")
    for _, key in ipairs({ "name", "class", "level", "zone", "rank", "lastSeen" }) do
        local column = c.E["ChillZoneUnionColumn" .. key]
        assert(column and H.FrameVisible(column) and column.scripts.OnClick, "visible sortable roster column missing: " .. key)
    end
    local window = c.E.ChillZoneUnionWindow
    assert(window.czuRosterSearch.czuRosterSearch and window.czuRosterOffline.czuRosterOffline, "stable roster control markers missing")
    Offline(c, true); Search(c, "Own Thirty")
    local frame = assert(Rows(c)[1], "known offline member missing")
    for _, key in ipairs({ "name", "classText", "level", "zone", "rank", "guild", "activity" }) do
        assert(frame[key] and H.FrameVisible(frame[key]), "visible roster column missing: " .. key)
    end
    assert(frame.activity and H.FrameVisible(frame.activity) and frame.activity:GetText():find("30", 1, true),
        "visible column does not show native inactivity")
    local info = c.U.ActivityInfo(frame.row)
    assert(info.known and info.fresh and type(info.details) == "string", "known member lost activity details")
    assert(c.U.AddonInfo(frame.row.name, frame.row.guild).known ~= true, "fixture member unexpectedly advertised an addon")
    frame.scripts.OnEnter(frame)
    local text = TooltipText(c)
    assert(text:find(c.U.SafeDisplay(info.details), 1, true), "roster tooltip omits native activity details")
    assert(text:find("Статус аддона неизвестен", 1, true), "native inactivity incorrectly requires an addon badge")
    NoNetwork(c)
end)

Scenario("7 14 and 30 day choices include only confirmed offline matches", function()
    local c = World()
    for _, days in ipairs({ 7, 14, 30 }) do
        Choose(c, "roster-activity", days)
        eq(Button(c, "roster-activity").czuChoiceValue(), days, "direct inactivity choice failed")
        local box = c.E.ChillZoneUnionWindow.czuRosterOffline
        assert(box:GetChecked() and not box:IsEnabled(), "active inactivity filter did not force and lock offline display")
        SameMembers(Collect(c), Expected(c, days), "inactivity threshold " .. days)
    end
    Choose(c, "roster-activity", 0)
    local box = c.E.ChillZoneUnionWindow.czuRosterOffline
    assert(box:IsEnabled() and box:GetChecked(), "all-members choice did not unlock and preserve offline display")
    NoNetwork(c)
end)

Scenario("activity combines with guild class rank name and text-location search", function()
    local c = World(); Choose(c, "roster-activity", 7)
    Choose(c, "roster-scope", 2)
    Search(c, c.U.ClassInfo("MAGE").label)
    SameMembers(Collect(c), Expected(c, 7, 2, function(row) return row.class == "MAGE" end), "guild and class filter")
    Search(c, "Рейдер")
    SameMembers(Collect(c), Expected(c, 7, 2, function(row) return row.rankName == "Рейдер" end), "guild and rank filter")
    Search(c, "Dark Zone")
    SameMembers(Collect(c), Expected(c, 7, 2, function(row) return row.zone == "Dark Zone" end), "guild and location search")
    Search(c, "Remote Seven")
    SameMembers(Collect(c), Expected(c, 7, 2, function(row) return row.name == "Remote Seven" end), "guild and name search")
    NoNetwork(c)
end)

Scenario("map location and inactivity replace conflicting filters explicitly", function()
    local c = World()
    assert(c.U.OpenLocationRoster("Focus Zone", 0), "map location rejected")
    for _, frame in ipairs(Rows(c)) do assert(frame.row.online and frame.row.zone == "Focus Zone", "map view is not exact fresh online") end
    Choose(c, "roster-activity", 7)
    local rows = Collect(c)
    SameMembers(rows, Expected(c, 7), "activity retained the incompatible exact online location")
    local hasOtherZone = false
    for _, row in ipairs(rows) do if row.zone ~= "Focus Zone" then hasOtherZone = true end end
    assert(hasOtherZone, "activity did not clear exact online location")
    assert(c.U.OpenLocationRoster("Focus Zone", 0), "second map location rejected")
    eq(Button(c, "roster-activity").czuChoiceValue(), 0, "map location retained an incompatible inactivity threshold")
    local box = c.E.ChillZoneUnionWindow.czuRosterOffline
    assert(box:IsEnabled() and not box:GetChecked(), "map location did not restore fresh-online controls")
    assert(#Rows(c) > 0, "map location became empty after inactivity")
    for _, frame in ipairs(Rows(c)) do assert(frame.row.online and frame.row.zone == "Focus Zone", "map location is not exact after inactivity") end
    NoNetwork(c)
end)

Scenario("reselecting the current threshold preserves scroll and selection", function()
    local c = World(); Choose(c, "roster-activity", 7)
    local first = assert(Rows(c)[1]); first.parent.scripts.OnMouseWheel(first.parent, -2)
    local frame = assert(Rows(c)[1]); local name = frame.row.name
    Click(frame)
    local selected = frame.parent.selection:GetText()
    assert(selected:find(name, 1, true), "fixture roster selection missing")
    Choose(c, "roster-activity", 7)
    eq(Rows(c)[1].row.name, name, "reselecting the same threshold reset scroll")
    eq(frame.parent.selection:GetText(), selected, "reselecting the same threshold reset the selected member")
    Choose(c, "roster-activity", 14)
    assert(not frame.parent.selection:GetText():find(name, 1, true), "changing threshold retained the selected member")
    local expectedFirst
    for id in pairs(Expected(c, 14)) do local n = id:match("^(.-)@"); if not expectedFirst or c.U.Fold(n) < c.U.Fold(expectedFirst) then expectedFirst = n end end
    eq(Rows(c)[1].row.name, expectedFirst, "changing threshold did not reset scroll")
    NoNetwork(c)
end)

Scenario("last-login sort is chronological in both directions with unknown entries last", function()
    local c = World(); Offline(c, true)
    local header = assert(c.E.ChillZoneUnionColumnlastSeen)
    for direction = 1, 2 do
        Click(header)
        local unknown, previous, unknownCount = false, nil, 0
        for _, row in ipairs(Collect(c)) do
            local info = c.U.ActivityInfo(row)
            if not info.known then unknown, unknownCount = true, unknownCount + 1
            else
                assert(not unknown, "known last-login data sorted after unknown data")
                local value = info.online and info.sourceAt or info.sourceAt - info.minDays * 86400
                if previous then
                    assert(direction == 1 and value >= previous or direction == 2 and value <= previous,
                        "last-login sort direction is not chronological")
                end
                previous = value
            end
        end
        assert(unknownCount >= 3, "fixture unknown native activity entries disappeared")
    end
    NoNetwork(c)
end)

Scenario("stale activity remains visibly saved and is excluded from inactivity filtering", function()
    local c = World()
    H.Advance(61)
    c.U.Refresh()
    Offline(c, true); Search(c, "Own Thirty")
    local frame = assert(Rows(c)[1], "saved member missing")
    local info = c.U.ActivityInfo(frame.row)
    assert(info.known and not info.fresh, "old native activity was presented as fresh")
    assert(frame.activity:GetText():find("*", 1, true), "saved activity lacks a visible stale marker")
    frame.scripts.OnEnter(frame)
    assert(TooltipText(c):find("Сохранено", 1, true), "stale tooltip does not explain saved data")
    Search(c, ""); Choose(c, "roster-activity", 7)
    eq(#Rows(c), 0, "stale last-online rows satisfy a current inactivity filter")
    NoNetwork(c)
end)

eq(H.ProtectedCalls(), 0, "activity UI invoked protected guild actions")
print("Activity UI scenarios: " .. (ran - failed) .. "/" .. ran)
assert(failed == 0, tostring(failed) .. " activity UI scenarios failed")
