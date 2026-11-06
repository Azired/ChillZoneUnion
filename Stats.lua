local _, U = ...

local classic = {
    { "WARRIOR", "Воин", 0.78, 0.61, 0.43 },
    { "PALADIN", "Паладин", 0.96, 0.55, 0.73 },
    { "HUNTER", "Охотник", 0.67, 0.83, 0.45 },
    { "ROGUE", "Разбойник", 1, 0.96, 0.41 },
    { "PRIEST", "Жрец", 1, 1, 1 },
    { "SHAMAN", "Шаман", 0, 0.44, 0.87 },
    { "MAGE", "Маг", 0.25, 0.78, 0.92 },
    { "WARLOCK", "Чернокнижник", 0.53, 0.53, 0.93 },
    { "DRUID", "Друид", 1, 0.49, 0.04 },
}
local defaults = {}
for _, entry in ipairs(classic) do defaults[entry[1]] = entry end

function U.ClassInfo(token)
    token = type(token) == "string" and U.Trim(token) or ""
    if token == "" then token = "UNKNOWN" end
    local definition = defaults[token]
    local label = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
    if type(label) ~= "string" or label == "" then
        label = definition and definition[2] or token == "UNKNOWN" and "Неизвестно" or token
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    local function Component(key, index)
        local value = color and color[key]
        return type(value) == "number" and value or definition and definition[index] or 0.65
    end
    return { class = token, label = label,
        color = { r = Component("r", 3), g = Component("g", 4), b = Component("b", 5) } }
end

local function StatisticsRow(row, guilds)
    row.knownTotal, row.knownOnline, row.guilds = 0, 0, {}
    for guild = 1, 2 do
        row.guilds[guild] = { total = guilds[guild].known and 0 or nil, online = guilds[guild].fresh and 0 or nil }
    end
    return row
end

-- Counts describe characters, including offline characters, independently of UI filters.
-- Missing rosters and stale online flags remain unknown rather than becoming zero.
local function StatisticsSources()
    local result = { rows = {}, guilds = {}, knownTotal = 0, knownOnline = 0, complete = true, onlineComplete = true }
    local sourceRows = {}
    for guild = 1, 2 do
        local cache = U.db and U.db.rosters and U.db.rosters[guild]
        local own = guild == U.guild
        local rows
        if own then rows = U.own else rows = cache and cache.rows end
        local known = type(rows) == "table" and (not own or rows[U.me] ~= nil)
        local fresh = known and U.RosterFresh and U.RosterFresh(guild) == true or false
        local state = U.RosterState and U.RosterState(guild) or {}
        result.guilds[guild] = { name = U.GUILDS[guild], known = known, fresh = fresh,
            age = state.age, at = state.at, status = state.status,
            total = known and 0 or nil, online = fresh and 0 or nil }
        sourceRows[guild] = known and rows or {}
        if not known then result.complete = false end
        if not fresh then result.onlineComplete = false end
    end

    return result, sourceRows
end

local function EachMember(sourceRows, visit)
    for guild = 1, 2 do
        local seen = {}
        for key, member in pairs(sourceRows[guild]) do
            if type(member) == "table" then
                local name = U.Name(member.name) or U.Name(key) or tostring(key)
                name = U.Fold(name)
                if not seen[name] then
                    seen[name] = true
                    visit(member, guild)
                end
            end
        end
    end
end

local function CountMember(result, row, member, guild)
    local metadata = result.guilds[guild]
    row.guilds[guild].total = row.guilds[guild].total + 1
    row.knownTotal = row.knownTotal + 1
    metadata.total = metadata.total + 1
    result.knownTotal = result.knownTotal + 1
    if metadata.fresh and member.online == true then
        row.guilds[guild].online = row.guilds[guild].online + 1
        row.knownOnline = row.knownOnline + 1
        metadata.online = metadata.online + 1
        result.knownOnline = result.knownOnline + 1
    end
end

local function FinishStatistics(result)
    for _, row in ipairs(result.rows) do
        row.total = result.complete and row.knownTotal or nil
        row.online = result.onlineComplete and row.knownOnline or nil
    end
    result.total = result.complete and result.knownTotal or nil
    result.online = result.onlineComplete and result.knownOnline or nil
    return result
end

function U.ClassStatistics()
    local result, sourceRows = StatisticsSources()
    local byClass, extra = {}, {}
    for _, definition in ipairs(classic) do
        local row = StatisticsRow(U.ClassInfo(definition[1]), result.guilds)
        byClass[row.class] = row
        result.rows[#result.rows + 1] = row
    end
    EachMember(sourceRows, function(member, guild)
        local info = U.ClassInfo(member.class)
        local row = byClass[info.class]
        if not row then
            row = StatisticsRow(info, result.guilds)
            byClass[row.class] = row; extra[#extra + 1] = row.class
        end
        CountMember(result, row, member, guild)
    end)
    table.sort(extra)
    for _, token in ipairs(extra) do result.rows[#result.rows + 1] = byClass[token] end
    return FinishStatistics(result)
end

local function LevelBounds(level, step)
    if type(level) ~= "number" or level ~= level or level < 1 or level > 100 or level % 1 ~= 0 then return end
    if level == 60 then return 60, 60 end
    local lower = math.max(1, math.floor(level / step) * step)
    if level > 60 then lower = math.max(61, lower) end
    local upper = math.min(level < 60 and 59 or 100, math.floor(level / step) * step + step - 1)
    return lower, upper
end

-- Level 60 remains a separate cap row. Valid higher levels are retained in
-- observed extra buckets; malformed or missing levels stay visible as unknown.
function U.LevelStatistics(step)
    if step ~= 1 and step ~= 5 and step ~= 10 then step = 10 end
    local result, sourceRows = StatisticsSources()
    result.step = step
    local byLower, extra, unknown = {}, {}
    local function LevelRow(lower, upper)
        return StatisticsRow({ lower = lower, upper = upper,
            label = lower == upper and tostring(lower) or lower .. "–" .. upper }, result.guilds)
    end
    for level = 1, 60 do
        local lower, upper = LevelBounds(level, step)
        if not byLower[lower] then
            local row = LevelRow(lower, upper)
            byLower[lower] = row; result.rows[#result.rows + 1] = row
        end
    end
    EachMember(sourceRows, function(member, guild)
        local lower, upper = LevelBounds(member.level, step)
        local row
        if lower then
            row = byLower[lower]
            if not row then
                row = LevelRow(lower, upper)
                byLower[lower] = row; extra[#extra + 1] = lower
            end
        else
            if not unknown then
                unknown = StatisticsRow({ unknown = true, label = U.ClassInfo("UNKNOWN").label }, result.guilds)
            end
            row = unknown
        end
        CountMember(result, row, member, guild)
    end)
    table.sort(extra)
    for _, lower in ipairs(extra) do result.rows[#result.rows + 1] = byLower[lower] end
    if unknown then result.rows[#result.rows + 1] = unknown end
    return FinishStatistics(result)
end
