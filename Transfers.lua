local _, U = ...
local lastReady, lastResend = -100, -100
local acceptRetry, receiptRetry, declineRetry = {}, {}, {}
local RETRY_FOR, CONFIRM_FOR = 5, 180
local syncRequest, syncReplies, syncReplyAt, syncProgress, syncPushState = nil, {}, {}, {}, {}
local gatewayRecovery
local syncWindow, syncCount, syncBytes = -100, 0, 0
local SYNC_REPLY_FOR, SYNC_REPLY_LIMIT, SYNC_REPLY_BYTES = 15, 8, 4096
local RECOVERY_UNKNOWN_LIMIT = 8
function U.Tickets()
    U.db.tickets = U.db.tickets or {}
    return U.db.tickets
end
local function FreshTicket(t)
    return type(t) == "table" and type(t.created) == "number" and U.stamp() - t.created < 1800 and t.created <= U.stamp() + 60
end
local function NewerTicket(a, b)
    if a.created ~= b.created then return a.created > b.created end
    local ap, an = tostring(a.id):match("^(%d+)%.(%d+)$")
    local bp, bn = tostring(b.id):match("^(%d+)%.(%d+)$")
    if ap and bp then
        if tonumber(ap) ~= tonumber(bp) then return tonumber(ap) > tonumber(bp) end
        return tonumber(an) > tonumber(bn)
    end
    return tostring(a.id) > tostring(b.id)
end
local function SameRoute(a, b)
    return a.member == b.member and a.source == b.source and a.dest == b.dest
end
local function CurrentTicket(t)
    if not FreshTicket(t) or t.state == "replaced" then return false end
    for _, other in pairs(U.Tickets()) do
        if other ~= t and FreshTicket(other) and SameRoute(other, t) and NewerTicket(other, t) then return false end
    end
    return true
end
local function ValidTicket(t)
    return CurrentTicket(t) and t.state ~= "declined" and t.state ~= "done"
end
local function ValidNonce(nonce)
    return U.Text(nonce, 40) and nonce ~= "" and nonce:match("^[%d%.]+$") ~= nil
end
local function OwnGateway(context)
    local gateway = U.GatewayName()
    if not gateway or not U.own[gateway] or not U.CanRelay(gateway) then return false end
    if context then return type(context) == "table" and context.gateway == gateway end
    return U.IsGateway()
end
local function DestinationReceiptPeer(t, sender, context)
    if U.guild ~= t.source or not U.Connected() or not OwnGateway(context) or U.TrustedPeer(sender) ~= t.dest then return false end
    local gateway = U.GatewayName()
    local peer = gateway == U.me and U.remote and U.remote.name
        or U.linkState and U.linkState.gateway == gateway and U.linkState.name
    return peer == sender
end
local function ConsentFields(t)
    local fields = { t.source, t.id, t.member, t.dest }
    if t.acceptNonce then fields[5] = t.acceptNonce end
    return fields
end
function U.TransferConfirmed(t)
    return ValidTicket(t) and t.state == "accepted" and ValidNonce(t.acceptNonce) and t.confirmedNonce == t.acceptNonce
end
function U.TransferPeer(name)
    for _, t in pairs(U.Tickets()) do
        if ValidTicket(t) and t.member == name and t.dest == U.guild
            and (t.state == "accepted" or t.state == "ready") then return t.source end
    end
end
local function FreshRemoteRoster(guild)
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    if guild == U.guild or not cache or type(cache.at) ~= "number" or U.stamp() - cache.at > 600 or cache.at > U.stamp() + 60 then return nil end
    return cache.rows
end
local function LiveAddonMember(name)
    local peer = U.peers[name]
    return name == U.me or (peer and U.clock() - peer.at <= 65) or false
end
local function RecoveryPeer(name)
    local row = U.own[name]
    return name ~= U.me and row and row.online and LiveAddonMember(name) and U.CanRelay(name) or false
end
-- Version is only a scheduling hint. Relay authority and nonce checks remain
-- mandatory even when a client advertises support for reverse recovery.
local function RecoveryCapability(name)
    local info = U.AddonInfo and U.AddonInfo(name, U.guild)
    if not info or not info.known or not info.live or not U.Text(info.version, 40) then return 0 end
    local major, minor, patch, suffix = info.version:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major or suffix ~= "" and not suffix:match("^[%.%-][A-Za-z0-9%.%-]+$") then return 0 end
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    if major > 0 or minor > 9 or minor == 9 and patch >= 3 then return 1 end
    return -1
end
local function RecoveryCandidate(recovery, name, capability)
    return capability >= 0 and not recovery.finished[name]
        and (capability > 0 or recovery.unknownPeers[name] or recovery.unknownUsed < RECOVERY_UNKNOWN_LIMIT)
end
local function ReplyAllowed(name, donor)
    -- A backup relay can attest only to the current gateway that requested it.
    if donor then return U.CanRelay() and name == U.GatewayName() and RecoveryPeer(name) end
    return OwnGateway() and U.own[name] and (U.CanRelay(name) or U.CanInvite(name)) or false
