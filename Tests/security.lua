-- Adversarial wire regressions. Attackers retain their actual native guild and
-- their own server-stamped character name; no trusted contacts are injected.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation harness missing from tests or packaged addon")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true), "simulation harness boundary missing")
local factory = assert(loadstring(source:sub(1, boundary - 1) .. "\n" .. [[
return { NewClient = NewClient, Step = Step, SetRosters = SetRosters, Count = Count,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    SetFilter = function(filter) deliveryFilter = filter end,
    Now = function() return time end }
]]))
local H = factory()
local failures, sequence = 0, 100000

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local officer = H.NewClient("Офицер Четвёртого", 1, 4); officer.officer = true
    local ordinary = H.NewClient("Первый Участник", 1, 1); ordinary.officer = false; ordinary.invitePermission = true
    H.SetRosters(0)
    assert(gm.U.CanRelay(officer.name) and officer.U.CanRelay(), "native officer flag at rank four is not eligible")
    assert(not gm.U.CanRelay(ordinary.name) and not ordinary.U.CanRelay(), "rank one or invitation permission was mistaken for officer status")
    ordinary.E.C_GuildInfo.IsGuildOfficer = function() return true end
    assert(not ordinary.U.CanRelay(), "self officer claim overrode the server rank permissions")
    gm.U.db.approvedRelays = { [ordinary.name] = 1 }
    assert(not gm.U.CanRelay(ordinary.name), "legacy manual grant admitted an ordinary relay")
    ordinary.U.Command("relay on " .. ordinary.name)
    assert(not ordinary.U.CanRelay(), "obsolete relay command elevated an ordinary member")
    officer.E.C_GuildInfo.GuildControlGetRankFlags = function() error("unavailable") end
    officer.E.C_GuildInfo.IsGuildOfficer = function() return false end
    assert(not officer.U.CanRelay(), "failed permission lookup fell back to rank or cached officer state")
    officer.E.C_GuildInfo.GuildControlGetRankFlags = nil
    officer.E.C_GuildInfo.IsGuildOfficer = function() return true end
    assert(not officer.U.CanRelay(), "missing rank permission API trusted only a self declaration")
    print("PASS native officer permissions, custom ranks, invitation-only members and fail-closed lookup")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local backup = H.NewClient("Запасной Чиллзон", 1, 4); backup.officer = true
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local otherBackup = H.NewClient("Запасной Навсегда", 2, 5); otherBackup.officer = true
    local member = H.NewClient("Обычный Участник", 1, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, backup, otherGM, otherBackup, member }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(not backup.U.GatewayName() and not otherBackup.U.GatewayName(), "officers invented trust before initial guild pairing")
    assert(gm.U.Link(otherGM.name), "initial guild setup rejected")
    H.Step(70)
    assert(member.U.Connected(), "ordinary reader did not learn the initial connection")
    assert(backup.U.TrustedPeer(otherBackup.name) == 2 and otherBackup.U.TrustedPeer(backup.name) == 1,
        "verified rosters did not automatically discover other-guild officers")
    assert(not otherGM.U.TrustedPeer(member.name), "ordinary roster member became a foreign relay")
    otherBackup.officer = false; H.SetRosters(0); H.Step(30)
    assert(not backup.U.TrustedPeer(otherBackup.name), "foreign officer permission revoke was not applied through roster deltas")
    otherBackup.officer = true; H.SetRosters(0); H.Step(30)
    assert(backup.U.TrustedPeer(otherBackup.name) == 2, "foreign officer permission restore did not refresh candidates")
    gm.live, otherGM.live = false, false; H.SetRosters(0); H.Step(140)
    assert(backup.U.IsGateway() and otherBackup.U.IsGateway() and member.U.Connected(),
        "officers did not pair and replace both original gateways automatically")
    assert(not next(backup.requestedLinks) and not next(otherBackup.requestedLinks), "automatic failover depended on fixture approval")
    local count = #otherBackup.U.history
    member.U.SendChat("Automatic officer failover"); H.Step(15)
    assert(#otherBackup.U.history == count + 1, "chat did not resume through automatically paired officers")
    local fresh = H.NewClient("Новый Офицер", 1, 6); fresh.officer = true
    H.SetRosters(0); fresh.U.frame.scripts.OnEvent(fresh.U.frame, "PLAYER_LOGIN"); H.Step(60)
    assert(fresh.U.Connected() and backup.U.GatewayName() == backup.name, "late officer needed manual trust sync or preempted the active bridge")
    backup.officer = false; H.SetRosters(0); H.Step(140)
    assert(not backup.U.CanRelay() and fresh.U.IsGateway() and otherBackup.U.Connected(), "officer demotion did not revoke and replace a gateway")
    fresh.officer = false; H.SetRosters(0); H.Step(100)
    assert(not member.U.GatewayName() and not member.U.Connected() and not member.U.CanRelay(), "no-officer outage elected an ordinary member")
    fresh.officer = true; H.SetRosters(0); H.Step(140)
    assert(fresh.U.Connected() and member.U.Connected(), "officer return did not restore the approved guild link")
    print("PASS automatic officer discovery, both-side failover, late installation, demotion, outage and recovery")
end
local function Check(label, vulnerable, detail)
    print((vulnerable and "VULNERABLE " or "PASS ") .. label .. " | " .. detail)
    if vulnerable then failures = failures + 1 end
end
local function SendEncoded(from, target, encoded, distribution)
    sequence = sequence + 1
    local id, size = tostring(sequence) .. ".1", 210
    local count = math.ceil(#encoded / size)
    for part = 1, count do
        local message = id .. "~" .. part .. "~" .. count .. "~" .. encoded:sub((part - 1) * size + 1, part * size)
        from.E.C_ChatInfo.SendAddonMessage(from.U.PREFIX, message, distribution or "WHISPER", target)
    end
end
local function Send(from, target, kind, fields, distribution)
    SendEncoded(from, target, "R" .. kind .. "~" .. from.U.Pack(fields), distribution)
end
local function Listen(attacker, responder)
    local buffers, received = {}, {}
    attacker.U.frame.scripts.OnEvent = function(_, event, prefix, message, distribution, stampedSender)
        if event ~= "CHAT_MSG_ADDON" and event ~= "CHAT_MSG_ADDON_LOGGED" then return end
        if prefix ~= attacker.U.PREFIX then return end
        local sender = attacker.U.Name(stampedSender)
        local id, part, count, body = message:match("^([%d%.]+)~(%d+)~(%d+)~(.*)$")
        if not id then return end
        part, count = tonumber(part), tonumber(count)
        local key = sender .. ":" .. id
        local batch = buffers[key] or { n = 0, parts = {} }; buffers[key] = batch
        if not batch.parts[part] then batch.parts[part] = body; batch.n = batch.n + 1 end
        if batch.n ~= count then return end
        buffers[key] = nil
        local encoded, raw = table.concat(batch.parts)
        if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
        elseif encoded:sub(1, 1) == "Z" then
            local zipped = attacker.U.Deflate:DecodeForWoWAddonChannel(encoded:sub(2))
            raw = zipped and attacker.U.Deflate:DecompressDeflate(zipped)
        end
        local kind, payload
        if raw then kind, payload = raw:match("^([A-Z]+)~(.*)$") end
        local fields = payload and attacker.U.Unpack(payload)
        if not fields then return end
        received[#received + 1] = { kind = kind, fields = fields, sender = sender }
        if responder then responder(kind, fields, sender) end
    end
    return received
end
local function HasHistory(c, text, author)
    for _, row in ipairs(c.U.history) do if row.text == text and (not author or row.name == author) then return true end end
    return false
end

do
    H.Reset()
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0)
    officer.rows[#officer.rows + 1] = { name = "Глава Навсегда", rank = 0, online = false, level = 60 }
    officer.U.ReadRoster()
    officer.U.frame.scripts.OnEvent(officer.U.frame, "PLAYER_LOGIN")
    assert(outsider.guild == nil and outsider.U.guild == nil and not officer.U.own[outsider.name], "outsider unexpectedly belongs to native guild roster")
    local nonce = "999.1"
    local received = Listen(outsider, function(kind, fields, sender)
        if kind == "LINK" and fields[2] == "challenge" then
            Send(outsider, sender, "LINK", { "3", "prove", 1, nonce, fields[5] })
        elseif kind == "PING" then
            Send(outsider, sender, "PONG", { 1, outsider.name, outsider.U.Pack({ outsider.name }) })
        end
    end)
    Send(outsider, officer.name, "LINK", { "3", "hello", 1, nonce, "" })
    H.Step(35)
    local trusted = officer.U.TrustedPeer(outsider.name) ~= nil
    officer.U.frame.scripts.OnEvent(officer.U.frame, "CHAT_MSG_GUILD", "PRIVATE guild-only test message", officer.name .. "-ForeverRealm")
    H.Step(12)
    local rosterLeaked, chatLeaked = false, false
    for _, packet in ipairs(received) do
        if packet.kind == "ROSTER" then rosterLeaked = true end
        if packet.kind == "CHAT" and packet.fields[3] == "PRIVATE guild-only test message" then chatLeaked = true end
    end
    Send(outsider, officer.name, "CHAT", { 1, "Невиновный Глава", "FORGED outsider author", "1:outsider:1", officer.U.stamp() })
    H.Step(5)
    local forged = HasHistory(officer, "FORGED outsider author", "Невиновный Глава")
    Check("unsolicited outsider LINK", trusted or rosterLeaked or chatLeaked or forged,
        "actualGuild=nil trusted=" .. tostring(trusted) .. " roster=" .. tostring(rosterLeaked) .. " chat=" .. tostring(chatLeaked) .. " forgedAuthor=" .. tostring(forged))
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Участник Чиллзон", 1, 2)
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member, officer }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(4)
    assert(gm.U.Link(officer.name), "legitimate guild-master setup failed")
    H.Step(50)
    assert(gm.U.Connected() and member.rank == 2 and not member.U.IsMaster(), "legitimate bridge fixture not established")
    assert(gm.U.RosterFresh(2) and not gm.U.db.rosters[2].rows["Вне Гильдии"], "author-membership test lacks a fresh verified foreign roster")
    Send(officer, gm.name, "CHAT", { 2, "Вне Гильдии", "FORGED nonexistent guild author", "2:bridge:nonmember", gm.U.stamp() })
    H.Step(2)
    Check("active approved peer author membership", HasHistory(gm, "FORGED nonexistent guild author"), "foreignRosterFresh=true nonexistentAuthorAccepted=" .. tostring(HasHistory(gm, "FORGED nonexistent guild author")))
    assert(not gm.U.TrustedPeer(outsider.name), "outsider was trusted before guild member packet")
    Send(member, nil, "CONTACT", { outsider.name, 2 }, "GUILD"); H.Step(3)
    local contactTrusted = gm.U.TrustedPeer(outsider.name) ~= nil
    Send(outsider, gm.name, "CHAT", { 2, "Невиновный Офицер", "FORGED via member CONTACT", "2:outsider:1", gm.U.stamp() })
    H.Step(5)
    local forged = HasHistory(gm, "FORGED via member CONTACT", "Невиновный Офицер")
    Check("ordinary guild member CONTACT", contactTrusted or forged,
        "nativeMemberRank=2 actualOutsiderGuild=nil trusted=" .. tostring(contactTrusted) .. " forgedAuthor=" .. tostring(forged))
    local second = H.NewClient("Другой Посторонний", nil, 2)
    Send(member, nil, "HELLO", { 1, member.U.VERSION, member.U.Pack({ second.name }), "", member.name, 0 }, "GUILD")
    H.Step(3)
    local helloTrusted = gm.U.TrustedPeer(second.name) ~= nil
    Send(second, gm.name, "CHAT", { 2, "Невиновный Офицер", "FORGED via member HELLO", "2:outsider:2", gm.U.stamp() })
    H.Step(4)
    Check("ordinary guild member HELLO contacts", helloTrusted or HasHistory(gm, "FORGED via member HELLO"),
        "nativeMemberRank=2 actualOutsiderGuild=nil trusted=" .. tostring(helloTrusted) .. " forgedAuthor=" .. tostring(HasHistory(gm, "FORGED via member HELLO")))
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Участник Чиллзон", 1, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    local raw = string.rep("A", 262144)
    local zipped = member.U.Deflate:CompressDeflate(raw, { level = 9 })
    local encoded = "Z" .. member.U.Deflate:EncodeForWoWAddonChannel(zipped)
    local inflated, original = 0, gm.U.Deflate.DecompressDeflate
    local limited, boundedCalls, boundedCap, boundedError = gm.U.Deflate.DecompressDeflateLimited, 0, nil, nil
    gm.U.Deflate.DecompressDeflate = function(self, ...)
        local result = original(self, ...)
        if result then inflated = math.max(inflated, #result) end
        return result
    end
    if limited then gm.U.Deflate.DecompressDeflateLimited = function(self, bytes, cap)
        boundedCalls, boundedCap = boundedCalls + 1, cap
        local result, status = limited(self, bytes, cap)
        boundedError = status
        if result then inflated = math.max(inflated, #result) end
        return result, status
    end end
    SendEncoded(member, nil, encoded, "GUILD"); H.Step(4)
    gm.U.Deflate.DecompressDeflate = original
    gm.U.Deflate.DecompressDeflateLimited = limited
    Check("compressed output bounded before allocation", inflated > 25000 or boundedCalls ~= 1 or boundedCap ~= 25000 or boundedError ~= -18,
        "encodedBytes=" .. #encoded .. " observedInflatedBytes=" .. inflated .. " boundedCalls=" .. boundedCalls .. " cap=" .. tostring(boundedCap) .. " status=" .. tostring(boundedError))
end

do
    H.Reset()
    local c = H.NewClient("Проверка Декодера", 1, 2)
    local D = c.U.Deflate
    assert(type(D.DecompressDeflateLimited) == "function", "bounded decoder API missing")
    for _, config in ipairs({ { level = 0 }, { level = 9, strategy = "fixed" }, { level = 9, strategy = "dynamic" } }) do
        local raw = string.rep("A", 25000)
        local compressed = D:CompressDeflate(raw, config)
        assert(D:DecompressDeflateLimited(compressed, 25000) == raw, "bounded decoder rejects valid exact-limit output")
        local result, status = D:DecompressDeflateLimited(D:CompressDeflate(raw .. "B", config), 25000)
        assert(result == nil and status == -18, "bounded decoder failed to stop output above limit")
        assert(D:DecompressDeflateLimited(compressed:sub(1, -2), 25000) == nil, "bounded decoder accepted truncated stream")
    end
    local function Stored(raw, final)
        local len = #raw; local complement = 65535 - len
        return string.char(final and 1 or 0, len % 256, math.floor(len / 256), complement % 256, math.floor(complement / 256)) .. raw
    end
    local twoBlocks = Stored(string.rep("A", 12500), false) .. Stored(string.rep("B", 12500), true)
    assert(#D:DecompressDeflateLimited(twoBlocks, 25000) == 25000, "bounded decoder lost cumulative exact-limit multi-block output")
    local result, status = D:DecompressDeflateLimited(twoBlocks .. "unused", 24999)
    assert(result == nil and status == -18, "bounded decoder reset its output budget between blocks")
    assert(D:DecompressDeflateLimited(string.char(7), 25000) == nil, "bounded decoder accepted invalid block type")
    assert(D:DecompressDeflateLimited(D:CompressDeflate(""), 0) == "", "zero-cap decoder rejects valid empty output")
    for _, cap in ipairs({ -1, 25001, 1.5, "25000" }) do
        result, status = D:DecompressDeflateLimited(D:CompressDeflate("A"), cap)
        assert(result == nil and status == -18, "bounded decoder accepted an invalid output cap")
    end
    local sharedCalls, shared = 0, { DecompressDeflate = function() return string.rep("X", 262144) end }
    local env = setmetatable({ LibStub = {
        GetLibrary = function() sharedCalls = sharedCalls + 1; return shared, 999999 end,
        NewLibrary = function() sharedCalls = sharedCalls + 1; return shared end,
    } }, { __index = _G })
    local loader, private = assert(loadfile("ChillZoneUnion/Libs/LibDeflate.lua")), {}
    setfenv(loader, env); loader("ChillZoneUnion", private)
    assert(sharedCalls == 0 and private.Deflate ~= shared and type(private.Deflate.DecompressDeflateLimited) == "function", "shared newer LibDeflate replaced private bounded decoder")
    print("PASS bounded decoder stored/fixed/dynamic limits, cumulative blocks, malformed input and private library isolation")
end

do
    H.Reset()
    local old = {
        trustSchema = 2,
        contacts = { ["Посторонний Игрок"] = { guild = 2, addon = true, approved = true, at = 1800000000 } },
        rosters = { [2] = { at = 1800000000, rows = { ["Посторонний Игрок"] = { name = "Посторонний Игрок", rank = 0, guild = 2, online = true } } } },
        approvedRelays = { ["Участник Чиллзон"] = true },
        tickets = { forged = { member = "Участник Чиллзон" } },
        announcement = { text = "untrusted old announcement", guild = 2 },
        addonPresence = { [2] = { ["Посторонний Игрок"] = { version = "0.4.6-beta", lastSeen = 1800000000 } } },
        bridgeGuildChat = false, showGuildBadge = true, memberNotices = true,
        minimapAngle = 42, chatFrameName = "Гильдия",
    }
    local c = H.NewClient("Участник Чиллзон", 1, 2, { realms = { ["ForeverRealm:Alliance"] = old } })
    assert(c.U.PREFIX == "CZUnion3" and c.U.db.trustSchema == 3, "defensive protocol/schema migration missing")
    assert(not c.U.TrustedPeer("Посторонний Игрок") and H.Count(c.U.db.contacts) == 0 and H.Count(c.U.db.rosters) == 0, "old unverified contacts or foreign roster survived migration")
    assert(H.Count(c.U.Tickets()) == 0 and c.U.db.announcement == nil and H.Count(c.U.db.addonPresence) == 0, "old foreign action/presence state survived migration")
    assert(H.Count(c.U.db.approvedRelays) == 0, "old cached ordinary relay permissions survived migration")
    assert(c.U.db.bridgeGuildChat == false and c.U.db.showGuildBadge == true and c.U.db.memberNotices == true
        and c.U.db.minimapAngle == 42 and c.U.db.chatFrameName == "Гильдия", "security migration discarded display/chat preferences")
    print("PASS legacy unverified cache migration resets trust and foreign state while preserving preferences")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Аарон Участник", 1, 2)
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member, officer }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(gm.U.GatewayName() ~= member.name and not gm.U.CanRelay(member.name), "unapproved ordinary member was elected as a relay")
    assert(gm.U.Link(officer.name), "native officer fixture could not initiate legitimate bridge")
    H.Step(55)
    assert(gm.U.Connected(), "approved bridge did not connect for relay injection fixture")
    Send(member, nil, "RELAY", { member.name, "1" }, "GUILD")
    Send(member, nil, "HELLO", { 1, member.U.VERSION, member.U.Pack({}), officer.name, member.name, 0 }, "GUILD")
    H.Step(3)
    Send(member, nil, "REMOTE", { "CHAT", member.U.Pack({ 2, officer.name, "FORGED unapproved REMOTE", "2:relay:forged", gm.U.stamp() }), officer.name }, "GUILD")
    H.Step(3)
    assert(not gm.U.CanRelay(member.name) and gm.U.GatewayName() == gm.name, "ordinary member authorized itself or preempted native officer relay")
    assert(not HasHistory(gm, "FORGED unapproved REMOTE"), "ordinary nonrelay injected a trusted REMOTE envelope")
    print("PASS native ordinary member cannot self-approve relay, steal election or inject REMOTE")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local backup = H.NewClient("Связной Чиллзон", 1, 4); backup.officer = true
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local otherBackup = H.NewClient("Связной Навсегда", 2, 5); otherBackup.officer = true
    H.SetRosters(0)
    for _, c in ipairs({ gm, backup, otherGM, otherBackup }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(gm.U.Link(otherGM.name), "native officers could not approve initial bridge")
    H.Step(55)
    assert(backup.U.CanRelay() and otherBackup.U.CanRelay(), "native officers did not become automatic backup candidates")
    gm.live, otherGM.live = false, false; H.SetRosters(0); H.Step(150)
    assert(backup.U.GatewayName() == backup.name and otherBackup.U.GatewayName() == otherBackup.name
        and backup.U.Connected() and otherBackup.U.Connected(), "officer backups could not maintain union after original leaders logged out")
    assert(not backup.U.IsMaster() and not backup.U.CanInvite() and not otherBackup.U.IsMaster(), "relay approval granted unrelated native guild powers")
    local unused = H.NewClient("Аарон Новый", 1, 2)
    H.SetRosters(0); unused.U.frame.scripts.OnEvent(unused.U.frame, "PLAYER_LOGIN"); H.Step(35)
    assert(backup.U.GatewayName() == backup.name and backup.U.Connected(), "new alphabetically earlier member displaced working officer relay")
    local fresh = H.NewClient("Новый Участник", 1, 2)
    H.SetRosters(0); fresh.U.frame.scripts.OnEvent(fresh.U.frame, "PLAYER_LOGIN"); H.Step(25)
    assert(fresh.U.CanRelay(backup.name) and fresh.U.Connected(), "native officer heartbeat did not automatically connect a fresh reader")
    gm.live = true; H.SetRosters(0)
    assert(gm.U.ShareTrust() and not fresh.U.ShareTrust(), "trust sharing is not restricted to native guild officers")
    H.Step(5); backup.U.SayHello(); H.Step(50)
    assert(fresh.U.TrustedPeer(otherBackup.name) == 2 and fresh.U.CanRelay(backup.name) and fresh.U.Connected(), "native officer settings did not bootstrap fresh client to already paired relay")
    otherBackup.U.SendChat("Verified trust sync shared chat"); H.Step(12)
    assert(HasHistory(fresh, "Verified trust sync shared chat"), "fresh client cannot read normal shared chat after officer trust sync")
    fresh.U.OpenSettings()
    assert(fresh.U.linkApprovalControls.share.enabled == false, "ordinary member can click officer trust-sharing control")
    Send(fresh, nil, "RELAYSET", { 1, fresh.U.Pack({ fresh.name }) }, "GUILD"); H.Step(2)
    assert(not gm.U.CanRelay(fresh.name), "ordinary member replaced authoritative relay grant set")
    for _, fields in ipairs({
        { 1, gm.U.Pack({ fresh.name }) },
        { 2, gm.U.Pack({ fresh.name }) },
        { 1, gm.U.Pack({ fresh.name, fresh.name }) },
    }) do
        Send(gm, nil, "RELAYSET", fields, "GUILD"); H.Step(2)
        assert(not fresh.U.CanRelay() and fresh.U.CanRelay(backup.name), "legacy officer relay set overrode native permissions")
    end
    Send(gm, nil, "RELAY", { fresh.name, "1" }, "GUILD"); H.Step(3)
    assert(not fresh.U.CanRelay(), "legacy native-officer relay grant enabled an ordinary member")
    backup.officer = false; H.SetRosters(0); H.Step(5)
    assert(not fresh.U.CanRelay(backup.name), "native permission revocation retained an officer backup")
    print("PASS automatic officer backups, fresh readers, shared chat and rejection of all legacy relay grants")
end

do
    H.Reset()
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0); officer.U.frame.scripts.OnEvent(officer.U.frame, "PLAYER_LOGIN")
    Send(outsider, officer.name, "LINK", { "3", "hello", 1, "888.1", "" }); H.Step(2)
    local request = officer.U.PendingLink()
    assert(request and request.name == outsider.name and not officer.U.TrustedPeer(outsider.name), "unverified inbound request was not held pending explicit officer action")
    officer.U.OpenSettings()
    local controls, input = officer.U.linkApprovalControls
    for _, frame in ipairs(officer.allFrames) do if frame.frameType == "EditBox" and frame.width == 350 then input = frame end end
    assert(controls.accept.enabled and controls.info:GetText():find(outsider.name, 1, true)
        and controls.info:GetText():find("не проверена", 1, true), "approval UI did not identify unverified requester and claimed guild")
    input:SetText("Другой Персонаж"); input.scripts.OnTextChanged(input, true)
    local recorded, actualAccept = nil, officer.U.AcceptLink
    officer.U.AcceptLink = function(name) recorded = name; return false end
    controls.accept.scripts.OnClick(controls.accept)
    assert(recorded == outsider.name, "approval button used editable connection input instead of captured requester")
    local staleCallback = controls.accept.scripts.OnClick
    officer.U.DeclineLink(outsider.name); H.Step(1)
    Send(outsider, officer.name, "LINK", { "3", "hello", 1, "888.2", "" }); H.Step(2)
    recorded = nil; staleCallback()
    assert(recorded == nil, "stale approval button authorized a replacement inbound request")
    officer.U.Refresh()
    local currentCallback = controls.accept.scripts.OnClick
    officer.rank = 2; officer.U.own[officer.name].rank = 2
    recorded = nil; currentCallback()
    assert(recorded == nil, "approval button retained authority after native officer demotion")
    assert(not controls.accept:IsShown() and not controls.decline:IsShown(), "ordinary member can still see trust approval controls")
    officer.U.AcceptLink = actualAccept
    print("PASS explicit approval UI captures unverified requester and rejects edited, replaced or demoted authorization")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    H.SetRosters(0)
    for i = 1, 33 do gm.rows[#gm.rows + 1] = { name = "Резерв" .. i .. " Участник", rank = 2, online = false, level = 20 } end
    gm.U.ReadRoster()
    gm.U.db.approvedRelays = {}
    for i = 1, 33 do
        local name = "Резерв" .. i .. " Участник"
        gm.U.db.approvedRelays[name] = 1
        assert(not gm.U.CanRelay(name), "legacy cached ordinary grant became an automatic officer")
    end
    assert(gm.U.AuthorizeRelay == nil, "manual relay authorization is still exposed")
    print("PASS legacy manual grants cannot enable ordinary members")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local relay = H.NewClient("Персонаж Связной", 1, 4); relay.officer = true
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ gm, relay, otherGM }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(relay.U.CanRelay(), "native officer not eligible in source guild")
    relay.officer = false
    relay.guild = 2; relay.U.frame.scripts.OnEvent(relay.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(3)
    assert(relay.U.guild == 2 and not relay.U.CanRelay(), "character inherited old guild's relay grant after moving to other guild")
    relay.officer = true; H.SetRosters(0)
    assert(relay.U.CanRelay(), "destination native officer rights did not enable the new guild's officer")
    print("PASS relay eligibility follows current guild permissions rather than old guild grants")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ gm, otherGM }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name), "officer-alt fixture could not establish original pair"); H.Step(55)
    local alt = H.NewClient("Другой Офицер", 1, 1, gm.E.ChillZoneUnionDB)
    H.SetRosters(0); alt.U.frame.scripts.OnEvent(alt.U.frame, "PLAYER_LOGIN"); H.Step(30)
    assert(otherGM.U.TrustedPeer(alt.name) == 1, "new officer was not discovered through the established link")
    local contact = alt.U.db.contacts[otherGM.name]
    assert(alt.U.db == gm.U.db and contact.pairedBy[gm.name] == true and not contact.pairedBy[alt.name], "per-character pairing fixture does not share cache without sharing proof")
    assert(alt.U.CanRelay() and alt.U.GatewayName() ~= alt.name, "new officer preempted the active original gateway")
    gm.live = false; H.SetRosters(0); H.Step(100)
    assert(alt.U.IsGateway() and alt.U.Connected(), "native officer alt needed separate manual pairing")
    assert(not next(alt.requestedLinks), "officer alt required manual fixture approval")
    print("PASS verified officer alt reuses approved guild contacts automatically")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local backup = H.NewClient("Яков Связной", 1, 4); backup.officer = true
    local otherBackup = H.NewClient("Яков Навсегда", 2, 5); otherBackup.officer = true
    H.SetRosters(0)
    for _, c in ipairs({ gm, otherGM, backup, otherBackup }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name)); H.Step(70)
    assert(gm.U.RosterFresh(2) and gm.U.db.rosters[2].verified, "candidate cache fixture lacks an authenticated roster")
    gm.U.db.contacts[otherBackup.name] = nil
    assert(gm.U.TrustedPeer(otherBackup.name) == 2, "bounded contact cache hid a roster-verified officer")
    assert(not gm.U.RowUnpack(gm.U.Pack({ "Игрок Тест", 4, "Офицер", 20, "PRIEST", "", "1", "true" }), 2), "malformed officer permission flag was accepted")
    local saved, otherSaved = backup.E.ChillZoneUnionDB, otherBackup.E.ChillZoneUnionDB
    H.Reset()
    local restored = H.NewClient(backup.name, 1, 4, saved); restored.officer = true
    local otherRestored = H.NewClient(otherBackup.name, 2, 5, otherSaved); otherRestored.officer = true
    H.SetRosters(0)
    for _, c in ipairs({ restored, otherRestored }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(150)
    assert(restored.U.Connected() and otherRestored.U.Connected(), "saved approved guild link did not recover after both officer clients reloaded")
    assert(not next(restored.requestedLinks) and not next(otherRestored.requestedLinks), "cold recovery required a manual request")
    print("PASS roster-verified officers outside the probe cache, strict role schema and both-side cold recovery")
end

do
    H.Reset()
    local officer = H.NewClient("Офицер С Очередью", 1, 4); officer.officer = true
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    assert(officer.U.Link(otherGM.name), "officer could not queue setup before demotion")
    officer.officer = false; H.SetRosters(0)
    local sentHandshake = false
    H.SetFilter(function(packet)
        if packet.from == officer and packet.dist == "WHISPER" and packet.text:find("~RLINK~", 1, true) then sentHandshake = true end
        return true
    end)
    H.Step(8)
    assert(not sentHandshake and not otherGM.U.PendingLink(), "queued officer handshake survived native permission revocation")
    print("PASS queued setup is discarded after native officer demotion")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local veteran = H.NewClient("Настоящий Ветеран", 1, 4); veteran.officer = false; veteran.rankName = "Ветеран"; veteran.invitePermission = false
    local ordinary = H.NewClient("Обычный Участник", 1, 2); ordinary.officer = false
    local honorary = H.NewClient("Почётный Участник", 1, 5); honorary.officer = false; honorary.rankName = "Почётный ветеран"
    H.SetRosters(0)
    assert(veteran.U.CanRelay() and gm.U.CanRelay(veteran.name) and not veteran.U.IsOfficer() and not veteran.U.CanInvite(), "real nonofficer veteran did not become relay independently of invitation rights")
    assert(not ordinary.U.CanRelay() and not honorary.U.CanRelay(), "ordinary or similarly named rank became a veteran relay")
    assert(gm.U.IsVeteranRankName("  ВЕТЕРАН  ") and not gm.U.IsVeteranRankName("Ветераны") and not gm.U.IsVeteranRankName("Почётный ветеран"), "veteran recognition does not use exact trimmed case-insensitive rank name")
    assert(not veteran.U.IsTrustOfficer() and not veteran.U.CanStartLink("Неизвестный Связной") and not veteran.U.Link("Неизвестный Связной") and not veteran.U.ShareTrust(), "veteran acquired first-link or trust administration rights")
    veteran.U.OpenSettings()
    assert(not veteran.U.linkApprovalControls.accept:IsShown() and veteran.U.linkApprovalControls.share.enabled == false, "veteran can operate native-officer approval controls")
    print("PASS exact native veteran rank eligibility without officer, invitation or bootstrap administration rights")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local veteran = H.NewClient("Ветеран Чиллзон", 1, 4); veteran.officer = false; veteran.rankName = "Ветеран"
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local otherVeteran = H.NewClient("Ветеран Навсегда", 2, 5); otherVeteran.officer = false; otherVeteran.rankName = "Ветеран"
    local reader = H.NewClient("Участник Чиллзон", 1, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, veteran, otherGM, otherVeteran, reader }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name)); H.Step(70)
    assert(veteran.U.TrustedPeer(otherVeteran.name) == 2 and otherVeteran.U.TrustedPeer(veteran.name) == 1, "verified union rosters did not discover nonofficer veteran counterparts")
    gm.live, otherGM.live = false, false; H.SetRosters(0); H.Step(140)
    assert(veteran.U.IsGateway() and otherVeteran.U.IsGateway() and reader.U.Connected(), "veterans did not replace both officer gateways automatically")
    assert(not next(veteran.requestedLinks) and not next(otherVeteran.requestedLinks), "veteran failover depended on fixture Link approval")
    reader.U.SendChat("Shared chat through real veterans"); H.Step(12)
    assert(HasHistory(otherVeteran, "Shared chat through real veterans"), "shared chat did not resume through nonofficer veteran gateways")
    local fresh = H.NewClient("Новый Читатель", 1, 2)
    H.SetRosters(0); fresh.U.frame.scripts.OnEvent(fresh.U.frame, "PLAYER_LOGIN"); H.Step(30)
    assert(not fresh.U.Connected() and not fresh.U.TrustedPeer(otherVeteran.name), "veteran-only heartbeats created first trust for a fresh client without native-officer anchor")
    gm.live = true; H.SetRosters(0); assert(gm.U.ShareTrust()); H.Step(5)
    veteran.U.SayHello(); H.Step(45)
    assert(fresh.U.Connected() and fresh.U.TrustedPeer(otherVeteran.name) == 2, "native-officer anchor did not bootstrap fresh reader to already running veteran relays")
    gm.live = false; H.SetRosters(0); H.Step(80)
    otherVeteran.U.SendChat("Fresh reader after native anchor leaves"); H.Step(12)
    assert(HasHistory(fresh, "Fresh reader after native anchor leaves"), "fresh anchored client lost shared chat when only veterans remained online")
    veteran.rankName = "Участник"; H.SetRosters(0); H.Step(100)
    assert(not veteran.U.CanRelay() and not veteran.U.IsGateway() and not reader.U.Connected(), "demoted nonofficer veteran kept operating as gateway")
    veteran.rankName = "Ветеран"; H.SetRosters(0); H.Step(140)
    assert(veteran.U.Connected() and reader.U.Connected(), "restored veteran rank did not resume approved union connection")
    print("PASS both-side veteran failover, veteran-only reader anchoring, demotion and automatic return")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local staleOfficer = H.NewClient("Офицер Со Старым Кэшем", 1, 1)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local veteran = H.NewClient("Ветеран Навсегда", 2, 4); veteran.officer = false; veteran.rankName = "Ветеран"
    H.SetRosters(0)
    for _, c in ipairs({ gm, staleOfficer, otherGM, veteran }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name)); H.Step(70)
    assert(gm.U.TrustedPeer(veteran.name) == 2 and staleOfficer.U.db.contacts[veteran.name], "stale-endorsement fixture never discovered veteran")
    staleOfficer.live = false
    veteran.rankName = "Участник"; H.SetRosters(0); H.Step(30)
    assert(gm.U.RosterFresh(2) and not gm.U.TrustedPeer(veteran.name), "verified remote veteran revocation did not remove trust")
    assert(staleOfficer.U.db.contacts[veteran.name], "offline native officer did not retain deliberately stale cache")
    local sentStale = false
    H.SetFilter(function(packet)
        if packet.from == staleOfficer and packet.dist == "GUILD" and packet.text:find(veteran.name, 1, true) then sentStale = true end
        return true
    end)
    staleOfficer.live = true; H.SetRosters(0)
    assert(staleOfficer.U.ShareTrust()); staleOfficer.U.SayHello(); H.Step(4)
    assert(sentStale, "stale native-officer endorsement was not delivered over the wire")
    assert(not gm.U.TrustedPeer(veteran.name) and not gm.U.db.contacts[veteran.name], "stale native-officer HELLO/CONTACT overrode fresh verified veteran revocation")
    H.SetFilter(nil)
    print("PASS fresh verified veteran revocation defeats stale native-officer contact gossip")
