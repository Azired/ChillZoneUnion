local _, U = ...
U.peers, U.links, U.inboundLinks, U.pings, U.probes = {}, {}, {}, {}, {}
U.setup = { state = "idle", message = "Глава или офицер указывает полное имя офицера второй гильдии и нажимает «Подключить»." }
local lastHello, lastPing, lastClean, lastAsk, lastChat = -100, -100, -100, -100, -100
local remoteSeen, nativeHint, legacyTried = {}, -100, {}
local lastLinkReply, replyWindow, replyCount = {}, -100, 0
local HANDSHAKE_TIMEOUT, LINK_RETRY, PEER_FOR = 180, 4, 65
local outbox, localPending, chatSeen, syncRequests = {}, {}, {}, {}
local historyReplyAt, historyGuildDue, historyRemoteDue = {}, nil, nil
local historyGuildAt, historyRemoteAt, lastBufferTick, lastGateway = -100, -100, -100, nil
local everConnected, disconnectedAt, outageNotified, wasConnected = false, nil, false, false
local OUTBOX_FOR, HISTORY_FOR, HISTORY_LIMIT = 30, 300, 100
local outboxSequence, nativeReadyAt = 0, 0
local QueueCross, RequestHistory, HistoryTick, BufferTick
local selectedLink
local function IsTextKind(kind)
    return kind == "CHAT" or kind == "NATIVE" or kind == "HREC" or kind == "ANNOUNCE" or kind == "ANNSTATE"
end
function U.OtherGuild() return U.guild == 1 and 2 or 1 end
function U.IsTrustOfficer(name)
    name = name or U.me
    local row = U.AuthorityRow(name)
    if not row or not U.RosterFresh(U.guild) then return false end
    return name == U.me and U.IsOfficer() or name ~= U.me and U.RankIsOfficer(row.rank)
end
function U.CanRelay(name)
    name = name or U.me
    local row = U.AuthorityRow(name)
    return row ~= nil and U.RosterFresh(U.guild) and (U.IsTrustOfficer(name) or U.IsVeteranRankName(row.rankName)) or false
end
local function FreshForeignRejection(name, guild)
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    if guild ~= U.OtherGuild() or not cache or not cache.verified or not U.RosterFresh(guild) then return false end
    return not cache.rows[name] or not U.RowCanRelay(cache.rows[name])
end
function U.TrustedPeer(name)
    if not U.db or not U.guild or not name or U.own[name] then return nil end
    if FreshForeignRejection(name, U.OtherGuild()) then return nil end
    local c = U.db.contacts[name]
    if c and c.approved == true and c.guild == U.OtherGuild() then return c.guild end
    -- The bounded probe/contact cache need not contain every officer. A roster
    -- authenticated through the approved link also authorizes its officers.
    local cache = U.db.rosters[U.OtherGuild()]
    local row = cache and cache.verified and cache.rows[name]
    if row and U.RowCanRelay(row) then return U.OtherGuild() end
end
function U.TrustedTransferPeer(name)
    return U.TransferPeer and U.TransferPeer(name) or nil
end
function U.CanStartLink(name)
    if not U.guild or not U.own or not U.own[U.me] then return false end
    if name == nil then return U.IsTrustOfficer() end
    name = U.Name(name)
    if not name or name == U.me or U.own[name] then return false end
    return U.IsTrustOfficer() or U.CanRelay() and U.TrustedPeer(name) == U.OtherGuild() or false
