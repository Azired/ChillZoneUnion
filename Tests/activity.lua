-- Native last-online and authenticated activity regressions. Only the WoW API
-- fixture is injected; every activity decision runs in the production modules.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation fixture missing")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true))
source = source:sub(1, boundary - 1)
source = source:gsub("    local U = {}", [[
    c.activityValues, c.activityCalls = {}, {}
    if CZU_ACTIVITY_NATIVE_MODE ~= "absent" then
        E.GetGuildRosterLastOnline = function(index)
            assert(type(index) == "number" and index == math.floor(index), "native last-online requires a roster index")
            local row = assert(c.rows[index], "native last-online index is out of bounds")
            c.activityCalls[row.name] = (c.activityCalls[row.name] or 0) + 1
            local values = c.activityValues[row.name]
            if values and values.error then error("injected native last-online error") end
            if values then return unpack(values, 1, 4) end
        end
    end
    local U = {}]], 1)
local H = assert(loadstring(source .. "\n" .. [[
return { NewClient = NewClient, SetRosters = SetRosters, Step = Step,
    FrameVisible = FrameVisible, SelectChoice = SelectChoice, UIObject = UIObject,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    Now = function() return time end, Advance = function(seconds) time = time + seconds end,
    SetFilter = function(filter) deliveryFilter = filter end,
    ClearWire = function() wire = {} end, Count = Count,
    ProtectedCalls = function() return protectedCalls end }
]]))()
local failed, ran = 0, 0
local function eq(a, b, message) assert(a == b, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Near(a, b, message) assert(type(a) == "number" and math.abs(a - b) < 0.000001, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Scenario(name, run)
    ran = ran + 1
    local ok, reason = pcall(run)
    if ok then print("PASS activity: " .. name)
    else failed = failed + 1; print("FAIL activity: " .. name .. ": " .. tostring(reason)) end
end
local function Event(c, event, ...) c.U.frame.scripts.OnEvent(c.U.frame, event, ...) end
local function Client(name, guild, rank, mode, saved)
    local previous = CZU_ACTIVITY_NATIVE_MODE
    CZU_ACTIVITY_NATIVE_MODE = mode
    local ok, c = pcall(H.NewClient, name, guild, rank, saved)
    CZU_ACTIVITY_NATIVE_MODE = previous
    assert(ok, c)
    return c
end
local function AddNative(c, name, online, values)
    c.rows[#c.rows + 1] = { name = name, rank = 2, level = 40, online = online, zone = "Native Zone" }
    c.activityValues[name] = values
end
local function Read(c)
    assert(c.U.ReadRoster(), "activity fixture failed to read native membership")
end
local function Local(mode)
    H.Reset()
    local c = Client("Activity Reader", 1, 2, mode)
    H.SetRosters(0)
    Event(c, "PLAYER_LOGIN")
    return c
end
local function Info(c, name, guild)
    guild = guild or c.guild
    local cache = c.U.db.rosters[guild]
    local row = guild == c.guild and c.U.own[name] or cache and cache.rows[name]
    assert(row, "activity fixture member is missing: " .. name)
    return c.U.ActivityInfo(row), row
end
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
-- Actual 0.9.5-beta decoder body, from Roster.lua SHA256
-- ED35FDF41B56366A0D38398365312B25514045927029E4C46500FD016A5E3E63.
-- Its private Integer helper is retained too; the new RowPack must stay usable
-- by this codec without appending a ninth field.
local function LegacyRowUnpack(U, raw, guild)
    local function Integer(value, minimum, maximum)
        local n = tonumber(value)
        return n and n == math.floor(n) and n >= minimum and n <= maximum and n or nil
    end
    local f = U.Unpack(raw, 8)
    if not f or (#f ~= 7 and #f ~= 8) then return nil end
    local name, rank, level = U.Name(f[1]), Integer(f[2], 0, 99), Integer(f[4], 0, 100)
    if not name or not rank or not level then return nil end
    if #f[3] > 120 or #f[5] > 30 or #f[6] > 180 or (f[7] ~= "0" and f[7] ~= "1") then return nil end
    if f[8] and f[8] ~= "0" and f[8] ~= "1" then return nil end
    return { name = name, rank = rank, rankName = f[3], level = level, class = f[5], zone = f[6], online = f[7] == "1", guild = guild,
        officer = rank == 0 or f[8] == "1" }
end
-- Observe actual fragmentation/compression and leave native transport intact.
local assemblies = setmetatable({}, { __mode = "k" })
local function Message(packet)
    local id, part, total, body = packet.text:match("^([^~]+)~(%d+)~(%d+)~(.*)$")
    part, total = tonumber(part), tonumber(total)
    if not part then return end
    local owner = assemblies[packet.from]
    if not owner then owner = {}; assemblies[packet.from] = owner end
    local key = id .. ":" .. packet.dist .. ":" .. tostring(packet.target)
    local buffer = owner[key]
    if not buffer then buffer = {}; owner[key] = buffer end
    buffer[part] = body
    for index = 1, total do if not buffer[index] then return end end
    local encoded, raw = table.concat(buffer)
    if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
    elseif encoded:sub(1, 1) == "Z" then
        local compressed = packet.from.U.Deflate:DecodeForWoWAddonChannel(encoded:sub(2))
        raw = compressed and packet.from.U.Deflate:DecompressDeflateLimited(compressed, 25000)
    end
    if type(raw) ~= "string" then return end
    local kind, packed = raw:match("^([A-Z]+)~(.*)$")
    return kind, packed and packet.from.U.Unpack(packed, 16)
end
local function ActivityMessage(packet)
    local kind, fields = Message(packet)
    if kind == "ACTIVITY" then return fields, packet.from.name end
    if kind == "REMOTE" and fields and fields[1] == "ACTIVITY" then
        return packet.from.U.Unpack(fields[2], 11), fields[3]
    end
end
local function World(options)
    options = options or {}
    H.Reset(); assemblies = setmetatable({}, { __mode = "k" })
    local own = Client("Own Gateway", 1, 0)
    local other = Client("Other Gateway", 2, 0)
    local c = Client(options.legacy and "Legacy Reader" or "Activity Reader", 1, 2)
    if options.legacy then
        c.U.VERSION = "0.9.5-beta"
        -- A frozen legacy decoder and absent new activity entry point model
        -- the old reader. Modern clients retain all production helpers.
        c.legacyDecodes = 0
        c.U.RowUnpack = function(raw, guild)
            c.legacyDecodes = c.legacyDecodes + 1
            return LegacyRowUnpack(c.U, raw, guild)
        end
        c.U.TakeActivity = nil
    end
    H.SetRosters(0)
    for index = 1, options.members or 1 do
        AddNative(other, index == 1 and "Offline Remote" or ("Remote Person%03d"):format(index), false, { 0, 0, 14, 0 })
    end
    Read(other)
    for _, client in ipairs({ own, other, c }) do Event(client, "PLAYER_LOGIN") end
    local observed = {}
    H.SetFilter(function(packet, receiver)
        local fields, sourceName = ActivityMessage(packet)
        if fields then observed[tonumber(fields[1])] = { fields = Copy(fields), source = sourceName, sender = packet.from } end
        if options.filter then return options.filter(packet, receiver) end
        return true
    end)
    assert(own.U.Link(other.name), "native link could not start")
    H.Step(75)
    assert(own.U.Connected() and c.U.Connected() and c.U.RosterFresh(2), "activity fixture has no authenticated remote roster")
    return own, other, c, observed
end
local function Record(U, name, state, tuple)
    tuple = tuple or { "", "", "", "" }
    return U.Pack({ name, state, tuple[1], tuple[2], tuple[3], tuple[4] })
end
local function Records(c, guild, duration)
    local cache = c.U.db.rosters[guild]
    local records, names = {}, {}
    for name in pairs(cache.rows) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if cache.rows[name].online then records[#records + 1] = Record(c.U, name, "o")
        else records[#records + 1] = Record(c.U, name, "k", { 0, 0, duration or 14, 0 }) end
    end
    return records
end
local function Fields(c, guild, records, revision, options)
    options = options or {}
    local cache, pages = c.U.db.rosters[guild], math.max(1, math.ceil(#records / 35))
    local result = {}
    for page = 1, pages do
        local body = {}
        for index = (page - 1) * 35 + 1, math.min(page * 35, #records) do body[#body + 1] = records[index] end
        result[#result + 1] = { guild, options.epoch or cache.epoch, options.base or cache.revision,
            options.from or 0, revision, options.mode or "F", page, pages,
            options.at or c.U.stamp(), #records, c.U.Pack(body) }
    end
    return result
end
local probeSerial = 0
local function Send(sender, gateway, pages)
    for _, fields in ipairs(pages) do
        probeSerial = probeSerial + 1
        assert(sender.U.Queue("ACTIVITY", fields, "WHISPER", gateway.name, false, false, "996." .. probeSerial), "activity probe could not enter native queue")
    end
end
local function QuietActivity(other, observe)
    H.SetFilter(function(packet, receiver)
        local kind, fields = Message(packet)
        if type(observe) == "function" then observe(packet, receiver, kind, fields) end
        if packet.from == other and kind == "ACTIVITY" and not packet.text:match("^996%.") then return false end
        return true
    end)
end
local function NativeRow(c, name)
    for _, row in ipairs(c.rows) do if row.name == name then return row end end
    error("missing indexed native row " .. name)
end
local function VisibleRows(c)
    local result = {}
    for _, frame in ipairs(c.allFrames) do if frame.row and H.FrameVisible(frame) then result[#result + 1] = frame end end
    return result
end

Scenario("native duration components retain hour precision without inventing a calendar timestamp", function()
    local c = Local()
    AddNative(c, "Offline Native", false, { 0, 0, 7, 5 }); Read(c)
    local info = Info(c, "Offline Native")
    assert(info.known and info.fresh and not info.online, "known native duration was not available")
    Near(info.minDays, 7 + 5 / 24, "day/hour minimum precision changed")
    Near(info.maxDays, 7 + 6 / 24, "hour precision upper bound changed")
    eq(info.sourceAt, c.U.stamp(), "source timestamp must identify observation time")
    assert(type(info.label) == "string" and info.label ~= "" and type(info.details) == "string", "native duration has no visible explanation")
    assert(not info.label:match("%d%d%d%d%-%d%d%-%d%d") and not info.details:match("%d%d%d%d%-%d%d%-%d%d"), "duration was presented as an exact calendar date")
end)

Scenario("native years and months use conservative calendar intervals", function()
    local c = Local()
    for index, tuple in ipairs({ { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 2, 3, 4, 5 } }) do
        local name = "Calendar Native" .. index
        AddNative(c, name, false, tuple)
    end
    Read(c)
    for index, tuple in ipairs({ { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 2, 3, 4, 5 } }) do
        local info = Info(c, "Calendar Native" .. index)
        assert(info.known and info.fresh, "calendar tuple was discarded")
        Near(info.minDays, tuple[1] * 365 + tuple[2] * 28 + tuple[3] + tuple[4] / 24, "calendar lower bound changed")
        Near(info.maxDays, tuple[1] * 366 + tuple[2] * 31 + tuple[3] + (tuple[4] + 1) / 24, "calendar upper bound changed")
    end
    local _, month = Info(c, "Calendar Native2")
    assert(c.U.MatchesInactivity(month, 14) and not c.U.MatchesInactivity(month, 30), "one calendar month was falsely certified as thirty days")
end)

Scenario("missing native API preserves membership and reports unknown activity", function()
    local c = Local("absent")
    AddNative(c, "Unknown Native", false); Read(c)
    local info, row = Info(c, "Unknown Native")
    assert(not info.known and not c.U.MatchesInactivity(row, 7), "missing API fabricated inactivity")
    eq(#assert(c.U.Unpack(c.U.RowPack(row), 8)), 8, "activity extended the legacy roster codec")
    assert(LegacyRowUnpack(c.U, c.U.RowPack(row), 1), "old decoder cannot read a modern member")
end)

Scenario("nil errors secret and invalid native components fail closed without losing the roster", function()
    local c = Local()
    local cases = { {}, { error = true }, { 0, 0, -1, 0 }, { 0, 12, 0, 0 }, { 101, 0, 0, 0 },
        { 0, 0, 32, 0 }, { 0, 0, 0, 24 }, { 0, 0, 7.5, 0 }, { "0", 0, 7, 0 },
        { 0, 0, 0 / 0, 0 }, { 0, 0, math.huge, 0 } }
    for component = 1, 4 do
        local tuple = { 0, 0, 14, 0 }; tuple[component] = { secret = true }; cases[#cases + 1] = tuple
        local missing = { 0, 0, 14, 0 }; missing[component] = nil; cases[#cases + 1] = missing
    end
    for index, tuple in ipairs(cases) do AddNative(c, "Invalid Native" .. index, false, tuple) end
    Read(c)
    for index in ipairs(cases) do
        local info, row = Info(c, "Invalid Native" .. index)
        assert(not info.known and not c.U.MatchesInactivity(row, 7), "invalid native tuple became inactivity: " .. index)
    end
end)

Scenario("zero-hour offline and native online are distinct and never inactive", function()
    local c = Local()
    AddNative(c, "Recent Offline", false, { 0, 0, 0, 0 })
    AddNative(c, "Online Native", true, { 50, 0, 0, 0 }); Read(c)
    local recent, recentRow = Info(c, "Recent Offline")
    assert(recent.known and not recent.online, "zero tuple was confused with unknown or online")
    Near(recent.minDays, 0, "recent offline lower bound changed"); Near(recent.maxDays, 1 / 24, "recent offline hour bound changed")
    local online, row = Info(c, "Online Native")
    assert(online.known and online.online and online.fresh, "native online did not override an obsolete duration")
    for _, threshold in ipairs({ 7, 14, 30 }) do
        assert(not c.U.MatchesInactivity(row, threshold) and not c.U.MatchesInactivity(recentRow, threshold), "active member entered inactive filter")
    end
end)

Scenario("seven fourteen thirty day boundaries use inclusive observed minimum without aging cached guesses", function()
    local c = Local()
    for _, threshold in ipairs({ 7, 14, 30 }) do
        AddNative(c, "Below" .. threshold, false, { 0, 0, threshold - 1, 23 })
        AddNative(c, "Exact" .. threshold, false, { 0, 0, threshold, 0 })
        AddNative(c, "Above" .. threshold, false, { 0, 0, threshold, 1 })
    end
    Read(c)
    for _, threshold in ipairs({ 7, 14, 30 }) do
        local _, below = Info(c, "Below" .. threshold); local _, exact = Info(c, "Exact" .. threshold); local _, above = Info(c, "Above" .. threshold)
        assert(not c.U.MatchesInactivity(below, threshold), "below-boundary member was inactive")
        assert(c.U.MatchesInactivity(exact, threshold) and c.U.MatchesInactivity(above, threshold), "inclusive inactivity boundary was lost")
    end
    H.Advance(59)
    Near(Info(c, "Exact7").minDays, 7, "cached observation was aged into a stronger duration")
    H.Advance(2)
    local info, row = Info(c, "Exact7")
    assert(not info.fresh and not c.U.MatchesInactivity(row, 7), "stale observation still certified inactivity")
end)

Scenario("native row reordering binds last-online to each current roster index", function()
    local c = Local()
    AddNative(c, "Index First", false, { 0, 0, 7, 0 }); AddNative(c, "Index Second", false, { 0, 0, 30, 0 }); Read(c)
    c.rows[#c.rows], c.rows[#c.rows - 1] = c.rows[#c.rows - 1], c.rows[#c.rows]
    Read(c)
    Near(Info(c, "Index First").minDays, 7, "reordered index borrowed another member's activity")
    Near(Info(c, "Index Second").minDays, 30, "reordered index lost the correct activity")
end)

Scenario("real gateway transport synchronizes last-online activity and native online changes", function()
    local own, other, c, observed = World()
    local info, row = Info(c, "Offline Remote", 2)
    assert(info.known and info.fresh and c.U.MatchesInactivity(row, 14), "authenticated remote duration did not reach an ordinary reader")
    Near(info.minDays, 14, "native remote minimum changed in transport")
    assert(observed[2] and #observed[2].fields == 11 and observed[2].source == other.name, "actual activity side channel was not observed")
    other.activityValues["Offline Remote"] = { 0, 0, 30, 0 }; Read(other); H.Step(12)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "activity-only native change did not synchronize")
    NativeRow(other, "Offline Remote").online = true; Read(other); H.Step(12)
    info, row = Info(c, "Offline Remote", 2)
    assert(info.known and info.online and not c.U.MatchesInactivity(row, 7), "native online update retained obsolete inactivity")
end)

Scenario("frozen eight-field legacy decoder receives normal rosters and chat while activity stays unknown", function()
    local own, other, c = World({ legacy = true })
    assert(c.legacyDecodes > 0, "native transport never exercised the frozen 0.9.5 decoder")
    local info, row = Info(c, "Offline Remote", 2)
    eq(row.level, 40, "legacy decoder lost the level")
    eq(row.class, "PRIEST", "legacy decoder lost the class")
    eq(row.zone, "Native Zone", "legacy decoder lost the native location")
    eq(#assert(c.U.Unpack(other.U.RowPack(other.U.own["Offline Remote"]), 8)), 8, "modern activity leaked into legacy roster rows")
    assert(not info.known and not c.U.MatchesInactivity(row, 7), "legacy reader without activity support fabricated a last-online value")
    assert(other.U.SendChat("Activity legacy codec chat"), "compatibility chat was rejected")
    H.Step(8)
    local found = false
    for _, entry in ipairs(c.U.history) do if entry.text == "Activity legacy codec chat" then found = true end end
    assert(found and c.U.RosterFresh(2), "legacy row transport interfered with ordinary shared chat or roster freshness")
end)

Scenario("multipart activity applies atomically after out-of-order and duplicate native pages", function()
    local own, other, c = World({ members = 36 })
    QuietActivity(other, 100)
    local pages = Fields(c, 2, Records(c, 2, 30), 100)
    eq(#pages, 2, "multipart fixture did not exceed one page")
    Send(other, own, { pages[2], Copy(pages[2]) }); H.Step(3)
    Near(Info(c, "Offline Remote", 2).minDays, 14, "incomplete activity page replaced the visible snapshot")
    Send(other, own, { pages[1] }); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "last missing page did not atomically complete activity")
    local cache = c.U.db.activity[2]
    eq(cache.revision, 100, "completed snapshot has the wrong activity revision")
    Send(other, own, { pages[1], pages[2] }); H.Step(3)
    eq(c.U.db.activity[2].revision, 100, "duplicate complete snapshot changed revision")
end)

Scenario("conflicting duplicate aborts assembly and expired pages cannot complete it", function()
    local own, other, c = World({ members = 36 })
    QuietActivity(other, 100)
    local baselineRevision = c.U.db.activity[2].revision
    local pages = Fields(c, 2, Records(c, 2, 30), 100)
    Send(other, own, { pages[1] }); H.Step(2)
    local conflict = Copy(pages[1])
    local records = assert(c.U.Unpack(conflict[11], 35)); records[1] = Record(c.U, "Offline Remote", "k", { 0, 0, 31, 0 })
    conflict[11] = c.U.Pack(records)
    Send(other, own, { conflict, pages[2] }); H.Step(3)
    eq(c.U.db.activity[2].revision, baselineRevision, "conflicting duplicate committed an incomplete snapshot")
    local conflictInfo, conflictRow = Info(c, "Offline Remote", 2)
    assert(not conflictInfo.fresh and not c.U.MatchesInactivity(conflictRow, 7), "conflicting assembly still certified inactivity")
    local expired = Fields(c, 2, Records(c, 2, 30), 101, { at = c.U.stamp() + 59 })
    Send(other, own, { expired[1] }); H.Step(1)
    H.Advance(61); H.Step(5)
    Send(other, own, { expired[2] }); H.Step(3)
    assert(Info(c, "Offline Remote", 2).minDays ~= 30, "expired first page was combined with a later final page")
    Send(other, own, Fields(c, 2, Records(c, 2, 7), 102)); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 7, "valid newer full snapshot could not repair a failed assembly")
end)

Scenario("native sender authorization rejects ordinary foreign revoked and forged local relay activity", function()
    local own, other, c = World()
    local outsider = Client("Outsider Activity", 2, 2)
    local backup = Client("Revoked Activity", 2, 1)
    local forger = Client("Local Activity Forger", 1, 2)
    H.SetRosters(0)
    AddNative(other, "Offline Remote", false, { 0, 0, 14, 0 }); Read(other)
    Event(outsider, "PLAYER_LOGIN"); Event(backup, "PLAYER_LOGIN"); Event(forger, "PLAYER_LOGIN"); H.Step(15)
    local baseline = Info(c, "Offline Remote", 2)
    assert(baseline.known and baseline.fresh, "authorization fixture lost initial activity")
    QuietActivity(other, 100)
    local fields = Fields(c, 2, Records(c, 2, 30), 100)[1]
    Send(outsider, own, { fields }); H.Step(3)
    assert(Info(c, "Offline Remote", 2).minDays ~= 30, "untrusted foreign member supplied activity")
    assert(forger.U.Queue("ACTIVITY", fields, "GUILD", nil, false), "ordinary native probe failed admission")
    assert(forger.U.Queue("REMOTE", { "ACTIVITY", forger.U.Pack(fields), other.name }, "GUILD", nil, false), "forged relay probe failed admission")
    H.Step(3)
    assert(Info(c, "Offline Remote", 2).minDays ~= 30, "ordinary guild sender forged local or relayed activity")
    assert(Info(own, "Offline Remote", 2).minDays ~= 30, "ordinary guild sender forged gateway activity")
    backup.rank, backup.officer = 2, false
    H.SetRosters(0); AddNative(other, "Offline Remote", false, { 0, 0, 14, 0 }); Read(other)
    Event(own, "GUILD_ROSTER_UPDATE"); H.Step(2)
    Send(backup, own, { fields }); H.Step(3)
    assert(Info(c, "Offline Remote", 2).minDays ~= 30, "revoked sender supplied activity")
    Send(other, own, Fields(c, 2, Records(c, 2, 30), 101)); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "authorized current remote gateway could not update activity")
    local accepted = c.U.db.activity[2].revision
    own.rank, own.officer = 2, false
    NativeRow(c, own.name).rank = 2; Read(c); Event(c, "GUILD_ROSTER_UPDATE")
    assert(not c.U.CanRelay(own.name) and c.U.GatewayName() ~= own.name, "revoked local gateway remained authoritative")
    local forged = Fields(c, 2, Records(c, 2, 31), 102)[1]
    assert(own.U.Queue("REMOTE", { "ACTIVITY", own.U.Pack(forged), other.name }, "GUILD", nil, false), "revoked gateway probe failed admission")
    H.Step(2)
    eq(c.U.db.activity[2].revision, accepted, "revoked native local gateway injected foreign activity")
end)

Scenario("activity header record and byte limits reject malformed snapshots without damaging membership", function()
    local own, other, c = World()
    local probeBody, forwarded = nil, 0
    QuietActivity(other, function(packet, receiver, kind, fields)
        if packet.from == own and receiver == c and kind == "REMOTE" and fields and fields[1] == "ACTIVITY" and fields[2] == probeBody then
            forwarded = forwarded + 1
        end
    end)
    local template = Fields(c, 2, Records(c, 2, 30), 100)[1]
    local firstPage = {}
    for index = 1, 35 do firstPage[index] = Record(c.U, ("Limit Person%02d"):format(index), "k", { 0, 0, 30, 0 }) end
    local mutations = {
        function(f) f[1] = 1 end,
        function(f) f[2] = "forged.epoch" end,
        function(f) f[2] = "123.456" end,
        function(f) f[4], f[6] = 17, "F" end,
        function(f) f[5] = "100.5" end,
        function(f) f[6] = "X" end,
        function(f) f[7] = 0 end,
        function(f) f[8], f[10], f[11] = 44, 1500, c.U.Pack(firstPage) end,
        function(f) f[8], f[10], f[11] = 43, 1501, c.U.Pack(firstPage) end,
        function(f) f[8], f[10] = 1, 0 end,
        function(f)
            local revision = c.U.db.activity[2].revision
            f[4], f[5], f[6], f[8], f[10], f[11] = revision, revision + 1, "D", 5, 141, c.U.Pack(firstPage)
        end,
        function(f) f[9] = c.U.stamp() + 120 end,
        function(f) f[9] = "1.5" end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[1] = c.U.Pack({ "Offline Remote", "k", string.rep("0", 11000), "0", "30", "0" })
            f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35); records[#records + 1] = records[1]; f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[1] = Record(c.U, "Offline Remote", "k", { 0, 0, -1, 0 }); f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[2] = Record(c.U, other.name, "o", { 0, 0, 30, 0 }); f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[2] = records[1]; f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[1] = Record(c.U, "Offline Remote", "k", { 0, 0, 30, 24 }); f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[1] = Record(c.U, "Offline Remote", "x"); f[11] = c.U.Pack(records)
        end,
        function(f)
            local records = c.U.Unpack(f[11], 35)
            records[1] = Record(c.U, "Nonmember Activity", "k", { 0, 0, 30, 0 }); f[11] = c.U.Pack(records)
        end,
    }
    for index, mutate in ipairs(mutations) do
        local fields = Copy(template); fields[5] = 100 + index; mutate(fields)
        probeBody, forwarded = c.U.Pack(fields), 0
        Send(other, own, { fields }); H.Step(2)
        eq(forwarded, 0, "malformed activity was accepted for relay: " .. index)
        assert(Info(c, "Offline Remote", 2).minDays ~= 30, "malformed activity body applied: " .. index)
        assert(c.U.RosterFresh(2) and c.U.db.rosters[2].rows["Offline Remote"], "activity validation damaged the native roster: " .. index)
    end
    Send(other, own, Fields(c, 2, Records(c, 2, 30), 200)); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "valid body could not repair malformed activity traffic")
end)

Scenario("activity delta requires the exact revision chain and stale epoch cannot replace it", function()
    local own, other, c = World()
    QuietActivity(other, 100)
    Send(other, own, Fields(c, 2, Records(c, 2, 14), 100)); H.Step(3)
    local delta = { Record(c.U, "Offline Remote", "k", { 0, 0, 30, 0 }) }
    Send(other, own, Fields(c, 2, delta, 102, { mode = "D", from = 101 })); H.Step(3)
    eq(c.U.db.activity[2].revision, 100, "activity revision gap committed a new duration")
    local gapInfo, gapRow = Info(c, "Offline Remote", 2)
    assert(not gapInfo.fresh and not c.U.MatchesInactivity(gapRow, 7), "activity revision gap retained a certified duration")
    Send(other, own, Fields(c, 2, delta, 101, { mode = "D", from = 100 })); H.Step(3)
    assert(Info(c, "Offline Remote", 2).minDays ~= 30, "delta bypassed required full repair after a revision gap")
    assert(c.U.RosterFresh(2), "activity revision repair damaged ordinary roster freshness")
    Send(other, own, Fields(c, 2, Records(c, 2, 14), 103)); H.Step(3)
    Send(other, own, Fields(c, 2, delta, 104, { mode = "D", from = 103 })); H.Step(3)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "exact activity delta chain was rejected after full repair")
    Send(other, own, Fields(c, 2, Records(c, 2, 7), 99)); H.Step(2)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "older activity revision replaced current state")
    Send(other, own, Fields(c, 2, Records(c, 2, 7), 105, { epoch = "123.456" })); H.Step(2)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "unrelated roster nonce replaced activity epoch")
end)


Scenario("a valid partial delta gap immediately invalidates activity while malformed pages preserve it", function()
    local own, other, c = World({ members = 36 })
    QuietActivity(other)
    local saved = c.U.db.activity[2].revision
    local changes = {}
    for name, row in pairs(c.U.db.rosters[2].rows) do
        if not row.online then changes[#changes + 1] = Record(c.U, name, "k", { 0, 0, 30, 0 }) end
    end
    eq(#changes, 36, "partial delta gap fixture must contain thirty-six changes")
    local pages = Fields(c, 2, changes, saved + 3, { mode = "D", from = saved + 2 })
    eq(#pages, 2, "partial delta gap did not require a second page")
    local badHeader = Copy(pages[1]); badHeader[7] = 0
    Send(other, own, { badHeader }); H.Step(2)
    local info, row = Info(c, "Offline Remote", 2)
    assert(info.fresh and c.U.MatchesInactivity(row, 14), "invalid gap header destroyed valid activity")
    local badBody = Copy(pages[1]); badBody[11] = c.U.Pack({ "invalid record" })
    Send(other, own, { badBody }); H.Step(2)
    info, row = Info(c, "Offline Remote", 2)
    assert(info.fresh and c.U.MatchesInactivity(row, 14), "invalid gap body destroyed valid activity")
    Send(other, own, { pages[1] }); H.Step(3)
    info, row = Info(c, "Offline Remote", 2)
    assert(not info.fresh and not c.U.MatchesInactivity(row, 7), "known partial delta gap waited for page two before invalidating activity")
    assert(c.U.RosterFresh(2), "partial activity gap made ordinary roster data stale")
    Send(other, own, Fields(c, 2, Records(c, 2, 30), saved + 4)); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "full snapshot did not repair a partial delta gap")
end)

Scenario("stale roster-base activity cannot certify a newly joined member", function()
    local own, other, c = World()
    QuietActivity(other)
    local base = c.U.db.rosters[2].revision
    AddNative(other, "Fresh Join", false, { 0, 0, 7, 0 }); Read(other); H.Step(8)
    assert(c.U.db.rosters[2].revision > base, "native join did not advance the roster revision")
    Send(other, own, Fields(c, 2, Records(c, 2, 30), 100, { base = base })); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "unaffected old member could not retain old-base activity")
    local info, row = Info(c, "Fresh Join", 2)
    assert(not info.known and not c.U.MatchesInactivity(row, 7), "pre-join activity fabricated a new member's last-online history")
end)

Scenario("an empty activity heartbeat cannot resurrect a tuple before online transitions", function()
    local own, other, c = World()
    QuietActivity(other)
    local revision, base = c.U.db.activity[2].revision, c.U.db.rosters[2].revision
    NativeRow(other, "Offline Remote").online = true; Read(other); H.Step(8)
    NativeRow(other, "Offline Remote").online = false; Read(other); H.Step(8)
    assert(c.U.db.rosters[2].revision > base, "native online transitions did not advance roster provenance")
    local before, row = Info(c, "Offline Remote", 2)
    assert(not before.known and not c.U.MatchesInactivity(row, 7), "old offline tuple survived a native online transition")
    Send(other, own, Fields(c, 2, {}, revision + 1, { mode = "D", from = revision })); H.Step(3)
    local after = Info(c, "Offline Remote", 2)
    assert(not after.known and not c.U.MatchesInactivity(row, 7), "empty heartbeat promoted stale per-row provenance")
    Send(other, own, Fields(c, 2, Records(c, 2, 7), revision + 2)); H.Step(5)
    local fresh, current = Info(c, "Offline Remote", 2)
    assert(fresh.known and fresh.fresh and c.U.MatchesInactivity(current, 7), "explicit current-base confirmation could not restore activity")
end)

Scenario("rank zone and level core deltas preserve untouched per-row activity provenance", function()
    local own, other, c = World()
    QuietActivity(other)
    local base = c.U.db.rosters[2].revision
    local native = NativeRow(other, "Offline Remote")
    native.rank, native.level, native.zone = 3, 42, "Updated Native Zone"; Read(other); H.Step(8)
    local info, row = Info(c, "Offline Remote", 2)
    assert(c.U.db.rosters[2].revision > base and info.known and info.fresh, "unrelated core delta invalidated unchanged activity")
    Near(info.minDays, 14, "unrelated core delta changed the duration")
    Send(other, own, Fields(c, 2, Records(c, 2, 30), 100, { base = base })); H.Step(5)
    Near(Info(c, "Offline Remote", 2).minDays, 30, "unrelated core revision incorrectly raised the member's activity floor")
    eq(row.rank, 3, "activity update changed native rank")
    eq(row.level, 42, "activity update changed native level")
    eq(row.zone, "Updated Native Zone", "activity update changed native location")
end)

Scenario("future-base activity waits atomically for the queued matching core roster revision", function()
    local own, other, c = World({ members = 36 })
    QuietActivity(other)
    local base = c.U.db.rosters[2].revision
    local pages = Fields(c, 2, Records(c, 2, 30), 100, { base = base + 1 })
    Send(other, own, pages); H.Step(3)
    Near(Info(c, "Offline Remote", 2).minDays, 14, "future-base activity applied before native roster provenance")
    NativeRow(other, "Offline Remote").zone = "Queued Core Zone"; Read(other)
    assert(other.U.PublishRosterDelta(own.name), "matching native core delta could not enter the queue")
    H.Step(8)
    eq(c.U.db.rosters[2].revision, base + 1, "matching core delta did not reach the ordinary reader")
    Near(Info(c, "Offline Remote", 2).minDays, 30, "queued core revision did not release the complete pending activity")
    eq(c.U.db.rosters[2].rows["Offline Remote"].zone, "Queued Core Zone", "activity release damaged native roster contents")
end)

Scenario("failed atomic activity queue admission retains samples and later delivers alongside chat", function()
    local own, other, c, observed = World({ members = 36 })
    other.U.ClearQueue()
    H.Advance(3)
    for name in pairs(other.activityValues) do other.activityValues[name] = { 0, 0, 30, 0 } end
    Read(other)
    assert(other.U.PublishRosterDelta(own.name), "native core measurement could not enter the queue")
    local coreCost = other.U.QueueSize()
    -- This is an empty core heartbeat; no member revision is lost by measuring
    -- it without sending before measuring the new metadata batch separately.
    other.U.ClearQueue()
    assert(other.U.PublishActivity(own.name), "native activity measurement could not enter the queue")
    local activityCost = other.U.QueueSize()
    assert(coreCost > 0 and activityCost > coreCost, "activity pressure fixture did not measure different fragment costs")
    H.Step(5)
    for _ = 1, 50 do if other.U.QueueSize() == 0 then break end; H.Step(0.1) end
    H.Step(0.5)
    eq(other.U.QueueSize(), 0, "activity measurement did not drain before pressure")
    local revision = tonumber(observed[2].fields[5])
    H.Advance(3)
    for name in pairs(other.activityValues) do other.activityValues[name] = { 0, 0, 31, 0 } end
    Read(other)
    while other.U.QueueSize() < 1500 - coreCost do
        assert(other.U.Queue("CHECK", { "activity pressure " .. other.U.QueueSize() }, "GUILD", nil, false, false, nil, false, nil, "activity-pressure-pad"), "native pressure padding failed")
    end
    assert(other.U.IsGateway() and other.U.CanRelay() and other.U.Connected(), "activity queue fixture lost publication authority")
    assert(other.U.PublishRosterDelta(own.name), "core roster heartbeat could not use its reserved fragment capacity")
    eq(other.U.QueueSize(), 1500, "core batch did not use the measured capacity")
    eq(other.U.PublishActivity(own.name), false, "two-page activity batch ignored atomic capacity")
    eq(other.U.QueueSize(), 1500, "failed activity batch partially entered the native queue")
    Near(Info(c, "Offline Remote", 2).minDays, 30, "failed queue admission claimed activity delivery")
    eq(other.U.CancelQueued("activity-pressure-pad"), 1500 - coreCost, "releasing pressure removed actual core fragments")
    local firstRetry
    H.SetFilter(function(packet)
        local fields = ActivityMessage(packet)
        if fields and packet.from == other and packet.dist == "WHISPER" then firstRetry = firstRetry or tonumber(fields[5]) end
        return true
    end)
    assert(own.U.SendChat("Activity queue pressure chat"), "ordinary chat was rejected during activity retry")
    H.Step(15)
    eq(firstRetry, revision + 1, "failed admission advanced the activity revision")
    Near(Info(c, "Offline Remote", 2).minDays, 31, "failed activity sample was lost instead of retried")
    local localChat, remoteChat = false, false
    for _, entry in ipairs(c.U.history) do if entry.text == "Activity queue pressure chat" then localChat = true end end
    for _, entry in ipairs(other.U.history) do if entry.text == "Activity queue pressure chat" then remoteChat = true end end
    assert(localChat and remoteChat and other.U.QueueSize() < 100, "activity retry blocked shared chat or retained an unbounded queue")
end)


Scenario("fresh native core heartbeats cannot refresh an expired activity observation", function()
    local own, other, c = World()
    QuietActivity(other)
    H.Step(65)
    local info, row = Info(c, "Offline Remote", 2)
    assert(c.U.RosterFresh(2), "activity expiry fixture also lost ordinary core freshness")
    assert(not info.fresh and not c.U.MatchesInactivity(row, 7), "core heartbeat falsely renewed the old activity observation")
end)


Scenario("one thousand known metadata records cannot delay native core joins control or forwarded chat", function()
    local own, other, c = World({ members = 1000 })
    local known = 0
    for _, row in pairs(c.U.db.rosters[2].rows) do
        if not row.online then
            local info = c.U.ActivityInfo(row)
            assert(info.known and info.fresh and info.minDays == 14, "large QoS fixture lacks confirmed native offline data")
            known = known + 1
        end
    end
    eq(known, 1000, "large QoS fixture did not contain one thousand known durations")
    assert(type(other.U.ForegroundQueueSize) == "function", "protocol has no foreground admission accounting")
    local function Backlog(sender, pages, wrapped)
        local foreground = sender.U.ForegroundQueueSize()
        for _ = 1, 10 do
            if sender.U.QueueSize() - sender.U.ForegroundQueueSize() >= 180 then break end
            for _, fields in ipairs(pages) do
                local kind = wrapped and "REMOTE" or "ACTIVITY"
                local body = wrapped and { "ACTIVITY", sender.U.Pack(fields), other.name } or fields
                local dist, target = "WHISPER", own.name
                if wrapped then dist, target = "GUILD", nil end
                -- The caller's high priority must not promote metadata over
                -- core/control traffic, including an attested local relay.
                assert(sender.U.Queue(kind, body, dist, target, true), "known metadata backlog failed native admission")
            end
        end
        eq(sender.U.ForegroundQueueSize(), foreground, "metadata was promoted into foreground accounting")
        assert(sender.U.QueueSize() - sender.U.ForegroundQueueSize() >= 180 and sender.U.QueueSize() <= 1500, "metadata background fixture is absent or unbounded")
    end
    Backlog(other, Fields(c, 2, Records(c, 2, 14), 300), false)
    Backlog(own, Fields(c, 2, Records(c, 2, 14), 400), true)
    assert(other.U.QueueSize() > 100 and own.U.QueueSize() > 100, "QoS fixture did not exercise the old total-queue admission barrier")
    H.Advance(6)
    AddNative(other, "QoS Backup Officer", true)
    NativeRow(other, "QoS Backup Officer").rank = 1
    NativeRow(other, "Offline Remote").zone = "QoS Core Zone"
    -- Start the sample inside the native request window, rather than racing
    -- the ordinary periodic request's separate five-second read debounce.
    other.U.RequestRoster()
    Read(other)
    local ownAt, otherAt = own.U.remote.at, other.U.remote.at
    assert(other.U.Queue("PING", { 2, other.U.CandidateNames(), other.U.GatewayName() }, "WHISPER", own.name, true), "native control probe failed admission")
    assert(other.U.SendChat("Known metadata QoS chat"), "chat failed admission behind metadata")
    H.Step(5)
    local cache = c.U.db.rosters[2]
    assert(cache.rows["QoS Backup Officer"] and c.U.RowCanRelay(cache.rows["QoS Backup Officer"]), "known metadata delayed publication of the new native officer")
    eq(cache.rows["Offline Remote"].zone, "QoS Core Zone", "known metadata delayed the core roster delta")
    assert(c.U.RosterFresh(2) and own.U.Connected() and other.U.Connected(), "known metadata interrupted native bridge liveness")
    assert(own.U.remote.at > ownAt and other.U.remote.at > otherAt, "metadata blocked native PING/PONG control refresh")
    local chat = false
    for _, entry in ipairs(c.U.history) do if entry.text == "Known metadata QoS chat" then chat = true end end
    assert(chat, "forwarded metadata blocked shared chat for an ordinary reader")
    local sourcePending = other.U.QueueSize() - other.U.ForegroundQueueSize()
    local relayPending = own.U.QueueSize() - own.U.ForegroundQueueSize()
    assert(sourcePending > 0 and relayPending > 0, "QoS assertion waited until metadata had already drained")
    print("ACTIVITY QoS: known=" .. known .. "; pending source=" .. sourcePending .. "; pending relay=" .. relayPending .. "; core/control delivered within 5s")
end)


assert(failed == 0, "activity regressions observed: " .. failed .. "/" .. ran)
assert(H.ProtectedCalls() == 0, "activity UI attempted a protected action")
print("Activity scenarios: " .. (ran - failed) .. "/" .. ran)

