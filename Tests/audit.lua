-- Production-module regressions for the six 0.9 audit findings. This suite
-- reuses only the isolated WoW fixture; every decision runs in the real addon.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation fixture missing")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true))
source = source:sub(1, boundary - 1)
-- Optional read-only negative control against the pre-fix module snapshot.
source = source:gsub('loadfile%("ChillZoneUnion/" %.%. module%)',
    'loadfile((CZU_AUDIT_SOURCE_ROOT or os.getenv("CZU_AUDIT_SOURCE_ROOT") or "ChillZoneUnion/") .. module)')
local H = assert(loadstring(source .. "\n" .. [[
return { NewClient = NewClient, Step = Step, SetRosters = SetRosters, Count = Count,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    SetFilter = function(filter) deliveryFilter = filter end,
    Advance = function(seconds) time = time + seconds end,
    ClearWire = function() wire = {} end,
    RemoveClient = function(client)
        for i = #clients, 1, -1 do if clients[i] == client then table.remove(clients, i) end end
    end,
    Now = function() return time end }
]]))()
local failed, ran, serial = 0, 0, 700000
local function eq(a, b, message) assert(a == b, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Scenario(name, run)
    ran = ran + 1
    local ok, reason = pcall(run)
    if ok then print("PASS audit: " .. name)
    else failed = failed + 1; print("FAIL audit: " .. name .. ": " .. tostring(reason)) end
end
local function Packet(c, sender, dist, part, total, data, id)
    serial = serial + 1
    c.U.Receive(c.U.PREFIX, (id or tostring(serial)) .. "~" .. part .. "~" .. total .. "~" .. data,
        dist or "GUILD", sender .. "-ForeverRealm")
    return id or tostring(serial)
end
local function Upvalue(fn, wanted)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error("missing production upvalue " .. wanted)
end
local function PoolConsistent(c)
    local count, bytes, senders = 0, 0, {}
    for _, buffer in pairs(Upvalue(c.U.Receive, "buffers")) do
        count, bytes = count + 1, bytes + buffer.bytes
        senders[buffer.sender] = (senders[buffer.sender] or 0) + 1
    end
    eq(Upvalue(c.U.Receive, "bufferCount"), count, "assembly count diverged from retained buffers")
    eq(Upvalue(c.U.Receive, "bufferBytes"), bytes, "assembly byte accounting diverged")
    local actual = Upvalue(c.U.Receive, "bufferSenders")
    for name, retained in pairs(senders) do eq(actual[name], retained, "sender assembly accounting diverged") end
    for name, retained in pairs(actual) do eq(senders[name], retained, "sender quota leaked after deletion") end
    assert(count <= 80 and bytes <= 800000, "global assembly budget exceeded")
end
local function LocalWorld()
    H.Reset()
    local receiver = H.NewClient("Reader Audit", 1, 2)
    local member = H.NewClient("Flood Member", 1, 2)
    local gateway = H.NewClient("Gateway Audit", 1, 0)
    H.SetRosters(0)
    return receiver, member, gateway
end
local function World(veteran)
    H.Reset()
    local sourceGM = H.NewClient("Source Master", 1, 0)
    local destGM = H.NewClient("Destination Master", 2, 0)
    local member = H.NewClient("Transfer Member", 1, 2)
    local invite, relay
    if veteran then
        invite = H.NewClient("Z Invite Officer", 2, 1)
        relay = H.NewClient("A Veteran Gateway", 2, 4)
        relay.officer, relay.rankName, relay.invitePermission = false, "Ветеран", false
    else invite = H.NewClient("Invite Reader", 2, 1) end
    local all = { sourceGM, destGM, member, invite }
    if relay then all[#all + 1] = relay end
    H.SetRosters(0)
    for _, c in ipairs(all) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(sourceGM.U.Link(destGM.name)); H.Step(70)
    assert(sourceGM.U.Connected() and member.U.Connected(), "fixture not connected")
    if veteran then
        destGM.live = false; H.SetRosters(0); H.Step(140)
        assert(relay.U.IsGateway() and not invite.U.IsGateway(), "veteran gateway fixture election failed")
        assert(relay.U.Connected() and invite.U.Connected(), "veteran gateway fixture disconnected")
    end
    return sourceGM, veteran and relay or destGM, member, invite, all
end
local function Proposal(gm, member)
    assert(gm.U.CreateTransfer(member.name), "proposal rejected")
    H.Step(12)
    local latest
    for _, t in pairs(member.U.Tickets()) do
        if t.member == member.name and t.state == "proposed" and (not latest or t.created >= latest.created) then latest = t end
    end
    assert(latest, "proposal missing at participant")
    return latest
end
local observedWire = setmetatable({}, { __mode = "k" })
local function WireMessage(packet)
    local id, part, total, encoded = packet.text:match("^([^~]+)~(%d+)~(%d+)~(.*)$")
    if not encoded then return nil end
    part, total = tonumber(part), tonumber(total)
    if total > 1 then
        local buffers = observedWire[packet.from] or {}; observedWire[packet.from] = buffers
        local key = id .. ":" .. packet.dist
        local buffer = buffers[key] or { parts = {}, count = 0 }; buffers[key] = buffer
        if not buffer.parts[part] then buffer.parts[part], buffer.count = encoded, buffer.count + 1 end
        if buffer.count ~= total then return nil end
        encoded = table.concat(buffer.parts)
    end
    local raw
    if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
    elseif encoded:sub(1, 1) == "Z" then
        local D = packet.from.U.Deflate
        local zipped = D and D:DecodeForWoWAddonChannel(encoded:sub(2))
        raw = zipped and D:DecompressDeflateLimited(zipped, 25000)
    end
    local kind, payload
    if raw then kind, payload = raw:match("^([A-Z]+)~(.*)$") end
    return kind, payload and packet.from.U.Unpack(payload)
end
local function IsKind(packet, kind) return WireMessage(packet) == kind end
local function Has(c, text)
    local count = 0
    for _, row in ipairs(c.U.history) do if row.text == text then count = count + 1 end end
    return count
end
local function Copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end
    return out
end
local function Login(c)
    c.live = true; H.SetRosters(0)
    c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
end
local function OfflineReady()
    local gm, relay, member, invite, all = World(true)
    local t = Proposal(gm, member)
    local saved = Copy(invite.E.ChillZoneUnionDB)
    invite.live = false; H.SetRosters(0)
    member.U.AcceptTransfer(t.id, true); H.Step(15)
    eq(t.state, "accepted", "offline-officer fixture never received destination ACK")
    member.U.LeaveForTransfer(t.id); eq(member.command, "/gquit", "confirmed fixture could not prepare leave")
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(12)
    eq(relay.U.Tickets()[t.id].state, "ready", "offline-officer fixture gateway missed READY")
    eq(invite.U.Tickets()[t.id].state, "proposed", "offline-officer fixture observed consent while absent")
    return gm, relay, member, invite, t, saved, all
end
local function ReadyGroup(count)
    local gm, relay, member, invite = World(true)
    invite.live = false
    local members, tickets = { member }, {}
    for i = 2, count do members[i] = H.NewClient(string.format("Budget Member%02d", i), 1, 2) end
    H.SetRosters(0)
    for i = 2, count do members[i].U.frame.scripts.OnEvent(members[i].U.frame, "PLAYER_LOGIN") end
    H.Step(30)
    for _, participant in ipairs(members) do assert(gm.U.CreateTransfer(participant.name)) end
    H.Step(35)
    for _, participant in ipairs(members) do
        local ticket
        for _, candidate in pairs(participant.U.Tickets()) do
            if candidate.member == participant.name and candidate.state == "proposed" then ticket = candidate; break end
        end
        assert(ticket, "budget participant did not receive actual proposal")
        tickets[#tickets + 1] = ticket
        assert(participant.U.AcceptTransfer(ticket.id, true))
    end
    H.Step(60)
    for i, participant in ipairs(members) do
        eq(tickets[i].state, "accepted", "budget participant missed actual destination ACK")
        participant.U.LeaveForTransfer(tickets[i].id)
        eq(participant.command, "/gquit", "budget participant could not prepare leave")
        participant.guild = nil; participant.U.frame.scripts.OnEvent(participant.U.frame, "PLAYER_GUILD_UPDATE", "player")
    end
    H.SetRosters(0); H.Step(65)
    for _, ticket in ipairs(tickets) do eq(relay.U.Tickets()[ticket.id].state, "ready", "budget gateway missed actual READY") end
    return gm, relay, invite, tickets
end
local function StateFields(relay, target, t, nonce)
    return { relay.U.guild, target.name, nonce or "", t.source, t.id, t.member, t.dest,
        t.master, t.created, t.authorityGuild or t.source, t.acceptNonce or "", t.state, t.receiptReady or "" }
end
-- Keep live gateway advertisements while admitting only explicitly queued
-- snapshot probes. This isolates hostile packets from automatic catch-up.
local function StateProbe(target)
    local allowed = {}
    H.SetFilter(function(packet, receiver)
        if receiver ~= target then return true end
        if IsKind(packet, "HELLO") then return true end
        return allowed[packet.text:match("^([^~]+)~")] == true
    end)
    return function(sender, fields, distribution)
        serial = serial + 1; local id = tostring(serial); allowed[id] = true
        local dist = distribution or "GUILD"
        local native, accepted = target.U.TransferMessage, nil
        target.U.TransferMessage = function(kind, ...)
            local result = native(kind, ...)
            if kind == "TSTATE" then accepted = result end
            return result
        end
        assert(sender.U.Queue("TSTATE", fields, dist, dist == "WHISPER" and target.name or nil, true, false, id), "snapshot probe queue rejected")
        H.Step(3)
        target.U.TransferMessage = native
        if dist == "GUILD" and target.U.GatewayName() == sender.name and target.U.CanRelay(sender.name) then
            assert(accepted ~= nil, "authenticated snapshot probe never reached production transfer handler")
        end
        return accepted
    end
end
local function TicketUI(c, id)
    c.U.OpenRoster()
    local render = Upvalue(c.U.Refresh, "RenderTickets")
    render()
    local rows = Upvalue(render, "ticketRows")
    for _, row in ipairs(rows) do
        if row.ticket and row.ticket.id == id then
            row.scripts.OnClick(row)
            return row, Upvalue(render, "inviteButton"), Upvalue(render, "states")
        end
    end
    error("transfer UI omitted requested ticket")
end

Scenario("one ordinary member cannot exhaust multipart slots", function()
    local c, flood, gateway = LocalWorld()
    local received = {}
    c.U.Handle = function(kind, fields) received[#received + 1] = { kind, fields } end
    for i = 1, 80 do Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~", "710" .. i) end
    assert(H.Count(Upvalue(c.U.Receive, "buffers")) <= 4, "ordinary sender retained more than four partial messages")
    Packet(c, gateway.name, "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "small" }))
    local raw = "RCHAT~" .. c.U.Pack({ string.rep("x", 300) })
    local id = Packet(c, gateway.name, "GUILD", 1, 2, raw:sub(1, 150))
    Packet(c, gateway.name, "GUILD", 2, 2, raw:sub(151), id)
    eq(#received, 2, "flood suppressed legitimate single or multipart delivery")
end)

Scenario("single packet bypasses an otherwise full global assembly pool", function()
    local c = LocalWorld()
    local received = 0
    c.U.Handle = function() received = received + 1 end
    for sender = 1, 20 do
        local name = "Flood " .. sender
        c.U.own[name] = { name = name, rank = 2, online = true }
        for fragment = 1, 4 do Packet(c, name, "GUILD", 1, 2, "RCHAT~") end
    end
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 80, "global saturation fixture did not fill eighty slots")
    c.U.own["Fresh Sender"] = { name = "Fresh Sender", rank = 2, online = true }
    Packet(c, "Fresh Sender", "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "still arrives" }))
    eq(received, 1, "single-packet message required an assembly slot")
end)

Scenario("assembly quotas release on conflict, completion, expiry and queue reset", function()
    local c, flood, gateway = LocalWorld()
    c.U.Handle = function() end
    local ids = {}
    for i = 1, 4 do ids[i] = Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~") end
    Packet(c, flood.name, "GUILD", 2, 3, "bad", ids[1])
    PoolConsistent(c)
    local new = Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~")
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 4, "conflicting-total deletion leaked sender quota")
    Packet(c, flood.name, "GUILD", 2, 2, c.U.Pack({ "completed" }), new)
    Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~")
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 4, "completion leaked sender quota")
    PoolConsistent(c)
    H.Advance(91)
    Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~")
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 1, "expired quota was not reclaimed during admission")
    PoolConsistent(c)
    c.U.ClearQueue()
    PoolConsistent(c)
    for i = 1, 4 do Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~") end
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 4, "ClearQueue left an invisible sender quota")
    c.U.ClearQueue()
    local raw = "RCHAT~" .. c.U.Pack({ string.rep("x", 9950) })
    local id = "754000"
    for i = 1, 54 do Packet(c, gateway.name, "GUILD", i, 54, raw:sub((i - 1) * 185 + 1, i * 185), id) end
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 0, "maximum legitimate multipart message did not complete")
    PoolConsistent(c)
    local oversized = "755000"
    for i = 1, 40 do Packet(c, gateway.name, "GUILD", i, 54, string.rep("x", 233), oversized) end
    Packet(c, gateway.name, "GUILD", 41, 54, string.rep("x", 233), oversized)
    Packet(c, gateway.name, "GUILD", 42, 54, string.rep("x", 233), oversized)
    Packet(c, gateway.name, "GUILD", 43, 54, string.rep("x", 233), oversized)
    assert(not Upvalue(c.U.Receive, "buffers")[gateway.name .. ":GUILD:" .. oversized], "oversize assembly retained resources")
    PoolConsistent(c)
    local conflict = Packet(c, flood.name, "GUILD", 1, 2, "RCHAT~")
    Packet(c, flood.name, "GUILD", 1, 2, "changed", conflict)
    assert(not Upvalue(c.U.Receive, "buffers")[flood.name .. ":GUILD:" .. conflict], "conflicting duplicate fragment retained resources")
    PoolConsistent(c)
    H.Advance(91); c.U.ProtocolClean(); PoolConsistent(c)
    eq(H.Count(Upvalue(c.U.Receive, "buffers")), 0, "periodic cleanup retained expired assembly")
end)

Scenario("single-packet fast path retains sender rate, deduplication and transport authentication", function()
    local c, member = LocalWorld()
    local received = 0
    c.U.Handle = function() received = received + 1 end
    for i = 1, 220 do Packet(c, member.name, "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "valid" })) end
    eq(received, 220, "valid sender rate budget unexpectedly reduced")
    Packet(c, member.name, "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "over limit" }))
    eq(received, 220, "single-packet fast path bypassed the shared sender rate")
    H.Advance(11)
    local id = Packet(c, member.name, "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "deduplicated" }))
    Packet(c, member.name, "GUILD", 1, 1, "RCHAT~" .. c.U.Pack({ "deduplicated" }), id)
    eq(received, 221, "single-packet fast path bypassed wire deduplication")
    Packet(c, "Unknown Sender", "WHISPER", 1, 1, "RCHAT~" .. c.U.Pack({ "unknown" }))
    Packet(c, member.name, "WHISPER", 1, 1, "RCHAT~" .. c.U.Pack({ "wrong transport" }))
    c.U.Receive(c.U.PREFIX, "799000~1~1~RCHAT~" .. c.U.Pack({ "wrong realm" }), "GUILD", member.name .. "-OtherRealm")
    eq(received, 221, "single-packet fast path authorized an untrusted transport or realm")
end)

Scenario("ACK and local relay enter the destination queue together", function()
    local gm, remote, member, invite, all = World()
    assert(gm.U.SendChat("atomic audit chat")); local row = gm.U.history[#gm.U.history]
    local fields = { row.guild, row.name, row.text, row.id, row.time }
    for _, c in ipairs(all) do c.U.ClearQueue() end
    H.ClearWire()
    for i = 1, 1499 do assert(remote.U.Queue("TEST", { "x" }, "GUILD", nil, false)) end
    remote.U.Handle("CHAT", fields, "WHISPER", gm.name, "780001")
    eq(remote.U.QueueSize(), 1499, "ACK committed when local REMOTE had insufficient queue space")
    eq(Has(remote, row.text), 0, "destination recorded delivery before atomic queue admission")
    remote.U.ClearQueue()
    remote.U.Handle("CHAT", fields, "WHISPER", gm.name, "780001")
    assert(remote.U.QueueSize() >= 2, "same wire identity could not retry after refused admission")
    H.Step(12, true)
    eq(Has(invite, row.text), 1, "retried atomic delivery was lost or duplicated for local readers")
    eq(gm.U.chatByID[row.id].status, "delivered", "sender did not receive successful retry ACK")
    eq(gm.U.ChatOutboxCount(), 0, "successful atomic retry left sender pending")
end)

Scenario("queue pressure cannot falsely complete the source outbox", function()
    local gm, remote, member, invite, all = World()
    assert(gm.U.SendChat("pending under pressure")); local row = gm.U.history[#gm.U.history]
    for _, c in ipairs(all) do c.U.ClearQueue() end
    H.ClearWire()
    for i = 1, 1499 do assert(remote.U.Queue("TEST", { "x" }, "GUILD", nil, false)) end
    remote.U.Handle("CHAT", { row.guild, row.name, row.text, row.id, row.time }, "WHISPER", gm.name, "780002")
    H.Step(0.3)
    eq(gm.U.ChatOutboxCount(), 1, "ACK-only delivery falsely drained sender outbox")
    eq(row.status, "pending", "sender displayed delivered although its remote readers received no relay")
end)

Scenario("acceptance stays pending during chat lockdown", function()
    local gm, remote, member = World()
    local t = Proposal(gm, member)
    member.locked = true
    member.U.AcceptTransfer(t.id, true)
    eq(t.state, "pending", "local acceptance claimed destination confirmation immediately")
    member.U.LeaveForTransfer(t.id)
    assert(member.command ~= "/gquit", "leave was available before destination ACK")
    H.Step(8)
    eq(t.state, "pending", "lockdown acceptance became confirmed without transport")
    member.locked = false; H.Step(20)
    eq(t.state, "accepted", "acceptance did not recover after transport unlocked")
    member.U.LeaveForTransfer(t.id)
    eq(member.command, "/gquit", "confirmed acceptance did not enable manual leave")
end)

Scenario("lost ACCEPT and destination ACK are retried before leave", function()
    local gm, remote, member = World()
    local t = Proposal(gm, member)
    local lostAccept, lostAck = 0, 0
    H.SetFilter(function(packet, receiver)
        if packet.from == member and receiver == gm and IsKind(packet, "ACCEPT") and lostAccept == 0 then lostAccept = 1; return false end
        if receiver == member and packet.dist == "GUILD" and packet.text:find("TACK", 1, true) and lostAck == 0 then lostAck = 1; return false end
        return true
    end)
    member.U.AcceptTransfer(t.id, true)
    member.U.LeaveForTransfer(t.id); assert(member.command ~= "/gquit", "leave available before first ACCEPT delivery")
    H.Step(40)
    eq(lostAccept, 1, "fixture did not drop first ACCEPT")
    eq(lostAck, 1, "destination confirmation was never sent over the guild wire")
    eq(t.state, "accepted", "lost confirmation never recovered")
    eq(remote.U.Tickets()[t.id].state, "accepted", "destination never recorded consent")
    member.U.LeaveForTransfer(t.id); eq(member.command, "/gquit", "retry confirmation did not allow manual leave")
    H.SetFilter(nil)
end)

Scenario("declined, expired, superseded and mismatched confirmations cannot enable leave", function()
    local gm, remote, member = World()
    local t = Proposal(gm, member)
    member.locked = true; member.U.AcceptTransfer(t.id, true)
    local nonce = t.acceptNonce
    assert(type(nonce) == "string" and nonce ~= "", "acceptance has no unique confirmation nonce")
    local ack = { t.source, t.id, t.member, t.dest, nonce }
    local bad = { t.source, t.id, t.member, t.dest, nonce .. "0" }
    assert(not member.U.TransferMessage("TACK", bad, remote.name, true), "wrong acceptance nonce was confirmed")
    assert(not member.U.TransferMessage("TACK", ack, gm.name, true), "own-guild actor impersonated destination confirmation")
    member.U.AcceptTransfer(t.id, false)
    assert(not member.U.TransferMessage("TACK", ack, remote.name, true), "declined acceptance accepted a delayed ACK")
    assert(member.U.TransferMessage("TICKET", { t.source, t.id, t.member, t.dest, t.master, t.created }, gm.name, false), "identical ticket replay was not recognized")
    eq(t.state, "declined", "ticket replay reopened declined consent")
    member.U.LeaveForTransfer(t.id); assert(member.command ~= "/gquit", "declined ticket enabled leave")
    member.locked = false; H.Step(8)
    local replacement = Proposal(gm, member)
    member.locked = true; member.U.AcceptTransfer(replacement.id, true)
    local fields = { replacement.source, replacement.id, replacement.member, replacement.dest, replacement.acceptNonce }
    replacement.created = member.U.stamp() - 1801
    assert(not member.U.TransferMessage("TACK", fields, remote.name, true), "expired ticket accepted confirmation")
    member.U.LeaveForTransfer(replacement.id); assert(member.command ~= "/gquit", "expired ticket enabled leave")
    member.locked = false; H.Step(8)
    local old = Proposal(gm, member)
    member.locked = true; member.U.AcceptTransfer(old.id, true)
    local oldAck = { old.source, old.id, old.member, old.dest, old.acceptNonce }
    H.Advance(1)
    local newer = Proposal(gm, member)
    eq(old.state, "replaced", "new active proposal did not supersede old consent")
    assert(newer.id ~= old.id, "replacement fixture reused old ticket")
    assert(not member.U.TransferMessage("TACK", oldAck, remote.name, true), "superseded consent accepted a delayed ACK")
    member.U.LeaveForTransfer(old.id); assert(member.command ~= "/gquit", "superseded ticket enabled leave")
end)

Scenario("Veteran READY reaches a separate destination invite officer", function()
    local gm, relay, member, invite = World(true)
    local t = Proposal(gm, member)
    member.U.AcceptTransfer(t.id, true); H.Step(15)
    eq(t.state, "accepted", "veteran relay did not confirm destination acceptance")
    eq(invite.U.Tickets()[t.id].state, "accepted", "invite officer missed destination acceptance")
    local ready = { t.id, member.name }
    assert(not invite.U.TransferMessage("READY", ready, member.name, true), "non-gateway accepted an unbound direct READY")
    assert(not invite.U.TransferMessage("READY", ready, member.name, true, { gateway = gm.name }), "foreign actor supplied a forged READY wrapper")
    eq(t.contact, relay.name, "confirmed transfer did not retain the authenticated destination gateway")
    -- The active endpoint can remain verified by the remote roster after the
    -- bounded contact cache evicts its address. Confirmation retains that route.
    member.U.db.contacts[relay.name] = nil
    eq(member.U.TrustedPeer(relay.name), 2, "contact eviction fixture lost independently verified destination authority")
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(12)
    eq(relay.U.Tickets()[t.id].state, "ready", "destination veteran missed direct guildless READY")
    eq(invite.U.Tickets()[t.id].state, "ready", "destination invite officer missed authenticated forwarded READY")
    invite.U.InviteTransfer(t.id); eq(invite.command, "/ginvite " .. member.name, "separate officer could not prepare native invitation")
    local before = #invite.U.history
    invite.U.Handle("REMOTE", { "CHAT", invite.U.Pack({ 1, member.name, "forged from ticket", "1:fake:ticket", invite.U.stamp() }), member.name }, "GUILD", relay.name, "790000")
    eq(#invite.U.history, before, "transfer-member exception authorized non-READY remote traffic")
end)

Scenario("returning destination officer recovers READY after missing consent and leave", function()
    local gm, relay, member, invite = World(true)
    local t = Proposal(gm, member)
    eq(invite.U.Tickets()[t.id].state, "proposed", "destination officer never received original proposal")
    invite.live = false; H.SetRosters(0)
    member.U.AcceptTransfer(t.id, true); H.Step(15)
    eq(t.state, "accepted", "destination did not confirm offline-officer transfer")
    member.U.LeaveForTransfer(t.id); eq(member.command, "/gquit", "confirmed member could not prepare leave")
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(12)
    eq(relay.U.Tickets()[t.id].state, "ready", "Veteran gateway did not receive guildless READY")
    eq(invite.U.Tickets()[t.id].state, "proposed", "offline officer unexpectedly observed live consent")
    invite.live = true; H.SetRosters(0)
    invite.U.frame.scripts.OnEvent(invite.U.frame, "PLAYER_LOGIN")
    H.Step(120)
    print("AUDIT offline transfer: gateway=" .. relay.U.Tickets()[t.id].state .. "; returning officer=" .. invite.U.Tickets()[t.id].state)
    eq(invite.U.Tickets()[t.id].state, "ready", "returning invite officer retained proposed after 120 seconds")
    invite.U.InviteTransfer(t.id); eq(invite.command, "/ginvite " .. member.name, "recovered officer could not prepare invitation")
    relay.command = nil; relay.U.InviteTransfer(t.id)
    assert(not relay.command, "Veteran gateway gained invitation permission")
end)

Scenario("cold destination restart upgrades saved proposed and enables bound invitation UI", function()
    local gm, relay, member, old, t, saved = OfflineReady()
    H.RemoveClient(old)
    local invite = H.NewClient(old.name, 2, 1, saved)
    eq(invite.U.Tickets()[t.id].state, "proposed", "cold restart did not load stale saved proposal")
    Login(invite); H.Step(120, true)
    local recovered = invite.U.Tickets()[t.id]
    eq(recovered and recovered.state, "ready", "cold destination restart did not recover READY")
    local row, button, states = TicketUI(invite, t.id)
    eq(row.ticket, recovered, "rendered transfer row is not bound to recovered ticket")
    assert(row:GetText():find(states.ready, 1, true), "transfer row did not render ready status")
    assert(button:IsEnabled(), "recovered ready ticket did not enable invitation button")
    button.scripts.OnClick(button)
    eq(invite.command, "/ginvite " .. member.name, "ready UI did not prepare native invitation")
    local veteranRow, veteranButton = TicketUI(relay, t.id)
    eq(veteranRow.ticket.state, "ready", "Veteran UI missed ready status")
    assert(not veteranButton:IsEnabled(), "Veteran relay without invite permission acquired enabled invitation UI")
    veteranButton.scripts.OnClick(veteranButton)
    assert(not relay.command, "Veteran invitation callback bypassed native invitation permission")
end)

Scenario("new destination officer learns active accepted and ready ticket bodies", function()
    local gm, relay, member, invite = World(true)
    local t = Proposal(gm, member)
    member.U.AcceptTransfer(t.id, true); H.Step(15)
    local newcomer = H.NewClient("New Destination Officer", 2, 1)
    eq(H.Count(newcomer.U.Tickets()), 0, "new destination client unexpectedly had a saved ticket")
    local acceptedSnapshots = 0
    H.SetFilter(function(packet, receiver)
        local kind, fields = WireMessage(packet)
        if receiver == newcomer and fields then
            if kind == "REMOTE" and (fields[1] == "TICKET" or fields[1] == "ACCEPT") then return false end
            if kind == "TSTATE" and #fields == 13 and fields[12] == "accepted" then acceptedSnapshots = acceptedSnapshots + 1 end
        end
        return true
    end)
    Login(newcomer); H.Step(60)
    local received = newcomer.U.Tickets()[t.id]
    eq(received and received.state, "accepted", "new destination officer did not learn accepted state")
    eq(received.member, t.member, "catch-up omitted ticket member")
    eq(received.master, t.master, "catch-up changed proposal authority")
    eq(received.created, t.created, "catch-up changed immutable creation time")
    assert(acceptedSnapshots > 0, "new officer recovered through legacy retransmit without receiving accepted snapshot")
    H.SetFilter(nil)
    member.U.LeaveForTransfer(t.id)
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(15)
    eq(received.state, "ready", "new destination officer did not advance to ready")
    local later = H.NewClient("Later Destination Officer", 2, 1)
    Login(later); H.Step(60)
    eq(later.U.Tickets()[t.id] and later.U.Tickets()[t.id].state, "ready", "new officer could not learn complete ready ticket after source member left")
    assert(not later.U.TransferConfirmed(later.U.Tickets()[t.id]), "destination snapshot acquired participant leave confirmation")
end)

Scenario("returning officer catches up from replacement Veteran gateway", function()
    local gm, relay, member, invite, t, saved = OfflineReady()
    local backup = H.NewClient("B Veteran Backup", 2, 4, saved)
    backup.officer, backup.rankName, backup.invitePermission = false, relay.rankName, false
    Login(backup); H.Step(60)
    eq(backup.U.Tickets()[t.id] and backup.U.Tickets()[t.id].state, "ready", "backup did not learn ticket before endpoint failed")
    relay.live = false; H.SetRosters(0); H.Step(140)
    assert(backup.U.IsGateway(), "offline officer fixture did not elect replacement Veteran gateway")
    Login(invite); H.Step(120)
    eq(invite.U.Tickets()[t.id].state, "ready", "returning officer did not recover state from current replacement gateway")
    invite.U.InviteTransfer(t.id); eq(invite.command, "/ginvite " .. member.name, "gateway replacement blocked recovered invitation")
end)

Scenario("lost state request and reply retry over GUILD with duplicate delivery", function()
    local gm, relay, member, invite, t = OfflineReady()
    local requests, replies, droppedRequest, droppedReply = 0, 0, 0, 0
    H.SetFilter(function(packet, receiver)
        if packet.from == invite and receiver == relay and IsKind(packet, "TSYNC") then
            requests = requests + 1
            if droppedRequest == 0 then droppedRequest = 1; return false end
        end
        local kind, fields = WireMessage(packet)
        if packet.from == relay and receiver == invite and kind == "TSTATE" and fields then
            if fields[3] == "" then return false end -- isolate request/reply recovery from HELLO pushes
            if #fields == 13 then
                replies = replies + 1
                if droppedReply == 0 then droppedReply = 1; return false end
            end
        end
        return true
    end)
    Login(invite); assert(invite.U.TransferSyncRequest(true)); H.Step(120, true)
    eq(droppedRequest, 1, "fixture did not drop a real state request")
    eq(droppedReply, 1, "fixture did not drop a real state snapshot")
    assert(requests >= 2 and replies >= 2, "state recovery did not retry both dropped request and reply")
    eq(invite.U.Tickets()[t.id].state, "ready", "lost state transport left destination officer stale")
    H.SetFilter(nil)
end)

Scenario("seventeen-ticket pagination retries a lost middle-page row before advancing", function()
    local gm, relay, member, invite = World(true)
    invite.live = false
    local members = { member }
    for i = 2, 17 do members[i] = H.NewClient(string.format("Paged Member%02d", i), 1, 2) end
    H.SetRosters(0)
    for i = 2, #members do members[i].U.frame.scripts.OnEvent(members[i].U.frame, "PLAYER_LOGIN") end
    H.Step(30)
    for _, participant in ipairs(members) do assert(gm.U.CreateTransfer(participant.name), "paged transfer proposal rejected") end
    H.Step(35)
    local tickets = {}
    for _, participant in ipairs(members) do
        local ticket
        for _, candidate in pairs(participant.U.Tickets()) do
            if candidate.member == participant.name and candidate.state == "proposed" then ticket = candidate; break end
        end
        assert(ticket, "paged participant never received proposal")
        tickets[#tickets + 1] = ticket
        assert(participant.U.AcceptTransfer(ticket.id, true), "paged participant could not accept")
    end
    H.Step(60)
    for i, participant in ipairs(members) do
        eq(tickets[i].state, "accepted", "paged participant never received destination ACK")
        participant.U.LeaveForTransfer(tickets[i].id)
        eq(participant.command, "/gquit", "paged participant could not prepare leave")
        participant.guild = nil; participant.U.frame.scripts.OnEvent(participant.U.frame, "PLAYER_GUILD_UPDATE", "player")
    end
    H.SetRosters(0); H.Step(65)
    for _, ticket in ipairs(tickets) do eq(relay.U.Tickets()[ticket.id].state, "ready", "paged gateway did not receive all READY messages") end
    local seen, unique, dropped, controls, acknowledgements, packets = {}, 0, nil, 0, 0, 0
    H.SetFilter(function(packet, receiver)
        local kind, fields = WireMessage(packet)
        if packet.from == invite and receiver == relay and kind == "TSYNC" and fields and #fields == 5 then
            acknowledgements = acknowledgements + 1
        end
        if packet.from == relay and receiver == invite and kind == "TSTATE" and fields then
            if fields[3] == "" then return false end
            packets = packets + 1
            if #fields == 13 then
                if not seen[fields[5]] then seen[fields[5]], unique = true, unique + 1 end
                if unique == 9 and not dropped then dropped = fields[5]; return false end
            elseif #fields == 6 then controls = controls + 1 end
        end
        return true
    end)
    Login(invite); H.Step(25)
    assert(invite.U.TransferSyncRequest(true), "pagination requester never discovered live gateway")
    H.Step(120, true)
    assert(dropped, "pagination fixture did not drop a middle-page ticket")
    assert(controls >= 3 and acknowledgements >= 2, "state synchronization did not paginate with explicit batch acknowledgements")
    for _, ticket in ipairs(tickets) do
        eq(invite.U.Tickets()[ticket.id] and invite.U.Tickets()[ticket.id].state, "ready", "lost middle page left a destination ticket missing or stale")
    end
    assert(packets <= 200, "bounded pagination emitted excessive snapshot traffic: " .. packets)
    H.SetFilter(nil)
end)

Scenario("full requesting queue retries state synchronization after admission recovers", function()
    local gm, relay, member, invite, t = OfflineReady()
    Login(invite); invite.U.ClearQueue(); invite.locked = true
    for i = 1, 1500 do assert(invite.U.Queue("TEST", { "x" }, "GUILD", nil, false)) end
    eq(invite.U.QueueSize(), 1500, "request queue saturation fixture did not fill queue")
    assert(type(invite.U.TransferSyncRequest) == "function", "state request API missing")
    local block, requests = true, 0
    H.SetFilter(function(packet, receiver)
        local kind, fields = WireMessage(packet)
        if packet.from == invite and receiver == relay and kind == "TSYNC" then requests = requests + 1 end
        if receiver == invite and kind == "TSTATE" and fields then return not block and fields[3] ~= "" end
        return true
    end)
    invite.U.TransferSyncRequest(true); H.Step(8)
    eq(invite.U.Tickets()[t.id].state, "proposed", "blocked request fixture unexpectedly recovered")
    invite.U.ClearQueue(); invite.locked = false
    block = false; H.Step(120)
    eq(invite.U.Tickets()[t.id].state, "ready", "queue refusal consumed state synchronization retry")
    assert(requests > 0, "request admission recovery never retried actual state transport")
    H.SetFilter(nil)
end)

Scenario("full gateway queue retains pending snapshot response for retry", function()
    local gm, relay, member, invite, t = OfflineReady()
    relay.U.ClearQueue(); relay.locked = true
    for i = 1, 1500 do assert(relay.U.Queue("TEST", { "x" }, "GUILD", nil, false)) end
    local requests, replies = 0, 0
    H.SetFilter(function(packet, receiver)
        local kind, fields = WireMessage(packet)
        if packet.from == invite and receiver == relay and kind == "TSYNC" then requests = requests + 1 end
        if receiver == invite and kind == "TSTATE" and fields then
            if fields[3] == "" then return false end
            if #fields == 13 then replies = replies + 1 end
        end
        return true
    end)
    Login(invite); assert(invite.U.TransferSyncRequest(true)); H.Step(8)
    eq(invite.U.Tickets()[t.id].state, "proposed", "full gateway queue unexpectedly delivered snapshot")
    relay.U.ClearQueue(); relay.locked = false; H.Step(120)
    eq(invite.U.Tickets()[t.id].state, "ready", "gateway queue refusal discarded pending catch-up")
    assert(requests > 0 and replies > 0, "gateway admission recovery did not use request/reply state transport")
    H.SetFilter(nil)
end)

Scenario("ordinary destination member cannot request or queue transfer-state replies", function()
    local gm, relay, member, invite, t = OfflineReady()
    local ordinary = H.NewClient("Ordinary State Requester", 2, 2)
    Login(ordinary); H.Step(25)
    assert(not ordinary.U.CanInvite() and not relay.U.CanInvite(ordinary.name) and not relay.U.CanRelay(ordinary.name), "ordinary requester unexpectedly has native transfer privileges")
    local calls, replies, nativeMessage, nativeBatch = 0, 0, relay.U.TransferMessage, relay.U.QueueBatch
    relay.U.TransferMessage = function(kind, fields, sender, ...)
        local before = relay.U.QueueSize()
        local result = nativeMessage(kind, fields, sender, ...)
        if kind == "TSYNC" and sender == ordinary.name then
            calls = calls + 1
            eq(result, false, "ordinary member TSYNC was admitted by production handler")
            eq(relay.U.QueueSize(), before, "rejected TSYNC changed the outgoing queue")
        end
        return result
    end
    relay.U.QueueBatch = function(items)
        local result = nativeBatch(items)
        if result then for _, item in ipairs(items) do
            if item.kind == "TSTATE" and item.fields[2] == ordinary.name then replies = replies + 1 end
        end end
        return result
    end
    assert(ordinary.U.Queue("TSYNC", { 2, relay.name, ordinary.name, ordinary.U.NewID() }, "GUILD", nil, false))
    H.Step(25)
    assert(calls > 0, "ordinary request never reached real GUILD handler")
    eq(replies, 0, "ordinary request created a deferred state reply")
    eq(relay.U.TransferSyncFor(ordinary.name, "1.777"), false, "direct sync scheduling API admitted ordinary member")
    relay.U.TransferMessage, relay.U.QueueBatch = nativeMessage, nativeBatch
end)

Scenario("invitation-only rank receives state and native flag revocation cancels pending replies", function()
    local gm, relay, member, invite, t = OfflineReady()
    local inviter = H.NewClient("Invitation Only Reader", 2, 3)
    inviter.officer, inviter.invitePermission, inviter.rankName = false, true, "Member"
    local permission = true
    for _, c in ipairs({ relay, inviter }) do
        local native = c.E.C_GuildInfo.GuildControlGetRankFlags
        c.E.C_GuildInfo.GuildControlGetRankFlags = function(order)
            local flags = native(order)
            if order == 4 then flags[7], flags[22] = permission, false end
            return flags
        end
        c.U.frame.scripts.OnEvent(c.U.frame, "GUILD_RANKS_UPDATE")
    end
    Login(inviter); H.Step(60)
    assert(inviter.U.CanInvite() and relay.U.CanInvite(inviter.name), "native flag 7 did not authorize invitation-only reader")
    assert(not inviter.U.CanRelay() and not relay.U.CanRelay(inviter.name) and not inviter.U.IsOfficer(), "invitation-only native flag granted relay or officer authority")
    eq(inviter.U.Tickets()[t.id] and inviter.U.Tickets()[t.id].state, "ready", "invitation-only reader did not receive authenticated state")
    inviter.U.InviteTransfer(t.id); eq(inviter.command, "/ginvite " .. member.name, "native invitation-only permission did not enable ready invite")
    local admitted, rejected, replies, nativeMessage, nativeBatch = 0, 0, 0, relay.U.TransferMessage, relay.U.QueueBatch
    relay.U.TransferMessage = function(kind, fields, sender, ...)
        local result = nativeMessage(kind, fields, sender, ...)
        if kind == "TSYNC" and sender == inviter.name then
            if result then admitted = admitted + 1 else rejected = rejected + 1 end
        end
        return result
    end
    relay.U.QueueBatch = function(items)
        local result = nativeBatch(items)
        if result then for _, item in ipairs(items) do
            if item.kind == "TSTATE" and item.fields[2] == inviter.name then replies = replies + 1 end
        end end
        return result
    end
    relay.U.ClearQueue(); relay.locked = true
    for i = 1, 1500 do assert(relay.U.Queue("TEST", { "x" }, "GUILD", nil, false)) end
    assert(inviter.U.TransferSyncRequest(true)); H.Step(8)
    assert(admitted > 0, "eligible request was not pending before native revocation")
    eq(replies, 0, "saturated gateway unexpectedly queued pending response")
    permission, inviter.invitePermission = false, false
    for _, c in ipairs({ relay, inviter }) do c.U.frame.scripts.OnEvent(c.U.frame, "GUILD_RANKS_UPDATE") end
    assert(not inviter.U.CanInvite() and not relay.U.CanInvite(inviter.name), "native rank event retained revoked flag 7 permission")
    assert(not relay.U.CanRelay(inviter.name), "revoked invitation-only reader acquired relay fallback")
    relay.U.ClearQueue(); relay.locked = false
    assert(inviter.U.Queue("TSYNC", { 2, relay.name, inviter.name, inviter.U.NewID() }, "GUILD", nil, false))
    H.Step(25)
    assert(rejected > 0, "revoked invitation-only requester was not refused")
    eq(replies, 0, "pending or new response survived native invitation revocation")
    inviter.command = nil; inviter.U.InviteTransfer(t.id)
    assert(not inviter.command, "revoked invitation-only native permission still enabled invitation")
    relay.U.TransferMessage, relay.U.QueueBatch = nativeMessage, nativeBatch
end)

Scenario("aggregate state records and controls stay within 4096 bytes while native chat delivers", function()
    local gm, relay, invite, tickets = ReadyGroup(4)
    local requesters = {}
    for i = 1, 12 do requesters[i] = H.NewClient(string.format("Budget Inviter%02d", i), 2, 1) end
    H.SetRosters(0)
    local syncTick = Upvalue(relay.U.TransferTick, "SyncTick")
    local windows, controls, records, totalBytes, nativeBatch = {}, 0, 0, 0, relay.U.QueueBatch
    relay.U.QueueBatch = function(items)
        local result = nativeBatch(items)
        if result then for _, item in ipairs(items) do if item.kind == "TSTATE" then
            assert(item.priority ~= true, "state catch-up occupied the urgent chat queue")
            local window = Upvalue(syncTick, "syncWindow")
            local bytes = #("TSTATE~" .. relay.U.Pack(item.fields))
            windows[window], totalBytes = (windows[window] or 0) + bytes, totalBytes + bytes
            assert(windows[window] <= 4096, "aggregate records plus controls exceeded 4096 bytes in ten-second window: " .. windows[window])
            if #item.fields == 6 then controls = controls + 1 else records = records + 1 end
        end end end
        return result
    end
    for _, requester in ipairs(requesters) do requester.U.frame.scripts.OnEvent(requester.U.frame, "PLAYER_LOGIN") end
    H.Step(4)
    assert(records > 0 and controls > 0, "state load fixture did not enqueue records and batch controls")
    local nativeText, queuedText = "native chat during state recovery", "ordinary queue chat during state recovery"
    relay.U.frame.scripts.OnEvent(relay.U.frame, "CHAT_MSG_GUILD", nativeText, relay.name .. "-ForeverRealm")
    assert(relay.U.Queue("CHAT", { 2, relay.name, queuedText, "2:audit:budget-chat", relay.U.stamp() }, "GUILD", nil, false, true))
    H.Step(10)
    eq(Has(gm, nativeText), 1, "actual native guild chat was lost under state synchronization load")
    eq(Has(requesters[1], queuedText), 1, "ordinary chat queue was starved by state synchronization")
    H.Step(46)
    assert(totalBytes > 4096 and H.Count(windows) >= 2, "aggregate budget fixture never crossed a ten-second byte window")
    local maxWindow = 0; for _, bytes in pairs(windows) do maxWindow = math.max(maxWindow, bytes) end
    print("AUDIT state budget: windows=" .. H.Count(windows) .. "; max window=" .. maxWindow .. "; raw bytes=" .. totalBytes .. "; records=" .. records .. "; controls=" .. controls)
    relay.U.QueueBatch = nativeBatch
end)

Scenario("state snapshot preserves declined done replaced expired and superseded tickets", function()
    local gm, relay, member, invite, t = OfflineReady()
    invite.live = true; H.SetRosters(0)
    local send = StateProbe(invite)
    local original = Copy(invite.U.Tickets()[t.id])
    for _, state in ipairs({ "declined", "done", "replaced" }) do
        invite.U.Tickets()[t.id] = Copy(original); invite.U.Tickets()[t.id].state = state
        send(relay, StateFields(relay, invite, relay.U.Tickets()[t.id]))
        eq(invite.U.Tickets()[t.id].state, state, "snapshot reopened terminal " .. state .. " ticket")
    end
    invite.U.Tickets()[t.id] = Copy(original)
    local newer = Copy(original); newer.id = t.id .. ".99"; newer.created = newer.created + 1
    invite.U.Tickets()[newer.id] = newer
    send(relay, StateFields(relay, invite, relay.U.Tickets()[t.id]))
    eq(invite.U.Tickets()[t.id].state, "proposed", "snapshot revived a superseded ticket")
    invite.U.Tickets()[newer.id] = nil
    invite.U.Tickets()[t.id] = Copy(original)
    invite.U.Tickets()[t.id].created = invite.U.stamp() - 1801
    local expired = Copy(relay.U.Tickets()[t.id]); expired.created = invite.U.Tickets()[t.id].created
    eq(send(relay, StateFields(relay, invite, expired)), false, "production handler accepted expired snapshot before periodic deletion")
    assert(not invite.U.Tickets()[t.id], "expired snapshot recreated removed ticket")
    H.SetFilter(nil)
end)

Scenario("state snapshot rejects conflicting immutable body consent nonce and receipt", function()
    local gm, relay, member, invite, t = OfflineReady()
    invite.live = true; H.SetRosters(0)
    local send = StateProbe(invite)
    local fields = StateFields(relay, invite, relay.U.Tickets()[t.id])
    local probes = { { 4, 2 }, { 6, "Different Member" }, { 7, 1 }, { 8, "Different Master" },
        { 9, t.created + 1 }, { 10, 2 }, { 11, "1.777" }, { 12, "pending" }, { 13, "1.888" } }
    for _, change in ipairs(probes) do
        local bad = Copy(fields); bad[change[1]] = change[2]
        send(relay, bad)
        eq(invite.U.Tickets()[t.id].state, "proposed", "conflicting snapshot field " .. change[1] .. " changed ticket state")
    end
    invite.U.Tickets()[t.id].acceptNonce = "1.999"
    send(relay, fields)
    eq(invite.U.Tickets()[t.id].state, "proposed", "snapshot replaced existing conflicting acceptance nonce")
    eq(invite.U.Tickets()[t.id].acceptNonce, "1.999", "snapshot rewrote existing acceptance nonce")
    invite.U.Tickets()[t.id].acceptNonce = nil
    send(relay, fields)
    eq(invite.U.Tickets()[t.id].state, "ready", "valid immutable snapshot did not recover after rejection probes")
    H.SetFilter(nil)
end)

Scenario("only current native gateway may supply destination state over GUILD", function()
    local gm, relay, member, invite, t = OfflineReady()
    invite.live = true; H.SetRosters(0)
    local ordinary = H.NewClient("Ordinary Destination Member", 2, 2)
    Login(ordinary); H.Step(1)
    invite.U.Tickets()[t.id].state = "proposed"
    local send = StateProbe(invite)
    local fields = StateFields(relay, invite, relay.U.Tickets()[t.id])
    send(ordinary, fields)
    eq(invite.U.Tickets()[t.id].state, "proposed", "ordinary destination member forged ready state")
    send(gm, fields, "WHISPER")
    eq(invite.U.Tickets()[t.id].state, "proposed", "remote source gateway forged local destination state")
    send(relay, fields, "WHISPER")
    eq(invite.U.Tickets()[t.id].state, "proposed", "state snapshot accepted wrong WHISPER transport")
    relay.rankName = "Member"; H.SetRosters(0); H.Step(6)
    assert(not relay.U.CanRelay(), "revocation probe retained native Veteran relay rights")
    send(relay, fields)
    eq(invite.U.Tickets()[t.id].state, "proposed", "revoked elected endpoint forged ready state")
    H.SetFilter(nil)
end)

Scenario("destination snapshot cannot confirm source participant consent or enable leave", function()
    local gm, relay, member, invite = World(true)
    local t = Proposal(gm, member)
    member.locked = true; assert(member.U.AcceptTransfer(t.id, true))
    eq(t.state, "pending", "source participant was not waiting for confirmation")
    local fields = StateFields(relay, member, { source = t.source, id = t.id, member = t.member, dest = t.dest,
        master = t.master, created = t.created, authorityGuild = t.authorityGuild, acceptNonce = t.acceptNonce,
        state = "accepted", receiptReady = t.acceptNonce })
    local send = StateProbe(member)
    send(relay, fields, "WHISPER")
    eq(t.state, "pending", "destination state snapshot advanced source consent")
    fields[1] = member.U.guild
    send(gm, fields)
    eq(t.state, "pending", "own source gateway snapshot advanced participant consent")
    assert(not member.U.TransferConfirmed(t) and not t.confirmedNonce, "snapshot granted destination ACK proof")
    member.U.LeaveForTransfer(t.id)
    assert(not member.command, "snapshot enabled source participant to prepare guild leave")
    H.SetFilter(nil)
end)

Scenario("forged state completion controls cannot suppress authenticated catch-up retries", function()
    local gm, relay, member, invite, t = OfflineReady()
    local ordinary = H.NewClient("Ordinary Control Forger", 2, 2)
    Login(ordinary); H.Step(1)
    local requestNonce, requests, allowed = nil, 0, {}
    H.SetFilter(function(packet, receiver)
        local kind, fields = WireMessage(packet)
        if packet.from == invite and receiver == relay and kind == "TSYNC" and fields then
            requestNonce, requests = fields[4], requests + 1
        end
        if receiver == invite and kind == "TSTATE" then return allowed[packet.text:match("^([^~]+)~")] == true end
        return true
    end)
    Login(invite); assert(invite.U.TransferSyncRequest(true)); H.Step(3)
    assert(requestNonce, "fixture did not send authenticated state request")
    local function Control(sender, nonce, marker, dist, legacyFields)
        serial = serial + 1; allowed[tostring(serial)] = true
        local fields = { 2, invite.name, nonce, marker, "1.999888", "" }
        if legacyFields then for i = 6, legacyFields + 1, -1 do fields[i] = nil end end
        assert(sender.U.Queue("TSTATE", fields, dist or "GUILD",
            dist == "WHISPER" and invite.name or nil, true, false, tostring(serial)))
        H.Step(1)
    end
    local before = requests
    Control(ordinary, requestNonce, "END")
    Control(gm, requestNonce, "END", "WHISPER")
    Control(relay, requestNonce .. ".9", "END")
    Control(relay, requestNonce, "INVALID")
    Control(relay, requestNonce, "END", nil, 4)
    Control(relay, requestNonce, "END", nil, 5)
    H.Step(8)
    assert(requests > before, "forged completion ended state request retry window")
    eq(invite.U.Tickets()[t.id].state, "proposed", "forged control changed ticket state")
    H.SetFilter(nil); H.Step(120)
    eq(invite.U.Tickets()[t.id].state, "ready", "catch-up did not recover after forged completion probes")
end)

Scenario("duplicate ready snapshots are idempotent and do not repeat invitation notifications", function()
    local gm, relay, member, invite, t = OfflineReady()
    invite.live = true; H.SetRosters(0)
    local send = StateProbe(invite)
    local notifications, nativeNotify = 0, invite.U.Notify
    invite.U.Notify = function(...) notifications = notifications + 1; return nativeNotify(...) end
    local fields = StateFields(relay, invite, relay.U.Tickets()[t.id])
    send(relay, fields)
    eq(invite.U.Tickets()[t.id].state, "ready", "first valid snapshot did not recover ready")
    local recovered, initial = invite.U.Tickets()[t.id], notifications
    send(relay, fields); send(relay, fields)
    eq(invite.U.Tickets()[t.id], recovered, "duplicate snapshot replaced the bound ticket table")
    eq(notifications, initial, "duplicate ready snapshot repeated invitation notification")
    fields[12] = "accepted"
    send(relay, fields)
    eq(recovered.state, "ready", "older accepted snapshot regressed ready ticket")
    eq(notifications, initial, "stale accepted snapshot repeated ready notification")
    H.SetFilter(nil)
end)

Scenario("guildless READY reaches an uncached replacement gateway and rejects a revoked backup", function()
    local gm, endpoint, member, invite = World()
    local backup = H.NewClient("Azz Backup Veteran", 2, 4)
    local revoked = H.NewClient("Bzz Retired Veteran", 2, 4)
    for _, c in ipairs({ backup, revoked }) do
        c.officer, c.rankName, c.invitePermission = false, "Ветеран", false
    end
    local receivers = { endpoint, invite, backup, revoked }
    local function NativeRosters()
        H.SetRosters(0)
        for _, c in ipairs(receivers) do
            -- Actual native online veterans without installed addons fill the
            -- bounded contact cache ahead of both real backup addresses.
            for i = 1, 32 do
                c.rows[#c.rows + 1] = { name = string.format("AAA%02d Candidate", i), rank = 4,
                    rankName = "Ветеран", online = true, level = 35 }
            end
            assert(c.U.ReadRoster(), "large destination native roster missing")
        end
    end
    NativeRosters()
    for _, c in ipairs({ backup, revoked }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(65)
    assert(endpoint.U.IsGateway() and backup.U.Connected(), "original gateway did not retain established tenure")
    -- A fresh full roster refills the contact cap with its first thirty native
    -- candidates. Suppress optional contact gossip during this short consent
    -- window so it cannot immediately reinsert either real backup address.
    H.SetFilter(function(packet, receiver)
        return receiver ~= member or not IsKind(packet, "HELLO")
    end)
    assert(endpoint.U.PublishRoster(gm.name), "destination full roster could not be queued")
    H.Step(10)
    eq(H.Count(member.U.db.contacts), 30, "destination candidates did not fill the contact cache")
    assert(not member.U.db.contacts[backup.name] and not member.U.db.contacts[revoked.name], "real backup addresses were not outside the contact cap")
    eq(member.U.TrustedPeer(backup.name), 2, "verified roster did not authorize uncached backup")
    local t = Proposal(gm, member)
    member.U.AcceptTransfer(t.id, true); H.Step(15)
    eq(t.state, "accepted", "large-roster destination did not confirm acceptance")
    eq(t.contact, endpoint.name, "confirmation did not bind the original endpoint")
    assert(t.readyTargets and t.readyTargets[backup.name] == true and t.readyTargets[revoked.name] == true,
        "authenticated confirmation omitted live verified backups outside contacts")
    assert(not member.U.db.contacts[backup.name], "acceptance unexpectedly put backup inside contact cache")

    endpoint.live = false
    revoked.rankName = "Member"
    member.U.LeaveForTransfer(t.id); eq(member.command, "/gquit", "confirmed participant could not prepare manual leave")
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    NativeRosters()
    assert(not revoked.U.CanRelay() and not revoked.U.IsGateway(), "revoked veteran retained native relay authority")
    local ready, retiredForward = { t.id, member.name }, false
    H.SetFilter(function(packet)
        if packet.from == revoked and packet.dist == "GUILD" and packet.text:find("READY", 1, true) then retiredForward = true end
        return true
    end)
    assert(member.U.Queue("READY", ready, "WHISPER", revoked.name, true), "revocation probe could not be queued")
    H.Step(2)
    eq(revoked.U.Tickets()[t.id].state, "accepted", "revoked backup accepted direct guildless READY")
    assert(not retiredForward, "revoked backup forwarded direct guildless READY")
    assert(not revoked.U.TransferMessage("READY", ready, member.name, true, { gateway = revoked.name }), "revoked backup forged its own READY wrapper")

    -- All thirty-two earlier candidates must get their bounded retry turn.
    -- The authenticated snapshot reaches the live backup on a later rotation.
    H.Step(350)
    assert(backup.U.IsGateway() and not invite.U.IsGateway(), "replacement gateway election did not choose live veteran")
    eq(backup.U.Tickets()[t.id].state, "ready", "uncached replacement gateway never received guildless READY")
    eq(invite.U.Tickets()[t.id].state, "ready", "separate invite officer missed replacement gateway READY relay")
    invite.U.InviteTransfer(t.id); eq(invite.command, "/ginvite " .. member.name, "invite officer could not prepare command after gateway replacement")
    revoked.command = nil; revoked.U.InviteTransfer(t.id)
    assert(not revoked.command and not retiredForward, "revoked backup acquired invitation or relay authority")
    H.SetFilter(nil)
end)

Scenario("one thousand active peers remain bounded during sixty idle seconds", function()
    H.Reset()
    local c = H.NewClient("Idle Reader", 1, 2)
    H.SetRosters(0)
    local names = {}
    for i = 1, 1000 do
        names[i] = string.format("Idle Peer%04d", i)
        c.rows[#c.rows + 1] = { name = names[i], rank = 2, online = true, level = 35 }
    end
    assert(c.U.ReadRoster())
    local native, calls, peerVisits = c.E.C_GuildInfo.GuildControlGetRankFlags, 0, 0
    c.E.C_GuildInfo.GuildControlGetRankFlags = function(order) calls = calls + 1; return native(order) end
    c.E.pairs = function(t)
        local iterator, state, key = pairs(t)
        if t ~= c.U.peers then return iterator, state, key end
        return function(s, k)
            local nextKey, value = iterator(s, k)
            if nextKey ~= nil then peerVisits = peerVisits + 1 end
            return nextKey, value
        end, state, key
    end
    for _, name in ipairs(names) do c.U.Handle("HELLO", { 1, c.U.VERSION, "", "", "", 0, "0" }, "GUILD", name) end
    eq(H.Count(c.U.peers), 1000, "active peer fixture lost advertisements")
    assert(not c.E.ChillZoneUnionWindow and not c.U.GatewayName(), "idle fixture opened UI or elected an unauthorized gateway")
    H.Step(60)
    print("AUDIT idle metrics: native rank calls=" .. calls .. "; peer visits=" .. peerVisits)
    assert(calls <= 20000, "native rank permission calls grew with repeated peer scans: " .. calls)
    assert(peerVisits <= 250000, "idle election repeatedly scanned all peers: " .. peerVisits)
    assert(not c.U.GatewayName(), "ordinary active peers manufactured a gateway")
end)

local function ChatPane(c)
    c.U.OpenRoster()
    for _, frame in ipairs(c.allFrames) do if frame.frameType == "ScrollingMessageFrame" then return frame end end
    error("chat pane missing")
end
local function Visible(c, pane)
    local index = #c.U.history - pane:GetScrollOffset()
    return c.U.history[index]
end
local function Add(c, suffix, at, metadata)
    metadata = metadata or {}; metadata.id, metadata.at = "1:audit:" .. suffix, at
    metadata.status = metadata.status or "delivered"
    c.U.Chat(1, "History Author", "history " .. suffix, false, metadata)
end
Scenario("earlier HREC preserves the visible message instead of moving ten to nine", function()
    local gm, remote, member = World()
    local pane = ChatPane(member)
    for i = 1, 20 do Add(member, tostring(i), member.U.stamp() - 40 + i) end
    pane:SetScrollOffset(10)
    local anchor = Visible(member, pane)
    member.U.Handle("HREC", { 1, "History Author", "history older", "1:audit:older", member.U.stamp() - 60 }, "GUILD", gm.name, "800001")
    eq(pane:GetScrollOffset(), 10, "earlier backfill changed offset")
    eq(Visible(member, pane), anchor, "earlier history changed the visible row")
end)

Scenario("mixed history, live appends, native adoption and trimming preserve row identity", function()
    local c = LocalWorld()
    local pane = ChatPane(c)
    for i = 1, 200 do Add(c, tostring(i), c.U.stamp() - 220 + i) end
    pane:SetScrollOffset(10)
    local anchor = Visible(c, pane)
    Add(c, "old backfill", c.U.stamp() - 300, { replayed = true })
    eq(Visible(c, pane), anchor, "trimmed old backfill moved retained visible row")
    Add(c, "live append", c.U.stamp())
    eq(Visible(c, pane), anchor, "live append with trim moved retained visible row")
    Add(c, "middle backfill", anchor.time - 0.5, { replayed = true })
    eq(Visible(c, pane), anchor, "insertion before anchor moved visible row")
    local _, observed = c.U.Chat(1, "Native Author", "native adopted", true, { at = c.U.stamp() + 1, observed = true, status = "local-only" })
    pane:SetScrollOffset(1)
    anchor = Visible(c, pane)
    c.U.Chat(1, "Native Author", "native adopted", true, { id = "1:audit:native", at = c.U.stamp() - 1, nativeRelay = true, status = "delivered" })
    eq(Visible(c, pane), anchor, "native identity adoption and timestamp reorder moved another retained anchor")
    pane:SetScrollOffset(0)
    Add(c, "bottom append", c.U.stamp() + 2)
    eq(pane:GetScrollOffset(), 0, "bottom reader stopped following live chat")
end)

assert(failed == 0, "audit regressions observed: " .. failed .. "/" .. ran)
print("ALL AUDIT SCENARIOS PASSED; scenarios=" .. ran)
