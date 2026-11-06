-- First-connection regressions against the real network and UI modules. The
-- shared fixture supplies native guild authority and frame primitives only.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation fixture missing")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true))
source = source:sub(1, boundary - 1)
source = source:gsub('loadfile%("ChillZoneUnion/" %.%. module%)',
    'loadfile((CZU_ONBOARDING_SOURCE_ROOT or os.getenv("CZU_ONBOARDING_SOURCE_ROOT") or "ChillZoneUnion/") .. module)')
source = source:gsub("    local U = {}", [[
    -- Model the actual secure post-hook instead of calling a UI callback
    -- directly: a displayed addon hyperlink must reach the registered hook.
    E.SetItemRef = function(link)
        local kind = type(link) == "string" and link:match("^([^:]+):")
        assert(kind == "addon" or kind == "item" or kind == "spell" or kind == "player",
            "native item-ref dispatcher rejected an unknown hyperlink type")
        c.lastItemRef = link
    end
    E.hooksecurefunc = function(name, hook)
        assert(type(name) == "string" and type(hook) == "function", "bad secure hook")
        local original = E[name]
        assert(type(original) == "function", "secure hook requires an existing function")
        E[name] = function(...) original(...); hook(...) end
    end
    local U = {}]])
local H = assert(loadstring(source .. "\n" .. [[
return { NewClient = NewClient, Step = Step, SetRosters = SetRosters,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    Advance = function(seconds) time = time + seconds end,
    RunUIUpdates = RunUIUpdates, FrameVisible = FrameVisible,
    ProtectedCalls = function() return protectedCalls end }
]]))()
local failed, ran, sequence = 0, 0, 950000
local function eq(a, b, message) assert(a == b, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Scenario(name, run)
    ran = ran + 1
    local ok, reason = pcall(run)
    if ok then print("PASS onboarding: " .. name)
    else failed = failed + 1; print("FAIL onboarding: " .. name .. ": " .. tostring(reason)) end
end
local function Event(c, name, ...) c.U.frame.scripts.OnEvent(c.U.frame, name, ...) end
local function World(rank, options)
    H.Reset()
    options = options or {}
    local c = H.NewClient(options.name or "Receiving Officer", 1, rank or 0)
    if options.officer ~= nil then c.officer = options.officer end
    if options.veteran then c.officer, c.rankName = false, "Ветеран" end
    local other = H.NewClient("External Officer", 2, 0)
    H.SetRosters(0)
    Event(c, "PLAYER_LOGIN")
    return c, other
end
local function RawLink(c, sender, nonce, mode, challenge)
    local payload = "RLINK~" .. c.U.Pack({ "3", mode or "hello", 2, nonce or "1234.1", challenge or "" })
    sequence = sequence + 1
    local count = math.ceil(#payload / 210)
    for part = 1, count do
        c.U.Receive(c.U.PREFIX, sequence .. "~" .. part .. "~" .. count .. "~" .. payload:sub((part - 1) * 210 + 1, part * 210),
            "WHISPER", sender.name .. "-ForeverRealm")
    end
end
local function Window(c) return c.E.ChillZoneUnionWindow end
local function IsPage(c, id)
    local tab = c.E["ChillZoneUnionWindowTab" .. id]
    return Window(c) and Window(c):IsShown() and tab and tab.nativeTabSelected == true
end
local function Click(frame)
    assert(frame and frame:IsEnabled() and frame.scripts.OnClick, "missing or disabled UI action")
    frame.scripts.OnClick(frame, "LeftButton")
end
local function LogCount(c, needle)
    local n = 0
    for _, line in ipairs(c.log) do if line:find(needle, 1, true) then n = n + 1 end end
    return n
end
local NOTICE_PREFIX = "addon:ChillZoneUnion:connection:"
local function NoticeHref(c, sender)
    local text = "Запрос соединения от " .. c.U.SafeDisplay(sender.name) .. " — "
    for i = #c.log, 1, -1 do
        local line = c.log[i]
        if line:find(text, 1, true) then return assert(line:match("|H([^|]+)|h"), "request notice has no hyperlink") end
    end
    error("request notice missing for " .. sender.name)
end
local function HexName(name)
    return (name:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
local function OpenNotice(c, sender)
    c.E.SetItemRef(NoticeHref(c, sender), "[Открыть]", "LeftButton")
end
local function AssertSelected(c, sender, nonce)
    local selected = assert(c.U.PendingLink(), "selected request missing")
    eq(selected.name, sender.name, "wrong request is selected")
    if nonce then eq(selected.nonce, nonce, "selected request nonce changed") end
    local view = c.U.ConnectionView()
    eq(view.pendingName, sender.name, "heading describes another request")
    local controls = assert(c.U.linkApprovalControls, "approval controls missing")
    assert(controls.info:GetText():find(c.U.SafeDisplay(sender.name), 1, true), "approval card describes another sender")
    assert(Window(c).czuSetupProgress:GetText():find(c.U.SafeDisplay(sender.name), 1, true),
        "connection status above the card describes another sender")
    assert(controls.accept:IsEnabled() and controls.decline:IsEnabled(), "selected request actions are unavailable")
    assert(not c.U.TrustedPeer(sender.name), "opening a notice approved its sender")
end
local function VisibleText(c, needle)
    for _, frame in ipairs(c.allFrames) do
        if H.FrameVisible(frame) then
            if type(frame.text) == "string" and frame.text:find(needle, 1, true) then return true end
            for _, label in ipairs(frame.fontStrings or {}) do
                if H.FrameVisible(label) and type(label.text) == "string" and label.text:find(needle, 1, true) then return true end
            end
        end
    end
    return false
end
local function PendingMark(c)
    local mark = c.U.minimapButton and c.U.minimapButton.pendingMark
    return mark and H.FrameVisible(mark) and mark:GetText() == "!" or false
end
local function AssertNoExternalTrust(c, sender)
    assert(not c.U.TrustedPeer(sender.name), "unsolicited request gained relay trust")
    local contact = c.U.db.contacts[sender.name]
    assert(not contact or contact.approved ~= true, "displayed request approved the external endpoint")
end

Scenario("closed-window incoming request is visible and remains untrusted", function()
    local c, sender = World(4, { officer = true })
    assert(not Window(c) or not Window(c):IsShown(), "unrelated officer window opened automatically")
    RawLink(c, sender)
    assert(c.U.PendingLink(), "manual request not retained")
    local view = c.U.ConnectionView()
    eq(view.stage, "pending", "pending view stage")
    eq(view.pendingName, sender.name, "pending view identity")
    assert(view.heading:find("подтверж", 1, true), "header does not call for manual confirmation")
    eq(LogCount(c, "|Haddon:ChillZoneUnion:connection:"), 1, "incoming request notice count")
    assert(PendingMark(c), "closed window has no temporary minimap marker")
    AssertNoExternalTrust(c, sender)
    assert(not Window(c) or not Window(c):IsShown(), "incoming stranger forced a modal window")
end)

Scenario("retrying the same request does not spam notices or grant approval", function()
    local c, sender = World()
    RawLink(c, sender, "1234.2")
    local n = LogCount(c, "|Haddon:ChillZoneUnion:connection:")
    for _ = 1, 6 do H.Advance(1); RawLink(c, sender, "1234.2") end
    eq(n, 1, "initial notice not emitted")
    eq(LogCount(c, "|Haddon:ChillZoneUnion:connection:"), n, "transport retries produced repeated notices")
    AssertNoExternalTrust(c, sender)
end)

Scenario("notice hyperlink opens approval without accepting it", function()
    local c, sender = World()
    RawLink(c, sender, "1234.3")
    for _, link in ipairs({ "item:123", "spell:456", "player:External Officer" }) do
        c.E.SetItemRef(link, "[Штатная ссылка]", "LeftButton")
        eq(c.lastItemRef, link, "connection hook replaced the native item-ref dispatcher")
        assert(not Window(c) or not Window(c):IsShown(), "ordinary native link opened connection setup")
    end
    local href = NoticeHref(c, sender)
    eq(href, NOTICE_PREFIX .. HexName(sender.name) .. ":1234.3", "notice is not bound to the sender and request nonce")
    c.E.SetItemRef(href, "[Открыть]", "LeftButton")
    assert(IsPage(c, 4), "notice hyperlink did not open the connection tab")
    local controls = c.U.linkApprovalControls
    assert(controls and controls.accept:IsEnabled() and controls.decline:IsEnabled(), "pending actions absent")
    assert(c.E.ChillZoneUnionWindowTab4:GetText():find("!", 1, true), "connection tab does not mark pending request")
    AssertNoExternalTrust(c, sender)
end)

Scenario("clicking the second notice selects its card and affects only that request", function()
    for _, action in ipairs({ "accept", "decline" }) do
        local c, a = World(4, { officer = true })
        RawLink(c, a, "8801.1"); H.Advance(1)
        local b = { name = "Second Officer" }
        RawLink(c, b, "8801.2")
        c.U.OpenSettings()
        eq(c.U.PendingLink().name, a.name, "fixture did not start at the older request")
        OpenNotice(c, b)
        AssertSelected(c, b, "8801.2")
        Click(c.U.linkApprovalControls[action])
        assert(c.U.inboundLinks[a.name] and not c.U.inboundLinks[a.name].approved,
            "the second request action changed the older first request")
        if action == "accept" then
            assert(c.U.inboundLinks[b.name] and c.U.inboundLinks[b.name].approved,
                "accept did not apply to the request named by the notice")
        else assert(not c.U.inboundLinks[b.name], "decline did not remove the request named by the notice") end
        AssertNoExternalTrust(c, a); AssertNoExternalTrust(c, b)
    end
end)

Scenario("a declined request notice cannot fall back to another pending sender", function()
    local c, a = World(4, { officer = true })
    RawLink(c, a, "8802.1"); H.Advance(1)
    local b = { name = "Second Officer" }
    RawLink(c, b, "8802.2")
    local stale = NoticeHref(c, b)
    OpenNotice(c, b); AssertSelected(c, b, "8802.2")
    Click(c.U.linkApprovalControls.decline)
    eq(c.U.PendingLink().name, a.name, "remaining first request disappeared")
    Window(c):Hide()
    c.E.SetItemRef(stale, "[Старое уведомление]", "LeftButton")
    assert(not Window(c):IsShown(), "stale second notice opened another sender's request")
    eq(c.U.PendingLink().name, a.name, "stale notice selected a different request")
    assert(not c.U.inboundLinks[a.name].approved, "stale notice approved the remaining request")
end)

Scenario("an expired notice cannot open a newer still-pending request", function()
    local c = World(4, { officer = true })
    local b, a = { name = "Expired Officer" }, { name = "Current Officer" }
    RawLink(c, b, "8803.1")
    local stale = NoticeHref(c, b)
    H.Advance(2); RawLink(c, a, "8803.2")
    c.U.OpenSettings(); Window(c):Hide()
    H.Advance(179.5); H.SetRosters(0); c.U.NetworkTick(); c.U.Refresh()
    assert(not c.U.inboundLinks[b.name] and c.U.PendingLink().name == a.name,
        "fixture did not preserve only the newer pending request")
    c.E.SetItemRef(stale, "[Старое уведомление]", "LeftButton")
    assert(not Window(c):IsShown(), "expired notice fell back to the current pending request")
    eq(c.U.PendingLink().name, a.name, "expired notice changed the current request")
end)

Scenario("a renewed sender nonce rejects the old notice and saved action closures", function()
    local c, a = World(4, { officer = true })
    RawLink(c, a, "8804.1"); H.Advance(1)
    local b = { name = "Renewed Officer" }
    RawLink(c, b, "8804.2"); OpenNotice(c, b)
    local oldHref = NoticeHref(c, b)
    local oldAccept = c.U.linkApprovalControls.accept.scripts.OnClick
    local oldDecline = c.U.linkApprovalControls.decline.scripts.OnClick
    H.Advance(1); RawLink(c, b, "8804.3")
    Window(c):Hide()
    c.E.SetItemRef(oldHref, "[Старое уведомление]", "LeftButton")
    assert(not Window(c):IsShown(), "old nonce reopened the sender's renewed request")
    assert(not c.U.SelectPendingLink(b.name, "8804.2"), "exact selector admitted an old request nonce")
    assert(not c.U.AcceptLink(b.name, "8804.2") and not c.U.DeclineLink(b.name, "8804.2"),
        "old action nonce changed a renewed request")
    OpenNotice(c, b); AssertSelected(c, b, "8804.3")
    oldAccept(); oldDecline()
    assert(c.U.inboundLinks[b.name] and not c.U.inboundLinks[b.name].approved
        and c.U.inboundLinks[b.name].nonce == "8804.3", "saved old action closure modified the renewed request")
    AssertSelected(c, b, "8804.3")
    Click(c.U.linkApprovalControls.decline)
    assert(not c.U.inboundLinks[b.name] and c.U.inboundLinks[a.name] and not c.U.inboundLinks[a.name].approved,
        "current nonce action did not stay within the selected request")
end)

Scenario("saved actions for an unselected request cannot act on either sender", function()
    local c, a = World(4, { officer = true })
    RawLink(c, a, "8805.1"); H.Advance(1)
    local b = { name = "Second Officer" }
    RawLink(c, b, "8805.2"); OpenNotice(c, b)
    local oldAccept = c.U.linkApprovalControls.accept.scripts.OnClick
    local oldDecline = c.U.linkApprovalControls.decline.scripts.OnClick
    OpenNotice(c, a); AssertSelected(c, a, "8805.1")
    oldAccept(); oldDecline()
    assert(c.U.inboundLinks[a.name] and not c.U.inboundLinks[a.name].approved
        and c.U.inboundLinks[b.name] and not c.U.inboundLinks[b.name].approved,
        "saved request action changed one of the pending senders after selection changed")
    AssertSelected(c, a, "8805.1")
end)

Scenario("malformed and unrelated native addon links leave the selected request alone", function()
    local c, a = World(4, { officer = true })
    RawLink(c, a, "8806.1"); H.Advance(1)
    local b = { name = "Second Officer" }
    RawLink(c, b, "8806.2"); OpenNotice(c, b); Window(c):Hide()
    local valid = NoticeHref(c, b)
    local links = {
        "addon:ChillZoneUnion:connection", NOTICE_PREFIX, NOTICE_PREFIX .. "0:8806.2",
        NOTICE_PREFIX .. "gg:8806.2", NOTICE_PREFIX .. ":8806.2",
        NOTICE_PREFIX .. HexName(b.name):upper() .. ":8806.2",
        NOTICE_PREFIX .. HexName(" " .. b.name) .. ":8806.2",
        NOTICE_PREFIX .. HexName(b.name .. " ") .. ":8806.2",
        NOTICE_PREFIX .. "00:8806.2", NOTICE_PREFIX .. "0a:8806.2",
        NOTICE_PREFIX .. string.rep("61", 161) .. ":8806.2",
        NOTICE_PREFIX .. HexName(b.name) .. ":", NOTICE_PREFIX .. HexName(b.name) .. ":nonnonce",
        NOTICE_PREFIX .. HexName(b.name) .. ":" .. string.rep("1", 41),
        NOTICE_PREFIX .. HexName(b.name) .. ":8806.99", NOTICE_PREFIX .. HexName("Unknown Officer") .. ":8806.2",
        valid .. ":trailing", "addon:AnotherAddon:connection", "addon:ChillZoneUnion:other:payload",
    }
    for _, link in ipairs(links) do
        c.E.SetItemRef(link, "[Неизвестная ссылка]", "LeftButton")
        eq(c.lastItemRef, link, "connection hook replaced native addon-link dispatch")
        assert(not Window(c):IsShown(), "malformed or unrelated link opened an approval card")
        eq(c.U.PendingLink().name, b.name, "malformed link fell back to the older request")
    end
    assert(not c.U.SelectPendingLink(nil, nil), "nil selector fell back to the oldest request")
    assert(not c.U.SelectPendingLink(a.name, nil), "selector without nonce changed the current request")
    assert(not c.U.PendingLink(a.name, "8806.99"), "exact query with unknown nonce returned another request")
    eq(c.U.PendingLink().name, b.name, "failed exact selection changed the current request")
    AssertNoExternalTrust(c, a); AssertNoExternalTrust(c, b)
end)

Scenario("bound notices round-trip Cyrillic spaces and accepted special name bytes", function()
    for i, name in ipairs({ "Вован Дубан", "Officer O'Brien", "Тест :50% ~Ю", string.rep("Ж", 65) .. " Отдел" }) do
        local c = World(4, { officer = true })
        local sender, nonce = { name = name }, "8807." .. i
        eq(c.U.Name(name), name, "name fixture is not canonical")
        RawLink(c, sender, nonce)
        eq(NoticeHref(c, sender), NOTICE_PREFIX .. HexName(name) .. ":" .. nonce,
            "notice changed name bytes or omitted its nonce")
        OpenNotice(c, sender); AssertSelected(c, sender, nonce)
        Click(c.U.linkApprovalControls.decline)
        assert(not c.U.inboundLinks[name], "decoded request action did not match the original name bytes")
    end
end)

Scenario("many unsolicited endpoints cannot flood chat or create trust", function()
    local c = World(4, { officer = true })
    for i = 1, 12 do RawLink(c, { name = "Stranger Officer" .. i }, "4200." .. i) end
    local notices = LogCount(c, "|Haddon:ChillZoneUnion:connection:")
    assert(notices > 0 and notices <= 8, "unsolicited endpoints exhausted the chat with request notices")
    assert(PendingMark(c) and c.U.PendingLink(), "rate-limited notices hid the remaining manual action")
    assert(not next(c.U.db.contacts), "notification flood inserted trusted endpoints")
end)

Scenario("slash and minimap first-open route native officers consistently", function()
    for _, via in ipairs({ "slash", "minimap" }) do
        for _, rank in ipairs({ 0, 4 }) do
            local c = World(rank, { officer = true })
            if via == "slash" then c.U.Command("") else Click(c.U.minimapButton) end
            assert(IsPage(c, 4), via .. " bypassed first setup for native officer rank " .. rank)
            assert(VisibleText(c, "Подключить"), "setup has no matching connect action")
            assert(Window(c).czuSetupSteps and #Window(c).czuSetupSteps == 3, "three setup steps missing")
        end
    end
end)

Scenario("ordinary first-open explains automatic setup and opens shared chat", function()
    for _, via in ipairs({ "slash", "minimap" }) do
        local c = World(2, { officer = false })
        if via == "slash" then c.U.Command("") else Click(c.U.minimapButton) end
        assert(VisibleText(c, "Ручная настройка не требуется"), "ordinary member has no setup explanation")
        local w, controls = Window(c), c.U.linkApprovalControls
        assert(not H.FrameVisible(w.czuContact) and not H.FrameVisible(w.czuConnect), "ordinary member sees manual link input")
        assert(not H.FrameVisible(controls.accept) and not H.FrameVisible(controls.decline) and not H.FrameVisible(controls.share), "ordinary member sees officer actions")
        Click(w.czuSetupChat)
        assert(IsPage(c, 2), "member chat shortcut did not open chat")
        assert(not c.U.CanRelay() and not c.U.IsTrustOfficer(), "member explanation changed native permissions")
    end
end)

Scenario("declining updates the view and a later request can be noticed", function()
    local c, sender = World()
    RawLink(c, sender, "1234.4")
    c.U.OpenSettings()
    Click(c.U.linkApprovalControls.decline)
    assert(not c.U.PendingLink(), "declined request retained")
    eq(c.U.ConnectionView().stage, "declined", "declined view retained approval instructions")
    assert(not PendingMark(c), "declined request retained minimap marker")
    assert(not c.U.linkApprovalControls.accept:IsEnabled(), "declined request can still be accepted")
    H.Advance(12); RawLink(c, sender, "1234.5")
    eq(c.U.ConnectionView().stage, "pending", "new request did not replace declined state")
    eq(LogCount(c, "|Haddon:ChillZoneUnion:connection:"), 2, "new intentional request not notified")
end)

Scenario("expired incoming request removes stale confirmation and stale links do nothing", function()
    local c, sender = World()
    RawLink(c, sender, "1234.6")
    local href = NoticeHref(c, sender)
    c.U.OpenSettings()
    H.Advance(181); H.SetRosters(0); c.U.NetworkTick(); c.U.Refresh()
    assert(not c.U.PendingLink(), "expired request retained")
    eq(c.U.ConnectionView().stage, "expired", "expired view retained approval instructions")
    assert(not PendingMark(c) and not c.U.linkApprovalControls.accept:IsEnabled(), "expired request still actionable")
    Window(c):Hide()
    c.E.SetItemRef(href, "[Открыть]", "LeftButton")
    assert(not Window(c):IsShown(), "stale notice reopened an expired request")
    AssertNoExternalTrust(c, sender)
end)

Scenario("empty input reports the missing full name instead of officer authority", function()
    local c = World(4, { officer = true })
    c.U.OpenSettings()
    local box = Window(c).czuContact
    box:SetText(""); box.scripts.OnEnterPressed(box)
    local message = c.U.SetupState().message
    assert(message:find("имя", 1, true), "empty Enter does not explain the missing name")
    assert(not message:find("полномоч", 1, true) and not message:find("настраивает", 1, true), "empty Enter misdiagnosed native officer authority")
    assert(not next(c.U.links), "empty input sent a connection request")
end)

Scenario("outgoing refusal and timeout expose a finished request rather than confirmation", function()
    local c, sender = World(4, { officer = true })
    assert(c.U.Link(sender.name), "native officer could not initiate setup")
    local pending = assert(c.U.links[sender.name], "outgoing request missing")
    RawLink(c, sender, pending.nonce, "error", "declined")
    eq(c.U.ConnectionView().stage, "declined", "remote refusal did not finish outgoing request")
    assert(not c.U.links[sender.name] and not c.U.PendingLink(), "refused request retained active controls")
    H.Advance(1)
    assert(c.U.Link(sender.name), "refused request could not be retried deliberately")
    H.Advance(181); H.SetRosters(0); c.U.NetworkTick()
    eq(c.U.ConnectionView().stage, "expired", "outgoing timeout still requests confirmation")
    assert(not c.U.links[sender.name] and not c.U.PendingLink(), "timed-out outgoing request retained")
end)

Scenario("trust sharing has no false success without contacts or queue admission", function()
    local c, sender = World()
    c.U.OpenSettings()
    local controls = c.U.linkApprovalControls
    if controls.advanced then Click(controls.advanced) end
    assert(not controls.share:IsEnabled(), "share enabled with no approved contacts")
    local successBefore = LogCount(c, "Подтверждённые контакты отправлены")
    assert(c.U.ShareTrust() == false, "empty trust set reported success")
    eq(LogCount(c, "Подтверждённые контакты отправлены"), successBefore, "empty trust set emitted success")
    assert(c.U.ApproveContact(sender.name, 2, false), "fixture trusted contact rejected")
    c.U.Refresh()
    assert(controls.share:IsEnabled(), "share unavailable after real approval")
    local queueBatch = c.U.QueueBatch
    c.U.QueueBatch = function() return false end
    assert(c.U.ShareTrust() == false, "queue rejection reported success")
    c.U.QueueBatch = queueBatch
    eq(LogCount(c, "Подтверждённые контакты отправлены"), successBefore, "queue rejection emitted success")
end)

Scenario("native authority revocation hides confirmation and disables old notice", function()
    local c, sender = World(4, { officer = true })
    RawLink(c, sender, "1234.7")
    local href = NoticeHref(c, sender)
    c.U.OpenSettings()
    local oldAction = c.U.linkApprovalControls.accept.scripts.OnClick
    c.officer = false; H.SetRosters(0); Event(c, "GUILD_RANKS_UPDATE"); c.U.Refresh()
    assert(not c.U.IsTrustOfficer() and not c.U.PendingLink(), "revoked officer retains manual authority")
    assert(not PendingMark(c), "revoked authority retained minimap marker")
    assert(not H.FrameVisible(c.U.linkApprovalControls.accept) and not H.FrameVisible(c.U.linkApprovalControls.decline), "revoked authority retained approval controls")
    if oldAction then oldAction() end
    AssertNoExternalTrust(c, sender)
    Window(c):Hide()
    c.E.SetItemRef(href, "[Открыть]", "LeftButton")
    assert(not Window(c):IsShown(), "old notification bypassed revoked native authority")
end)

Scenario("veteran can relay configured data but cannot confirm initial stranger", function()
    local c, sender = World(4, { veteran = true })
    RawLink(c, sender, "1234.8")
    assert(c.U.CanRelay() and not c.U.IsTrustOfficer(), "veteran fixture authority mismatch")
    assert(not c.U.PendingLink() and not PendingMark(c), "veteran offered initial stranger approval")
    eq(LogCount(c, "|Haddon:ChillZoneUnion:connection:"), 0, "veteran received officer approval notice")
    AssertNoExternalTrust(c, sender)
end)

Scenario("configured main entry and explicit roster/location keep their destination", function()
    local c, sender = World()
    assert(c.U.ApproveContact(sender.name, 2, false), "fixture trusted contact rejected")
    c.U.Command("")
    assert(IsPage(c, 1), "configured main entry unexpectedly opened setup")
    c.U.OpenSettings(); c.U.OpenRoster()
    assert(IsPage(c, 1), "explicit roster was redirected to setup")
    assert(c.U.OpenLocationRoster("Штормград", 1), "explicit location roster rejected")
    assert(IsPage(c, 1), "map/location action redirected to setup")
    local clean = World(4, { officer = true })
    clean.U.OpenRoster()
    assert(IsPage(clean, 1), "unconfigured explicit roster was redirected to setup")
end)

Scenario("confirmed pairing reaches connected state for ordinary readers automatically", function()
    local c, sender = World(4, { officer = true })
    local reader = H.NewClient("Ordinary Reader", 1, 2); reader.officer = false
    H.SetRosters(0); Event(sender, "PLAYER_LOGIN"); Event(reader, "PLAYER_LOGIN")
    c.U.OpenSettings()
    assert(c.U.Link(sender.name), "native officer could not start initial pairing")
    eq(c.U.ConnectionView().stage, "connecting", "initiator has no wait-for-confirmation state")
    -- The shared fixture supplies explicit recipient consent only for this
    -- successful intentional Link call. Raw unsolicited requests above never
    -- receive it.
    H.Step(70)
    assert(c.U.Connected() and sender.U.Connected() and reader.U.Connected(), "approved guild connection did not reach readers")
    eq(c.U.ConnectionView().stage, "connected", "officer setup did not finish")
    eq(reader.U.ConnectionView().stage, "connected", "ordinary member was not told the connection is ready")
    reader.U.OpenSettings()
    assert(VisibleText(reader, "Ручная настройка не требуется"), "connected reader still needs an officer explanation")
    Click(Window(reader).czuSetupChat)
    assert(IsPage(reader, 2), "connected reader cannot reach shared chat")
    assert(not PendingMark(c) and not PendingMark(sender), "completed pairing retained approval marker")
end)

eq(H.ProtectedCalls(), 0, "onboarding invoked protected guild actions")
print("Onboarding scenarios: " .. (ran - failed) .. "/" .. ran)
assert(failed == 0, tostring(failed) .. " onboarding scenarios failed")