end

do
    H.Reset()
    local actor = H.NewClient("Офицер С Очередью", 1, 4); actor.officer = true
    local target = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    assert(actor.U.Link(target.name), "native officer could not queue first setup before veteran demotion")
    actor.officer = false; actor.rankName = "Ветеран"; H.SetRosters(0)
    assert(actor.U.CanRelay() and not actor.U.CanStartLink(target.name), "queued-link fixture did not retain veteran relay but lose bootstrap authority")
    local sent = false
    H.SetFilter(function(packet) if packet.from == actor and packet.text:find("~RLINK~", 1, true) then sent = true end; return true end)
    H.Step(8)
    assert(not sent and not target.U.PendingLink(), "queued first LINK escaped after native officer became a nonadmin veteran")
    H.SetFilter(nil)
    H.Reset()
    actor = H.NewClient("Офицер Затем Ветеран", 1, 4); actor.officer = true
    target = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ actor, target }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(actor.U.Link(target.name)); H.Step(60)
    actor.officer = false; actor.rankName = "Ветеран"; H.SetRosters(0); H.Step(20)
    assert(actor.U.CanRelay() and actor.U.CanStartLink(target.name), "known approved counterpart became unavailable to a legitimate veteran")
    assert(actor.U.Link(target.name)); actor.requestedLinks = {}; H.Step(35)
    assert(actor.U.Connected(), "veteran could not reconnect a known approved counterpart without new administrative approval")
    print("PASS late queued bootstrap permission guard preserves eligible veteran reconnection")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Первая", 1, 0)
    local otherGM = H.NewClient("Глава Вторая", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ gm, otherGM }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name)); H.Step(55)
    local switched, setRemote = false, otherGM.U.SetRemote
    otherGM.U.SetRemote = function(name, paired)
        local accepted = setRemote(name, paired)
        if otherGM.U.remote and otherGM.U.remote.name ~= gm.name then switched = true end
        return accepted
    end
    local alt = H.NewClient("Аарон Новый", 1, 4, gm.E.ChillZoneUnionDB); alt.officer = true
    H.SetRosters(0); alt.U.frame.scripts.OnEvent(alt.U.frame, "PLAYER_LOGIN")
    alt.locked = true; H.Step(8); alt.locked = false; H.Step(30)
    assert(not switched and otherGM.U.remote.name == gm.name and gm.U.GatewayName() == gm.name, "queued stale PING transiently stole an established remote even though final election recovered")
    print("PASS delayed candidate PING never transiently preempts an established gateway")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local remote = H.NewClient("Яков Глава Навсегда", 2, 0)
    local function AddRemoteVeterans()
        for i = 1, 32 do remote.rows[#remote.rows + 1] = { name = string.format("AAA%02d Ветеран", i), rank = 4, rankName = "Ветеран", online = true, level = 20 } end
        assert(remote.U.ReadRoster())
    end
    H.SetRosters(0); AddRemoteVeterans()
    for _, c in ipairs({ gm, remote }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(remote.name)); H.Step(70)
    assert(remote.U.PublishRoster(gm.name))
    for _ = 1, 25 do H.Step(0.2); if not gm.U.db.contacts[remote.name] then break end end
    assert(not gm.U.db.contacts[remote.name] and H.Count(gm.U.db.contacts) == 30 and gm.U.TrustedPeer(remote.name) == 2,
        "large-candidate fixture did not evict active foreign endpoint while retaining verified-roster trust")
    local fresh = H.NewClient("Новый Читатель Большой Гильдии", 1, 2)
    H.SetRosters(0); AddRemoteVeterans(); fresh.U.frame.scripts.OnEvent(fresh.U.frame, "PLAYER_LOGIN")
    local advertised, queue = nil, gm.U.Queue
    gm.U.Queue = function(kind, fields, ...)
        if kind == "HELLO" and not advertised then advertised = gm.U.Unpack(fields[3]) end
        return queue(kind, fields, ...)
    end
    assert(gm.U.SayHello())
    assert(advertised and advertised[1] == remote.name and #advertised <= 3, "native officer HELLO omitted its active verified endpoint outside the 30-contact cache")
    local seen = {}; for _, name in ipairs(advertised) do assert(not seen[name], "active endpoint appeared twice in bounded HELLO contacts"); seen[name] = true end
    H.Step(8)
    assert(fresh.U.TrustedPeer(remote.name) == 2 and fresh.U.Connected(), "fresh reader did not connect using first native-officer active-endpoint advertisement")
    gm.rank, gm.officer, gm.rankName = 4, false, "Ветеран"
    local unanchored = H.NewClient("Ещё Новый Читатель", 1, 2)
    H.SetRosters(0); AddRemoteVeterans(); unanchored.U.frame.scripts.OnEvent(unanchored.U.frame, "PLAYER_LOGIN")
    assert(gm.U.CanRelay() and not gm.U.IsTrustOfficer()); gm.U.SayHello(); H.Step(8)
    assert(not unanchored.U.TrustedPeer(remote.name) and not unanchored.U.Connected(), "active-endpoint advertisement from veteran created an unauthorized first trust anchor")
    print("PASS active verified endpoint survives bounded HELLO advertisement without granting veteran bootstrap authority")
end

do
    H.Reset()
    local gm = H.NewClient("Яков Чиллзон", 1, 0)
    local otherGM = H.NewClient("Яков Навсегда", 2, 0)
    local veteran = H.NewClient("Ярослав Чиллзон", 1, 4); veteran.officer = false; veteran.rankName = "Ветеран"
    local otherVeteran = H.NewClient("Ярослав Навсегда", 2, 5); otherVeteran.officer = false; otherVeteran.rankName = "Ветеран"
    local players = { gm, otherGM, veteran, otherVeteran }
    local leaders = { [1] = gm.name, [2] = otherGM.name }
    local function DummyName(i, guild) return string.format("AAA%02d Ветеран%d", i, guild) end
    local function NativeRoster(cold)
        H.SetRosters(0)
        for _, c in ipairs(players) do
            for i = 1, 32 do c.rows[#c.rows + 1] = { name = DummyName(i, c.guild), rank = c.guild == 1 and 4 or 5, rankName = "Ветеран", online = true, level = 35 } end
            if cold then c.rows[#c.rows + 1] = { name = leaders[c.guild], rank = 0, rankName = "Глава", online = false, level = 60 } end
            assert(c.U.ReadRoster())
        end
    end
    local function Copy(value)
        if type(value) ~= "table" then return value end
        local result = {}; for key, item in pairs(value) do result[key] = Copy(item) end; return result
    end
    NativeRoster(false)
    for _, c in ipairs(players) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name)); H.Step(70)
    for change = 1, 34 do
        for _, c in ipairs(players) do
            for _, row in ipairs(c.rows) do if row.name == DummyName(1, c.guild) then row.level = 35 + change % 10 end end
            c.U.frame.scripts.OnEvent(c.U.frame, "GUILD_ROSTER_UPDATE")
        end
        H.Step(6)
    end
    assert(H.Count(veteran.U.db.contacts) == 30 and H.Count(otherVeteran.U.db.contacts) == 30
        and not veteran.U.db.contacts[otherVeteran.name] and not otherVeteran.U.db.contacts[veteran.name], "large-guild failover fixture did not evict both real backup addresses")
    assert(veteran.U.TrustedPeer(otherVeteran.name) == 2 and otherVeteran.U.TrustedPeer(veteran.name) == 1, "verified role roster no longer authorizes real backups outside contact cache")
    local saved, otherSaved = Copy(veteran.E.ChillZoneUnionDB), Copy(otherVeteran.E.ChillZoneUnionDB)
    gm.live, otherGM.live = false, false; NativeRoster(false); H.Step(180)
    assert(veteran.U.Connected() and otherVeteran.U.Connected(), "both real veteran backups failed to reconnect behind thirty online non-addon candidates")

    -- A separate cold start retains authenticated trust but has no optional
    -- version-display history, so fairness cannot depend on known-addon priority.
    saved.realms["ForeverRealm:Alliance"].addonPresence = {}
    otherSaved.realms["ForeverRealm:Alliance"].addonPresence = {}
    H.Reset()
    veteran = H.NewClient("Ярослав Чиллзон", 1, 4, saved); veteran.officer = false; veteran.rankName = "Ветеран"
    otherVeteran = H.NewClient("Ярослав Навсегда", 2, 5, otherSaved); otherVeteran.officer = false; otherVeteran.rankName = "Ветеран"
    players = { veteran, otherVeteran }; NativeRoster(true)
    local began, firstReal, queues = H.Now(), {}, {}
    for _, c in ipairs(players) do
        local sender, queue = c.E.C_ChatInfo.SendAddonMessage, c.U.Queue
        queues[c.name] = {}
        c.E.C_ChatInfo.SendAddonMessage = function(prefix, message, distribution, target)
            if distribution == "WHISPER" and message:find("~RPING~", 1, true) and (target == veteran.name or target == otherVeteran.name) then
                firstReal[c.name] = firstReal[c.name] or H.Now() - began
            end
            return sender(prefix, message, distribution, target)
        end
        c.U.Queue = function(kind, fields, distribution, target, ...)
            local result = queue(kind, fields, distribution, target, ...)
            if result and kind == "PING" then queues[c.name][#queues[c.name] + 1] = H.Now() end
            return result
        end
        c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
    end
    H.Step(180)
    assert(veteran.U.Connected() and otherVeteran.U.Connected(), "unknown-version cold backup pool starved real eligible endpoints")
    local delayed = false
    for _, c in ipairs(players) do
        if firstReal[c.name] then
            assert(firstReal[c.name] < 180, "real cold backup was not probed within the recovery budget")
            if firstReal[c.name] >= 60 then delayed = true end
        end
        local attempts = queues[c.name]
        for i = 1, #attempts do
            local count = 0
            for j = i, #attempts do if attempts[j] - attempts[i] < 14.999 then count = count + 1 end end
            assert(count <= 3, "large candidate recovery exceeded three queued probes per fifteen seconds")
        end
    end
    assert(delayed, "unknown-version fairness fixture did not exercise candidates beyond the first minute of probes")
    print("PASS both-side veteran recovery outside contact cap, fair unknown-candidate rotation and unchanged probe budget; firstReal="
        .. tostring(firstReal[veteran.name]) .. "/" .. tostring(firstReal[otherVeteran.name]))
end

assert(failures == 0, "security regressions observed: " .. failures)
print("ALL SECURITY SCENARIOS PASSED")