end
local function Contact(name, guild, share, approve)
    name, guild = U.Name(name), tonumber(guild)
    if not name or name == U.me or U.own[name] or not U.GUILDS[guild] or guild == U.guild then return false end
    if FreshForeignRejection(name, guild) then return false end
    local old = U.db.contacts[name]
    if not approve and U.TrustedPeer(name) ~= guild then return false end
    local fresh = not old or old.addon ~= true or old.guild ~= guild
    U.db.contacts[name] = { guild = guild, at = U.stamp(), addon = true, approved = true,
        pairedBy = old and old.guild == guild and old.approved == true and old.pairedBy or nil }
    local contacts = {}
    for n, c in pairs(U.db.contacts) do contacts[#contacts + 1] = { name = n, at = c.at or 0, addon = c.addon == true } end
    table.sort(contacts, function(a, b)
        if a.addon ~= b.addon then return a.addon end
        if a.at ~= b.at then return a.at > b.at end
        return a.name < b.name
    end)
    for i = 31, #contacts do U.db.contacts[contacts[i].name] = nil end
    if U.ElectionChanged then U.ElectionChanged(U.me) end
    if share and (fresh or approve) and U.IsTrustOfficer() then U.Queue("CONTACT", { name, guild }, "GUILD", nil, true) end
    return true
end
function U.AddContact(name, guild, share) return Contact(name, guild, share, false) end
function U.ApproveContact(name, guild, share) return Contact(name, guild, share, true) end
local function PairReady(name)
    name = name or U.me
    if name ~= U.me then
        local peer = U.peers[name]
        return peer ~= nil and peer.pairReady == true and U.CanRelay(name) or false
    end
    if not U.CanRelay(name) then return false end
    for _, contact in pairs(U.db.contacts) do
        if contact.approved == true and contact.guild == U.OtherGuild() then return true end
    end
    return false
end
function U.ShareTrust()
    if not U.IsTrustOfficer() then return false end
    local jobs = {}
    for name, contact in pairs(U.db.contacts) do
        if contact.approved == true and contact.guild == U.OtherGuild() then
            jobs[#jobs + 1] = { kind = "CONTACT", fields = { name, contact.guild }, dist = "GUILD", priority = true }
        end
    end
    if #jobs == 0 then
        U.Print("Подтверждённых контактов пока нет. Сначала подключите вторую гильдию и дождитесь подтверждения.")
        return false
    end
    if not U.QueueBatch(jobs) then
        U.Print("Не удалось передать настройки: очередь сообщений заполнена. Повторите через несколько секунд.")
        return false
    end
    U.Print("Подтверждённые контакты отправлены участникам своей гильдии, которые сейчас в игре с аддоном. Связные выбираются автоматически.")
    return true
end
-- Only complete rosters/deltas from an already authenticated union connection
-- can introduce new foreign officers. HELLO/candidate claims cannot do so.
function U.LearnRosterContacts(guild, rows)
    if guild ~= U.OtherGuild() then return end
    for name, c in pairs(U.db.contacts) do
        if c.guild == guild and (not rows[name] or not U.RowCanRelay(rows[name])) then
            U.db.contacts[name], U.links[name], U.inboundLinks[name], U.probes[name] = nil, nil, nil, nil
            if U.remote and U.remote.name == name then U.remote, U.gatewaySince = nil, nil end
            if U.linkState and U.linkState.name == name then U.linkState = nil end
        end
    end
    local names = {}
    for name, row in pairs(rows) do if U.RowCanRelay(row) then names[#names + 1] = name end end
    table.sort(names, function(a, b)
        if rows[a].online ~= rows[b].online then return rows[a].online end
        return a < b
    end)
    for i = 1, math.min(30, #names) do U.ApproveContact(names[i], guild) end
    if U.ElectionChanged then U.ElectionChanged(U.me) end
end
local function Alive(name)
    if not name or not U.guild then return false end
    local row = U.AuthorityRow(name)
    if not row or not row.online then return false end
    if name == U.me then return true end
    local p = U.peers[name]
    return p and p.guild == U.guild and U.clock() - p.at < PEER_FOR
end
-- Maintain both election orders incrementally. HELLO changes one entry; ticks
-- read the elected heap root rather than walking every installed member.
local electionDirty, indexedPeers, indexedOwn, indexedGuild, indexedMe = true
local indexedRemote, indexedSince, indexedRanks
local alphabetical = { rows = {}, positions = {}, connected = false }
local established = { rows = {}, positions = {}, connected = true }
local function Before(heap, a, b)
    if heap.connected and a.since ~= b.since then return a.since < b.since end
    return a.name < b.name
end
local function Swap(heap, a, b)
    local rows = heap.rows
    rows[a], rows[b] = rows[b], rows[a]
    heap.positions[rows[a].name], heap.positions[rows[b].name] = a, b
end
local function Restore(heap, index)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not Before(heap, heap.rows[index], heap.rows[parent]) then break end
        Swap(heap, index, parent); index = parent
    end
    while true do
        local child = index * 2
        if child > #heap.rows then break end
        if child < #heap.rows and Before(heap, heap.rows[child + 1], heap.rows[child]) then child = child + 1 end
        if not Before(heap, heap.rows[child], heap.rows[index]) then break end
        Swap(heap, index, child); index = child
    end
end
local function RemoveCandidate(heap, name)
    local index, rows = heap.positions[name], heap.rows
    if not index then return end
    heap.positions[name] = nil
    local last = table.remove(rows)
    if index <= #rows then rows[index], heap.positions[last.name] = last, index; Restore(heap, index) end
end
local function InsertCandidate(heap, entry)
    local index = #heap.rows + 1
    heap.rows[index], heap.positions[entry.name] = entry, index
    Restore(heap, index)
end
local function UpdateCandidate(name)
    RemoveCandidate(alphabetical, name); RemoveCandidate(established, name)
    if not PairReady(name) or not Alive(name) then return end
    local peer, now = U.peers[name], U.clock()
    local entry = { name = name, expires = name == U.me and math.huge or peer.at + PEER_FOR }
    InsertCandidate(alphabetical, entry)
    if name == U.me then
        if not U.remote or now - U.remote.at >= PEER_FOR or not U.gatewaySince then return end
        entry.since, entry.connectionExpires = U.gatewaySince, U.remote.at + PEER_FOR
    elseif peer.remote and peer.leader == name then
        entry.since, entry.connectionExpires = peer.since or 0, entry.expires
    else return end
    InsertCandidate(established, entry)
end
function U.ElectionChanged(name)
    if not name or electionDirty or indexedPeers ~= U.peers or indexedOwn ~= U.own
        or indexedGuild ~= U.guild or indexedMe ~= U.me then electionDirty = true; return end
    UpdateCandidate(name)
end
local function EnsureElection()
    U.RankPermissionsCurrent()
    if electionDirty or indexedPeers ~= U.peers or indexedOwn ~= U.own or indexedGuild ~= U.guild
        or indexedMe ~= U.me or indexedRanks ~= U.rankPermissionRevision then
        alphabetical.rows, alphabetical.positions, established.rows, established.positions = {}, {}, {}, {}
        UpdateCandidate(U.me)
        for name in pairs(U.peers) do if name ~= U.me then UpdateCandidate(name) end end
        indexedPeers, indexedOwn, indexedGuild, indexedMe = U.peers, U.own, U.guild, U.me
        indexedRanks, electionDirty = U.rankPermissionRevision, false
    end
    if indexedRemote ~= U.remote or indexedSince ~= U.gatewaySince then
        indexedRemote, indexedSince = U.remote, U.gatewaySince
        UpdateCandidate(U.me)
    end
end
local function ValidCandidate(entry, connected)
    return entry.expires > U.clock() and (not connected or entry.connectionExpires > U.clock())
        and PairReady(entry.name) and Alive(entry.name)
end
local function Elected(heap)
    while heap.rows[1] do
        local entry = heap.rows[1]
        if ValidCandidate(entry, heap.connected) then return entry.name end
        UpdateCandidate(entry.name)
    end
end
function U.GatewayName()
    if not U.guild or not Alive(U.me) then return nil end
    EnsureElection()
    return Elected(established) or Elected(alphabetical)
end
function U.IsGateway() return U.guild ~= nil and U.GatewayName() == U.me end
function U.CandidateNames()
    if not U.guild or not Alive(U.me) then return U.Pack({}) end
    EnsureElection()
    -- Find the first eight names through a bounded heap frontier.
    -- Expired candidates are removed lazily, including ones outside the winner.
    while true do
        local names, frontier, retry = {}, #alphabetical.rows > 0 and { 1 } or {}, false
        while #frontier > 0 and #names < 8 do
            local best = 1
            for i = 2, #frontier do
                if alphabetical.rows[frontier[i]].name < alphabetical.rows[frontier[best]].name then best = i end
            end
            local index = table.remove(frontier, best)
            local entry = alphabetical.rows[index]
            if not ValidCandidate(entry, false) then UpdateCandidate(entry.name); retry = true; break end
            names[#names + 1] = entry.name
            if alphabetical.rows[index * 2] then frontier[#frontier + 1] = index * 2 end
            if alphabetical.rows[index * 2 + 1] then frontier[#frontier + 1] = index * 2 + 1 end
        end
        if not retry then return U.Pack(names) end
    end
end
function U.LearnCandidates(raw, guild)
    local names = U.Unpack(raw, 8)
    if names then for _, name in ipairs(names) do U.AddContact(name, guild) end end
end
function U.Connected()
    local gateway = U.GatewayName()
    if not gateway then return false end
    if gateway == U.me then return U.remote ~= nil and U.clock() - U.remote.at < PEER_FOR end
    return U.linkState ~= nil and U.linkState.gateway == gateway and U.clock() - U.linkState.at < PEER_FOR
end
function U.SetupState()
    if U.Connected() then
        return { state = "connected", target = U.setup.target or U.db.setupContact, message = "Гильдии соединены. Общий чат работает; состав загружается или обновляется." }
    end
    if U.setup.state == "connected" then
        return { state = "connecting", target = U.setup.target, message = "Восстанавливаем связь со второй гильдией…" }
    end
    return U.setup
end
local function Setup(state, target, message)
    U.setup = { state = state, target = target, message = message }
    if U.Refresh then U.Refresh() end
end
function U.NetworkReset()
    if U.PresenceReset then U.PresenceReset() end
    for id in pairs(outbox) do if U.CancelQueued then U.CancelQueued("out:" .. id) end end
    outbox, localPending, chatSeen, syncRequests = {}, {}, {}, {}
    historyGuildDue, historyRemoteDue, lastGateway = nil, nil, nil
    wasConnected, disconnectedAt, outageNotified = false, nil, false
    U.peers, U.remote, U.linkState, U.gatewaySince = {}, nil, nil, nil
    U.links, U.inboundLinks, U.probes, U.pings = {}, {}, {}, {}
    selectedLink = nil
    U.setup = { state = "idle", message = "Выберите офицера второй гильдии для первого подключения." }
    U.own = {}
    U.ClearQueue()
    if U.ElectionChanged then U.ElectionChanged() end
    lastHello, lastPing, U.snapshotDue = -100, -100, 0
end
function U.SayHello()
    if not U.guild or not U.me then return false end
    local contacts, list = {}, {}
    for n, c in pairs(U.db.contacts) do
        if c.approved == true and c.guild ~= U.guild and c.addon == true then list[#list + 1] = { name = n, at = c.at or 0 } end
    end
    local active = U.remote and U.remote.name or U.linkState and U.linkState.name
    if active and U.TrustedPeer(active) == U.OtherGuild() then contacts[1] = active end
    table.sort(list, function(a, b)
        if (a.name == active) ~= (b.name == active) then return a.name == active end
        if a.at == b.at then return a.name < b.name end
        return a.at > b.at
    end)
    for _, entry in ipairs(list) do
        if #contacts >= 3 then break end
        if entry.name ~= active then contacts[#contacts + 1] = entry.name end
    end
    local gateway = U.GatewayName()
    local remote = gateway == U.me and U.remote and U.clock() - U.remote.at < PEER_FOR and U.remote.name or ""
    local queued = U.Queue("HELLO", { U.guild, U.VERSION, U.Pack(contacts), remote, gateway or "", remote ~= "" and (U.gatewaySince or 0) or 0, PairReady() and "1" or "0" }, "GUILD", nil, true)
    if queued then lastHello = U.clock() end
    return queued
end
function U.OnRosterReady()
    U.SayHello(); lastPing = -100
    nativeReadyAt = U.clock() + 2
    if RequestHistory then RequestHistory(false) end
    if U.TransferSyncRequest then U.TransferSyncRequest(true) end
end
local function SendPing(name, introduction)
    if not U.guild or not U.CanRelay() or not Alive(U.me) or not U.TrustedPeer(name) or (not introduction and not U.IsGateway()) then return false end
    if U.Queue("PING", { U.guild, U.CandidateNames(), U.GatewayName() or "" }, "WHISPER", name, true, false, nil, not introduction) then
        U.probes[name] = { at = U.clock(), untilAt = U.clock() + 30 }
        U.pings[name] = U.clock()
        return true
    end
    return false
end
function U.SetRemote(name, paired)
    if paired and U.CanRelay() and U.TrustedPeer(name) then
        local contact = U.db.contacts[name]
        if contact then
            if type(contact.pairedBy) ~= "table" then contact.pairedBy = {} end
            contact.pairedBy[U.me] = true
        end
    end
    if not U.IsGateway() or not U.TrustedPeer(name) then return false end
    local changed = not U.remote or U.remote.name ~= name
    if not U.gatewaySince then U.gatewaySince = U.stamp() end
    U.remote = { name = name, at = U.clock() }
    if U.ElectionChanged then U.ElectionChanged(U.me) end
    U.linkState = { name = name, gateway = U.me, at = U.clock() }
    U.AddContact(name, U.OtherGuild(), changed)
    if changed then
        U.snapshotDue = 0
        U.SayHello()
        if RequestHistory then RequestHistory(true) end
        if U.ExtensionSync then U.ExtensionSync("remote") end
    end
    if U.setup.state == "connecting" or U.setup.state == "idle" then Setup("connected", U.setup.target or name, "Гильдии соединены. Можно писать в общий чат.") end
    return true
end
local function ValidNonce(n) return U.Text(n, 40) and n ~= "" and n:match("^[%d%.]+$") ~= nil end
local function LinkSend(name, mode, nonce, challenge)
    return U.Queue("LINK", { "3", mode, U.guild, nonce, challenge or "" }, "WHISPER", name, true)
end
local function ReplyLink(name, mode, nonce, challenge)
    local now = U.clock()
    if now - replyWindow > 10 then replyWindow, replyCount = now, 0 end
    if replyCount >= 40 or now - (lastLinkReply[name] or -100) < 0.2 then return false end
    if LinkSend(name, mode, nonce, challenge) then
        lastLinkReply[name], replyCount = now, replyCount + 1
        return true
    end
    return false
end
function U.Link(name)
    if not U.guild then
        Setup("error", nil, "Персонаж должен состоять в одной из двух гильдий союза.")
        U.Print(U.setup.message); return false
    end
    if not U.own[U.me] then
        U.RequestRoster()
        Setup("error", name, "Состав вашей гильдии ещё загружается. Повторите через несколько секунд.")
        U.Print(U.setup.message); return false
    end
    name = U.Name(name)
    if not name then
        Setup("error", nil, "Введите полное имя офицера второй гильдии: Имя Фамилия.")
        U.Print(U.setup.message); return false
    end
    if name == U.me or U.own[name] then
        Setup("error", name, "Укажите офицера второй гильдии. Этот персонаж состоит в вашей гильдии.")
        U.Print(U.setup.message); return false
    end
    if not U.CanStartLink(name) then
        Setup("error", name, "Первое соединение настраивает глава или персонаж с игровыми офицерскими правами. Обычные участники не становятся связными.")
        U.Print(U.setup.message); return false
    end
    if U.ChatLocked() then
        Setup("error", name, "Игра временно ограничила обмен сообщениями. Повторите после снятия ограничения.")
        U.Print(U.setup.message); return false
    end
    local active = U.links[name]
    if active and U.clock() < active.untilAt then
        Setup("connecting", name, "Ожидаем ответа офицера " .. U.SafeDisplay(name) .. "…")
        return true
    end
    local nonce = U.NewID()
    if not LinkSend(name, "hello", nonce, "") then
        Setup("error", name, "Очередь сообщений заполнена. Повторите соединение через несколько секунд.")
        U.Print(U.setup.message); return false
    end
    U.links[name] = { outbound = true, nonce = nonce, guild = U.OtherGuild(), phase = "hello", at = U.clock(), untilAt = U.clock() + HANDSHAKE_TIMEOUT, nextAt = U.clock() + LINK_RETRY }
    U.db.setupContact = name
    Setup("connecting", name, "Ожидаем подтверждения соединения от " .. U.SafeDisplay(name) .. "…")
    U.Print("Соединяем гильдии через " .. U.SafeDisplay(name) .. ". Первое соединение гильдий нужно подтвердить на второй стороне после проверки полного имени.")
    return true
end
local function InboundLink(name)
    name = U.Name(name)
    if not name then return nil end
    if U.inboundLinks[name] then return name, U.inboundLinks[name] end
    for canonical, request in pairs(U.inboundLinks) do
        if U.Fold(canonical) == U.Fold(name) then return canonical, request end
    end
end
function U.PendingLink(name, nonce)
    if not U.IsTrustOfficer() then return nil end
    local function Card(canonical, request, expected)
        if request and not request.approved and U.clock() <= request.untilAt
            and (expected == nil or request.nonce == expected) then
            return { name = canonical, guild = request.guild, nonce = request.nonce, untilAt = request.untilAt }
        end
    end
    if name ~= nil or nonce ~= nil then
        if not ValidNonce(nonce) then return nil end
        local canonical, request = InboundLink(name)
        return Card(canonical, request, nonce)
    end
    if selectedLink then
        local canonical, request = InboundLink(selectedLink.name)
        local current = Card(canonical, request, selectedLink.nonce)
        if current then return current end
        selectedLink = nil
    end
    local chosen, request
    for name, pending in pairs(U.inboundLinks) do
        if not pending.approved and U.clock() <= pending.untilAt and (not request or pending.at < request.at or pending.at == request.at and name < chosen) then
            chosen, request = name, pending
        end
    end
    return Card(chosen, request)
end
function U.SelectPendingLink(name, nonce)
    if not U.Name(name) or not ValidNonce(nonce) then return false end
    local request = U.PendingLink(name, nonce)
    if not request then return false end
    selectedLink = { name = request.name, nonce = request.nonce }
    if U.Refresh then U.Refresh() end
    return true
end
function U.ConnectionView()
    local view = { connected = false, hasContacts = false, stage = "idle" }
    if not U.db or not U.guild then
        view.role, view.heading = "outside", "Вы не в гильдии союза"
        view.message = "Аддон работает для «Чиллзон» и «Чиллзон Навсегда»."
        return view
    end
    if not U.own[U.me] then
        view.role, view.heading = "loading", "Загружаем состав гильдии"
        view.message = "Подождите несколько секунд: проверяем игровые права и настройки союза."
        return view
    end
    local officer = U.IsTrustOfficer()
    view.role = officer and "officer" or U.CanRelay() and "relay" or "member"
    for name, contact in pairs(U.db.contacts or {}) do
        if contact.approved == true and contact.guild == U.OtherGuild() and not U.own[name] and U.Name(name) == name then
            view.hasContacts = true; break
        end
    end
    view.connected = U.Connected() == true
    local pending = officer and U.PendingLink()
    if pending then
        view.stage, view.heading = "pending", "Требуется ваше подтверждение"
        view.pendingName, view.pendingGuild = pending.name, pending.guild
        view.message = "Запрос соединения от " .. U.SafeDisplay(pending.name)
            .. ". Сверьте полное имя с руководителем второй гильдии, затем подтвердите или отклоните запрос. Внешняя гильдия и звание автоматически не проверены."
    elseif view.connected then
        view.stage, view.heading = "connected", "Союз подключён"
        view.message = officer and "Общий чат и состав работают. Настройки участникам передаются автоматически."
            or "Ручная настройка не требуется. Общий чат и состав работают; пишите в обычный /г или откройте чат здесь."
    elseif not officer then
        view.stage, view.heading = "connecting", "Ожидаем подключение союза"
        view.message = view.hasContacts and "Ручная настройка не требуется. Ждём связного онлайн в каждой гильдии; аддон восстановит связь автоматически."
            or "Ручная настройка не требуется. Ждём настроенного главу или офицера вашей гильдии онлайн, чтобы получить настройки союза."
    else
        local state = U.setup or {}
        if state.state == "declined" or state.state == "expired" or state.state == "error" then
            view.stage = state.state
            view.heading = state.state == "declined" and "Запрос отклонён" or state.state == "expired" and "Время ожидания истекло" or "Подключение не выполнено"
            view.message = state.message
        elseif state.state == "connecting" then
            view.stage, view.heading, view.message = "connecting", "Дождитесь подтверждения", state.message
        elseif view.hasContacts then
            view.stage, view.heading = "connecting", "Восстанавливаем связь"
            view.message = "Настройки сохранены. Нужен настроенный связной онлайн с каждой стороны; повторное подключение вручную обычно не требуется."
        else
            view.heading = "Выберите офицера второй гильдии"
            view.message = "Оба офицера должны быть онлайн с аддоном. Введите полное имя, нажмите «Подключить» и попросите второго офицера открыть запрос и подтвердить ваше имя."
        end
    end
    return view
end
function U.AcceptLink(name, nonce)
    local canonical, request = InboundLink(name)
    if not U.IsTrustOfficer() or not request or request.approved or U.clock() > request.untilAt or U.ChatLocked()
        or nonce ~= nil and request.nonce ~= nonce then return false end
    if selectedLink and selectedLink.name == canonical and selectedLink.nonce == request.nonce then selectedLink = nil end
    request.approved, request.challenge, request.manual = true, U.NewID(), true
    request.untilAt = U.clock() + HANDSHAKE_TIMEOUT
    ReplyLink(canonical, "challenge", request.nonce, request.challenge)
    Setup("connecting", canonical, "Запрос подтверждён. Дождитесь завершения соединения; повторно вводить имя не нужно.")
    return true
end
function U.DeclineLink(name, nonce)
    local canonical, request = InboundLink(name)
    if not U.IsTrustOfficer() or not request or request.approved or U.clock() > request.untilAt
        or nonce ~= nil and request.nonce ~= nonce then return false end
    if selectedLink and selectedLink.name == canonical and selectedLink.nonce == request.nonce then selectedLink = nil end
    U.inboundLinks[canonical] = nil
    ReplyLink(canonical, "error", request.nonce, "declined")
    Setup("declined", canonical, "Вы отклонили запрос. Для нового подключения договоритесь со вторым офицером и попросите его отправить запрос заново либо введите его полное имя.")
    return true
end
local function OutgoingLink(sender, nonce, guild)
    local direct = U.links[sender]
    if direct then return direct end
    local folded = U.Fold(sender)
    for name, pending in pairs(U.links) do
        if U.Fold(name) == folded and pending.outbound and pending.nonce == nonce
            and pending.guild == guild and U.clock() <= pending.untilAt then
            U.links[name], U.links[sender] = nil, pending
            if U.setup.target == name then U.setup.target = sender end
            if U.db.setupContact == name then U.db.setupContact = sender end
            return pending
        end
    end
end
local function TakeLink(f, sender)
    if #f ~= 5 or f[1] ~= "3" or not U.guild or U.own[sender] or not ValidNonce(f[4]) then return end
    local mode, guild, nonce, challenge = f[2], tonumber(f[3]), f[4], f[5]
    if guild ~= U.OtherGuild() then return end
    if mode == "hello" then
        if challenge ~= "" then return end
        if not U.own[U.me] then U.RequestRoster(); ReplyLink(sender, "wait", nonce, "roster"); return end
        if not U.CanRelay() then ReplyLink(sender, "error", nonce, "officer"); return end
        local p = U.inboundLinks[sender]
        if p and p.nonce == nonce and U.clock() <= p.untilAt then
            if p.approved then ReplyLink(sender, "challenge", nonce, p.challenge)
            else ReplyLink(sender, "wait", nonce, "approval") end
            return
        end
        local n = 0; for _ in pairs(U.inboundLinks) do n = n + 1 end
        if n >= 12 then return end
        local approved = U.TrustedPeer(sender) == guild
        if not approved and not U.IsTrustOfficer() then ReplyLink(sender, "error", nonce, "approval"); return end
        p = { nonce = nonce, guild = guild, approved = approved, at = U.clock(), untilAt = U.clock() + HANDSHAKE_TIMEOUT }
        U.inboundLinks[sender] = p
        if approved then
            p.challenge = U.NewID(); ReplyLink(sender, "challenge", nonce, p.challenge)
        else
            Setup("approval", sender, "Запрос соединения от " .. U.SafeDisplay(sender) .. ". Внешняя гильдия и ранг не проверены игрой. Проверьте полное имя с руководителем второй гильдии, затем подтвердите или отклоните запрос.")
            if U.NotifyConnectionRequest then U.NotifyConnectionRequest({ name = sender, guild = guild, nonce = nonce, untilAt = p.untilAt }) end
            ReplyLink(sender, "wait", nonce, "approval")
        end
    elseif mode == "prove" then
        local p = U.inboundLinks[sender]
        if not p or not p.approved or p.nonce ~= nonce or p.challenge ~= challenge or U.clock() > p.untilAt or not U.CanRelay() then return end
        -- A challenge proves only liveness. A local native officer must first approve
        -- the exact external endpoint; authorized relay operators remain trusted.
        if not p.completed then
            if p.manual and not U.IsTrustOfficer() then return end
            if not U.ApproveContact(sender, guild, true) then
                ReplyLink(sender, "wait", nonce, "roster")
                return
            end
            p.completed = true
            U.SetRemote(sender, true)
            U.SayHello()
            lastPing = -100
        end
        ReplyLink(sender, "ready", nonce, challenge)
        -- A setup officer may not be the elected bridge. Introduce the bridge
        -- through this proved endpoint before unknown bridges can contact it.
        SendPing(sender, true)
    else
        local p = OutgoingLink(sender, nonce, guild)
        if not p or not p.outbound or p.nonce ~= nonce or p.guild ~= guild or U.clock() > p.untilAt then return end
        if not U.CanStartLink(sender) then U.links[sender] = nil; return end
        if mode == "challenge" then
            if not ValidNonce(challenge) or (p.challenge and p.challenge ~= challenge) then return end
            p.challenge, p.phase, p.nextAt = challenge, "prove", U.clock() + LINK_RETRY
            LinkSend(sender, "prove", nonce, challenge)
            Setup("connecting", sender, "Офицер ответил. Проверяем соединение…")
        elseif mode == "ready" then
            if p.phase ~= "prove" or not p.challenge or p.challenge ~= challenge then return end
            if not U.ApproveContact(sender, guild, true) then
                Setup("connecting", sender, "Свежий состав ещё не подтверждает права выбранного связного. Ожидаем обновления состава и повторяем соединение.")
                return
            end
            U.links[sender] = nil
            U.SetRemote(sender, true)
            U.SayHello(); lastPing = -100
            Setup("connecting", sender, "Ответ проверен. Соединяем общий чат гильдий…")
            SendPing(sender, true)
        elseif mode == "wait" and p.phase == "hello" and challenge == "roster" then
            Setup("connecting", sender, "У офицера ещё загружается состав гильдии. Повторяем соединение…")
        elseif mode == "wait" and p.phase == "hello" and challenge == "approval" then
            Setup("connecting", sender, "Ожидаем однократного подтверждения точного имени на второй стороне. Внешняя гильдия и роль не могут быть проверены этим аддоном автоматически.")
        elseif mode == "error" and (challenge == "declined" or challenge == "approval") then
            U.links[sender] = nil
            Setup(challenge == "declined" and "declined" or "error", sender, challenge == "declined"
                and "Вторая сторона отклонила запрос. Сверьте полное имя и договоритесь о подключении, затем нажмите «Подключить» ещё раз."
                or "Новый контакт должен подтвердить настоящий глава или офицер второй гильдии.")
            U.Print(U.setup.message)
        elseif mode == "error" and p.phase == "hello" and challenge == "officer" then
            U.links[sender] = nil
            Setup("error", sender, "Этот персонаж не является офицером второй гильдии. Укажите её главу или офицера.")
            U.Print(U.setup.message)
        end
    end
end
local function LinkTick(now)
    for name, p in pairs(U.links) do
        if now > p.untilAt then
            U.links[name] = nil
            if U.setup.target == name then
                Setup("expired", name, "Соединение не подтверждено за 3 минуты. Сверьте полное имя, попросите второго офицера открыть запрос и нажмите «Подключить» ещё раз, когда оба будете онлайн с аддоном.")
                U.Print(U.setup.message)
            end
        elseif now >= p.nextAt then
            if U.CanStartLink(name) then LinkSend(name, p.phase == "prove" and "prove" or "hello", p.nonce, p.challenge or "") end
            p.nextAt = now + LINK_RETRY
        end
    end
    for name, p in pairs(U.inboundLinks) do
        if now > p.untilAt then
            U.inboundLinks[name] = nil
            if not p.completed and U.setup.target == name then
                Setup("expired", name, "Время ожидания запроса истекло. Попросите второго офицера отправить запрос заново либо введите его полное имя и нажмите «Подключить».")
            end
        end
    end
end
function U.Status()
    if not U.guild then return "Вы не в одной из гильдий союза." end
    if not U.own[U.me] then return "Загружается состав вашей гильдии…" end
    local gateway, remote = U.GatewayName(), nil
    if U.Connected() then remote = gateway == U.me and U.remote.name or U.linkState.name end
    return "Гильдия: " .. U.GUILDS[U.guild] .. ". Посредник: " .. tostring(gateway) .. ". Связь: " .. (remote or "ожидание второй гильдии") .. ". В очереди: " .. U.QueueSize()
end

local function StableID()
    return tostring(U.guild) .. ":" .. U.me .. ":" .. U.NewID()
end
local function RecordFields(entry)
    return { entry.guild, entry.name, entry.text, entry.id, entry.time or entry.at }
end
local function ValidateRecord(f, guild)
    if #f ~= 5 or tonumber(f[1]) ~= guild or not U.Name(f[2]) or not U.Text(f[3], 1200) then return nil end
    if not U.Text(f[4], 240) or f[4] == "" or f[4]:find("[%c|]") or f[4]:sub(1, 2) ~= tostring(guild) .. ":" then return nil end
    local at = tonumber(f[5])
    if not at or at > U.stamp() + 60 or U.stamp() - at > HISTORY_FOR then return nil end
    return at
end
local function Status(id, state, announce)
    local seen = chatSeen[id]
    if seen and seen.state == "delivered" and state ~= "delivered" then return end
    chatSeen[id] = { at = U.clock(), state = state }
    if state ~= "pending" then localPending[id] = nil end
    if U.ChatStatus then U.ChatStatus(id, state) end
    if announce and U.IsGateway() then
        U.Queue("STATE", { id, state }, "GUILD", nil, true, false, nil, true, U.clock() + OUTBOX_FOR)
    end
end
local function ShowRecord(f, native, state, replayed, nativeRelay)
    local id, at = f[4], tonumber(f[5])
    local previous = chatSeen[id]
    if previous and previous.state ~= "pending" and state == "pending" then state = previous.state end
    chatSeen[id] = { at = U.clock(), state = state }
    if state == "pending" then
        localPending[id] = U.clock() + math.max(0, OUTBOX_FOR - (U.stamp() - at))
    else localPending[id] = nil end
    U.Chat(tonumber(f[1]), U.Name(f[2]), f[3], native, { id = id, at = at, status = state,
        replayed = replayed == true, nativeRelay = nativeRelay == true })
end
local function Recent()
    if U.ChatRecent then return U.ChatRecent(HISTORY_LIMIT, U.stamp() - HISTORY_FOR) end
    return U.history or {}
end
function U.ChatOutboxCount()
    local n = 0; for _ in pairs(outbox) do n = n + 1 end; return n
end
QueueCross = function(f)
    if not U.IsGateway() then return false end
    local id, now = f[4], U.clock()
    if outbox[id] then return true end
    local known = chatSeen[id]
    if known and known.state ~= "pending" then return false end
    local remaining = OUTBOX_FOR - (U.stamp() - tonumber(f[5]))
    if remaining <= 0 or U.ChatOutboxCount() >= 100 then Status(id, "local-only", true); return false end
    outboxSequence = outboxSequence + 1
    outbox[id] = { fields = f, untilAt = now + math.min(OUTBOX_FOR, remaining), nextAt = now, order = outboxSequence, id = id }
    return true
end
local function AcceptAck(f)
    if #f ~= 2 or tonumber(f[1]) ~= U.guild or not U.Text(f[2], 240) then return false end
    local id = f[2]
    if not outbox[id] and not chatSeen[id] then return false end
    outbox[id] = nil
    if U.CancelQueued then U.CancelQueued("out:" .. id) end
    Status(id, "delivered", true)
    return true
end
BufferTick = function(now)
    for id, untilAt in pairs(localPending) do
        if now >= untilAt then Status(id, "local-only", false) end
    end
    for id, item in pairs(outbox) do
        if now >= item.untilAt then
            outbox[id] = nil
            if U.CancelQueued then U.CancelQueued("out:" .. id) end
            Status(id, "local-only", true)
        end
    end
    if not U.IsGateway() or not U.Connected() or now - lastBufferTick < 0.5 then return end
    lastBufferTick = now
    local pending = {}
    for _, item in pairs(outbox) do if now >= item.nextAt then pending[#pending + 1] = item end end
    table.sort(pending, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
    for i = 1, math.min(3, #pending) do
        local item = pending[i]
        if U.Queue("CHAT", item.fields, "WHISPER", U.remote.name, true, true, nil, true, item.untilAt, "out:" .. item.id) then
            -- Allow the queued fragments to leave before repeating a missing acknowledgement.
            item.nextAt = now + math.max(3, U.QueueSize() * 0.2 + 2)
        else item.nextAt = now + 1 end
    end
end
local function KnownIDs()
    local ids = {}
    for _, entry in ipairs(Recent()) do if entry.id then ids[#ids + 1] = entry.id end end
    while #ids > HISTORY_LIMIT do table.remove(ids, 1) end
    return U.Pack(ids)
end
RequestHistory = function(remote)
    if remote then historyRemoteDue = U.clock() else historyGuildDue = U.clock() end
end
function U.RequestHistory() RequestHistory(false); RequestHistory(true) end
local function SendHistory(f, dist, target)
    if #f ~= 4 or not U.Name(f[4]) or not U.IsGateway() then return false end
    local knownList, since = U.Unpack(f[3], HISTORY_LIMIT), tonumber(f[2])
    if not knownList or not since then return false end
    since = math.max(U.stamp() - HISTORY_FOR, math.min(since, U.stamp()))
    local key = dist == "GUILD" and "guild" or target
    if U.clock() - (historyReplyAt[key] or -100) < 10 then return true end
    local known, jobs, bytes, candidates, sentIDs = {}, {}, 0, {}, {}
    for _, id in ipairs(knownList) do if #id > 240 then return false end; known[id] = true end
    for _, entry in ipairs(Recent()) do
        if entry.id and not known[entry.id] and entry.status == "delivered" and (entry.time or 0) >= since then candidates[#candidates + 1] = entry end
    end
    local count = 0
    for _, entry in ipairs(candidates) do
        local fields = RecordFields(entry)
        local size = #U.Pack(fields) + 40
        if count >= 20 or bytes + size > 12000 then break end
        jobs[#jobs + 1] = { kind = "HREC", fields = fields, dist = dist, target = target,
            priority = false, logged = true, requiresGateway = true, expiresAt = U.clock() + OUTBOX_FOR }
        sentIDs[#sentIDs + 1] = entry.id
        bytes, count = bytes + size, count + 1
    end
    jobs[#jobs + 1] = { kind = "HEND", fields = { U.guild, count < #candidates and "1" or "0", U.Pack(sentIDs), f[4] }, dist = dist, target = target,
        priority = false, requiresGateway = true, expiresAt = U.clock() + OUTBOX_FOR }
    if not U.QueueBatch(jobs) then return false end
    historyReplyAt[key] = U.clock()
    return true
end
HistoryTick = function(now)
    if not U.guild or not U.own[U.me] then return end
    if historyGuildDue and now >= historyGuildDue and now - historyGuildAt >= 10 then
        local f = { U.guild, U.stamp() - HISTORY_FOR, KnownIDs(), U.me }
        local queued
        if U.IsGateway() then queued = true
        else queued = U.Queue("HREQ", f, "GUILD", nil, true, false, nil, false, now + OUTBOX_FOR) end
        if queued then
            historyGuildAt = now
            if U.IsGateway() then historyGuildDue = nil else historyGuildDue = now + 15 end
        end
    end
    if historyRemoteDue and now >= historyRemoteDue and now - historyRemoteAt >= 10 and U.IsGateway() and U.Connected() then
        if U.Queue("HREQ", { U.guild, U.stamp() - HISTORY_FOR, KnownIDs(), U.me }, "WHISPER", U.remote.name, true, false, nil, true, now + OUTBOX_FOR) then
            historyRemoteAt, historyRemoteDue = now, now + 15
        end
    end
end
local function HistoryEnd(f, remote)
    if #f ~= 4 or U.Name(f[4]) ~= U.me or (f[2] ~= "0" and f[2] ~= "1") then return false end
    local ids = U.Unpack(f[3], 20)
    if not ids then return false end
    local missing = f[2] == "1"
    for _, id in ipairs(ids) do if not chatSeen[id] then missing = true end end
    if remote then historyRemoteDue = missing and U.clock() + 2 or nil
    else historyGuildDue = missing and U.clock() + 2 or nil end
    return true
end
function U.RequestFullRoster(guild, source, reason)
    if guild ~= U.OtherGuild() or not U.guild then return false end
    local now = U.clock()
    if now - (syncRequests[guild] or -100) < 10 then return false end
    local queued
    if U.IsGateway() and U.Connected() then
        queued = U.Queue("ASK", { U.guild }, "WHISPER", U.remote.name, true, false, nil, true)
    elseif not U.IsGateway() then queued = U.Queue("SYNC", { guild }, "GUILD", nil, true) end
    if queued then syncRequests[guild] = now end
    return queued == true
end
function U.Emit(kind, fields, logged)
    if not U.guild then return false end
    local chat = kind == "CHAT" or kind == "NATIVE"
    local jobs = { { kind = kind, fields = fields, dist = "GUILD", priority = true, logged = logged,
        expiresAt = chat and U.clock() + OUTBOX_FOR or nil, requiresGateway = kind == "NATIVE" } }
    if not chat and U.IsGateway() and U.Connected() then
        jobs[#jobs + 1] = { kind = kind, fields = fields, dist = "WHISPER", target = U.remote.name, priority = true, logged = logged, requiresGateway = true }
    end
    if not U.QueueBatch(jobs) then return false end
    U.HandleOwn(kind, fields, U.me, true)
    return true
end
function U.SendChat(text)
    if not U.guild then U.Print("Персонаж не состоит в гильдии союза.") return false end
    if not U.own[U.me] then U.RequestRoster(); U.Print("Состав гильдии ещё загружается. Повторите через несколько секунд.") return false end
    if not U.Text(text, 1200) then U.Print("Сообщение слишком длинное: максимум 1200 байт.") return false end
    text = U.Trim(text):gsub("[\r\n]", " ")
    if text == "" then return false end
    if U.clock() - lastChat < 1.5 then U.Print("Подождите полторы секунды между сообщениями.") return false end
    if U.ChatLocked() then U.Print("Forever временно ограничил обмен сообщениями. Повторите после снятия ограничения.") return false end
    if not U.Emit("CHAT", { U.guild, U.me, text, StableID(), U.stamp() }, true) then U.Print("Очередь сообщений заполнена. Сообщение не отправлено; повторите позже.") return false end
    lastChat = U.clock()
    return true
end
function U.HandleOwn(kind, f, sender, mine)
    if kind == "ADDONS" then
        if U.PresenceMessage then U.PresenceMessage(kind, f, sender, false) end
        return false
    end
    if kind == "CHAT" or kind == "NATIVE" then
        if not ValidateRecord(f, U.guild) then return false end
        if kind == "CHAT" and U.Name(f[2]) ~= sender then return false end
        if kind == "NATIVE" and (sender ~= U.GatewayName() or not U.own[U.Name(f[2])]) then return false end
        local forwarding = kind ~= "NATIVE" or U.db.bridgeGuildChat
        ShowRecord(f, kind == "NATIVE", forwarding and "pending" or "local-only", false, kind == "NATIVE")
        if U.IsGateway() then
            if forwarding then QueueCross(f) else Status(f[4], "local-only", true) end
        end
        return true
    elseif kind == "STATE" then
        if sender == U.GatewayName() and #f == 2 and chatSeen[f[1]] and (f[2] == "delivered" or f[2] == "local-only") then Status(f[1], f[2], false) end
        return false
    elseif kind == "HREQ" then
        if tonumber(f[1]) == U.guild and U.Name(f[4]) == sender and U.IsGateway() then SendHistory(f, "GUILD") end
        return false
    elseif kind == "HREC" then
        local guild = tonumber(f[1])
        if sender == U.GatewayName() and U.GUILDS[guild] and ValidateRecord(f, guild) then ShowRecord(f, guild == U.guild, "delivered", true) end
        return false
    elseif kind == "HEND" then
        if sender == U.GatewayName() and tonumber(f[1]) == U.guild then HistoryEnd(f, false) end
        return false
    elseif kind == "SYNC" then
        if U.IsGateway() and #f == 1 then U.RequestFullRoster(tonumber(f[1]), nil, "guild request") end
        return false
    end
    if U.TransferMessage(kind, f, sender, false) then return true end
    return U.ExtensionMessage and U.ExtensionMessage(kind, f, sender, false) == true or false
end
local function ActiveRemote()
    if not U.guild or not U.Connected() then return nil end
    return U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
end
local function KnownAuthor(name, guild)
    if not U.RosterFresh(guild) then return false end
    local cache = U.db.rosters[guild]
    local rows = guild == U.guild and U.own or cache and cache.rows
    return rows ~= nil and rows[name] ~= nil
end
function U.HandleRemote(kind, f, source, direct, context)
    -- A guildless transfer participant is authenticated by the accepted ticket,
    -- never promoted to a general foreign relay. Wrapped packets also bind the
    -- server-stamped local gateway passed by Handle below.
    if kind == "READY" then return U.TransferMessage(kind, f, source, true, context) end
    local guild = U.TrustedPeer(source)
    if not guild then return false end
    if kind == "ADDONS" then return U.PresenceMessage and U.PresenceMessage(kind, f, source, true) == true or false end
    if kind == "ROSTER" then
        if tonumber(f[1]) ~= guild then return false end
        return U.TakeRoster(f, source)
    elseif kind == "DELTA" then
        if tonumber(f[1]) ~= guild or not U.TakeRosterDelta then return false end
        return U.TakeRosterDelta(f, source)
    elseif kind == "CHAT" or kind == "HREC" then
        if source ~= ActiveRemote() then return false end
        local recordGuild = guild
        if kind == "HREC" then
            local expected = U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
            if not U.Connected() or expected ~= source then return false end
            recordGuild = tonumber(f[1])
            if not U.GUILDS[recordGuild] or not ValidateRecord(f, recordGuild) then return false end
            if recordGuild == U.guild then
                local existing = U.chatByID and U.chatByID[f[4]]
                if existing and (existing.guild ~= recordGuild or existing.name ~= U.Name(f[2]) or existing.text ~= f[3]) then return false end
                -- A forgotten body cannot attest a changed row. Let guildmates
                -- with a retained matching body validate the unchanged replay.
                if not existing and U.chatSeen and U.chatSeen[f[4]] then return true end
            end
        end
        if not ValidateRecord(f, recordGuild) then return false end
        if not KnownAuthor(U.Name(f[2]), recordGuild) then return false end
        if direct and kind == "CHAT" then
            if not U.IsGateway() then return false end
            local expires = U.clock() + OUTBOX_FOR
            -- Reserve the guild broadcast and its receipt together. A full
            -- queue must leave the sender's retry state pending.
            if not U.QueueBatch({
                { kind = "REMOTE", fields = { kind, U.Pack(f), source }, dist = "GUILD", priority = true,
                    logged = true, requiresGateway = true, expiresAt = expires },
                { kind = "ACK", fields = { guild, f[4] }, dist = "WHISPER", target = source, priority = true,
                    requiresGateway = true, expiresAt = expires },
            }) then return false end
        end
        ShowRecord(f, kind == "HREC" and recordGuild == U.guild, "delivered", kind == "HREC")
        return true
    end
    if U.TransferMessage(kind, f, source, true, context) then return true end
    return U.ExtensionMessage and U.ExtensionMessage(kind, f, source, true) == true or false
end
function U.Handle(kind, f, dist, sender, id)
    if kind == "LINK" and dist == "WHISPER" then TakeLink(f, sender); return end
    if dist == "GUILD" then
        if not U.guild or not U.own[sender] then return end
        if kind == "HELLO" then
            if (#f ~= 4 and #f ~= 6 and #f ~= 7) or tonumber(f[1]) ~= U.guild then return end
            if #f == 7 and f[7] ~= "0" and f[7] ~= "1" then return end
            local fresh = not U.peers[sender]
            local remote, leader = U.Name(f[4]), #f >= 6 and U.Name(f[5]) or sender
            local since = #f >= 6 and tonumber(f[6]) or 0
            if not since or since < 0 or since > U.stamp() + 60 then since = 0 end
            -- A native officer can endorse the endpoint in this very HELLO.
            -- Apply that endorsement before checking the advertised connection.
            local contacts = U.Unpack(f[3], 3)
            if contacts then for _, name in ipairs(contacts) do
                if U.IsTrustOfficer(sender) then U.ApproveContact(name, U.OtherGuild())
                else U.AddContact(name, U.OtherGuild()) end
            end end
            if not U.CanRelay(sender) or not remote or U.TrustedPeer(remote) ~= U.OtherGuild() then remote = nil end
            U.peers[sender] = { at = U.clock(), guild = U.guild, remote = remote, leader = leader, since = since,
                pairReady = #f == 7 and f[7] == "1" }
            if U.ElectionChanged then U.ElectionChanged(sender) end
            if U.PresenceHello then U.PresenceHello(sender, f[2]) end
            local gateway = U.GatewayName()
            if sender == gateway then
                if remote then
                    U.AddContact(remote, U.OtherGuild())
                    U.linkState = { name = remote, gateway = sender, at = U.clock() }
                elseif U.linkState and U.linkState.gateway == sender then U.linkState = nil end
            end
            if U.linkState and U.linkState.gateway ~= gateway then U.linkState = nil end
            -- Returning clients may retain a proposed ticket after missing its
            -- consent/READY broadcasts. Resync only through the current gateway.
            if U.TransferSyncFor then U.TransferSyncFor(sender) end
            if sender == gateway and U.TransferSyncRequest then U.TransferSyncRequest() end
            if U.IsGateway() and U.TransferSyncRequest then U.TransferSyncRequest(false, sender) end
            if fresh and U.IsGateway() then
                U.SayHello()
                if U.ExtensionSync then U.ExtensionSync("guild") end
                if U.remote and U.clock() - lastAsk > 10 then
                    lastAsk = U.clock()
                    U.Queue("ASK", { U.guild }, "WHISPER", U.remote.name, true, false, nil, true)
                    SendPing(U.remote.name)
                end
            end
        elseif kind == "CONTACT" then
            if #f == 2 and tonumber(f[2]) == U.OtherGuild() and U.IsTrustOfficer(sender) then U.ApproveContact(f[1], f[2]); lastPing = -100 end
        elseif kind == "TSYNC" or kind == "TSTATE" then
            -- Local state recovery never crosses the inter-guild relay.
            U.TransferMessage(kind, f, sender, false)
        elseif kind == "REMOTE" then
            if #f ~= 3 or sender ~= U.GatewayName() then return end
            local fields = U.Unpack(f[2])
            if fields then U.HandleRemote(f[1], fields, U.Name(f[3]), false, { gateway = sender }) end
        elseif U.HandleOwn(kind, f, sender) and kind ~= "CHAT" and kind ~= "NATIVE" and U.IsGateway() and U.Connected() then
            U.Queue(kind, f, "WHISPER", U.remote.name, true, IsTextKind(kind), nil, true)
        end
        return
    end
    if kind == "READY" and U.TrustedTransferPeer(sender) then
        if U.IsGateway() and U.TransferMessage(kind, f, sender, true) then
            U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, true, false, nil, true)
        end
        return
    end
    local guild = U.TrustedPeer(sender)
    if not guild then return end
    if kind == "PING" then
        if not U.CanRelay() then return end
        if (#f ~= 2 and #f ~= 3) or tonumber(f[1]) ~= guild then return end
        U.AddContact(sender, guild)
        U.LearnCandidates(f[2], guild)
        U.Queue("PONG", { U.guild, U.GatewayName() or U.me, U.CandidateNames() }, "WHISPER", sender, true)
        local senderGateway = #f == 3 and U.Name(f[3]) or sender
        if senderGateway == sender and U.IsGateway() then U.SetRemote(sender) end
    elseif kind == "PONG" then
        if not U.CanRelay() then return end
        if #f ~= 3 or tonumber(f[1]) ~= guild or not U.Name(f[2]) then return end
        local probe = U.probes[sender]
        if not probe or U.clock() > probe.untilAt then return end
        U.probes[sender] = nil
        U.AddContact(sender, guild, true)
        U.LearnCandidates(f[3], guild)
        if f[2] ~= sender then
            if U.AddContact(f[2], guild, true) then SendPing(f[2]) end
        elseif U.IsGateway() then U.SetRemote(sender) end
    elseif kind == "ASK" then
        if U.IsGateway() and U.clock() - (U.lastSnapshot or -100) > 10 then U.snapshotDue = 0 end
    elseif kind == "ACK" then
        if U.IsGateway() then AcceptAck(f) end
    elseif kind == "HREQ" then
        if U.IsGateway() and tonumber(f[1]) == guild and U.Name(f[4]) == sender then SendHistory(f, "WHISPER", sender) end
    elseif kind == "HEND" then
        if U.IsGateway() and tonumber(f[1]) == guild then HistoryEnd(f, true) end
    elseif kind == "READY" then
        if U.IsGateway() and U.TransferMessage(kind, f, sender, true) then
            U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, true, false, nil, true)
        end
    elseif U.IsGateway() then
        local key = sender .. ":" .. id
        if remoteSeen[key] then return end
        if U.HandleRemote(kind, f, sender, true) then
            local priority = kind ~= "ROSTER" and kind ~= "DELTA" and kind ~= "HREC" and kind ~= "ADDONS"
            -- Direct CHAT already committed its REMOTE+ACK atomically above.
            local queued = kind == "CHAT" or U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, priority, IsTextKind(kind), nil, true,
                kind == "HREC" and U.clock() + OUTBOX_FOR or nil)
            if queued then
                remoteSeen[key] = U.clock()
                if U.TransferRelayQueued then U.TransferRelayQueued(kind, f, sender) end
            end
        end
    end
end
function U.NetworkTick()
    local now = U.clock()
    LinkTick(now)
    BufferTick(now)
    if now - lastClean > 15 then
        lastClean = now; U.ProtocolClean()
        for k, t in pairs(remoteSeen) do if now - t > 180 then remoteSeen[k] = nil end end
        for k, t in pairs(lastLinkReply) do if now - t > 60 then lastLinkReply[k] = nil end end
        for k, p in pairs(U.probes) do if now > p.untilAt then U.probes[k] = nil end end
        for id, row in pairs(chatSeen) do if now - row.at > HISTORY_FOR then chatSeen[id] = nil end end
    end
    if not U.guild then return end
    if now - lastHello > 20 then U.SayHello() end
    if U.remote and now - U.remote.at > PEER_FOR then
        U.remote, U.gatewaySince = nil, nil
        if U.ElectionChanged then U.ElectionChanged(U.me) end
        if U.linkState and U.linkState.gateway == U.me then U.linkState = nil end
    end
    local gateway = U.GatewayName()
    if U.linkState and U.linkState.gateway ~= gateway then U.linkState = nil end
    if gateway ~= lastGateway then
        lastGateway = gateway
        if U.TransferSyncRequest then U.TransferSyncRequest(true) end
        if gateway == U.me then
            -- A new gateway starts a fair round; known-addon candidates
            -- win the initial unprobed tie instead of inheriting old probes.
            U.pings = {}
            for _, entry in ipairs(Recent()) do
                if entry.guild == U.guild and entry.id and entry.status == "pending" and U.stamp() - (entry.time or 0) < OUTBOX_FOR then QueueCross(RecordFields(entry)) end
            end
        end
    end
    local connected = U.Connected()
    if connected then
        everConnected, disconnectedAt, outageNotified = true, nil, false
        if not wasConnected then RequestHistory(false); if U.IsGateway() then RequestHistory(true) end end
    elseif everConnected then
        disconnectedAt = disconnectedAt or now
        if now - disconnectedAt >= 60 and not outageNotified then
            outageNotified = true
            U.Print("Связь со второй гильдией временно недоступна. Аддон восстановит её автоматически.")
        end
    end
    wasConnected = connected and true or false
    HistoryTick(now)
    if U.PresenceTick then U.PresenceTick() end
    if gateway ~= U.me then U.remote, U.gatewaySince = nil, nil; return end
    if now - lastPing < 15 then return end
    lastPing = now
    if U.remote then SendPing(U.remote.name); return end
    local list, candidates = {}, {}
    for name, c in pairs(U.db.contacts) do
        -- Old caches get one migration probe per login; new candidates are confirmed addon users.
        local eligible = c.approved == true and (c.addon == true or (c.addon == nil and not legacyTried[name]))
        if c.guild == U.OtherGuild() and not U.own[name] and eligible then candidates[name] = true end
    end
    local roster = U.db.rosters[U.OtherGuild()]
    if roster and roster.verified then
        for name, row in pairs(roster.rows) do if U.RowCanRelay(row) and not U.own[name] then candidates[name] = true end end
    end
    for name in pairs(candidates) do
        if now - (U.pings[name] or -math.huge) > 90 then list[#list + 1] = name end
    end
    local presence = U.db.addonPresence and U.db.addonPresence[U.OtherGuild()] or {}
    local function KnownAddon(name)
        local info = presence[name]
        local version = type(info) == "table" and info.version
        return U.Text(version, 40) and version ~= "" and version:match("^[A-Za-z0-9%.%-]+$") ~= nil or false
    end
    table.sort(list, function(a, b)
        local pa, pb = U.pings[a] or -math.huge, U.pings[b] or -math.huge
        if pa ~= pb then return pa < pb end
        local ka, kb = KnownAddon(a), KnownAddon(b)
        if ka ~= kb then return ka end
        local ca, cb = U.db.contacts[a] or {}, U.db.contacts[b] or {}
        if (ca.at or 0) ~= (cb.at or 0) then return (ca.at or 0) > (cb.at or 0) end
        return a < b
    end)
    while #list > 1500 do table.remove(list) end
    for i = 1, math.min(3, #list) do
        local name = list[i]
        local contact = U.db.contacts[name]
        if SendPing(name) and contact and contact.addon == nil then legacyTried[name] = true end
    end
end
U.On("CHAT_MSG_GUILD", function(text, sender)
    if not U.guild then return end
    if not U.Text(text, 1200) or not U.Public(sender) then
        if U.IsGateway() and U.clock() - nativeHint > 120 then nativeHint = U.clock(); U.Print("Forever скрыл содержимое /г от аддонов. Для общего чата используйте /czu.") end
        return
    end
    sender = U.Name(sender)
    if not sender or not U.own[sender] then return end
    -- Local viewing does not require another installed client or relay rights.
    -- ID-less observations cannot be exported by the history/catchup protocol.
    U.Chat(U.guild, sender, text, true, { at = U.stamp(), status = "local-only", observed = true })
    if not U.IsGateway() or U.clock() < nativeReadyAt then return end
    U.Emit("NATIVE", { U.guild, sender, text, StableID(), U.stamp() }, true)
end)
