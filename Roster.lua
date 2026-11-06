local _, U = ...
U.own = {}
local lastRequest, lastRead, lastAttempt, changedAt, dirtySince = -100, -100, -100, 0, 0
local dirty, pending, deltaPending = true, {}, {}
local acceptedAt, needsFull = {}, {}
local published, wasGateway
local authorityRevision, authorityRows = 0, {}
local activityPending, activityNeedsFull, activityPublished = {}, {}, nil
local activityNextAt, activityForceFull = 0, false
local ApplyActivity
local READ_RETRY, READ_GAP, MAX_DEBOUNCE, DELTA_EVERY, FRESH_FOR = 3, 5, 8, 5, 25
local ACTIVITY_FRESH, ACTIVITY_TTL, ACTIVITY_PAGE = 60, 60, 35
local function MarkDirty()
    local now = U.clock()
    if not dirty then dirtySince = now end
    dirty, changedAt = true, now
end
local function Incomplete()
    if not dirty then dirtySince = U.clock() end
    dirty = true
    return false
end
local function Integer(value, minimum, maximum)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= minimum and n <= maximum and n or nil
end
local function Count(rows)
    local n = 0
    for _ in pairs(rows or {}) do n = n + 1 end
    return n
end
local function Same(a, b)
    return a and b and a.rank == b.rank and a.rankName == b.rankName and a.level == b.level
        and a.class == b.class and a.zone == b.zone and a.online == b.online and a.officer == b.officer
