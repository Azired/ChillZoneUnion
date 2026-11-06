-- Direct-choice UI regressions. Production widgets and their real responders
-- run against the shared native-frame fixture; network setup happens once per
-- world, before observers begin measuring purely visual interactions.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation fixture missing")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true))
local H = assert(loadstring(source:sub(1, boundary - 1) .. "\n" .. [[
return { NewClient = NewClient, SetRosters = SetRosters, Step = Step,
    UIObject = UIObject, FrameVisible = FrameVisible, RunUIUpdates = RunUIUpdates,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    Sent = function() return sent end, ProtectedCalls = function() return protectedCalls end }
]]))()
local failed, ran = 0, 0
local function eq(a, b, message) assert(a == b, message .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function Scenario(name, run)
    ran = ran + 1
    local ok, reason = pcall(run)
    if ok then print("PASS selectors: " .. name)
    else failed = failed + 1; print("FAIL selectors: " .. name .. ": " .. tostring(reason)) end
end
local function Event(c, name, ...) c.U.frame.scripts.OnEvent(c.U.frame, name, ...) end
local function Click(frame)
    assert(frame and H.FrameVisible(frame) and frame:IsEnabled() and frame.scripts.OnClick, "missing visible enabled action")
    frame.scripts.OnClick(frame, "LeftButton")
end
local function MenuClosed(c)
    return not c.U.choiceMenu or not c.U.choiceMenu.active
end
local function InstallNativeMenu(c)
    -- The native manager pools its popup frame. Old OnHide hooks must not
    -- invalidate a later selector context using that same widget.
    c.reuseContextFrame = true
    local create = c.E.MenuUtil.CreateContextMenu
    c.E.MenuUtil.CreateContextMenu = function(owner, generator)
        return create(owner, function(button, description)
            function description:SetScrollMode(extent)
                assert(type(extent) == "number" and extent > 0, "native menu scroll mode requires a positive extent")
                self.scrollExtent = extent
            end
            -- CreateRadio's selected predicate and responder receive data in
            -- the actual native API. Retain both to inspect the native mark
            -- and invoke the native entry's real responder below.
            function description:CreateRadio(text, selected, responder, data)
                assert(type(selected) == "function" and type(responder) == "function", "radio requires native predicates/responders")
                local entry = self:CreateButton(text, function() return responder(data) end)
                entry.isSelected, entry.data = selected, data
                return entry
            end
            generator(button, description)
        end)
    end
    local manager = {}
    function manager:CloseMenus()
        if c.contextMenu and c.contextMenu.native then c.contextMenu.native:Hide() end
    end
    c.E.Menu = { GetManager = function() return manager end }
end
local function World(mode)
    H.Reset()
    local own = H.NewClient("Own Gateway", 1, 0)
    local other = H.NewClient("Other Gateway", 2, 0)
    local c = H.NewClient("Selector Reader", 1, 2)
    H.SetRosters(0)
    for _, client in ipairs({ own, other, c }) do Event(client, "PLAYER_LOGIN") end
    assert(own.U.Link(other.name), "fixture link start failed"); H.Step(70)
    assert(c.U.Connected() and c.U.RosterFresh(1) and c.U.RosterFresh(2), "fixture has no authenticated fresh rosters")
    local function Member(name, guild, level, online, zone, rank)
        return { name = name, guild = guild, level = level, online = online, zone = zone,
            rank = rank or 2, rankName = "Участник", class = "PRIEST" }
    end
    -- Preserve the actual native authority/index metadata of existing clients.
    -- Synthetic display rows must not revoke the authenticated local gateway.
    local selfRow, gatewayRow = c.U.own[c.name], c.U.own[own.name]
    selfRow.zone, gatewayRow.zone, gatewayRow.level = "Focus Zone", "Focus Zone", 60
    c.U.own = { [c.name] = selfRow, [own.name] = gatewayRow }
    for i = 1, 38 do
        local name = ("Own Person%02d"):format(i)
        c.U.own[name] = Member(name, 1, i, i % 3 ~= 0, i <= 25 and "Focus Zone" or "Own Zone" .. i)
    end
    c.U.db.rosters[1].rows = c.U.own
    local remote = { [other.name] = Member(other.name, 2, 100, true, "Focus Zone", 0) }
    for i = 1, 28 do
        local name = ("Other Person%02d"):format(i)
        remote[name] = Member(name, 2, i + 40, i % 4 ~= 0, i <= 18 and "Focus Zone" or "Other Zone" .. i)
    end
    c.U.db.rosters[2].rows = remote
    c.mode = mode
    if mode == "native" then InstallNativeMenu(c) else c.E.MenuUtil = nil end
    c.mouseOver = nil
    c.E.MouseIsOver = function(frame) return c.mouseOver == frame end
    c.nativeQueries, c.queueCalls, c.requestCalls = 0, 0, 0
    local queue, batch, request = c.U.Queue, c.U.QueueBatch, c.U.RequestRoster
    c.U.Queue = function(...) c.queueCalls = c.queueCalls + 1; return queue(...) end
    c.U.QueueBatch = function(...) c.queueCalls = c.queueCalls + 1; return batch(...) end
    c.U.RequestRoster = function(...) c.requestCalls = c.requestCalls + 1; return request(...) end
    c.sentBefore = H.Sent()
    c.U.OpenRoster()
    assert(c.U.choiceButtons, "production selector buttons missing")
    return c
end
local function Button(c, key) return assert(c.U.choiceButtons[key], "selector missing: " .. key) end
local function OpenMenu(c, key)
    local button = Button(c, key)
    Click(button)
    local context = assert(c.U.choiceMenu, "selector did not open a menu")
    assert(context.active and context.owner == button and context.key == key, "selector opened an unrelated menu")
    if c.mode == "native" then
        assert(c.contextMenu and context.menu == c.contextMenu.native, "native MenuUtil path was not used")
    else eq(context.menu, c.E.ChillZoneUnionChoiceMenu, "fallback popup missing") end
    return context, button
end
local function Entry(context, value)
    for _, entry in ipairs(context.entries) do if entry.value == value then return entry end end
    error("choice value missing: " .. tostring(value))
end
local function ActualCallback(c, context, value)
    local entry = Entry(context, value)
    if c.mode == "native" then
        for _, native in ipairs(c.contextMenu.description.entries) do
            if native.text == entry.text then
                return function() return native.callback() end, native
            end
        end
        error("native responder missing for " .. entry.text)
    end
    for _, row in ipairs(context.menu.buttons) do
        if H.FrameVisible(row) and row.czuChoiceEntry and row.czuChoiceEntry.value == value then
            local callback = assert(row.scripts.OnClick, "fallback row responder missing")
            return function() return callback(row, "LeftButton") end, row
        end
    end
    error("fallback responder missing for " .. entry.text)
end
local function Choose(c, key, value)
    local context = OpenMenu(c, key)
    local callback = ActualCallback(c, context, value)
    callback()
    assert(MenuClosed(c), "choosing an option left the menu active")
end
local function Checked(c, context, value)
    local entry = Entry(context, value)
    eq(entry.checked == true, true, "current choice missing from menu metadata")
    local _, visual = ActualCallback(c, context, value)
    if c.mode == "native" then
        assert(visual.isSelected and visual.isSelected(visual.data) == true, "native radio did not mark the current choice")
    else assert(visual.check and visual.check:IsShown(), "fallback menu did not show the current checkmark") end
    local count = 0
    for _, option in ipairs(context.entries) do if option.checked then count = count + 1 end end
    eq(count, 1, "single-choice menu marks several options")
end
local function Rows(c)
    local rows = {}
    for _, frame in ipairs(c.allFrames) do if frame.row and H.FrameVisible(frame) then rows[#rows + 1] = frame end end
    return rows
end
local function LevelRows(c)
    local rows = {}
    for _, frame in ipairs(c.allFrames) do if frame.levelRow and H.FrameVisible(frame) then rows[#rows + 1] = frame end end
    return rows
end
local function Action(c, tag, wanted)
    for _, frame in ipairs(c.allFrames) do if frame[tag] == wanted then return frame end end
    error("UI action missing: " .. tag .. "=" .. wanted)
end
local function Scroll(frame, delta)
    assert(frame and frame.scripts.OnMouseWheel, "scroll callback missing")
    frame.scripts.OnMouseWheel(frame, delta)
end
local function NoNetwork(c)
    eq(c.queueCalls, 0, "visual selector queued addon messages")
    eq(c.requestCalls, 0, "visual selector requested a guild roster")
    eq(H.Sent(), c.sentBefore, "visual selector sent network packets")
end

for _, mode in ipairs({ "native", "fallback" }) do
    Scenario(mode .. " guild scopes open without cycling and allow direct selection", function()
        local c = World(mode)
        local scopes = {
            { key = "roster-scope", open = c.U.OpenRoster },
            { key = "overview-scope", open = c.U.OpenOverview },
            { key = "level-scope", open = c.U.OpenLevelStats },
        }
        for _, item in ipairs(scopes) do
            item.open()
            local button = Button(c, item.key)
            eq(button.czuChoiceValue(), 0, "default scope changed")
            local text = button:GetText()
            local context = OpenMenu(c, item.key)
            eq(button.czuChoiceValue(), 0, "opening a selector cycled its scope")
            eq(button:GetText(), text, "opening a selector changed its label")
            Checked(c, context, 0)
            local callback = ActualCallback(c, context, 2); callback()
            eq(button.czuChoiceValue(), 2, "direct third option did not select the second guild")
            eq(button:GetText(), c.U.GUILDS[2], "scope selector label is not the selected guild")
            context = OpenMenu(c, item.key); Checked(c, context, 2); c.U.CloseChoiceMenu()
            Choose(c, item.key, 1); eq(button.czuChoiceValue(), 1, "direct first-guild choice failed")
            Choose(c, item.key, 0); eq(button.czuChoiceValue(), 0, "direct all-guild choice failed")
        end
        NoNetwork(c)
    end)

    Scenario(mode .. " roster selection preserves exact location and resets pagination", function()
        local c = World(mode)
        assert(c.U.OpenLocationRoster("Focus Zone", 0), "location view rejected")
        local first = assert(Rows(c)[1], "location roster empty")
        local initial = first.row.name
        Scroll(first.parent, -2)
        local scrolled = assert(Rows(c)[1]).row.name
        assert(scrolled ~= initial, "fixture did not scroll the roster")
        local context, button = OpenMenu(c, "roster-scope")
        eq(Rows(c)[1].row.name, scrolled, "opening menu reset the roster position")
        eq(button.czuChoiceValue(), 0, "opening roster selector changed scope")
        local callback = ActualCallback(c, context, 2); callback()
        local actual = Rows(c)
        assert(#actual > 0, "second-guild location selection is empty")
        for _, frame in ipairs(actual) do
            eq(frame.row.guild, 2, "roster scope includes the wrong guild")
            eq(frame.row.zone, "Focus Zone", "scope selection dropped the exact location filter")
        end
        eq(actual[1].row.name, "Other Gateway", "scope selection did not reset roster pagination")
        NoNetwork(c)
    end)

    Scenario(mode .. " level grouping and online checkbox update the displayed graph", function()
        local c = World(mode); c.U.OpenLevelStats()
        local step = Button(c, "level-step")
        eq(step.czuChoiceValue(), 10, "default level grouping changed")
        local context = OpenMenu(c, "level-step")
        eq(step.czuChoiceValue(), 10, "opening level grouping cycled its value")
        Checked(c, context, 10)
        local callback = ActualCallback(c, context, 1); callback()
        eq(step.czuChoiceValue(), 1, "single-level grouping requires cycling")
        local frame = assert(LevelRows(c)[1], "level graph empty")
        eq(frame.levelRow.lower, frame.levelRow.upper, "single-level choice did not render single levels")
        Scroll(frame.parent, -3)
        assert(LevelRows(c)[1].levelRow.lower > 1, "fixture did not scroll the level graph")
        Choose(c, "level-step", 5)
        eq(step.czuChoiceValue(), 5, "five-level grouping failed")
        eq(LevelRows(c)[1].levelRow.lower, 1, "grouping selection did not reset graph position")
        Choose(c, "level-scope", 1)
        local toggle = Action(c, "czuLevelAction", "mode")
        eq(toggle.frameType, "CheckButton", "online mode is still a cycling text button")
        local total = 0
        for _, row in ipairs(LevelRows(c)) do total = total + row.bar.value end
        toggle:SetChecked(true); Click(toggle)
        assert(toggle:GetChecked(), "online checkbox did not remain checked")
        local online = 0
        for _, row in ipairs(LevelRows(c)) do online = online + row.bar.value end
        assert(online < total, "online checkbox did not exclude offline characters from graph values")
        toggle:SetChecked(false); Click(toggle)
        local restored = 0
        for _, row in ipairs(LevelRows(c)) do restored = restored + row.bar.value end
        eq(restored, total, "unchecking online did not restore total graph values")
        NoNetwork(c)
    end)

    Scenario(mode .. " statistics action menu opens either view directly", function()
        local c = World(mode)
        local context = OpenMenu(c, "roster-statistics")
        assert(c.E.ChillZoneUnionWindowTab1.nativeTabSelected, "opening statistics menu changed the roster page")
        local classes = ActualCallback(c, context, "classes"); classes()
        assert(c.E.ChillZoneUnionWindowTab1.nativeTabSelected, "class statistics changed stable roster tab identity")
        local visible = false
        for _, frame in ipairs(c.allFrames) do if frame.statsRow and H.FrameVisible(frame) then visible = true end end
        assert(visible, "class menu action did not open class statistics")
        c.U.OpenRoster(); Choose(c, "roster-statistics", "levels")
        assert(#LevelRows(c) > 0, "level menu action did not open level statistics")
        NoNetwork(c)
    end)

    Scenario(mode .. " chat selector supports automatic nil and live native window names", function()
        local c = World(mode); c.U.OpenSettings()
        local button = Button(c, "chat-window")
        local before = c.U.db.chatFrameName
        local context = OpenMenu(c, "chat-window")
        eq(c.U.db.chatFrameName, before, "opening chat selector changed routing")
        Checked(c, context, false)
        local third = c.U.ChatWindowNames()[3]
        assert(third, "fixture has no third chat window")
        local callback = ActualCallback(c, context, third); callback()
        eq(c.U.db.chatFrameName, third, "direct chat window choice did not update routing")
        context = OpenMenu(c, "chat-window"); Checked(c, context, third); c.U.CloseChoiceMenu()
        Choose(c, "chat-window", false)
        eq(c.U.db.chatFrameName, nil, "automatic choice stored false or a string instead of nil")
        local names = { "Общий", "Гильдия", "Новый канал" }
        c.E.GetChatWindowInfo = function(index) return names[index] end
        c.E.ChatFrame3.name = names[3]
        context = OpenMenu(c, "chat-window")
        local stale = ActualCallback(c, context, names[3])
        c.E.ChatFrame3 = nil
        stale()
        eq(c.U.db.chatFrameName, nil, "a disappeared native chat window was selected from a stale menu")
        c.U.CloseChoiceMenu()
        c.E.ChatFrame3 = H.UIObject(); c.E.ChatFrame3.name = names[3]
        Choose(c, "chat-window", names[3])
        eq(c.U.db.chatFrameName, names[3], "new native chat window is missing from fresh options")
        NoNetwork(c)
    end)

    Scenario(mode .. " disabled owners and stale hidden callbacks cannot apply a choice", function()
        local c = World(mode)
        local button = Button(c, "roster-scope")
        button:Disable(); button.scripts.OnClick(button, "LeftButton")
        assert(MenuClosed(c), "disabled selector opened its menu")
        button:Enable()
        local context = OpenMenu(c, "roster-scope")
        local old = ActualCallback(c, context, 2)
        button:Disable(); old()
        eq(button.czuChoiceValue(), 0, "disabled selector callback bypassed native enabled state")
        button:Enable(); c.U.CloseChoiceMenu()
        context = OpenMenu(c, "roster-scope"); old = ActualCallback(c, context, 2)
        c.U.OpenChat()
        assert(MenuClosed(c), "page change left a selector menu active")
        old(); eq(button.czuChoiceValue(), 0, "stale hidden-page callback changed a filter")
        c.U.OpenRoster(); context = OpenMenu(c, "roster-scope"); old = ActualCallback(c, context, 2)
        c.E.ChillZoneUnionWindow:Hide()
        assert(MenuClosed(c), "hiding the parent window left a selector menu active")
        old(); eq(button.czuChoiceValue(), 0, "hidden-window callback changed a filter")
        NoNetwork(c)
    end)

    Scenario(mode .. " long live chat lists remain selectable with visible checkmarks", function()
        local c = World(mode); c.U.OpenSettings()
        local names = {}
        c.E.NUM_CHAT_WINDOWS = 17
        for i = 1, 17 do
            names[i] = ("Native Window%02d"):format(i)
            c.E["ChatFrame" .. i] = c.E["ChatFrame" .. i] or H.UIObject()
            c.E["ChatFrame" .. i].name = names[i]
        end
        c.E.GetChatWindowInfo = function(index) return names[index] end
        local context = OpenMenu(c, "chat-window")
        eq(#context.entries, 18, "live chat selector omitted a native window or automatic option")
        eq(c.U.db.chatFrameName, nil, "opening a long chat list changed routing")
        if mode == "native" then
            eq(c.contextMenu.description.scrollExtent, 288, "long native menu did not enable bounded scrolling")
        else
            local shown = 0
            for _, row in ipairs(context.menu.buttons) do if H.FrameVisible(row) then shown = shown + 1 end end
            assert(shown <= 12, "fallback menu exceeded its bounded visible rows")
            Scroll(context.menu, -5)
        end
        local callback = ActualCallback(c, context, names[17]); callback()
        eq(c.U.db.chatFrameName, names[17], "last live native chat window cannot be selected directly")
        context = OpenMenu(c, "chat-window")
        if mode == "fallback" then Scroll(context.menu, -5) end
        Checked(c, context, names[17]); c.U.CloseChoiceMenu()
        NoNetwork(c)
    end)

    Scenario(mode .. " menus close through selection dismiss hide and opening another selector", function()
        local c = World(mode)
        local context = OpenMenu(c, "roster-scope")
        context.menu:Hide()
        assert(MenuClosed(c), "native popup hide did not invalidate its context")
        context = OpenMenu(c, "roster-scope")
        local old = ActualCallback(c, context, 2)
        c.U.OpenOverview(); OpenMenu(c, "overview-scope")
        old(); eq(Button(c, "roster-scope").czuChoiceValue(), 0, "replaced menu responder changed an unrelated filter")
        assert(not MenuClosed(c) and c.U.choiceMenu.key == "overview-scope", "old menu responder dismissed the new selector")
        c.U.CloseChoiceMenu(); assert(MenuClosed(c), "explicit menu dismissal failed")
        c.U.OpenRoster(); context = OpenMenu(c, "roster-scope")
        if mode == "native" then c.E.Menu.GetManager():CloseMenus()
        else
            assert(context.dismiss and context.dismiss.scripts.OnMouseDown, "fallback has no outside-mouse dismissal path")
            context.dismiss.scripts.OnMouseDown(context.dismiss, "LeftButton")
        end
        assert(MenuClosed(c), "outside mouse dismissal left the menu active")
        c.U.OpenRoster(); context = OpenMenu(c, "roster-scope")
        if mode == "native" then c.E.Menu.GetManager():CloseMenus()
        elseif context.menu.scripts.OnKeyDown then context.menu.scripts.OnKeyDown(context.menu, "ESCAPE")
        else
            local registered = false
            for _, name in ipairs(c.E.UISpecialFrames) do if c.E[name] == context.menu then registered = true end end
            assert(registered, "fallback menu has no Escape dismissal path")
            context.menu:Hide()
        end
        assert(MenuClosed(c), "Escape/native dismissal left a live menu context")
        NoNetwork(c)
    end)
end

eq(H.ProtectedCalls(), 0, "visual selectors invoked protected guild actions")
print("Selector scenarios: " .. (ran - failed) .. "/" .. ran)
assert(failed == 0, tostring(failed) .. " selector scenarios failed")