end
function U.CreateTransfer(name, guild)
    guild = guild or U.guild
    name = U.Name(name)
    if not name or not U.guild or not U.GUILDS[guild] then return false end
    if guild ~= U.guild then
        if not U.IsUnionLeader() then U.Print("Предложить переход из другой гильдии может руководитель союза.") return false end
        local remoteRows = FreshRemoteRoster(guild)
        local remoteRow = remoteRows and remoteRows[name]
        if not remoteRow or not remoteRow.online or remoteRow.rank == 0 or name == U.me then
            U.Print("Для перехода выбери участника второй гильдии в сети; её глава перейти не может. При необходимости обнови состав.") return false
        end
        if not U.Connected() then U.Print("Дождитесь связи со второй гильдией.") return false end
        return U.Emit("UTICKET", { guild, U.NewID(), name, U.guild, U.me, U.stamp(), U.guild }) == true
    end
    if not U.IsMaster() then U.Print("Предложить переход может глава текущей гильдии.") return false end
    local row = U.own[name]
    if not row or name == U.me or row.rank == 0 then U.Print("Выберите участника своей гильдии. Главу гильдии переводить нельзя.") return false end
    if not row.online or not U.peers[name] or U.clock() - U.peers[name].at > 65 then
        U.Print("Для согласованного перехода участник должен быть онлайн с установленным аддоном.") return false
    end
    if not U.Connected() then U.Print("Дождитесь связи со второй гильдией.") return false end
    return U.Emit("TICKET", { U.guild, U.NewID(), name, U.OtherGuild(), U.me, U.stamp() }) == true
end
local function FieldsMatch(t, f)
    return t and tonumber(f[1]) == t.source and f[2] == t.id and f[3] == t.member and tonumber(f[4]) == t.dest
end
local function CancelState(t)
    if U.CancelQueued then U.CancelQueued("transfer-state:" .. t.id) end
end
-- A state reply is a local gateway attestation of an already received consent.
-- It never supplies the foreign TACK proof that permits the source to leave.
local function Syncable(t)
    return ValidTicket(t) and t.dest == U.guild and U.GUILDS[t.source]
        and t.dest == (t.source == 1 and 2 or 1)
        and (t.state == "accepted" or t.state == "ready")
        and ValidNonce(t.acceptNonce) and t.receiptReady == t.acceptNonce
        and U.Name(t.member) == t.member and U.Name(t.master) == t.master
        and U.Text(t.id, 40) and t.id ~= ""
        and ((t.authorityGuild or t.source) == t.source
            or (t.authorityGuild == t.dest and U.IsUnionLeader(t.master, t.dest)))
end
local function StateProof(t, state)
    local fields = U.Pack({ t.source, t.id, t.member, t.dest, t.master, t.created,
        t.authorityGuild or t.source, t.acceptNonce or "", state, t.receiptReady or "" })
    local hash = 5381
    for i = 1, #fields do hash = (hash * 33 + fields:byte(i)) % 4294967291 end
    return tostring(hash)
end
function U.TransferSyncRequest(force, peer)
    if not U.db or not U.guild or not U.me or not (U.CanInvite() or U.CanRelay()) then return false end
    local gateway, now = U.GatewayName(), U.clock()
    if not gateway or not U.own[gateway] or not U.CanRelay(gateway) then return false end
    if gateway == U.me then
        syncRequest = nil
        if not OwnGateway() then return false end
        if not force and gatewayRecovery and gatewayRecovery.guild == U.guild then
            if peer and RecoveryPeer(peer) then
                local helloAt, previous = U.peers[peer].at, gatewayRecovery.seen[peer]
                local capability = RecoveryCapability(peer)
                local upgraded = capability > 0 and not gatewayRecovery.supported[peer]
                if capability > 0 then gatewayRecovery.supported[peer] = true end
                gatewayRecovery.seen[peer] = helloAt
                if capability >= 0 and (not previous or helloAt - previous > 65 or upgraded) then
                    gatewayRecovery.peers[peer] = nil
                    gatewayRecovery.finished[peer] = nil
                    if gatewayRecovery.active == peer then gatewayRecovery.active = nil end
                    gatewayRecovery.untilAt = now + CONFIRM_FOR
                    gatewayRecovery.dormant = nil
                end
            end
            return true
        end
        gatewayRecovery = { guild = U.guild, untilAt = now + CONFIRM_FOR, nextAt = now, peers = {}, seen = {},
            finished = {}, supported = {}, unknownPeers = {}, unknownUsed = 0 }
        for name, info in pairs(U.peers) do if RecoveryPeer(name) then
            gatewayRecovery.seen[name] = info.at
            if RecoveryCapability(name) > 0 then gatewayRecovery.supported[name] = true end
        end end
        return true
    end
    gatewayRecovery = nil
    if not force and syncRequest and syncRequest.guild == U.guild and syncRequest.gateway == gateway then return true end
    syncRequest = { guild = U.guild, gateway = gateway, nonce = U.NewID(), untilAt = now + CONFIRM_FOR, nextAt = now }
    return true
