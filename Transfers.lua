local _, U = ...
local lastReady, lastResend = -100, -100
local acceptRetry, receiptRetry, declineRetry = {}, {}, {}
local RETRY_FOR, CONFIRM_FOR = 5, 180
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
function U.TransferMessage(kind, f, sender, remote, context)
    local tickets = U.Tickets()
    if kind == "TICKET" or kind == "UTICKET" then
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
            if f[5] and context and OwnGateway(context) then t.receiptReady = f[5] end
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
    t.receiptReady = f[5]
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
    if U.guild and U.IsGateway() and U.Connected() and U.remote then
        for id, t in pairs(tickets) do
            if ValidTicket(t) and t.dest == U.guild and t.state == "accepted" and t.receiptReady == t.acceptNonce
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