end
local function Changes(before, after)
    local changes = { joined = {}, left = {}, online = {}, offline = {}, updated = {} }
    local n = 0
    for name, row in pairs(after) do
        local old = before and before[name]
        if not old then
            changes.joined[#changes.joined + 1] = row; n = n + 1
        elseif not Same(old, row) then
            changes.updated[#changes.updated + 1] = row; n = n + 1
            if row.online ~= old.online then
                local list = row.online and changes.online or changes.offline
                list[#list + 1] = row
            end
        end
    end
    for name, row in pairs(before or {}) do
        if not after[name] then changes.left[#changes.left + 1] = row; n = n + 1 end
    end
    for _, list in pairs(changes) do table.sort(list, function(a, b) return a.name < b.name end) end
    return changes, n
end
local function Announce(guild, before, after, initial)
    if not U.OnRosterChanges then return end
    local changes, n = Changes(before, after)
    if initial or n > 0 then U.OnRosterChanges(guild, changes, initial and true or false) end
end
local function RemoteSource()
    if U.IsGateway() then return U.remote and U.remote.name end
    return U.linkState and U.linkState.name
end
function U.RosterState(guild)
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    if guild == U.guild then
        local fresh = U.own[U.me] ~= nil and U.clock() - lastRead <= 60
        return { fresh = fresh, status = fresh and "own" or "loading",
            age = cache and math.max(0, U.stamp() - cache.at) or nil,
            at = cache and cache.at, fullAt = cache and cache.fullAt, source = U.me }
    end
    local connected = U.guild and U.Connected() and true or false
    local age = cache and math.max(0, U.stamp() - cache.at) or nil
    local limit = cache and cache.revision and FRESH_FOR or 240
    local sameSource = cache and (not RemoteSource() or RemoteSource() == cache.source)
    local fresh = connected and cache ~= nil and acceptedAt[guild] ~= nil and sameSource
        and not needsFull[guild] and U.clock() - acceptedAt[guild] <= limit
    local status
    if not cache then status = connected and "loading" or "disconnected"
    elseif not connected then status = "disconnected"
    elseif needsFull[guild] or not sameSource then status = "syncing"
    elseif not fresh then status = "stale"
    else status = "connected" end
    return { fresh = fresh and true or false, status = status, age = age, at = cache and cache.at,
        fullAt = cache and cache.fullAt, source = cache and cache.source,
        revision = cache and cache.revision, epoch = cache and cache.epoch }
end
function U.RosterFresh(guild) return U.RosterState(guild).fresh end
local function AskFull(guild, source, reason)
    needsFull[guild], deltaPending[guild] = true, nil
    if U.RequestFullRoster then U.RequestFullRoster(guild, source, reason) end
    if U.Refresh then U.Refresh() end
    return false
end
function U.RequestRoster()
    if not U.guild or U.clock() - lastRequest < 10 or U.ChatLocked() then return end
    lastRequest = U.clock()
    local fn = C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster
    if fn then pcall(fn) end
end
local function SafeNumber(v, fallback)
    return U.Public(v) and type(v) == "number" and v or fallback
end
local function NativeInteger(value, maximum)
    if not U.Public(value) or type(value) ~= "number" then return nil end
    return Integer(value, 0, maximum)
end
local function ActivityTuple(years, months, days, hours)
    years, months, days, hours = NativeInteger(years, 100), NativeInteger(months, 11), NativeInteger(days, 31), NativeInteger(hours, 23)
    if years == nil or months == nil or days == nil or hours == nil then return nil end
    return { state = "k", years = years, months = months, days = days, hours = hours }
end
local function ReadActivity(row, index, at)
    local value = { state = row.online and "o" or "u", sourceAt = at }
    -- The global exists on Forever; an undocumented C_GuildInfo alias is not
    -- assumed. Online status comes from the roster, never from a nil tuple.
    if not row.online and type(GetGuildRosterLastOnline) == "function" then
        local ok, years, months, days, hours = pcall(GetGuildRosterLastOnline, index)
        local tuple = ok and ActivityTuple(years, months, days, hours)
        if tuple then tuple.sourceAt = at; value = tuple end
    end
    row.activity = value
end
function U.ActivityInfo(row)
    local info = { known = false, online = false, fresh = false, label = "Неизвестно", details = "Нет данных о последнем входе." }
    if type(row) ~= "table" or not U.GUILDS[row.guild] or not U.Name(row.name) then return info end
    local cache = U.db and U.db.rosters and U.db.rosters[row.guild]
    local current = row.guild == U.guild and U.own[row.name] or cache and cache.rows[row.name]
    if not current then return info end
    local state, activity = U.RosterState(row.guild)
    if row.guild == U.guild then activity = current.activity
    else
        local saved = U.db and U.db.activity and U.db.activity[row.guild]
        if saved and cache and saved.source == cache.source and saved.epoch == cache.epoch and not activityNeedsFull[row.guild]
            and not saved.needsFull and saved.baseRevision <= (cache.revision or 0) then
            local record = saved.records[row.name]
            if record and record.baseRevision >= ((cache.activityFloors or {})[row.name] or cache.revision or 0) then
                activity = record
                info.sourceAt = saved.sourceAt
            end
        end
    end
    info.online = current.online == true
    info.sourceAt = info.sourceAt or activity and activity.sourceAt
    local at = info.sourceAt
    local stamp = U.stamp()
    local recent = type(at) == "number" and at <= stamp + 60 and stamp - at <= ACTIVITY_FRESH
    info.fresh = state.fresh and recent and true or false
    if info.online then
        info.known, info.label = true, "В сети"
        info.minDays, info.maxDays = 0, 0
        info.sourceAt = info.sourceAt or cache and cache.at
        info.fresh = state.fresh and true or false
        info.details = info.fresh and "Участник сейчас в сети." or "Участник был в сети в сохранённом составе."
        return info
    end
    if not activity or activity.state ~= "k" then
        info.details = info.fresh and "Сервер не предоставил время последнего входа." or "Нет свежих данных о последнем входе."
        return info
    end
    local tuple = ActivityTuple(activity.years, activity.months, activity.days, activity.hours)
    if not tuple then return info end
    local years, months, days, hours = tuple.years, tuple.months, tuple.days, tuple.hours
    info.known = true
    -- These are conservative duration bounds, not an exact calendar date.
    -- Keep the observation fixed: cached offline time must not grow into a filter.
    info.minDays = years * 365 + months * 28 + days + hours / 24
    info.maxDays = years * 366 + months * 31 + days + (hours + 1) / 24
    if years > 0 then info.label = "~" .. years .. " г."
    elseif months > 0 then info.label = "~" .. months .. " мес."
    elseif days > 0 then info.label = "~" .. days .. " дн."
    elseif hours > 0 then info.label = "~" .. hours .. " ч."
    else info.label = "Менее 1 ч." end
    info.details = (years > 0 or months > 0)
        and "Оценка по календарным годам и месяцам; точная дата входа неизвестна."
        or "Время последнего входа известно с точностью до часа."
    if not info.fresh then info.details = info.details .. " Показаны сохранённые данные; фильтр неактивности их не использует." end
    if at then info.lastSeenMin, info.lastSeenMax = at - info.maxDays * 86400, at - info.minDays * 86400 end
    return info
end
function U.MatchesInactivity(row, days)
    if days ~= 7 and days ~= 14 and days ~= 30 then return false end
    local info = U.ActivityInfo(row)
    return info.known and not info.online and info.fresh and info.minDays >= days or false
end
local function ReadRow(index)
    local name, rankName, rank, level, _, zone, _, _, online, _, class = GetGuildRosterInfo(index)
    name = U.Name(name)
    if not name or not U.Public(rank) or not U.Public(online) or not U.Public(level) then return nil end
    return { name = name, rankName = U.Text(rankName, 120) and rankName or "",
        rank = SafeNumber(rank, 99), level = SafeNumber(level, 0),
        zone = U.Text(zone, 180) and zone or "", online = online and true or false,
        class = U.Text(class, 30) and class or "", guild = U.guild, officer = U.RankIsOfficer(rank),
        rosterIndex = index, authorityRevision = authorityRevision }
end
-- Native roster/rank events invalidate authority immediately. Query only rows
-- actually used for authorization while the full roster remains debounced.
-- A reordered index cannot authorize a different character.
function U.AuthorityRow(name)
    local row = U.guild and U.own[name]
    if not row or not U.own[U.me] or U.clock() - lastRead > 60 then return nil end
    if row.authorityRevision == authorityRevision then return row end
    if authorityRows[name] ~= nil then return authorityRows[name] or nil end
    local ok, current = false, nil
    if row.rosterIndex then ok, current = pcall(ReadRow, row.rosterIndex) end
    if not ok or not current or current.name ~= name then current = nil end
    authorityRows[name] = current or false
    return current
end
local function AuthorityChanged()
    authorityRevision, authorityRows = authorityRevision + 1, {}
    U.InvalidateRankPermissions()
    MarkDirty()
end
function U.ReadRoster()
    lastAttempt = U.clock()
    if not U.guild or U.ChatLocked() then return Incomplete() end
    local count = GetNumGuildMembers()
    if not U.Public(count) or type(count) ~= "number" or count < 1 or count > 1500 then return Incomplete() end
    U.InvalidateRankPermissions()
    local rows, observedAt = {}, NativeInteger(U.stamp(), 9999999999) or 0
    for i = 1, count do
        local row = ReadRow(i)
        if not row then return Incomplete() end
        ReadActivity(row, i, observedAt)
        rows[row.name] = row
    end
    if not rows[U.me] then return Incomplete() end
    local before = U.own
    local firstReady = not before[U.me] or before[U.me].guild ~= U.guild
    U.own, lastRead, dirty = rows, U.clock(), false
    authorityRows, U.ownRosterFreshUntil = {}, lastRead + 60
    U.rosterRevision = (U.rosterRevision or 0) + 1
    if U.ElectionChanged then U.ElectionChanged() end
    dirtySince = nil
    U.db.rosters[U.guild] = { rows = rows, at = U.stamp(), fullAt = U.stamp(), source = U.me }
    Announce(U.guild, before, rows, firstReady)
    if firstReady and U.OnRosterReady then U.OnRosterReady() end
    if U.Refresh then U.Refresh() end
    return true
end
function U.RowPack(row)
    return U.Pack({ row.name, row.rank, row.rankName, row.level, row.class, row.zone, row.online and "1" or "0", row.officer and "1" or "0" })
end
function U.RowUnpack(raw, guild)
    local f = U.Unpack(raw, 8)
    if not f or (#f ~= 7 and #f ~= 8) then return nil end
    local name, rank, level = U.Name(f[1]), Integer(f[2], 0, 99), Integer(f[4], 0, 100)
    if not name or not rank or not level then return nil end
    if #f[3] > 120 or #f[5] > 30 or #f[6] > 180 or (f[7] ~= "0" and f[7] ~= "1") then return nil end
    if f[8] and f[8] ~= "0" and f[8] ~= "1" then return nil end
    return { name = name, rank = rank, rankName = f[3], level = level, class = f[5], zone = f[6], online = f[7] == "1", guild = guild,
        officer = rank == 0 or f[8] == "1" }
end
local function Context(target)
    if published and published.guild == U.guild and published.target == target and published.tenure == U.gatewaySince then return published end
    return { guild = U.guild, target = target, tenure = U.gatewaySince, epoch = U.NewID(), revision = 0 }
end
local function ActivityFloors(before, after, oldFloors, previousRevision, revision)
    local floors = {}
    for name, row in pairs(after) do
        local old = before and before[name]
        floors[name] = old and old.online == row.online and ((oldFloors or {})[name] or previousRevision) or revision
    end
    return floors
end
local function ActivitySame(a, b)
    return a and b and a.state == b.state and a.years == b.years and a.months == b.months and a.days == b.days and a.hours == b.hours
end
local function ActivityPack(name, value)
    return U.Pack({ name, value.state, value.years or "", value.months or "", value.days or "", value.hours or "" })
end
local function ActivityUnpack(raw, mode)
    local f = U.Unpack(raw, 6)
    if not f or #f ~= 6 or not U.Name(f[1]) or U.Name(f[1]) ~= f[1] then return nil end
    local value
    if f[2] == "k" then
        value = ActivityTuple(Integer(f[3], 0, 100), Integer(f[4], 0, 11), Integer(f[5], 0, 31), Integer(f[6], 0, 23))
        if not value then return nil end
    elseif f[2] == "o" or f[2] == "u" or f[2] == "r" and mode == "D" then
        for i = 3, 6 do if f[i] ~= "" then return nil end end
        value = { state = f[2] }
    else return nil end
    return f[1], value
end
function U.PublishActivity(target)
    local context, now = published, U.clock()
    if not U.IsGateway() or not U.CanRelay() or not U.Connected() or not context or context.guild ~= U.guild
        or context.target ~= target or context.tenure ~= U.gatewaySince or not context.rows or now < activityNextAt then return false end
    local old = activityPublished
    local same = old and old.epoch == context.epoch and old.target == target and old.tenure == U.gatewaySince
    if same and not activityForceFull and old.rowsRef == context.rows and old.checkedRevision == context.revision then
        activityNextAt = now + READ_RETRY
        return true
    end
    local records, sourceAt = {}, nil
    for name, row in pairs(context.rows) do
        local value = row.activity
        if not value or value.sourceAt ~= (sourceAt or value.sourceAt) then return false end
        sourceAt = value.sourceAt
        records[name] = value
    end
    if not sourceAt or sourceAt > U.stamp() + 60 or U.stamp() - sourceAt > ACTIVITY_FRESH then return false end
    local mode, changed = same and not activityForceFull and "D" or "F", {}
    for name, value in pairs(records) do
        if mode == "F" or not ActivitySame(old.records[name], value)
            or (context.activityFloors[name] or context.revision) > old.baseRevision then
            changed[#changed + 1] = { name = name, value = value }
        end
    end
    if mode == "D" then
        for name in pairs(old.records) do if not records[name] then changed[#changed + 1] = { name = name, value = { state = "r" } } end end
        if #changed > 140 then
            mode, changed = "F", {}
            for name, value in pairs(records) do changed[#changed + 1] = { name = name, value = value } end
        end
    end
    if same and not activityForceFull and #changed == 0 and old.sourceAt == sourceAt then
        old.rowsRef, old.checkedRevision = context.rows, context.revision
        activityNextAt = now + READ_RETRY
        return true
    end
    table.sort(changed, function(a, b) return a.name < b.name end)
    local revision, from = same and old.revision + 1 or 1, mode == "D" and old.revision or 0
    local pages, jobs = math.max(1, math.ceil(#changed / ACTIVITY_PAGE)), {}
    for page = 1, pages do
        local rows = {}
        for i = (page - 1) * ACTIVITY_PAGE + 1, math.min(page * ACTIVITY_PAGE, #changed) do
            rows[#rows + 1] = ActivityPack(changed[i].name, changed[i].value)
        end
        local fields = { U.guild, context.epoch, context.revision, from, revision, mode, page, pages, sourceAt, #changed, U.Pack(rows) }
        if #U.Pack(fields) + 9 > 10000 then return false end
        jobs[#jobs + 1] = { kind = "ACTIVITY", fields = fields, dist = "WHISPER", target = target,
            priority = false, requiresGateway = true, expiresAt = now + 90 }
    end
    if not U.QueueBatch(jobs) then activityNextAt = now + READ_RETRY; return false end
    activityPublished = { epoch = context.epoch, target = target, tenure = U.gatewaySince, revision = revision,
        baseRevision = context.revision, records = records, sourceAt = sourceAt,
        rowsRef = context.rows, checkedRevision = context.revision }
    activityForceFull, activityNextAt = false, now + READ_RETRY
    return true
end
local function AskActivityFull(guild, source)
    activityNeedsFull[guild], activityPending[guild] = true, nil
    local saved = U.db.activity and U.db.activity[guild]
    if saved then saved.needsFull = true end
    if U.RequestFullRoster then U.RequestFullRoster(guild, source, "activity_gap") end
    if U.Refresh then U.Refresh() end
    -- The validated page also tells guild readers about this gap/conflict.
    -- Forward it even though its metadata was deliberately not applied here.
    return true
end
ApplyActivity = function(guild)
    local p, cache = activityPending[guild], U.db.rosters[guild]
    if not p or p.received ~= p.pages or not cache or cache.source ~= p.source or cache.epoch ~= p.epoch
        or not cache.revision or p.baseRevision > cache.revision or not U.Connected() or RemoteSource() ~= p.source then return false end
    local saved = U.db.activity and U.db.activity[guild]
    local same = saved and saved.source == p.source and saved.epoch == p.epoch
    if same and (p.revision <= saved.revision or p.sourceAt < saved.sourceAt or p.baseRevision < saved.baseRevision) then
        activityPending[guild] = nil; return false
    end
    if p.mode == "D" and (not same or activityNeedsFull[guild] or saved.needsFull or p.from ~= saved.revision) then
        return AskActivityFull(guild, p.source)
    end
    local records, named, n = {}, {}, 0
    if p.mode == "D" then for name, value in pairs(saved.records) do if cache.rows[name] then records[name] = value end end end
    for page = 1, p.pages do
        for _, entry in ipairs(p.parts[page]) do
            local name, value = entry.name, entry.value
            if named[name] then activityPending[guild] = nil; return false end
            named[name], n = true, n + 1
            local row, floor = cache.rows[name], (cache.activityFloors or {})[name] or cache.revision
            if p.mode == "F" and p.baseRevision == cache.revision and not row then activityPending[guild] = nil; return false end
            if row and p.baseRevision >= floor then
                if value.state == "r" then activityPending[guild] = nil; return false
                else
                    if (value.state == "o") ~= row.online then activityPending[guild] = nil; return false end
                    value.baseRevision = p.baseRevision
                    records[name] = value
                end
            end
        end
    end
    if n ~= p.count or p.mode == "F" and p.baseRevision == cache.revision and n ~= Count(cache.rows) then
        activityPending[guild] = nil; return false
    end
    -- Unchanged rows retain their own revision floor. A heartbeat must not
    -- resurrect an offline tuple from before a join or online transition.
    U.db.activity = U.db.activity or {}
    U.db.activity[guild] = { source = p.source, epoch = p.epoch, revision = p.revision, baseRevision = p.baseRevision,
        sourceAt = p.sourceAt, records = records }
    activityPending[guild], activityNeedsFull[guild] = nil, nil
    if U.Refresh then U.Refresh() end
    return true
end
function U.TakeActivity(f, sender)
    if #f ~= 11 or not U.guild or not U.Connected() or #U.Pack(f) + 9 > 10000 then return false end
    local guild, epoch, mode = Integer(f[1], 1, 2), f[2], f[6]
    if not guild or guild == U.guild or U.TrustedPeer(sender) ~= guild or RemoteSource() ~= sender
        or not U.Text(epoch, 40) or epoch == "" or mode ~= "F" and mode ~= "D" then return false end
    local base, from, revision = Integer(f[3], 1, 1000000000), Integer(f[4], 0, 1000000000), Integer(f[5], 1, 1000000000)
    local index, pages = Integer(f[7], 1, 43), Integer(f[8], 1, mode == "F" and 43 or 4)
    local at, count = Integer(f[9], 0, U.stamp() + 60), Integer(f[10], mode == "F" and 1 or 0, mode == "F" and 1500 or 140)
    if not base or not from or not revision or not index or not pages or index > pages or not at or not count
        or pages ~= math.max(1, math.ceil(count / ACTIVITY_PAGE)) or not U.Text(f[11], 10000)
        or mode == "F" and from ~= 0 or mode == "D" and (from < 1 or revision ~= from + 1) then return false end
    local cache, saved = U.db.rosters[guild], U.db.activity and U.db.activity[guild]
    if saved and saved.source == sender and saved.epoch == epoch and revision <= saved.revision then return false end
    if cache and cache.source == sender and cache.epoch ~= epoch then
        local future = pending[guild]
        if not future or future.source ~= sender or future.epoch ~= epoch then return false end
    end
    local strings = U.Unpack(f[11], ACTIVITY_PAGE)
    local expected = index < pages and ACTIVITY_PAGE or count - (pages - 1) * ACTIVITY_PAGE
    if not strings or #strings ~= expected then return false end
    local entries, named = {}, {}
    for _, raw in ipairs(strings) do
        local name, value = ActivityUnpack(raw, mode)
        if not name or named[name] then return false end
        entries[#entries + 1], named[name] = { name = name, value = value }, true
    end
    local same = saved and saved.source == sender and saved.epoch == epoch
    if mode == "D" and (not same or activityNeedsFull[guild] or saved.needsFull or from ~= saved.revision) then
        return AskActivityFull(guild, sender)
    end
    local p = activityPending[guild]
    if p and p.source == sender and p.epoch == epoch and p.revision > revision then return false end
    if not p or p.source ~= sender or p.epoch ~= epoch or p.revision ~= revision then
        if p and mode == "D" then return AskActivityFull(guild, sender) end
        p = { source = sender, epoch = epoch, baseRevision = base, from = from, revision = revision, mode = mode,
            pages = pages, count = count, sourceAt = at, parts = {}, raw = {}, received = 0, at = U.clock() }
        activityPending[guild] = p
    end
    if p.baseRevision ~= base or p.from ~= from or p.mode ~= mode or p.pages ~= pages or p.count ~= count or p.sourceAt ~= at then return false end
    if p.parts[index] and p.raw[index] ~= f[11] then return AskActivityFull(guild, sender) end
    if not p.parts[index] then p.parts[index], p.raw[index] = entries, f[11]; p.received = p.received + 1 end
    if p.received == pages and cache and cache.source == sender and cache.epoch == epoch and base <= (cache.revision or 0) then
        return ApplyActivity(guild)
    end
    return true
end
function U.PublishRoster(target, localOnly)
    if not U.guild or not next(U.own) or (not localOnly and not target) then return false end
    local rows, page, jobs = {}, {}, {}
    for _, row in pairs(U.own) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local context = localOnly and { epoch = U.NewID(), revision = 0 } or Context(target)
    local version, revision, total = U.NewID(), context.revision + 1, math.ceil(#rows / 35)
    for i, row in ipairs(rows) do
        page[#page + 1] = U.RowPack(row)
        if #page == 35 or i == #rows then
            jobs[#jobs + 1] = { kind = "ROSTER",
                fields = { U.guild, version, math.ceil(i / 35), total, #rows, U.Pack(page), context.epoch, revision },
                dist = localOnly and "GUILD" or "WHISPER", target = not localOnly and target or nil,
                priority = false, requiresGateway = not localOnly }
            page = {}
        end
    end
    if not U.QueueBatch(jobs) then return false end
    if not localOnly then
        context.activityFloors = ActivityFloors(context.rows, U.own, context.activityFloors, context.revision, revision)
        context.revision, context.rows, context.sentAt = revision, U.own, U.clock()
        published = context
        activityForceFull = true
        U.lastSnapshot, U.snapshotDue = U.clock(), U.clock() + 180
    end
    return true
end
function U.TakeRoster(fields, sender)
    if #fields ~= 6 and #fields ~= 8 then return false end
    local guild, version = Integer(fields[1], 1, 2), fields[2]
    local index, pages, count = Integer(fields[3], 1, 43), Integer(fields[4], 1, 43), Integer(fields[5], 1, 1500)
    local epoch = #fields == 8 and fields[7] or nil
    local revision = #fields == 8 and Integer(fields[8], 1, 1000000000) or nil
    if not guild or guild == U.guild or not U.Text(version, 40) or not index or not pages or index > pages then return false end
    if not count or math.ceil(count / 35) ~= pages then return false end
    if #fields == 8 and (not U.Text(epoch, 40) or epoch == "" or not revision) then return false end
    local expectedSource, cache = RemoteSource(), U.db.rosters[guild]
    if expectedSource and expectedSource ~= sender then return false end
    if epoch and cache and cache.epoch == epoch and cache.source == sender and (cache.revision or 0) > revision then return false end
    local strings = U.Unpack(fields[6], 35)
    if not strings or #strings == 0 then return false end
    local rows = {}
    for _, raw in ipairs(strings) do
        local row = U.RowUnpack(raw, guild)
        if not row then return false end
        rows[#rows + 1] = row
    end
    if (index < pages and #rows ~= 35) or (index == pages and #rows ~= count - (pages - 1) * 35) then return false end
    local p = pending[guild]
    if p and p.source == sender and p.epoch == epoch and p.revision and revision and p.revision > revision then return false end
    if not p or p.version ~= version or p.source ~= sender then
        p = { version = version, source = sender, epoch = epoch, revision = revision, count = count,
            pages = pages, received = 0, at = U.clock(), parts = {}, initial = not U.RosterFresh(guild) }
        pending[guild] = p
    end
    if p.pages ~= pages or p.count ~= count or p.epoch ~= epoch or p.revision ~= revision then return false end
    if cache and (cache.source ~= sender or cache.epoch ~= epoch) then needsFull[guild] = true end
    if not p.parts[index] then p.parts[index] = rows; p.received = p.received + 1 end
    if p.received ~= pages then return true end
    local all, n = {}, 0
    for i = 1, pages do
        for _, row in ipairs(p.parts[i]) do
            if all[row.name] then pending[guild] = nil return false end
            all[row.name] = row; n = n + 1
        end
    end
    if n ~= count then pending[guild] = nil return false end
    -- A newer complete delta may have arrived while this snapshot was assembling.
    cache = U.db.rosters[guild]
    if epoch and cache and cache.epoch == epoch and cache.source == sender and (cache.revision or 0) > revision then pending[guild] = nil return false end
    local before = cache and cache.rows
    local same = cache and cache.source == sender and cache.epoch == epoch
    local floors = ActivityFloors(same and cache.rows, all, same and cache.activityFloors,
        same and cache.revision or 0, revision or 0)
    U.db.rosters[guild] = { rows = all, at = U.stamp(), fullAt = U.stamp(), source = sender, epoch = epoch, revision = revision,
        verified = true, activityFloors = floors }
    acceptedAt[guild], needsFull[guild], pending[guild], deltaPending[guild] = U.clock(), nil, nil, nil
    Announce(guild, before, all, p.initial)
    if U.LearnRosterContacts then U.LearnRosterContacts(guild, all) end
    ApplyActivity(guild)
    if U.Refresh then U.Refresh() end
    return true
end
function U.PublishRosterDelta(target)
    local context = published
    if not context or context.guild ~= U.guild or context.target ~= target or context.tenure ~= U.gatewaySince or not context.rows then return false end
    local ops = {}
    for name, row in pairs(U.own) do
        if not Same(context.rows[name], row) then ops[#ops + 1] = { name = name, row = row } end
    end
    for name in pairs(context.rows) do if not U.own[name] then ops[#ops + 1] = { name = name } end end
    if #ops > 140 then return U.PublishRoster(target) end
    table.sort(ops, function(a, b) return a.name < b.name end)
    local from, revision = context.revision, context.revision + (#ops > 0 and 1 or 0)
    local pages, count, jobs = math.max(1, math.ceil(#ops / 35)), Count(U.own), {}
    for page = 1, pages do
        local upserts, removals = {}, {}
        for i = (page - 1) * 35 + 1, math.min(page * 35, #ops) do
            local op = ops[i]
            if op.row then upserts[#upserts + 1] = U.RowPack(op.row) else removals[#removals + 1] = op.name end
        end
        jobs[#jobs + 1] = { kind = "DELTA",
            fields = { U.guild, context.epoch, from, revision, page, pages, U.Pack(upserts), U.Pack(removals), count },
            dist = "WHISPER", target = target, priority = false, requiresGateway = true }
    end
    if not U.QueueBatch(jobs) then return false end
    context.activityFloors = ActivityFloors(context.rows, U.own, context.activityFloors, context.revision, revision)
    context.revision, context.rows, context.sentAt = revision, U.own, U.clock()
    return true
end
function U.TakeRosterDelta(fields, sender)
    if #fields ~= 9 then return false end
    local guild, epoch = Integer(fields[1], 1, 2), fields[2]
    local from, revision = Integer(fields[3], 1, 1000000000), Integer(fields[4], 1, 1000000000)
    local index, pages, count = Integer(fields[5], 1, 4), Integer(fields[6], 1, 4), Integer(fields[9], 1, 1500)
    if not guild or guild == U.guild or not U.Text(epoch, 40) or epoch == "" or not from or not revision or not index or not pages or index > pages or not count then return false end
    if revision ~= from and revision ~= from + 1 then return false end
    local up, remove = U.Unpack(fields[7], 35), U.Unpack(fields[8], 35)
    if not up or not remove or #up + #remove > 35 then return false end
    local empty = #up + #remove == 0
    if empty and (pages ~= 1 or revision ~= from) then return false end
    if not empty and revision ~= from + 1 then return false end
    local cache, expectedSource = U.db.rosters[guild], RemoteSource()
    if expectedSource and expectedSource ~= sender then return false end
    if not cache or cache.source ~= sender or cache.epoch ~= epoch or not cache.revision then return AskFull(guild, sender, "epoch") end
    if revision < cache.revision or (revision == cache.revision and not empty) then return false end
    if needsFull[guild] or from ~= cache.revision then return AskFull(guild, sender, "revision") end
    if empty then
        if count ~= Count(cache.rows) then return AskFull(guild, sender, "count") end
        cache.at, acceptedAt[guild] = U.stamp(), U.clock()
        return true
    end
    local page, named = { up = {}, remove = {} }, {}
    for _, raw in ipairs(up) do
        local row = U.RowUnpack(raw, guild)
        if not row or named[row.name] then return false end
        page.up[#page.up + 1], named[row.name] = row, true
    end
    for _, raw in ipairs(remove) do
        local name = U.Name(raw)
        if not name or named[name] then return false end
        page.remove[#page.remove + 1], named[name] = name, true
    end
    local p = deltaPending[guild]
    if p and (p.epoch ~= epoch or p.source ~= sender or p.from ~= from or p.revision ~= revision) then return AskFull(guild, sender, "overlap") end
    if not p then
        p = { epoch = epoch, source = sender, from = from, revision = revision, pages = pages, count = count,
            received = 0, parts = {}, at = U.clock(), initial = not U.RosterFresh(guild) }
        deltaPending[guild] = p
    end
    if p.pages ~= pages or p.count ~= count then return AskFull(guild, sender, "parts") end
    if not p.parts[index] then p.parts[index] = page; p.received = p.received + 1 end
    if p.received ~= pages then return true end
    local all, changed = {}, {}
    for name, row in pairs(cache.rows) do all[name] = row end
    for i = 1, pages do
        for _, row in ipairs(p.parts[i].up) do
            if changed[row.name] then return AskFull(guild, sender, "duplicate") end
            all[row.name], changed[row.name] = row, true
        end
        for _, name in ipairs(p.parts[i].remove) do
            if changed[name] or not all[name] then return AskFull(guild, sender, "removal") end
            all[name], changed[name] = nil, true
        end
    end
    if Count(all) ~= count then return AskFull(guild, sender, "count") end
    local before = cache.rows
    local floors = ActivityFloors(before, all, cache.activityFloors, cache.revision, revision)
    U.db.rosters[guild] = { rows = all, at = U.stamp(), fullAt = cache.fullAt or cache.at,
        source = sender, epoch = epoch, revision = revision, verified = true, activityFloors = floors }
    acceptedAt[guild], deltaPending[guild] = U.clock(), nil
    Announce(guild, before, all, p.initial)
    if U.LearnRosterContacts then U.LearnRosterContacts(guild, all) end
    ApplyActivity(guild)
    if U.Refresh then U.Refresh() end
    return true
end
function U.RosterTick()
    if not U.guild then return end
    local now, gateway = U.clock(), U.IsGateway()
    if wasGateway and not gateway then published, activityPublished, activityForceFull = nil, nil, false end
    wasGateway = gateway
    local settled = now - changedAt >= 2 or now - (dirtySince or now) >= MAX_DEBOUNCE
    if dirty and settled and now - lastAttempt >= READ_RETRY and now - lastRead >= READ_GAP then U.ReadRoster() end
    if now - lastRequest > (gateway and 15 or 45) then U.RequestRoster(); if not dirty then MarkDirty() end end
    for guild, p in pairs(pending) do
        if now - p.at > 60 then pending[guild] = nil; AskFull(guild, p.source, "snapshot_timeout") end
    end
    for guild, p in pairs(deltaPending) do
        if now - p.at > 20 then AskFull(guild, p.source, "delta_timeout") end
    end
    for guild, p in pairs(activityPending) do
        if now - p.at > ACTIVITY_TTL then AskActivityFull(guild, p.source) end
    end
    if gateway and U.remote and U.Connected() and now >= (U.snapshotDue or 0) and U.ForegroundQueueSize() < 100 then
        local ready = not dirty and now - lastRead < 1 and U.own[U.me]
        if not ready and now - lastAttempt >= READ_RETRY then ready = U.ReadRoster() end
        if ready and U.PublishRoster(U.remote.name) then
            U.snapshotDue, U.lastSnapshot = now + 180, now
        else U.snapshotDue = now + READ_RETRY end
    end
    if gateway and U.remote and U.Connected() and published and not dirty and now - lastRead <= 60
        and now - published.sentAt >= DELTA_EVERY and U.ForegroundQueueSize() < 100 then
        U.PublishRosterDelta(U.remote.name)
    end
    if gateway and U.remote and U.Connected() and published and U.QueueSize() < 100 then U.PublishActivity(U.remote.name) end
end
U.On("GUILD_ROSTER_UPDATE", AuthorityChanged)
U.On("GUILD_RANKS_UPDATE", AuthorityChanged)
U.On("GUILD_RANKS_UPDATE_ACTIVE_PLAYER", AuthorityChanged)
U.On("PLAYER_GUILD_UPDATE", AuthorityChanged)
U.On("PLAYER_REGEN_ENABLED", MarkDirty)