end
local function SyncCandidates()
    local candidates, signature = {}, {}
    for _, t in pairs(U.Tickets()) do if Syncable(t) then candidates[#candidates + 1] = t end end
    table.sort(candidates, function(a, b) return a.id < b.id end)
    for _, t in ipairs(candidates) do signature[#signature + 1] = U.Pack({ t.id, t.acceptNonce, t.state }) end
    return candidates, table.concat(signature)
end
function U.TransferSyncFor(name, nonce, ack)
    name = U.Name(name)
    if not U.db or not U.guild or not name or name == U.me or not U.own[name]
        or not (U.CanRelay(name) or U.CanInvite(name))
        or nonce ~= nil and not ValidNonce(nonce) or ack ~= nil and not ValidNonce(ack) then return false end
    local donor = not OwnGateway()
    if not ReplyAllowed(name, donor) or donor and nonce == nil then return false end
    -- Both requests and HELLO pushes are limited to invitation-capable clients
    -- and backup relays. Ordinary members cannot consume the reply budget.
    local _, signature = SyncCandidates()
    if nonce == nil and (signature == "" or syncPushState[name] == signature) then return false end
    local now, count = U.clock(), 0
    local progress = syncProgress[name]
    if not progress or progress.nonce ~= (nonce or "") or progress.signature ~= signature then
        progress = { nonce = nonce or "", cursor = "", signature = signature, at = now }
        syncProgress[name] = progress
    elseif progress.batch and ack == progress.batch.token then
        progress.cursor, progress.batch = progress.batch.cursor, nil
    end
    for peer, reply in pairs(syncReplies) do
        if reply.untilAt < now or not U.own[peer] then syncReplies[peer] = nil else count = count + 1 end
    end
    local reply = syncReplies[name]
    if not reply then
        if count >= 32 then return false end
        reply = { cursor = progress.cursor,
            nextAt = math.max(now, (syncReplyAt[name] or -100) + RETRY_FOR) }
        syncReplies[name] = reply
    end
    if reply.nonce and reply.nonce ~= (nonce or "") then
        if nonce == nil then return true end
        reply.cursor = ""
    end
    reply.nonce, reply.signature, reply.untilAt, reply.donor = nonce or "", signature, now + SYNC_REPLY_FOR, donor
    reply.cursor = progress.cursor
    return true
end
local function RecoveryTick(now)
    local recovery = gatewayRecovery
    if not recovery then return end
    if recovery.guild ~= U.guild or not OwnGateway() then gatewayRecovery = nil; return end
    if now >= (recovery.cleanAt or 0) then
        for name in pairs(recovery.seen) do
            if not U.own[name] then
                recovery.seen[name], recovery.finished[name], recovery.peers[name], recovery.supported[name] = nil, nil, nil, nil
            end
        end
        recovery.cleanAt = now + SYNC_REPLY_FOR
    end
    if recovery.dormant then return end
    local active = recovery.active and recovery.peers[recovery.active]
    if active and (active.complete or not RecoveryPeer(recovery.active) or RecoveryCapability(recovery.active) < 0
        or now >= active.untilAt or now >= active.slotUntil) then
        recovery.active, active = nil, nil
    end
    -- END closes one donor only. Another relay can retain a later READY or an
    -- entirely different ticket; an empty first reply cannot close the round.
    if not active then
        local candidates, capabilities, count = {}, {}, 0
        for name, peer in pairs(recovery.peers) do
            if peer.complete or now >= peer.untilAt then
                recovery.finished[name], recovery.peers[name] = true, nil
            elseif not RecoveryPeer(name) then recovery.peers[name] = nil
            else count = count + 1 end
        end
        for name in pairs(U.peers) do
            local peer = recovery.peers[name]
            if RecoveryPeer(name) then
                local capability = RecoveryCapability(name)
                if RecoveryCandidate(recovery, name, capability) and (peer and not peer.complete or not peer and count < 32) then
                    capabilities[name], candidates[#candidates + 1] = capability, name
                end
            end
        end
        table.sort(candidates, function(a, b)
            if capabilities[a] ~= capabilities[b] then return capabilities[a] > capabilities[b] end
            local aa = recovery.peers[a] and recovery.peers[a].lastTry or -100
            local ba = recovery.peers[b] and recovery.peers[b].lastTry or -100
            if aa ~= ba then return aa < ba end
            return a < b
        end)
        local name = candidates[1]
        if not name then recovery.dormant = true; return end
        active = recovery.peers[name]
        if not active then
            -- Every newly served donor gets a fixed full window. Later donors
            -- can finish the finite pass without reopening timed-out peers.
            active = { nonce = U.NewID(), nextAt = now, untilAt = now + CONFIRM_FOR }
            recovery.untilAt = math.max(recovery.untilAt, active.untilAt)
            if capabilities[name] == 0 and not recovery.unknownPeers[name] then
                recovery.unknownPeers[name], recovery.unknownUsed = true, recovery.unknownUsed + 1
            end
        end
        active.lastTry, active.slotUntil = now, now + SYNC_REPLY_FOR
        recovery.peers[name], recovery.active = active, name
        recovery.seen[name] = U.peers[name].at
    end
    if now >= recovery.nextAt and now >= active.nextAt then
        local fields = { U.guild, recovery.active, U.me, active.nonce }
        if active.ack then fields[5] = active.ack end
        U.Queue("TSYNC", fields, "GUILD", nil, false, false, nil, true, now + RETRY_FOR)
        active.nextAt, recovery.nextAt = now + RETRY_FOR, now + RETRY_FOR
    end
end
local function SyncTick(now)
    if syncRequest then
        if syncRequest.guild ~= U.guild or syncRequest.gateway ~= U.GatewayName() then
            syncRequest = nil
            U.TransferSyncRequest()
        elseif not syncRequest.complete and now <= syncRequest.untilAt and now >= syncRequest.nextAt then
            if U.own[U.me] and U.own[syncRequest.gateway] and U.CanRelay(syncRequest.gateway)
                and (U.CanInvite() or U.CanRelay()) then
                local fields = { U.guild, syncRequest.gateway, U.me, syncRequest.nonce }
                if syncRequest.ack then fields[5] = syncRequest.ack end
                U.Queue("TSYNC", fields, "GUILD", nil, false, false, nil, false, now + RETRY_FOR)
            end
            syncRequest.nextAt = now + RETRY_FOR
        end
    end
    RecoveryTick(now)
    if now - syncWindow >= 10 then syncWindow, syncCount, syncBytes = now, 0, 0 end
    local names = {}
    for name, reply in pairs(syncReplies) do
        if reply.untilAt < now or not ReplyAllowed(name, reply.donor) then syncReplies[name] = nil
        elseif now >= reply.nextAt then names[#names + 1] = name end
    end
    table.sort(names, function(a, b)
        local aa, ba = syncReplyAt[a] or -100, syncReplyAt[b] or -100
        if aa ~= ba then return aa < ba end
        return a < b
    end)
    for index, name in ipairs(names) do
        if syncCount >= 8 or syncBytes >= SYNC_REPLY_BYTES then
            for i = index, #names do
                local pending = syncReplies[names[i]]
                pending.nextAt = syncWindow + 10
                pending.untilAt = math.max(pending.untilAt, pending.nextAt + SYNC_REPLY_FOR)
            end
            break
        end
        local reply = syncReplies[name]
        local candidates, signature = SyncCandidates()
        local progress = syncProgress[name]
        if not progress or progress.nonce ~= reply.nonce or progress.signature ~= signature then
            progress = { nonce = reply.nonce, cursor = "", signature = signature, at = now }
            syncProgress[name], reply.cursor = progress, ""
        end
        local jobs, manifest, bytes, cursor = {}, {}, 0, reply.cursor
        for _, t in ipairs(candidates) do
            if t.id > reply.cursor then
                local fields = { U.guild, name, reply.nonce, t.source, t.id, t.member, t.dest,
                    t.master, t.created, t.authorityGuild or t.source, t.acceptNonce, t.state, t.receiptReady }
                local size = #U.Pack(fields) + 7
                if #jobs >= SYNC_REPLY_LIMIT or bytes + size > SYNC_REPLY_BYTES - 1280 then break end
                jobs[#jobs + 1] = { kind = "TSTATE", fields = fields, dist = "GUILD", priority = false,
                    requiresGateway = not reply.donor, expiresAt = now + RETRY_FOR, cancelKey = "transfer-state:" .. t.id }
                bytes, cursor = bytes + size, t.id
                manifest[#manifest + 1] = U.Pack({ t.id, t.acceptNonce, t.state, StateProof(t, t.state) })
            end
        end
        local more = #candidates > 0 and cursor < candidates[#candidates].id
        local token = progress.batch and progress.batch.token or U.NewID()
        local control = { U.guild, name, reply.nonce, more and "MORE" or "END", token, U.Pack(manifest) }
        jobs[#jobs + 1] = { kind = "TSTATE", fields = control,
            dist = "GUILD", priority = false, requiresGateway = not reply.donor, expiresAt = now + RETRY_FOR }
        bytes = bytes + #U.Pack(control) + 7
        if syncBytes + bytes > SYNC_REPLY_BYTES then
            reply.nextAt = syncWindow + 10
            reply.untilAt = math.max(reply.untilAt, reply.nextAt + SYNC_REPLY_FOR)
        elseif U.QueueBatch(jobs) then
            -- An explicit request replays this page until its manifest token is
            -- acknowledged. Queue reservation alone cannot advance its cursor.
            progress.batch = { token = token, cursor = more and cursor or "" }
            progress.at = now
            syncReplyAt[name], syncCount, syncBytes = now, syncCount + 1, syncBytes + bytes
            if reply.nonce == "" and more then
                progress.cursor, progress.batch, reply.cursor, reply.nextAt = cursor, nil, cursor, now + RETRY_FOR
            else
                syncPushState[name] = signature
                syncReplies[name] = nil
            end
        else reply.nextAt = now + 1 end
    end
    for name, at in pairs(syncReplyAt) do if now - at > CONFIRM_FOR then syncReplyAt[name] = nil end end
    for name, progress in pairs(syncProgress) do if now - progress.at > CONFIRM_FOR or not U.own[name] then syncProgress[name] = nil end end
    for name in pairs(syncPushState) do if not U.own[name] then syncPushState[name] = nil end end
end
local function TakeState(f, sender, remote)
    if remote or (#f ~= 13 and #f ~= 6) or tonumber(f[1]) ~= U.guild or f[2] ~= U.me or not U.own[sender]
        or not U.CanRelay(sender) then return false end
    local request
    if sender == U.GatewayName() then
        if f[3] ~= "" then
            if not ValidNonce(f[3]) or not syncRequest or syncRequest.guild ~= U.guild
                or syncRequest.gateway ~= sender or syncRequest.nonce ~= f[3] or U.clock() > syncRequest.untilAt then return false end
            request = syncRequest
        end
    else
        local recovery = gatewayRecovery
        request = recovery and recovery.peers[sender]
        if not OwnGateway() or not RecoveryPeer(sender) or not recovery or recovery.guild ~= U.guild
            or recovery.active ~= sender or not request or not ValidNonce(f[3]) or request.nonce ~= f[3]
            or U.clock() > recovery.untilAt or U.clock() >= request.untilAt or U.clock() >= request.slotUntil then return false end
    end
    if #f == 6 then
        if (f[4] ~= "END" and f[4] ~= "MORE") or not ValidNonce(f[5]) then return false end
        local manifest = U.Unpack(f[6], SYNC_REPLY_LIMIT)
        if not manifest then return false end
        for _, packed in ipairs(manifest) do
            local item = U.Unpack(packed, 4)
            if not item or #item ~= 4 or not U.Text(item[1], 40) or item[1] == "" or not ValidNonce(item[2])
                or (item[3] ~= "accepted" and item[3] ~= "ready") or not item[4]:match("^%d+$") then return false end
            local t = U.Tickets()[item[1]]
            if not t then return false end
            local terminal = t.state == "declined" or t.state == "replaced" or t.state == "done" or not CurrentTicket(t)
            if not terminal and (not Syncable(t) or t.acceptNonce ~= item[2]
                or t.state ~= item[3] and not (t.state == "ready" and item[3] == "accepted")
                or StateProof(t, item[3]) ~= item[4]) then return false end
        end
        if f[3] ~= "" then
            local progress = request.ack ~= f[5]
            request.ack = f[5]
            if f[4] == "END" then request.complete = true end
            if progress and gatewayRecovery and gatewayRecovery.peers[sender] == request then request.slotUntil = U.clock() + SYNC_REPLY_FOR end
        end
        return true
    end
    local source, dest, created, authority = tonumber(f[4]), tonumber(f[7]), tonumber(f[9]), tonumber(f[10])
    local member, master = U.Name(f[6]), U.Name(f[8])
    if not source or not U.GUILDS[source] or dest ~= U.guild or dest ~= (source == 1 and 2 or 1)
        or member ~= f[6] or not member or master ~= f[8] or not master
        or not U.Text(f[5], 40) or f[5] == "" or not created
        or not ValidNonce(f[11]) or f[13] ~= f[11] or (f[12] ~= "accepted" and f[12] ~= "ready")
        or (authority ~= source and (authority ~= dest or not U.IsUnionLeader(master, dest))) then return false end
    local incoming = { id = f[5], source = source, dest = dest, member = member, master = master,
        created = created, authorityGuild = authority, acceptNonce = f[11], receiptReady = f[13], state = f[12] }
    if not CurrentTicket(incoming) or U.own[member] then return false end
    local tickets, existing = U.Tickets(), U.Tickets()[incoming.id]
    if existing then
        if not ValidTicket(existing) or (existing.state ~= "proposed" and existing.state ~= "accepted" and existing.state ~= "ready")
            or existing.source ~= source or existing.dest ~= dest or existing.member ~= member or existing.master ~= master
            or existing.created ~= created or (existing.authorityGuild or existing.source) ~= authority
            or existing.acceptNonce and existing.acceptNonce ~= incoming.acceptNonce then return false end
        -- Receipt attestation repairs destination state, but cannot mint a TACK.
        existing.acceptNonce, existing.receiptReady, existing.receiptSynced = incoming.acceptNonce, incoming.receiptReady, true
        if existing.state ~= "ready" then existing.state = incoming.state end
    else
        for _, other in pairs(tickets) do
            if FreshTicket(other) and SameRoute(other, incoming) and NewerTicket(incoming, other) then
                CancelState(other)
                other.state, other.confirmedNonce, other.receiptReady, other.left = "replaced", nil, nil, nil
            end
        end
        incoming.receiptSynced = true
        tickets[incoming.id] = incoming
    end
    if U.Refresh then U.Refresh() end
    return true
end
function U.TransferMessage(kind, f, sender, remote, context)
    local tickets = U.Tickets()
    if kind == "TSYNC" then
        if remote or (#f ~= 4 and #f ~= 5) or tonumber(f[1]) ~= U.guild or f[2] ~= U.me or f[3] ~= sender
            or not U.own[sender] or not (U.CanRelay(sender) or U.CanInvite(sender)) or not ValidNonce(f[4]) then return false end
        return U.TransferSyncFor(sender, f[4], f[5])
    elseif kind == "TSTATE" then return TakeState(f, sender, remote)
    elseif kind == "TICKET" or kind == "UTICKET" then
        local union = kind == "UTICKET"
        if #f ~= (union and 7 or 6) then return false end
        local src, dest, member, master, created = tonumber(f[1]), tonumber(f[4]), U.Name(f[3]), U.Name(f[5]), tonumber(f[6])
        if not src or not dest or not U.GUILDS[src] or dest ~= (src == 1 and 2 or 1) or not member or not master then return false end
        if not U.Text(f[2], 40) or f[2] == "" or not created or U.stamp() - created > 1800 or created - U.stamp() > 60 then return false end
        local authority = union and tonumber(f[7]) or src
        if union then
            if authority ~= dest or not U.IsUnionLeader(master, authority) then return false end
            if remote then
                if src ~= U.guild or U.TrustedPeer(sender) ~= authority then return false end
                local row = U.own[member]
                if not row or not row.online or row.rank == 0 or not LiveAddonMember(member) then return false end
            else
                if authority ~= U.guild or sender ~= master then return false end
                local roster = FreshRemoteRoster(src)
                local row = roster and roster[member]
                if not row or not row.online or row.rank == 0 then return false end
            end
        elseif remote then
            if dest ~= U.guild or U.TrustedPeer(sender) ~= src then return false end
            local roster = U.db.rosters[src]
            if not roster or U.stamp() - roster.at > 600 or not roster.rows[master] or roster.rows[master].rank ~= 0 or not roster.rows[member] then return false end
        else
            if src ~= U.guild or sender ~= master or not U.own[master] or U.own[master].rank ~= 0 or not U.own[member] then return false end
        end
        local existing = tickets[f[2]]
        if existing then
            return existing.source == src and existing.dest == dest and existing.member == member and existing.master == master
                and existing.created == created and (existing.authorityGuild or existing.source) == authority
        end
        local incoming = { id = f[2], source = src, dest = dest, member = member, master = master, created = created, authorityGuild = authority, state = "proposed" }
        for _, other in pairs(tickets) do
            if FreshTicket(other) and SameRoute(other, incoming) then
                if NewerTicket(other, incoming) then incoming.state = "replaced"
                elseif NewerTicket(incoming, other) then
                    CancelState(other)
                    other.state, other.confirmedNonce, other.receiptReady, other.left = "replaced", nil, nil, nil
                end
            end
        end
        tickets[f[2]] = incoming
        if incoming.state == "replaced" then return true end
        if member == U.me then U.Notify("Глава предлагает перейти в «" .. U.GUILDS[dest] .. "». /cz → Переходы: согласиться или отказаться.")
        elseif remote and U.CanInvite() then U.Notify("Предложен переход: " .. U.SafeDisplay(member) .. ". /cz → Переходы.") end
        if U.Refresh then U.Refresh() end
        return true
    elseif kind == "ACCEPT" or kind == "DECLINE" then
        if kind == "DECLINE" and #f ~= 4 or kind == "ACCEPT" and #f ~= 4 and #f ~= 5 then return false end
        if #f == 5 and not ValidNonce(f[5]) then return false end
        local t = tickets[f[2]]
        if not FieldsMatch(t, f) or not CurrentTicket(t) or t.state == "done" then return false end
        if remote then
            if U.TrustedPeer(sender) ~= t.source or t.dest ~= U.guild then return false end
        elseif sender ~= t.member or U.guild ~= t.source or not U.own[sender] then return false end
        if kind == "DECLINE" then
            CancelState(t)
            t.state, t.confirmedNonce, t.receiptReady, t.left = "declined", nil, nil, nil
            t.declinedAt = t.declinedAt or U.stamp()
            if U.Refresh then U.Refresh() end
            return true
        end
        if t.state == "declined" or t.state == "accept_error" then return false end
        if t.acceptNonce and f[5] and t.acceptNonce ~= f[5] then return false end
        local changed = t.state == "proposed"
        t.acceptNonce = t.acceptNonce or f[5]
        if remote then
            if t.state ~= "ready" then t.state = "accepted" end
            -- Do not acknowledge until the destination guild relay is queued.
            if f[5] and context and OwnGateway(context) then t.receiptReady, t.receiptSynced = f[5], nil end
        elseif not U.TransferConfirmed(t) then
            t.state = "pending"
            t.acceptStarted = t.acceptStarted or U.stamp()
        end
        if not changed then if U.Refresh then U.Refresh() end; return true end
        if t.dest == U.guild and kind == "ACCEPT" and U.CanInvite() then U.Notify(U.SafeDisplay(t.member) .. " согласился на переход. Дождитесь выхода из старой гильдии.") end
        if U.Refresh then U.Refresh() end
        return true
    elseif kind == "TACK" then
        if #f ~= 5 or not ValidNonce(f[5]) then return false end
        local t = tickets[f[2]]
        if not FieldsMatch(t, f) or not ValidTicket(t) or not remote
            or (t.state ~= "pending" and t.state ~= "accepted") or t.acceptNonce ~= f[5]
            or not DestinationReceiptPeer(t, sender, context) then return false end
        if t.member == U.me and t.state == "pending" and t.acceptStarted and U.stamp() - t.acceptStarted >= CONFIRM_FOR then return false end
        local changed = t.state ~= "accepted" or t.confirmedNonce ~= f[5]
        local endpointChanged = t.contact ~= sender
        t.state, t.confirmedNonce, t.contact = "accepted", f[5], sender
        t.acceptError = nil
        if t.member == U.me and (changed or endpointChanged) then
            local cache, rows = U.db.rosters[t.dest], FreshRemoteRoster(t.dest)
            if cache and cache.verified and rows then
                t.readyTargets = {}
                for name, row in pairs(rows) do
                    if U.RowCanRelay(row) then t.readyTargets[name] = row.online == true end
                end
            end
        end
        if changed and t.member == U.me then U.Print("Принимающая гильдия подтвердила перевод. Теперь можно подготовить выход из гильдии.") end
        if U.Refresh then U.Refresh() end
        return true
    elseif kind == "READY" then
        if #f ~= 2 then return false end
        local t = tickets[f[1]]
        if not remote or not OwnGateway(context) or not ValidTicket(t) or t.dest ~= U.guild or f[2] ~= t.member or sender ~= t.member
            or (t.state ~= "accepted" and t.state ~= "ready") then return false end
        local changed = t.state ~= "ready"
        t.state = "ready"
        if changed and U.CanInvite() then U.Notify(U.SafeDisplay(t.member) .. " сообщает о выходе. Можно отправить приглашение: /cz → Переходы.") end
        if U.Refresh then U.Refresh() end
        return true
    end
    return false
end
-- Network calls this only after successfully reserving the destination GUILD
-- relay. A failed queue reservation must never authorize the member to leave.
function U.TransferRelayQueued(kind, f, source)
    if kind ~= "ACCEPT" or #f ~= 5 or not U.IsGateway() then return false end
    local t = U.Tickets()[f[2]]
    if not FieldsMatch(t, f) or not ValidTicket(t) or t.dest ~= U.guild
        or t.state ~= "accepted" or t.acceptNonce ~= f[5] or U.TrustedPeer(source) ~= t.source then return false end
    t.receiptReady, t.receiptSynced = f[5], nil
    return true
end
function U.AcceptTransfer(id, accept)
    local t = U.Tickets()[id]
    if not ValidTicket(t) or t.member ~= U.me or U.guild ~= t.source then return false end
    if accept then
        if t.state ~= "proposed" and t.state ~= "accept_error" then return false end
        local oldNonce, oldStarted, oldState, oldError = t.acceptNonce, t.acceptStarted, t.state, t.acceptError
        t.acceptNonce, t.acceptStarted, t.acceptError, t.state = t.acceptNonce or U.NewID(), U.stamp(), nil, "pending"
        if not U.Emit("ACCEPT", ConsentFields(t)) then
            t.acceptNonce, t.acceptStarted, t.state, t.acceptError = oldNonce, oldStarted, oldState, oldError
            U.Print("Согласие не отправлено: очередь заполнена. Повторите попытку.")
            return false
        end
        acceptRetry[t.id] = U.clock() + RETRY_FOR
        U.Print("Согласие отправлено. Ждём подтверждения принимающей гильдии; выход пока недоступен.")
    else
        if t.state ~= "proposed" and t.state ~= "pending" and t.state ~= "accept_error" then return false end
        if not U.Emit("DECLINE", { t.source, t.id, t.member, t.dest }) then
            U.Print("Отказ не отправлен: очередь заполнена. Повторите попытку.")
            return false
        end
    end
    if U.Refresh then U.Refresh() end
    return true
end
function U.LeaveForTransfer(id)
    local t = U.Tickets()[id]
    if not U.TransferConfirmed(t) or t.member ~= U.me or U.guild ~= t.source then return end
    if U.IsMaster() then U.Print("Глава гильдии сначала должен передать руководство.") return end
    -- Leave/Invite are protected on modern clients. Prepare the native command;
    -- only the player's own Enter key executes it through Blizzard's chat handler.
    if InCombatLockdown() then U.Print("Подготовьте выход после боя.") return end
    ChatFrame_OpenChat("/gquit")
    U.Print("Подготовлена команда выхода. Нажмите Enter, только когда офицер второй гильдии готов пригласить вас.")
end
function U.InviteTransfer(id)
    local t = U.Tickets()[id]
    if not ValidTicket(t) or t.dest ~= U.guild or t.state ~= "ready" or not U.CanInvite() then return end
    if InCombatLockdown() then U.Print("Пригласите участника после боя.") return end
    ChatFrame_OpenChat("/ginvite " .. t.member)
    U.Print("Нажмите Enter, чтобы отправить штатное приглашение. Его принятие подтвердит сам участник.")
end
function U.IdentityChanged(previous)
    if not U.db then return end
    for _, t in pairs(U.Tickets()) do
        if t.member == U.me and ValidTicket(t) then
            if U.guild == t.dest then t.state = "done"; U.Print("Переход завершён: «" .. U.GUILDS[t.dest] .. "».")
            elseif previous == t.source and not U.guild and U.TransferConfirmed(t) then
                t.left, t.readyStarted, t.readyError = true, U.stamp(), nil
                lastReady = -100
            end
        end
    end
end
function U.TransferTick()
    if not U.db then return end
    local tickets, now, stamp = U.Tickets(), U.clock(), U.stamp()
    for id, t in pairs(tickets) do
        if not FreshTicket(t) then
            tickets[id], acceptRetry[id], receiptRetry[id], declineRetry[id] = nil, nil, nil, nil
        elseif ValidTicket(t) and t.dest == U.guild and U.own[t.member] then
            CancelState(t)
            t.state, t.receiptReady = "done", nil
        elseif ValidTicket(t) and t.member == U.me and t.source == U.guild and t.state == "accepted" and not U.TransferConfirmed(t) then
            t.state, t.acceptError = "accept_error", true
            U.Print("Сохранённое согласие требует подтверждения принимающей гильдии. Повторите согласие после обновления аддона у участника и принимающего связного.")
            if U.Refresh then U.Refresh() end
        elseif ValidTicket(t) and t.member == U.me and t.source == U.guild and t.state == "pending" then
            t.acceptStarted = t.acceptStarted or stamp
            if stamp - t.acceptStarted >= CONFIRM_FOR then
                t.state, t.acceptError = "accept_error", true
                U.Print("Принимающая гильдия не подтвердила перевод за 3 минуты. Выход заблокирован. Проверьте связь, обновите аддон у участника и принимающего связного, затем повторите согласие или откажитесь.")
                if U.Refresh then U.Refresh() end
            elseif now >= (acceptRetry[id] or -100) then
                U.Emit("ACCEPT", ConsentFields(t))
                acceptRetry[id] = now + RETRY_FOR
            end
        elseif CurrentTicket(t) and t.state == "declined" and stamp - (t.declinedAt or stamp) < CONFIRM_FOR
            and t.member == U.me and t.source == U.guild and now >= (declineRetry[id] or -100) then
            U.Emit("DECLINE", { t.source, t.id, t.member, t.dest })
            declineRetry[id] = now + RETRY_FOR
        end
    end
    SyncTick(now)
    if U.guild and U.IsGateway() and U.Connected() and U.remote then
        for id, t in pairs(tickets) do
            if ValidTicket(t) and t.dest == U.guild and t.state == "accepted" and not t.receiptSynced and t.receiptReady == t.acceptNonce
                and ValidNonce(t.acceptNonce) and U.TrustedPeer(U.remote.name) == t.source
                and now >= (receiptRetry[id] or -100) then
                if U.Queue("TACK", ConsentFields(t), "WHISPER", U.remote.name, true, false, nil, true, now + RETRY_FOR) then
                    receiptRetry[id] = now + RETRY_FOR
                end
            elseif CurrentTicket(t) and t.source == U.guild and t.state == "declined"
                and stamp - (t.declinedAt or stamp) < CONFIRM_FOR and now >= (declineRetry[id] or -100) then
                if U.Queue("DECLINE", { t.source, t.id, t.member, t.dest }, "WHISPER", U.remote.name, true, false, nil, true, now + RETRY_FOR) then
                    declineRetry[id] = now + RETRY_FOR
                end
            end
        end
        if now - lastResend > 45 then
            lastResend = now
            for _, t in pairs(tickets) do
                local authority = t.authorityGuild or t.source
                if authority == t.dest and authority == U.guild and ValidTicket(t) and U.IsUnionLeader(t.master, authority) then
                    local roster = FreshRemoteRoster(t.source)
                    local row = roster and roster[t.member]
                    if row and row.online and row.rank ~= 0 then
                        U.Queue("UTICKET", { t.source, t.id, t.member, t.dest, t.master, t.created, authority }, "WHISPER", U.remote.name, true, false, nil, true)
                    end
                elseif authority == t.source and t.source == U.guild and ValidTicket(t) and U.own[t.member] and U.own[t.master] and U.own[t.master].rank == 0 then
                    U.Queue("TICKET", { t.source, t.id, t.member, t.dest, t.master, t.created }, "WHISPER", U.remote.name, true, false, nil, true)
                end
                if t.source == U.guild and ValidTicket(t) and U.own[t.member]
                    and (t.state == "pending" or t.state == "accepted") then
                    U.Queue("ACCEPT", ConsentFields(t), "WHISPER", U.remote.name, true, false, nil, true)
                end
            end
        end
    end
    if now - lastReady < 30 then return end
    lastReady = now
    for _, t in pairs(tickets) do
        if t.member == U.me and t.left and not U.guild and U.TransferConfirmed(t) then
            t.readyStarted = t.readyStarted or stamp
            if not t.readyError and stamp - t.readyStarted >= CONFIRM_FOR then
                t.readyError = true
                U.Print("Приглашение пока не получено. Сообщите офицеру принимающей гильдии: повторные уведомления о готовности продолжаются до истечения заявки.")
                if U.Refresh then U.Refresh() end
            end
            local list, known = {}, {}
            local function Add(name)
                name = U.Name(name)
                if name and not known[name] then list[#list + 1], known[name] = name, true end
            end
            -- This endpoint was authenticated by the matching TACK. Its trust
            -- is limited to this ticket and survives bounded contact eviction.
            Add(t.contact)
            local candidates, candidateSeen = {}, {}
            local function Candidate(name)
                name = U.Name(name)
                if name and not candidateSeen[name] then candidates[#candidates + 1], candidateSeen[name] = name, true end
            end
            for name, c in pairs(U.db.contacts) do
                if c.guild == t.dest and c.approved == true then Candidate(name) end
            end
            for name in pairs(t.readyTargets or {}) do Candidate(name) end
            table.sort(candidates, function(a, b)
                local pa, pb = t.readyTargets and t.readyTargets[a] == true, t.readyTargets and t.readyTargets[b] == true
                if pa ~= pb then return pa end
                return a < b
            end)
            -- Rotate backups so an offline prior gateway cannot starve the
            -- current gateway when the approved contact cache has many entries.
            local offset = t.readyOffset or 0
            for i = 1, math.min(3, #candidates) do Add(candidates[(offset + i - 1) % #candidates + 1]) end
            if #candidates > 0 then t.readyOffset = (offset + 3) % #candidates end
            for i = 1, #list do U.Queue("READY", { t.id, U.me }, "WHISPER", list[i], true, false, nil, false, now + 30) end
        end
    end
end
