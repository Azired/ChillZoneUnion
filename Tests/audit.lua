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
local function IsKind(packet, kind) return packet.text:find("~R" .. kind .. "~", 1, true) ~= nil end
local function Has(c, text)
    local count = 0
    for _, row in ipairs(c.U.history) do if row.text == text then count = count + 1 end end
    return count
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
