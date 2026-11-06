local _, U = ...
local window, page, selected, selectedTicket
local offset, ticketOffset, guildFilter = 0, 0, 0
local sortKey, sortDirection, sortHeaders = nil, 1, {}
local pages, rows, ticketRows, tabs = {}, {}, {}, {}
local classRows, classTotals, classGuildStates = {}, {}, {}
local classOffset, classRange, classSummary = 0
local search, offline, counts, guildCounts, status, guildButton, chatBox, chatLog, chatJump, announcementBanner
local acceptButton, declineButton, leaveButton, inviteButton, ticketInfo
local contact, connectButton, setupHint, setupProgress, diagnostics, leaderInfo
local Setup = { steps = {}, advanced = false }
local badgeCheck, noticesCheck, chatWindowButton, announcementEdit, announcementSave, announcementClear, announcementHint
local headerDot, headerState
local announcementDirty, unread = false, 0
local seenHistory, renderedLines, renderedKeys = {}, {}, {}
local RenderRoster, RenderTickets, RenderLinks, RenderClassStats, Build

local function Label(parent, text, x, y, width, font)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    t:SetPoint("TOPLEFT", x, y); t:SetWidth(width); t:SetJustifyH("LEFT"); t:SetText(text)
    return t
end
local function Button(parent, text, x, y, width, action)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24); b:SetPoint("TOPLEFT", x, y); b:SetText(text); b:SetScript("OnClick", action)
    return b
end
local ARROW_MEDIA = "Interface\\AddOns\\ChillZoneUnion\\Media\\arrow-"
local function ArrowText(direction, size)
    size = size or 12
    return "|T" .. ARROW_MEDIA .. direction .. ":" .. size .. ":" .. size .. ":0:0|t"
end
local function Edit(parent, x, y, width, hint)
    local b = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    b:SetSize(width, 26); b:SetPoint("TOPLEFT", x, y); b:SetAutoFocus(false); b:SetMaxBytes(1200)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if hint then Label(parent, hint, x, y + 23, width, "GameFontNormalSmall") end
    return b
end
local Native = {}
local Level = { rows = {}, offset = 0, step = 10, scope = 0, mode = "total" }
local Overview = { rows = {}, cards = {}, offset = 0, scope = 0 }
function Native.HasMethod(object, method)
    local kind = type(object)
    return (kind == "table" or kind == "userdata") and type(object[method]) == "function"
end
U.choiceButtons = {}
function Native.ChoiceOptions(button)
    local choice, entries = button.czuChoice, {}
    local current = choice.getValue and choice.getValue()
    for _, item in ipairs(choice.options()) do
        if #entries >= 52 then break end
        if type(item) == "table" and U.Text(item.text, 400) then
            entries[#entries + 1] = { value = item.value, text = U.SafeDisplay(item.text),
                enabled = item.enabled ~= false, checked = not choice.action and item.value == current }
        end
    end
    return entries
end
function Native.RefreshChoice(button)
    if not button then return end
    local choice, text = button.czuChoice, button.czuChoice.label
    if not choice.action then
        for _, entry in ipairs(Native.ChoiceOptions(button)) do
            if entry.checked then text = entry.text; break end
        end
    end
    button:SetText(text)
end
function U.CloseChoiceMenu()
    local context = U.choiceMenu
    U.choiceMenu = nil
    if not context then return end
    context.active = false
    if context.menu then context.menu:Hide() end
    if context.dismiss then context.dismiss:Hide() end
end
function Native.ChoiceVisible(button)
    local parent = button
    for _ = 1, 20 do
        if not parent then return true end
        if not parent:IsShown() then return false end
        parent = parent:GetParent()
    end
    return false
end
function Native.ChooseChoice(context, value)
    local button = context.owner
    if U.choiceMenu ~= context or not context.active or not window or not window:IsShown()
        or page ~= context.page or U.guild ~= context.guild or not Native.ChoiceVisible(button) or not button:IsEnabled() then return false end
    local allowed = false
    for _, entry in ipairs(Native.ChoiceOptions(button)) do
        if entry.value == value then allowed = entry.enabled; break end
    end
    U.CloseChoiceMenu()
    if not allowed then return false end
    if not button.czuChoice.action and button.czuChoice.getValue() == value then
        Native.RefreshChoice(button); return true
    end
    button.czuChoice.choose(value)
    Native.RefreshChoice(button)
    return true
end
function Native.ChoiceHidden(menu)
    local context = menu.czuChoiceContext
    menu.czuChoiceContext = nil
    if context and U.choiceMenu == context then
        U.choiceMenu, context.active = nil, false
        if context.dismiss then context.dismiss:Hide() end
    end
end
function Native.ChoiceFallback(context)
    local popup = Native.choicePopup
    if not popup then
        local dismiss = CreateFrame("Frame", "ChillZoneUnionChoiceDismiss", UIParent)
        dismiss:SetAllPoints(UIParent); dismiss:SetFrameStrata("FULLSCREEN_DIALOG"); dismiss:EnableMouse(true)
        dismiss:SetScript("OnMouseDown", U.CloseChoiceMenu); dismiss:Hide()
        popup = CreateFrame("Frame", "ChillZoneUnionChoiceMenu", UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP"); popup:SetClampedToScreen(true); popup:EnableMouse(true)
        popup:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        popup:SetBackdropColor(0.08, 0.08, 0.08, 1)
        popup.buttons, popup.dismiss = {}, dismiss
        for index = 1, 12 do
            local row = CreateFrame("Button", nil, popup)
            row:SetPoint("TOPLEFT", 7, -7 - (index - 1) * 24); row:SetSize(286, 24)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.label = Label(row, "", 25, -5, 250, "GameFontHighlightSmall")
            row.label:SetHeight(16); row.label:SetWordWrap(false)
            row.check = row:CreateTexture(nil, "OVERLAY"); row.check:SetSize(20, 20)
            row.check:SetPoint("LEFT", 2, 0); row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            popup.buttons[index] = row
        end
        popup.range = Label(popup, "", 12, -299, 276, "GameFontDisableSmall")
        popup:SetScript("OnHide", function(self) Native.ChoiceHidden(self); self.dismiss:Hide() end)
        popup:EnableMouseWheel(true)
        popup:SetScript("OnMouseWheel", function(self, delta)
            local active = U.choiceMenu
            if active and active.menu == self then
                active.offset = math.max(0, math.min(active.offset - delta * 3, math.max(0, #active.entries - 12)))
                Native.RenderChoiceFallback(active)
            end
        end)
        table.insert(UISpecialFrames, "ChillZoneUnionChoiceMenu")
        popup:Hide(); Native.choicePopup = popup
    end
    context.menu, context.dismiss, context.offset = popup, popup.dismiss, 0
    popup.czuChoiceContext = context
    popup:ClearAllPoints(); popup:SetPoint("TOPLEFT", context.owner, "BOTTOMLEFT", 0, -2)
    Native.RenderChoiceFallback(context)
    popup.dismiss:Show(); popup:Show()
end
function Native.RenderChoiceFallback(context)
    local popup, visible = context.menu, math.min(12, #context.entries)
    popup:SetSize(300, 14 + visible * 24 + (#context.entries > 12 and 20 or 0))
    for index, row in ipairs(popup.buttons) do
        local entry = index <= visible and context.entries[index + context.offset] or nil
        row.czuChoiceEntry = entry; row:SetShown(entry ~= nil)
        if entry then
            local callback = entry.callback
            row:SetScript("OnClick", function() return callback() end)
            row.label:SetText(entry.text); row.check:SetShown(entry.checked)
            row.label:SetTextColor(entry.enabled and 1 or 0.5, entry.enabled and 1 or 0.5, entry.enabled and 1 or 0.5)
            if entry.enabled then row:Enable() else row:Disable() end
        else row:SetScript("OnClick", nil) end
    end
    popup.range:SetShown(#context.entries > 12)
    popup.range:SetText((context.offset + 1) .. "–" .. (context.offset + visible) .. " из " .. #context.entries .. " • прокрутка мышью")
end
function Native.OpenChoice(button)
    if not window or not window:IsShown() or not Native.ChoiceVisible(button) or not button:IsEnabled() then return false end
    if U.choiceMenu and U.choiceMenu.owner == button then U.CloseChoiceMenu(); return false end
    U.CloseChoiceMenu(); U.CloseRosterContextMenu(); Native.ClearPageFocus(); Native.ClearChoiceHover()
    local context = { owner = button, key = button.czuChoiceKey, active = true, page = page, guild = U.guild,
        entries = Native.ChoiceOptions(button), offset = 0 }
    U.choiceMenu = context
    for _, entry in ipairs(context.entries) do
        local value = entry.value
        entry.callback = function() return Native.ChooseChoice(context, value) end
    end
    if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
        context.menu = MenuUtil.CreateContextMenu(button, function(_, root)
            root:CreateTitle(button.czuChoice.title)
            if #context.entries > 12 then
                local ok, scroll = pcall(function() return root.SetScrollMode end)
                if ok and type(scroll) == "function" then root:SetScrollMode(288) end
            end
            for _, entry in ipairs(context.entries) do
                local ok, radio = pcall(function() return root.CreateRadio end)
                local description
                if not button.czuChoice.action and ok and type(radio) == "function" then
                    description = root:CreateRadio(entry.text,
                        function(value) return button.czuChoice.getValue() == value end, entry.callback, entry.value)
                else
                    local check = entry.checked and "|TInterface\\Buttons\\UI-CheckBox-Check:14:14:0:0|t " or ""
                    description = root:CreateButton(check .. entry.text, entry.callback)
                end
                description:SetEnabled(entry.enabled)
            end
        end)
        if context.menu then
            context.menu.czuChoiceContext = context
            if not context.menu.czuChoiceOnHideHooked then
                context.menu.czuChoiceOnHideHooked = true
                context.menu:HookScript("OnHide", Native.ChoiceHidden)
            end
        else U.CloseChoiceMenu(); return false end
    else Native.ChoiceFallback(context) end
    return true
end
function Native.Choice(parent, key, label, x, y, width, options, getValue, choose, action)
    local button = Button(parent, label, x, y, width)
    button.czuChoiceKey = key
    button.czuChoice = { label = label, title = label, options = options, getValue = getValue, choose = choose, action = action }
    button.czuChoiceOptions = function() return Native.ChoiceOptions(button) end
    button.czuChoiceValue = getValue
    button.czuChoiceOpen = function() return Native.OpenChoice(button) end
    button.czuChoiceArrow = button:CreateTexture(nil, "OVERLAY")
    button.czuChoiceArrow:SetSize(12, 12); button.czuChoiceArrow:SetPoint("RIGHT", -9, 0)
    button.czuChoiceArrow:SetTexture(ARROW_MEDIA .. "down")
    local font = button:GetFontString()
    if font then
        font:ClearAllPoints(); font:SetPoint("LEFT", 10, 0); font:SetWidth(width - 34)
        font:SetJustifyH("LEFT"); font:SetWordWrap(false)
    end
    button:SetScript("OnClick", button.czuChoiceOpen)
    button:SetScript("OnHide", function(self) if U.choiceMenu and U.choiceMenu.owner == self then U.CloseChoiceMenu() end end)
    U.choiceButtons[key] = button
    return button
end
function Native.GuildChoices()
    return { { value = 0, text = "Весь союз" }, { value = 1, text = U.GUILDS[1] }, { value = 2, text = U.GUILDS[2] } }
end
Native.activity = { days = 0 }
function Native.Activity(row)
    return U.ActivityInfo and U.ActivityInfo(row) or { known = false, online = false, fresh = false, label = "Нет данных" }
end
function Native.ActivityLabel(info)
    local text = "Нет данных"
    if info.online then text = info.fresh and "В сети" or "Был в сети"
    elseif info.known and U.Text(info.label, 160) then
        text = info.label
        if U.Fold(text) == "сейчас" then text = "Недавно"
        elseif not text:find("назад", 1, true) then text = text .. " назад" end
    end
    if not info.fresh and type(info.sourceAt) == "number" then text = text .. " *" end
    return text
end
function Native.ActivityOrder(info)
    if not info.known or type(info.sourceAt) ~= "number" then return nil end
    if info.online and info.fresh then return info.sourceAt end
    if type(info.minDays) == "number" then return info.sourceAt - info.minDays * 86400 end
end
function Native.ActivityChoices()
    return { { value = 0, text = "Все участники" }, { value = 7, text = "Не заходили 7 дней" },
        { value = 14, text = "Не заходили 14 дней" }, { value = 30, text = "Не заходили 30 дней" } }
end
function Native.RefreshActivityFilter()
    if not Native.activity.note then return end
    local active = Native.activity.days > 0
    if active then offline:SetChecked(true); offline:Disable() else offline:Enable() end
    Native.RefreshChoice(U.choiceButtons["roster-activity"])
    Native.activity.note:SetShown(active or Overview.location == nil)
    Native.activity.note:SetText(active
        and ("Не заходили не менее " .. Native.activity.days .. " дней. Офлайн включён; неизвестные и устаревшие сведения не учитываются.")
        or "* — сохранённые сведения. Наведите на участника, чтобы узнать подробности последнего входа.")
end
function Native.ChatChoices()
    local entries, present = { { value = false, text = "Автоматически" } }, false
    local saved = U.db.chatFrameName
    local wanted = U.Text(saved, 128) and U.Fold(U.Trim(saved)) or nil
    for _, name in ipairs(U.ChatWindowNames and U.ChatWindowNames() or {}) do
        entries[#entries + 1] = { value = name, text = name }
        if wanted and U.Fold(U.Trim(name)) == wanted then present = true end
    end
    if saved and not present then
        entries[#entries + 1] = { value = saved, text = saved .. " (недоступно)", enabled = false }
    end
    return entries
end
function Native.ChatChoiceValue()
    local saved = U.db.chatFrameName
    if saved == nil then return false end
    local wanted = U.Text(saved, 128) and U.Fold(U.Trim(saved)) or nil
    for _, name in ipairs(U.ChatWindowNames and U.ChatWindowNames() or {}) do
        if wanted and U.Fold(U.Trim(name)) == wanted then return name end
    end
    return saved
end
-- Let the client supply its own frame art: Forever replaces these templates with
-- its bronze frame layout, while other compatible clients keep their own skin.
function Native.Frame(kind, name, parent, templates)
    for index, template in ipairs(templates) do
        local frameName = name and (index == 1 and name or name .. "Fallback" .. index) or nil
        local ok, frame = pcall(CreateFrame, kind, frameName, parent, template)
        if ok and frame then return frame, template end
    end
end
function Native.Inset(parent, x, y, width, height)
    local frame = Native.Frame("Frame", nil, parent, { "InsetFrameTemplate" })
    if not frame then
        frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    end
    frame:SetFrameLevel(math.max(0, parent:GetFrameLevel() - 1))
    frame:EnableMouse(false)
    frame:SetPoint("TOPLEFT", x, y); frame:SetSize(width, height)
    return frame
end
function Native.RowArt(button, index)
    local stripe = button:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(); stripe:SetTexture("Interface\\GuildFrame\\GuildFrame")
    stripe:SetTexCoord(0.36230469, 0.38183594, 0.95898438, 0.99804688)
    stripe:SetAlpha(index % 2 == 0 and 0.16 or 0.04)
    button.bg = button:CreateTexture(nil, "ARTWORK"); button.bg:SetAllPoints()
    button.bg:SetColorTexture(0.12, 0.32, 0.62, 0)
    button:SetHighlightTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar", "ADD")
    local highlight = button:GetHighlightTexture()
    if Native.HasMethod(highlight, "SetVertexColor") then highlight:SetVertexColor(0.3, 0.5, 1, 0.3) end
end
function Native.ClearPageFocus()
    if Level.hover then Level.hover = nil; GameTooltip:Hide() end
    if Overview.hover then Overview.hover = nil; GameTooltip:Hide() end
    for _, edit in pairs({ search = search, chat = chatBox, contact = contact, announcement = announcementEdit }) do
        if edit:HasFocus() then edit:ClearFocus() end
    end
end
function Native.ResizeTab(tab)
    if tab and tab.czuNative and type(PanelTemplates_TabResize) == "function" then
        pcall(PanelTemplates_TabResize, tab, 12)
    end
end
function Native.RefreshTabs()
    local current = (page == "stats" or page == "levels") and "roster" or page
    for key, tab in pairs(tabs) do
        local active = key == current
        tab.czuSelected = active
        local style = active and PanelTemplates_SelectTab or PanelTemplates_DeselectTab
        if tab.czuNative and type(style) == "function" then
            pcall(style, tab)
        else
            if active then tab:Disable() else tab:Enable() end
        end
        Native.ResizeTab(tab)
    end
end
local function Enable(button, on) if on then button:Enable() else button:Disable() end end
local function Age(at)
    if not at then return "нет данных" end
    local s = math.max(0, U.stamp() - at)
    if s < 60 then return "только что" end
    return math.floor(s / 60) .. " мин назад"
end
local function GuildRows(guild)
    if guild == U.guild then return U.own end
    local cache = U.db.rosters[guild]
    return cache and cache.rows or {}
end
local function Fresh(guild)
    if U.RosterFresh then return U.RosterFresh(guild) end
    return guild == U.guild and U.own[U.me] ~= nil
end
local function Color(row)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[row.class]
    if c then return c.r, c.g, c.b end
    return 0.85, 0.87, 0.9
end
local rosterTooltipOwner, rosterContext, rosterContextFallback
function Native.ClearChoiceHover()
    for _, button in ipairs(rows) do button.czuHovered = nil end
    rosterTooltipOwner = nil; GameTooltip:Hide()
end
local function RosterAddonInfo(row)
    return row and U.AddonInfo and U.AddonInfo(row.name, row.guild) or { known = false }
end
local function ShowRosterTooltip(button)
    if rosterContext or U.choiceMenu then return end
    local row = button.row
    if not row or not button:IsShown() then return end
    local info = RosterAddonInfo(row)
    rosterTooltipOwner = button
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(U.SafeDisplay(row.name), 1, 1, 1)
    GameTooltip:AddLine(U.SafeDisplay(U.GUILDS[row.guild]), 0.72, 0.77, 0.82)
    local class = U.ClassInfo(row.class)
    GameTooltip:AddLine("Класс: " .. U.SafeDisplay(class.label), 0.8, 0.85, 0.9)
    GameTooltip:AddLine("Локация: " .. U.SafeDisplay(row.zone or "неизвестна"), 0.8, 0.85, 0.9, true)
    GameTooltip:AddLine("Звание: " .. U.SafeDisplay(row.rankName or "неизвестно"), 0.8, 0.85, 0.9, true)
    local activity = Native.Activity(row)
    GameTooltip:AddLine("Последний вход: " .. U.SafeDisplay(Native.ActivityLabel(activity)), 1, 0.82, 0, true)
    if U.Text(activity.details, 1500) then GameTooltip:AddLine(U.SafeDisplay(activity.details), 0.8, 0.85, 0.9, true) end
    if type(activity.sourceAt) == "number" then
        GameTooltip:AddLine((activity.fresh and "Сведения обновлены: " or "Сохранено: ") .. Age(activity.sourceAt), 0.65, 0.7, 0.75)
    end
    if not activity.fresh then GameTooltip:AddLine("Текущий вход не подтверждён свежими данными.", 0.65, 0.7, 0.75, true) end
    if info.known == true then
        local version = U.Text(info.version, 40) and info.version or "версия неизвестна"
        GameTooltip:AddLine("ChillZoneUnion: " .. U.SafeDisplay(version), 0.85, 0.9, 0.95)
        GameTooltip:AddLine(info.live and "Аддон подтверждён сейчас" or "Сведения сохранены",
            info.live and 0.45 or 0.6, info.live and 0.85 or 0.65, info.live and 0.78 or 0.68)
        if not info.live and type(info.lastSeen) == "number" then
            GameTooltip:AddLine("Последнее подтверждение: " .. Age(info.lastSeen), 0.6, 0.65, 0.68)
        end
    else
        GameTooltip:AddLine("Статус аддона неизвестен", 0.65, 0.68, 0.72)
    end
    GameTooltip:Show()
end
function U.RosterRowEnter(button)
    if rosterContext or U.choiceMenu then button.czuHovered = nil; return end
    if rosterTooltipOwner and rosterTooltipOwner ~= button then rosterTooltipOwner.czuHovered = nil end
    button.czuHovered = true
    ShowRosterTooltip(button)
end
function U.RosterRowLeave(button)
    button.czuHovered = nil
    if rosterTooltipOwner == button then
        rosterTooltipOwner = nil
        GameTooltip:Hide()
    end
end
local function PendingRequest()
    return U.IsTrustOfficer and U.IsTrustOfficer() and U.PendingLink and U.PendingLink() or nil
end
local function ConnectionView()
    if U.ConnectionView then return U.ConnectionView() end
    local ready, hasContacts = U.guild and U.own[U.me] ~= nil, false
    for _, entry in pairs(U.db and U.db.contacts or {}) do
        if entry.approved == true and entry.guild == U.OtherGuild() then hasContacts = true; break end
    end
    local role = not U.guild and "outside" or not ready and "loading"
        or U.IsTrustOfficer and U.IsTrustOfficer() and "officer"
        or U.CanRelay and U.CanRelay() and "relay" or "member"
    local setup = U.SetupState and U.SetupState() or {}
    return { role = role, stage = U.Connected() and "connected" or PendingRequest() and "pending" or setup.state or "idle",
        message = setup.message, hasContacts = hasContacts, connected = U.Connected() }
end
local function Connection()
    if not U.guild then return "Вне гильдии", 0.55, 0.58, 0.62 end
    if PendingRequest() then return "Требуется ваше подтверждение", 1, 0.78, 0.2 end
    if U.Connected() then return "Союз на связи", 0.3, 0.85, 0.57 end
    local setup = U.SetupState and U.SetupState()
    if setup and setup.state == "connecting" then return "Соединяемся", 0.95, 0.72, 0.3 end
    if setup and setup.state == "declined" then return "Запрос отклонён", 0.95, 0.72, 0.3 end
    if setup and setup.state == "expired" then return "Время ожидания истекло", 0.95, 0.72, 0.3 end
    return "Ожидаем связь", 0.7, 0.72, 0.76
end
local function RefreshConnection()
    local text, r, g, b = Connection()
    if headerDot then headerDot:SetVertexColor(r, g, b, 1) end
    if headerState then headerState:SetText(text) end
    local pending = PendingRequest() ~= nil
    if U.minimapButton and U.minimapButton.pendingMark then U.minimapButton.pendingMark:SetShown(pending) end
    if tabs.link then tabs.link:SetText(pending and "Связь (!)" or "Связь"); Native.ResizeTab(tabs.link) end
end
local function ChatOffset()
    local n = chatLog and chatLog:GetScrollOffset()
    return type(n) == "number" and math.max(0, n) or 0
end
local function AtBottom()
    if not chatLog then return true end
    local bottom = chatLog:AtBottom()
    if type(bottom) == "boolean" then return bottom end
    return ChatOffset() == 0
end
local function ReadingChat()
    return window and window:IsShown() and page == "chat" and AtBottom()
end
local function UpdateUnread()
    if tabs.chat then tabs.chat:SetText(unread > 0 and ("Общий чат (" .. (unread > 99 and "99+" or unread) .. ")") or "Общий чат") end
    Native.ResizeTab(tabs.chat)
    if chatJump then
        chatJump:SetText((unread > 0 and ("К новым (" .. unread .. ") ") or "В конец ") .. ArrowText("down"))
        chatJump:SetShown(unread > 0 or not AtBottom())
    end
end
local function MarkRead()
    if ReadingChat() then unread = 0 end
    UpdateUnread()
end
local function Switch(which)
    U.CloseChoiceMenu()
    U.CloseRosterContextMenu()
    Native.ClearPageFocus()
    page = which
    for name, p in pairs(pages) do p:SetShown(name == which) end
    Native.RefreshTabs()
    U.Refresh()
    if which == "chat" then U.RefreshChat(); MarkRead() end
end
local function RenderAnnouncement()
    local a = U.GetAnnouncement and U.GetAnnouncement()
    if announcementBanner then
        announcementBanner:SetText(a and a.text ~= "" and ("|cffd8c98bСообщение союза:|r " .. U.SafeDisplay(a.text)) or "|cff929ca8Сообщение союза пока не задано.|r")
    end
    return a
end

function U.CloseRosterContextMenu()
    local context = rosterContext
    rosterContext = nil
    if not context then return end
    context.active = false
    if context.menu then context.menu:Hide() end
end
local function CurrentContextRow(context)
    if rosterContext ~= context or not context.active or not window or not window:IsShown() or page ~= "roster" then return nil end
    local row = GuildRows(context.guild)[context.name]
    return row and row.name == context.name and row.guild == context.guild and row or nil
end
local function ContextCanChat(row, guild)
    return row and row.name ~= U.me and row.online == true and Fresh(guild)
end
local function ContextCanTransfer(row, guild)
    if not row or row.name == U.me or row.rank == 0 or row.online ~= true or not U.Connected() then return false end
    if guild == U.guild then
        local peer = U.peers[row.name]
        return U.IsMaster() and peer and type(peer.at) == "number" and U.clock() - peer.at <= 65 or false
    end
    local cache = U.db.rosters[guild]
    return U.IsUnionLeader() and cache and type(cache.at) == "number"
        and U.stamp() - cache.at <= 600 and cache.at <= U.stamp() + 60 or false
end
local function ContextAction(context, action)
    local row = CurrentContextRow(context)
    if not row then U.CloseRosterContextMenu(); return false end
    if action == "transfer" then
        if not ContextCanTransfer(row, context.guild) then U.CloseRosterContextMenu(); return false end
        U.CloseRosterContextMenu()
        if U.CreateTransfer(context.name, context.guild) then ticketOffset = 0; Switch("transfers"); return true end
        return false
    end
    if not ContextCanChat(row, context.guild) then U.CloseRosterContextMenu(); return false end
    U.CloseRosterContextMenu()
    ChatFrame_OpenChat((action == "invite" and "/invite " or "/w ") .. context.name .. (action == "invite" and "" or " "))
    return true
end
local function ContextEntries(context, row)
    local chat = ContextCanChat(row, context.guild) and true or false
    local entries = {
        { text = "Шепнуть", enabled = chat, action = function() return ContextAction(context, "whisper") end },
        { text = "Пригласить в группу", enabled = chat, action = function() return ContextAction(context, "invite") end },
        { text = "Предложить переход", enabled = ContextCanTransfer(row, context.guild) and true or false,
            action = function() return ContextAction(context, "transfer") end },
    }
    local info = RosterAddonInfo(row)
    if info.known == true then
        entries[#entries + 1] = { text = "ChillZoneUnion: " .. U.SafeDisplay(info.version or "версия неизвестна"), enabled = false }
        entries[#entries + 1] = { text = info.live and "Аддон подтверждён сейчас" or "Сведения сохранены", enabled = false }
    else
        entries[#entries + 1] = { text = "Статус аддона неизвестен", enabled = false }
    end
    entries[#entries + 1] = { text = "Закрыть", enabled = true, action = U.CloseRosterContextMenu }
    return entries
end
local function FallbackContextMenu(context, entries)
    if not rosterContextFallback then
        local popup = CreateFrame("Frame", "ChillZoneUnionRosterMenu", UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP"); popup:SetClampedToScreen(true); popup:EnableMouse(true)
        popup:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        popup:SetBackdropColor(0.08, 0.08, 0.08, 1)
        popup.title = Label(popup, "", 12, -12, 276, "GameFontNormal")
        popup.guild = Label(popup, "", 12, -33, 276, "GameFontHighlightSmall")
        popup.buttons = {}
        popup:SetScript("OnHide", function(self)
            if rosterContext and rosterContext.menu == self then rosterContext.active = false; rosterContext = nil end
        end)
        table.insert(UISpecialFrames, "ChillZoneUnionRosterMenu")
        rosterContextFallback = popup
    end
    local popup = rosterContextFallback
    popup:ClearAllPoints(); popup:SetPoint("TOPLEFT", context.owner, "BOTTOMLEFT", 0, 0)
    popup:SetSize(300, 66 + #entries * 27)
    popup.title:SetText(U.SafeDisplay(context.name)); popup.guild:SetText(U.SafeDisplay(U.GUILDS[context.guild]))
    for i, entry in ipairs(entries) do
        local button = popup.buttons[i]
        if not button then button = Button(popup, "", 10, -55 - (i - 1) * 27, 280); popup.buttons[i] = button end
        button:SetText(entry.text); Enable(button, entry.enabled); button:SetScript("OnClick", entry.action); button:Show()
    end
    for i = #entries + 1, #popup.buttons do popup.buttons[i]:Hide() end
    context.menu = popup
    popup:Show()
end
function U.OpenRosterContextMenu(owner)
    U.CloseChoiceMenu()
    U.CloseRosterContextMenu()
    local row = owner and owner.row
    if not row or not window or not window:IsShown() or page ~= "roster" then return false end
    local context = { owner = owner, name = row.name, guild = row.guild, active = true }
    rosterContext = context
    for _, button in ipairs(rows) do button.czuHovered = nil end
    rosterTooltipOwner = nil; GameTooltip:Hide()
    local entries = ContextEntries(context, row)
    if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
        context.menu = MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(U.SafeDisplay(context.name)); root:CreateTitle(U.SafeDisplay(U.GUILDS[context.guild]))
            root:CreateDivider()
            for _, entry in ipairs(entries) do
                local description = root:CreateButton(entry.text, entry.action)
                description:SetEnabled(entry.enabled)
            end
        end)
        if context.menu then
            context.menu.czuRosterContext = context
            if not context.menu.czuRosterOnHideHooked then
                context.menu.czuRosterOnHideHooked = true
                context.menu:HookScript("OnHide", function(menu)
                    local current = menu.czuRosterContext
                    menu.czuRosterContext = nil
                    if current and rosterContext == current then current.active = false; rosterContext = nil end
                end)
            end
        else U.CloseRosterContextMenu(); return false end
    else FallbackContextMenu(context, entries) end
    return true
end
function U.RosterRowClick(button, mouseButton)
    U.CloseRosterContextMenu()
    if not button.row then return end
    selected = button.row; RenderRoster()
    if mouseButton == "RightButton" then U.OpenRosterContextMenu(button) end
end
function U.RosterRowDoubleClick(button, mouseButton)
    if mouseButton ~= "LeftButton" or not button.row then return end
    U.CloseRosterContextMenu()
    local row = GuildRows(button.row.guild)[button.row.name]
    if row and ContextCanChat(row, row.guild) then ChatFrame_OpenChat("/w " .. row.name .. " ") end
end
function U.RosterRowHide(button)
    U.RosterRowLeave(button)
    if rosterContext and rosterContext.owner == button then U.CloseRosterContextMenu() end
end

RenderRoster = function()
    if not window then return end
    local all, summary, fresh, activity = {}, {}, {}, {}
    local function Activity(row)
        if not activity[row] then activity[row] = Native.Activity(row) end
        return activity[row]
    end
    local classes = {}
    local function Class(row)
        local token = type(row.class) == "string" and row.class or ""
        if not classes[token] then
            local info = U.ClassInfo(token)
            info.sortName = U.Fold(info.label)
            classes[token] = info
        end
        return classes[token]
    end
    local onlineTotal, memberTotal, unknownOnline, unknownMembers, cached = 0, 0, false, false, false
    local needle = U.Fold(search:GetText() or "")
    for guild = 1, 2 do
        local online, total = 0, 0
        fresh[guild] = Fresh(guild)
        local cache = U.db.rosters[guild]
        local known = guild == U.guild and U.own[U.me] ~= nil or cache ~= nil
        for _, row in pairs(GuildRows(guild)) do
            total = total + 1
            if fresh[guild] and row.online then online = online + 1 end
            local text = U.Fold(row.name .. " " .. Class(row).label .. " " .. (row.rankName or "") .. " " .. (row.zone or ""))
            local location = Overview.location
            local zone = type(row.zone) == "string" and U.Trim(row.zone) or ""
            local locationMatches = not location or (fresh[guild] and row.online == true
                and (location.unknown and zone == "" or not location.unknown and U.Fold(zone) == location.key))
            if (guildFilter == 0 or guildFilter == guild) and (offline:GetChecked() or not fresh[guild] or row.online)
                and locationMatches and (needle == "" or text:find(needle, 1, true))
                and (Native.activity.days == 0 or U.MatchesInactivity and U.MatchesInactivity(row, Native.activity.days)) then all[#all + 1] = row end
        end
        memberTotal, onlineTotal = memberTotal + total, onlineTotal + online
        if not fresh[guild] then unknownOnline = true; if known then cached = true end end
        if not known then unknownMembers = true end
        local rosterState = U.RosterState and U.RosterState(guild)
        local savedAt = rosterState and rosterState.at or (cache and cache.at)
        local suffix = not known and " • загружаем" or (not fresh[guild] and (" • сохранено " .. Age(savedAt)) or "")
        summary[#summary + 1] = U.GUILDS[guild] .. ": " .. (fresh[guild] and online or "?") .. " / " .. (known and total or "?") .. suffix
    end
    counts:SetText("В сети: " .. onlineTotal .. (unknownOnline and " + ?" or "") .. "     •     Участников: " .. memberTotal
        .. (unknownMembers and " + ?" or (cached and " (по последним данным)" or "")))
    guildCounts:SetText(table.concat(summary, "     |     "))
    local function Before(a, b)
        return sortDirection == 1 and a < b or sortDirection == -1 and a > b
    end
    local function LocationKey(row)
        if not fresh[row.guild] then return 3, "" end
        if not row.online then return 2, "" end
        return 1, U.Fold(row.zone or "")
    end
    table.sort(all, function(a, b)
        local an, bn = U.Fold(a.name), U.Fold(b.name)
        if sortKey == "class" then
            local ac, bc = Class(a), Class(b)
            local au, bu = ac.class == "UNKNOWN", bc.class == "UNKNOWN"
            if au ~= bu then return not au end
            if ac.sortName ~= bc.sortName then return Before(ac.sortName, bc.sortName) end
        elseif sortKey == "level" then
            local av, bv = tonumber(a.level) or 0, tonumber(b.level) or 0
            if av ~= bv then return Before(av, bv) end
        elseif sortKey == "rank" then
            local av, bv = tonumber(a.rank) or math.huge, tonumber(b.rank) or math.huge
            if av ~= bv then return Before(av, bv) end
        elseif sortKey == "zone" then
            local ag, az = LocationKey(a)
            local bg, bz = LocationKey(b)
            if ag ~= bg then return Before(ag, bg) end
            if az ~= bz then return Before(az, bz) end
        elseif sortKey == "lastSeen" then
            local aa, ba = Activity(a), Activity(b)
            local av, bv = Native.ActivityOrder(aa), Native.ActivityOrder(ba)
            if (av ~= nil) ~= (bv ~= nil) then return av ~= nil end
            if av ~= nil and bv ~= nil and av ~= bv then return Before(av, bv) end
        elseif sortKey == "name" then
            if an ~= bn then return Before(an, bn) end
        else
            local ao, bo = fresh[a.guild] and a.online == true, fresh[b.guild] and b.online == true
            if ao ~= bo then return ao end
        end
        if an ~= bn then return an < bn end
        if a.guild ~= b.guild then return a.guild < b.guild end
        return a.name < b.name
    end)
    for key, header in pairs(sortHeaders) do
        header.sortArrow:SetTexture(ARROW_MEDIA .. (sortDirection == 1 and "up" or "down"))
        header.sortArrow:SetShown(sortKey == key)
    end
    offset = math.max(0, math.min(offset, math.max(0, #all - #rows)))
    local hovered
    for i, b in ipairs(rows) do
        local row = all[offset + i]
        b.row = row; b:SetShown(row ~= nil)
        if row then
            local r, g, blue = Color(row)
            local dim = fresh[row.guild] and (row.online and 1 or 0.65) or 0.75
            local addon = RosterAddonInfo(row)
            b.addonBadge:SetShown(addon.known == true)
            if addon.live then b.addonBadge:SetTextColor(0.45, 0.85, 0.78)
            else b.addonBadge:SetTextColor(0.45, 0.5, 0.53) end
            b.name:SetText(U.SafeDisplay(row.name)); b.name:SetTextColor(r * dim, g * dim, blue * dim)
            local info = Class(row)
            b.classText:SetText(U.SafeDisplay(info.label))
            b.classText:SetTextColor(info.color.r * dim, info.color.g * dim, info.color.b * dim)
            b.guild:SetText(U.GUILDS[row.guild]); b.guild:SetTextColor(0.62, 0.69, 0.73)
            b.level:SetText(tostring(row.level))
            b.zone:SetText(fresh[row.guild] and U.SafeDisplay(row.online and row.zone or "Не в сети") or "Нет свежих данных")
            b.rank:SetText(U.SafeDisplay(row.rankName))
            local lastLogin = Activity(row)
            b.activity:SetText(U.SafeDisplay(Native.ActivityLabel(lastLogin)))
            if lastLogin.online and lastLogin.fresh then b.activity:SetTextColor(0.45, 0.85, 0.57)
            elseif lastLogin.known and lastLogin.fresh then b.activity:SetTextColor(0.85, 0.87, 0.9)
            else b.activity:SetTextColor(0.6, 0.65, 0.68) end
            b.bg:SetColorTexture(0.12, 0.32, 0.62, selected and selected.name == row.name and selected.guild == row.guild and 0.45 or 0)
            if b.czuHovered then hovered = b end
        else
            b.addonBadge:Hide()
            U.RosterRowLeave(b)
        end
    end
    pages.roster.range:SetText((#all > 0 and (offset + 1) or 0) .. "–" .. math.min(offset + #rows, #all) .. " из " .. #all)
    Native.activity.empty:SetShown(Native.activity.days > 0 and #all == 0)
    pages.roster.selection:SetText(selected and ("Выбран: " .. U.SafeDisplay(selected.name) .. " — «" .. U.GUILDS[selected.guild] .. "»") or "Выберите участника для шёпота, приглашения в группу или предложения перехода.")
    Enable(pages.roster.move, selected and selected.rank ~= 0 and selected.name ~= U.me
        and ((selected.guild == U.guild and U.IsMaster()) or (selected.guild ~= U.guild and U.IsUnionLeader())))
    if rosterContext and (not rosterContext.owner.row or rosterContext.owner.row.name ~= rosterContext.name
        or rosterContext.owner.row.guild ~= rosterContext.guild) then U.CloseRosterContextMenu() end
    if hovered then ShowRosterTooltip(hovered) end
    Native.RefreshLocationFilter()
end
local states = { proposed = "Ожидает согласия", pending = "Ждём подтверждения второй гильдии", accept_error = "Согласие не подтверждено; повторите", replaced = "Заменена новой заявкой", accepted = "Согласие подтверждено; ждёт выхода", ready = "Можно пригласить", declined = "Отказ", done = "Завершён" }
local function TicketPriority(t)
    if t.member == U.me and (t.state == "proposed" or t.state == "pending" or t.state == "accept_error" or t.state == "accepted") then return 1 end
    if t.dest == U.guild and t.state == "ready" and U.CanInvite() then return 2 end
    if t.state ~= "done" and t.state ~= "declined" and t.state ~= "replaced" then return 3 end
    return 4
end
RenderTickets = function()
    if not window then return end
    local all = {}
    for _, t in pairs(U.Tickets()) do if U.stamp() - t.created < 1800 then all[#all + 1] = t end end
    table.sort(all, function(a, b)
        local ap, bp = TicketPriority(a), TicketPriority(b)
        if ap ~= bp then return ap < bp end
        if a.created ~= b.created then return a.created > b.created end
        return a.id < b.id
    end)
    ticketOffset = math.max(0, math.min(ticketOffset, math.max(0, #all - #ticketRows)))
    for i, b in ipairs(ticketRows) do
        local t = all[ticketOffset + i]; b.ticket = t; b:SetShown(t ~= nil)
        if t then
            b:SetText(U.SafeDisplay(t.member) .. " " .. ArrowText("right", 10) .. " " .. U.GUILDS[t.dest] .. "   •   " .. (states[t.state] or t.state))
            b.bg:SetColorTexture(0.12, 0.32, 0.62, t.id == selectedTicket and 0.45 or 0)
        end
    end
    pages.transfers.range:SetText((#all > 0 and ticketOffset + 1 or 0) .. "–" .. math.min(ticketOffset + #ticketRows, #all) .. " из " .. #all)
    local t = selectedTicket and U.Tickets()[selectedTicket]
    if t and U.stamp() - t.created >= 1800 then t = nil end
    ticketInfo:SetText(t and (U.SafeDisplay(t.member) .. "\n" .. U.GUILDS[t.source] .. " " .. ArrowText("right", 10) .. " " .. U.GUILDS[t.dest] .. "\nГлава: " .. U.SafeDisplay(t.master) .. "\n" .. (states[t.state] or t.state)) or "Выберите переход в списке.\n\nВаши заявки и переходы, где нужно действие, показаны первыми.\n\nПредложение создаётся главой из вкладки «Состав». Участник принимает его и выходит штатной командой. Офицер второй гильдии отправляет приглашение.\n\nЗаявки действуют 30 минут.")
    local mine = t and t.member == U.me and t.source == U.guild
    Enable(acceptButton, mine and (t.state == "proposed" or t.state == "accept_error"))
    acceptButton:SetText(t and t.state == "accept_error" and "Повторить согласие" or "Согласиться")
    Enable(declineButton, mine and (t.state == "proposed" or t.state == "pending" or t.state == "accept_error"))
    Enable(leaveButton, mine and U.TransferConfirmed and U.TransferConfirmed(t))
    Enable(inviteButton, t and t.dest == U.guild and t.state == "ready" and U.CanInvite())
end
local function ClassCount(value, known)
    if value ~= nil then return tostring(value) end
    if known and known > 0 then return tostring(known) .. " + ?" end
    return "?"
end
local function ClassCountPair(record)
    return ClassCount(record.online, record.knownOnline) .. " / " .. ClassCount(record.total, record.knownTotal)
end
RenderClassStats = function()
    local data = U.ClassStatistics()
    classOffset = math.max(0, math.min(classOffset, math.max(0, #data.rows - #classRows)))
    classSummary:SetText("В сети / всего. Считаем персонажей обеих гильдий, включая офлайн; фильтры списка не влияют.")
    classRange:SetText((#data.rows > 0 and classOffset + 1 or 0) .. "-" .. math.min(classOffset + #classRows, #data.rows) .. " из " .. #data.rows)
    for guild = 1, 2 do
        local state = data.guilds[guild]
        classGuildStates[guild]:SetText(not state.known and "Нет данных" or (state.fresh and "Актуальные данные" or ("Сохранено: " .. Age(state.at))))
        classTotals[guild]:SetText(ClassCountPair(state))
    end
    classTotals.union:SetText(ClassCountPair(data))
    for index, frame in ipairs(classRows) do
        local row = data.rows[classOffset + index]
        frame.statsRow = row; frame:SetShown(row ~= nil)
        if row then
            frame.name:SetText(U.SafeDisplay(row.label))
            frame.name:SetTextColor(row.color.r, row.color.g, row.color.b)
            frame.guild1:SetText(ClassCountPair(row.guilds[1]))
            frame.guild2:SetText(ClassCountPair(row.guilds[2]))
            frame.union:SetText(ClassCountPair(row))
        end
    end
end
local function BuildClassStats(stats)
    Native.Inset(stats, -8, -79, 966, 349)
    Button(stats, "К списку", 0, 0, 130, function() Switch("roster") end)
    Label(stats, "Статистика по классам", 155, -4, 460, "GameFontNormalLarge")
    Button(stats, "По уровням", 630, 0, 180, function() U.OpenLevelStats() end)
    Button(stats, "Обновить", 820, 0, 130, function() U.RequestRoster(); U.snapshotDue = 0; RenderClassStats() end)
    classSummary = Label(stats, "", 0, -41, 950, "GameFontHighlightSmall")
    classSummary:SetHeight(35); classSummary:SetJustifyV("TOP")
    Label(stats, "Класс", 5, -85, 220, "GameFontNormal")
    Label(stats, U.GUILDS[1], 240, -85, 220, "GameFontNormal")
    Label(stats, U.GUILDS[2], 485, -85, 240, "GameFontNormal")
    Label(stats, "Весь союз", 750, -85, 195, "GameFontNormal")
    classGuildStates[1] = Label(stats, "", 240, -107, 220, "GameFontHighlightSmall")
    classGuildStates[2] = Label(stats, "", 485, -107, 240, "GameFontHighlightSmall")
    for i = 1, 11 do
        local frame = CreateFrame("Frame", nil, stats)
        frame:SetSize(950, 22); frame:SetPoint("TOPLEFT", 0, -130 - (i - 1) * 22)
        local background = frame:CreateTexture(nil, "BACKGROUND"); background:SetAllPoints()
        background:SetTexture("Interface\\GuildFrame\\GuildFrame")
        background:SetTexCoord(0.36230469, 0.38183594, 0.95898438, 0.99804688)
        background:SetAlpha(i % 2 == 0 and 0.16 or 0.04)
        frame.name = Label(frame, "", 5, -4, 220)
        frame.guild1 = Label(frame, "", 240, -4, 220)
        frame.guild2 = Label(frame, "", 485, -4, 240)
        frame.union = Label(frame, "", 750, -4, 195)
        classRows[i] = frame
    end
    stats:EnableMouseWheel(true)
    stats:SetScript("OnMouseWheel", function(_, delta) classOffset = classOffset - delta * 3; RenderClassStats() end)
    Label(stats, "Всего персонажей", 5, -397, 220, "GameFontNormal")
    classTotals[1] = Label(stats, "", 240, -397, 220, "GameFontNormal")
    classTotals[2] = Label(stats, "", 485, -397, 240, "GameFontNormal")
    classTotals.union = Label(stats, "", 750, -397, 195, "GameFontNormal")
    classRange = Label(stats, "", 750, -435, 195, "GameFontHighlightSmall")
    local note = Label(stats, "? — данных пока нет. У сохранённого состава онлайн неизвестен.\nЕсли классы не помещаются, прокрутите колесом мыши.", 0, -435, 730, "GameFontHighlightSmall")
    note:SetHeight(34); note:SetJustifyV("TOP")

end
function Native.LevelRecord(record)
    return Level.scope == 0 and record or record.guilds[Level.scope]
end
function Native.LevelValue(record)
    local scoped = Native.LevelRecord(record)
    local value = scoped[Level.mode]
    local known = scoped[Level.mode == "online" and "knownOnline" or "knownTotal"]
    return value, known or value or 0
end
function Native.LevelTooltip(frame)
    local row = frame.levelRow
    if not row then return end
    Level.hover = frame
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.unknown and "Уровень неизвестен" or ("Уровни: " .. row.label), 1, 0.82, 0)
    for guild = 1, 2 do
        GameTooltip:AddLine(U.SafeDisplay(U.GUILDS[guild]) .. ": " .. ClassCountPair(row.guilds[guild]), 0.85, 0.87, 0.9)
    end
    GameTooltip:AddLine("Весь союз: " .. ClassCountPair(row), 1, 1, 1)
    if Level.data then
        local value, known = Native.LevelValue(row)
        local total, totalKnown = Native.LevelValue(Level.data)
        if total and total > 0 and value then
            GameTooltip:AddLine(("Доля выбранной группы: %.1f%%"):format(value * 100 / total), 0.8, 0.8, 0.8)
        elseif totalKnown > 0 then
            GameTooltip:AddLine(("Доля среди известных: %.1f%%"):format(known * 100 / totalKnown), 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:AddLine("В сети / всего; считаем персонажей, включая офлайн.", 0.65, 0.68, 0.72)
    GameTooltip:Show()
end
function Native.LevelScroll(_, delta)
    Level.offset = Level.offset - delta * 3
    Native.RenderLevelStats()
end
function Native.RenderLevelStats()
    if not Level.page then return end
    local data = U.LevelStatistics(Level.step)
    Level.data = data
    Level.offset = math.max(0, math.min(Level.offset, math.max(0, #data.rows - #Level.rows)))
    local peak = 1
    for _, row in ipairs(data.rows) do local _, known = Native.LevelValue(row); peak = math.max(peak, known) end
    Native.RefreshChoice(Level.scopeButton)
    Level.modeButton:SetChecked(Level.mode == "online")
    Native.RefreshChoice(Level.stepButton)
    local freshness = {}
    for guild = 1, 2 do
        if Level.scope == 0 or Level.scope == guild then
            local state = data.guilds[guild]
            freshness[#freshness + 1] = U.GUILDS[guild] .. ": " .. (not state.known and "нет данных"
                or (state.fresh and "актуально" or ("сохранено " .. Age(state.at))))
        end
    end
    Level.summary:SetText("В сети / всего: " .. ClassCountPair(Native.LevelRecord(data)) .. "     •     Фильтры состава не влияют.\n" .. table.concat(freshness, "     |     "))
    Level.range:SetText((Level.offset + 1) .. "–" .. math.min(Level.offset + #Level.rows, #data.rows) .. " из " .. #data.rows)
    Enable(Level.previous, Level.offset > 0)
    Enable(Level.next, Level.offset + #Level.rows < #data.rows)
    for index, frame in ipairs(Level.rows) do
        local row = data.rows[Level.offset + index]
        frame.levelRow = row; frame:SetShown(row ~= nil)
        if row then
            local value, known = Native.LevelValue(row)
            frame.name:SetText(U.SafeDisplay(row.label))
            frame.value:SetText(ClassCount(value, known))
            frame.counts:SetText(ClassCountPair(Native.LevelRecord(row)))
            frame.bar:SetMinMaxValues(0, peak); frame.bar:SetValue(known); frame.bar:SetShown(known > 0)
            if Level.mode == "online" then frame.bar:SetStatusBarColor(0.25, 0.78, 0.35)
            elseif Level.scope == 1 then frame.bar:SetStatusBarColor(0.25, 0.65, 0.85)
            elseif Level.scope == 2 then frame.bar:SetStatusBarColor(0.65, 0.45, 0.85)
            else frame.bar:SetStatusBarColor(0.85, 0.65, 0.22) end
        end
    end
    if Level.hover then Native.LevelTooltip(Level.hover) end
end
function Native.BuildLevelStats(body)
    local p = CreateFrame("Frame", "ChillZoneUnionLevelStatistics", window)
    p:SetPoint("TOPLEFT", 24, -86); p:SetPoint("BOTTOMRIGHT", -24, 54)
    p:SetFrameLevel(body:GetFrameLevel() + 2); p:Hide()
    pages.levels, Level.page = p, p
    Button(p, "К списку", 0, 0, 130, function() Switch("roster") end).czuLevelAction = "back"
    Label(p, "Распределение по уровням", 155, -4, 460, "GameFontNormalLarge")
    Button(p, "По классам", 630, 0, 180, function() U.OpenClassStats() end).czuLevelAction = "classes"
    Button(p, "Обновить", 820, 0, 130, function() U.RequestRoster(); U.snapshotDue = 0; Native.RenderLevelStats() end).czuLevelAction = "refresh"
    Level.scopeButton = Native.Choice(p, "level-scope", "Весь союз", 0, -40, 270, Native.GuildChoices,
        function() return Level.scope end,
        function(value) Level.scope, Level.offset = value, 0; Native.RenderLevelStats() end)
    Level.scopeButton.czuLevelAction = "scope"
    Level.modeButton = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    Level.modeButton:SetSize(24, 24); Level.modeButton:SetPoint("TOPLEFT", 285, -40)
    Label(p, "Только онлайн", 313, -47, 130, "GameFontHighlightSmall")
    Level.modeButton:SetScript("OnClick", function(self)
        Level.mode, Level.offset = self:GetChecked() == true and "online" or "total", 0
        Native.RenderLevelStats()
    end)
    Level.modeButton.czuLevelAction = "mode"
    Level.stepButton = Native.Choice(p, "level-step", "По 10 уровней", 450, -40, 180,
        function() return { { value = 1, text = "Каждый уровень" }, { value = 5, text = "По 5 уровней" }, { value = 10, text = "По 10 уровней" } } end,
        function() return Level.step end,
        function(value) Level.step, Level.offset = value, 0; Native.RenderLevelStats() end)
    Level.stepButton.czuLevelAction = "step"
    Level.summary = Label(p, "", 0, -76, 950, "GameFontHighlightSmall")
    Level.summary:SetHeight(31); Level.summary:SetJustifyV("TOP")
    p.summary = Level.summary
    Native.Inset(p, -8, -106, 966, 328)
    Label(p, "Уровни", 5, -112, 100, "GameFontNormal")
    Label(p, "Количество персонажей", 120, -112, 550, "GameFontNormal")
    Label(p, "В сети / всего", 755, -112, 190, "GameFontNormal")
    for i = 1, 11 do
        local frame = CreateFrame("Frame", nil, p)
        frame:SetSize(950, 24); frame:SetPoint("TOPLEFT", 0, -136 - (i - 1) * 26); frame:EnableMouse(true)
        local stripe = frame:CreateTexture(nil, "BACKGROUND"); stripe:SetAllPoints()
        stripe:SetTexture("Interface\\GuildFrame\\GuildFrame")
        stripe:SetTexCoord(0.36230469, 0.38183594, 0.95898438, 0.99804688)
        stripe:SetAlpha(i % 2 == 0 and 0.16 or 0.04)
        frame.name = Label(frame, "", 5, -6, 105, "GameFontHighlightSmall")
        local track = frame:CreateTexture(nil, "BACKGROUND"); track:SetSize(550, 16); track:SetPoint("LEFT", 120, 0)
        track:SetColorTexture(0, 0, 0, 0.4)
        frame.bar = CreateFrame("StatusBar", nil, frame)
        frame.bar:SetSize(550, 16); frame.bar:SetPoint("LEFT", 120, 0)
        frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); frame.bar:EnableMouse(false)
        frame.value = Label(frame, "", 680, -6, 70, "GameFontHighlightSmall")
        frame.counts = Label(frame, "", 755, -6, 190, "GameFontHighlightSmall")
        frame:SetScript("OnEnter", Native.LevelTooltip)
        frame:EnableMouseWheel(true); frame:SetScript("OnMouseWheel", Native.LevelScroll)
        local function Leave()
            if Level.hover == frame then Level.hover = nil; GameTooltip:Hide() end
        end
        frame:SetScript("OnLeave", Leave); frame:SetScript("OnHide", Leave)
        Level.rows[i] = frame
    end
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", Native.LevelScroll)
    p:SetScript("OnHide", function() if Level.hover then Level.hover = nil; GameTooltip:Hide() end end)
    Level.previous = Button(p, ArrowText("left"), 0, -447, 40, function()
        Level.offset = Level.offset - #Level.rows; Native.RenderLevelStats()
    end); Level.previous.czuLevelAction = "previous"
    Level.range = Label(p, "", 55, -453, 150, "GameFontHighlightSmall"); p.range = Level.range
    Level.next = Button(p, ArrowText("right"), 220, -447, 40, function()
        Level.offset = Level.offset + #Level.rows; Native.RenderLevelStats()
    end); Level.next.czuLevelAction = "next"
    local note = Label(p, "? — данные неизвестны. Неполные полосы показывают известную часть.\nНаведите на строку для сводки по обеим гильдиям.", 280, -450, 670, "GameFontHighlightSmall")
    note:SetHeight(34); note:SetJustifyV("TOP")
end
function Native.ClearLocationFilter(refresh)
    Overview.location = nil
    Native.RefreshLocationFilter()
    if refresh and window then offset = 0; RenderRoster() end
end
function Native.RefreshLocationFilter()
    if not Overview.filterButton then return end
    local location = Overview.location
    Overview.filterButton:SetShown(location ~= nil); Overview.filterNote:SetShown(location ~= nil)
    if location then
        Overview.filterButton:SetText((location.unknown and "Локация не указана" or ("Локация: " .. U.SafeDisplay(location.name))) .. " — сбросить")
    end
    Native.RefreshActivityFilter()
end
function Native.BuildLocationFilter(parent)
    Overview.filterButton = Button(parent, "", 0, -482, 530, function() Native.ClearLocationFilter(true) end)
    Overview.filterButton.czuLocationClear = true
    Overview.filterNote = Label(parent, "Только участники онлайн со свежими данными.", 545, -488, 405, "GameFontHighlightSmall")
    Native.activity.note = Label(parent, "", 0, -488, 950, "GameFontHighlightSmall")
    Native.RefreshLocationFilter()
end
function Native.OverviewCount(zone)
    if Overview.scope == 0 then return zone.online, zone.knownOnline end
    local value = zone.guilds[Overview.scope].online
    return value, value or 0
end
function Native.OverviewTooltip(frame)
    local row = frame.zoneRow
    if not row then return end
    Overview.hover = frame
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.unknown and "Локация не указана" or U.SafeDisplay(row.name), 1, 0.82, 0)
    for guild = 1, 2 do
        GameTooltip:AddLine(U.SafeDisplay(U.GUILDS[guild]) .. ": " .. ClassCount(row.guilds[guild].online), 0.85, 0.87, 0.9)
    end
    GameTooltip:AddLine("Всего онлайн: " .. ClassCount(row.online, row.knownOnline), 1, 1, 1)
    GameTooltip:AddLine("Нажмите, чтобы открыть участников этой локации.", 0.65, 0.68, 0.72)
    GameTooltip:Show()
end
function Native.OverviewScroll(_, delta)
    Overview.offset = Overview.offset - delta * 3
    Native.RenderOverview()
end
function Native.RenderOverview()
    if not Overview.page then return end
    local data = U.OverviewStatistics()
    Overview.data = data
    Overview.summary:SetText("В сети / всего: " .. ClassCountPair(data) .. "     •     " .. Connection())
    for guild, frame in ipairs(Overview.cards) do
        local state = data.guilds[guild]
        frame.guildSummary = state
        frame.counts:SetText("В сети / всего: " .. ClassCountPair(state))
        frame.state:SetText(not state.known and "Нет данных" or (state.fresh and "Актуально" or ("Сохранено " .. Age(state.at))))
        frame.levels:SetText("Средний ур.: " .. (state.avgLevel and ("%.1f"):format(state.avgLevel) or "?") .. "     Максимальный: " .. (state.maxLevel or "?")
            .. (state.levelComplete == false and state.levelCount > 0 and (" (по " .. state.levelCount .. ")") or ""))
        frame.leader:SetText("Глава: " .. U.SafeDisplay(state.leader or "нет данных"))
        if state.addonCount ~= nil then
            frame.addons:SetText("Аддон подтверждён: " .. state.addonCount .. (state.addonUnknownOnline > 0 and ("; не проверено: " .. state.addonUnknownOnline) or " (все онлайн)"))
        else frame.addons:SetText("Аддон: нет свежих подтверждений") end
    end
    local locations = {}
    for _, row in ipairs(data.zones) do
        local _, known = Native.OverviewCount(row)
        if known > 0 then locations[#locations + 1] = { zone = row, count = known } end
    end
    table.sort(locations, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.zone.key < b.zone.key
    end)
    Overview.offset = math.max(0, math.min(Overview.offset, math.max(0, #locations - #Overview.rows)))
    local peak = #locations > 0 and math.max(1, locations[1].count) or 1
    Native.RefreshChoice(Overview.scopeButton)
    Overview.range:SetText((#locations > 0 and Overview.offset + 1 or 0) .. "–" .. math.min(Overview.offset + #Overview.rows, #locations) .. " из " .. #locations)
    Enable(Overview.previous, Overview.offset > 0)
    Enable(Overview.next, Overview.offset + #Overview.rows < #locations)
    Overview.empty:SetShown(#locations == 0)
    local state = Overview.scope == 0 and data or data.guilds[Overview.scope]
    Overview.empty:SetText(state.online == nil and "Ожидаем свежие данные о локациях." or "Нет участников онлайн.")
    if U.UnionMapPinsEnabled then Overview.pins:SetChecked(U.UnionMapPinsEnabled()) end
    if U.UnionMapStatus then
        local map = U.UnionMapStatus(data)
        Overview.mapState:SetText(not map.enabled and "Метки союза на карте выключены."
            or (not map.available and (map.reason or "Карта этого клиента недоступна."))
            or (map.unmappedZones and map.unmappedZones > 0 and ("Зон без привязки к карте: " .. map.unmappedZones))
            or "Метки показывают численность в центре локации.")
    end
    for index, frame in ipairs(Overview.rows) do
        local item = locations[Overview.offset + index]
        frame.zoneRow = item and item.zone or nil; frame:SetShown(item ~= nil)
        if item then
            local row = item.zone
            local value, known = Native.OverviewCount(row)
            frame.name:SetText(row.unknown and "Локация не указана" or U.SafeDisplay(row.name))
            frame.count:SetText(ClassCount(value, known))
            frame.bar:SetMinMaxValues(0, peak); frame.bar:SetValue(known)
            frame.bar:SetStatusBarColor(0.25, 0.67, 0.82)
        end
    end
    if Overview.hover then Native.OverviewTooltip(Overview.hover) end
end
function Native.BuildOverview(body)
    local p = pages.overview
    _G.ChillZoneUnionOverview = p
    Overview.page = p
    Label(p, "Обзор союза", 0, -4, 450, "GameFontNormalLarge")
    Button(p, "Классы", 490, 0, 105, function() U.OpenClassStats() end).czuOverviewAction = "classes"
    Button(p, "Уровни", 605, 0, 105, function() U.OpenLevelStats() end).czuOverviewAction = "levels"
    Button(p, "Карта мира", 720, 0, 110, function()
        if U.OpenUnionMap and U.OpenUnionMap() then window:Hide()
        else U.Print("Карта пока недоступна. Локации можно посмотреть в «Обзоре».") end
    end).czuOverviewAction = "map"
    Button(p, "Обновить", 840, 0, 110, function()
        U.RequestRoster(); U.snapshotDue = 0; if U.MarkMapDirty then U.MarkMapDirty() end; Native.RenderOverview()
    end).czuOverviewAction = "refresh"
    for guild = 1, 2 do
        local frame = CreateFrame("Frame", nil, p)
        frame:SetSize(465, 120); frame:SetPoint("TOPLEFT", (guild - 1) * 485, -42)
        Native.Inset(frame, 0, 0, 465, 120)
        Label(frame, U.GUILDS[guild], 12, -10, 245, "GameFontNormal")
        frame.state = Label(frame, "", 265, -12, 188, "GameFontHighlightSmall")
        frame.counts = Label(frame, "", 12, -35, 441, "GameFontHighlight")
        frame.levels = Label(frame, "", 12, -59, 441, "GameFontHighlightSmall")
        frame.leader = Label(frame, "", 12, -78, 441, "GameFontHighlightSmall")
        frame.addons = Label(frame, "", 12, -96, 441, "GameFontHighlightSmall")
        Overview.cards[guild] = frame
    end
    Overview.summary = Label(p, "", 0, -176, 950, "GameFontHighlightSmall")
    Overview.scopeButton = Native.Choice(p, "overview-scope", "Весь союз", 0, -204, 245, Native.GuildChoices,
        function() return Overview.scope end,
        function(value) Overview.scope, Overview.offset = value, 0; Native.RenderOverview() end)
    Overview.scopeButton.czuOverviewAction = "scope"
    Overview.pins = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    Overview.pins:SetSize(24, 24); Overview.pins:SetPoint("TOPLEFT", 270, -204); Overview.pins.czuOverviewAction = "pins"
    Label(p, "Метки союза на карте", 298, -211, 280, "GameFontHighlightSmall")
    Overview.pins:SetScript("OnClick", function(self) if U.SetUnionMapPins then U.SetUnionMapPins(self:GetChecked() == true) end; Native.RenderOverview() end)
    Overview.mapState = Label(p, "Метки показывают численность в зоне.", 580, -211, 370, "GameFontHighlightSmall")
    Native.Inset(p, -8, -236, 966, 232)
    Label(p, "Локация — нажмите для списка", 10, -242, 310, "GameFontNormal")
    Label(p, "Участники онлайн", 330, -242, 380, "GameFontNormal")
    Label(p, "Количество", 725, -242, 210, "GameFontNormal")
    for i = 1, 8 do
        local frame = CreateFrame("Button", nil, p)
        frame:SetSize(950, 22); frame:SetPoint("TOPLEFT", 0, -268 - (i - 1) * 24)
        Native.RowArt(frame, i)
        frame.name = Label(frame, "", 10, -5, 310, "GameFontHighlightSmall")
        frame.bar = CreateFrame("StatusBar", nil, frame)
        frame.bar:SetSize(380, 13); frame.bar:SetPoint("LEFT", 330, 0)
        frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); frame.bar:EnableMouse(false)
        frame.count = Label(frame, "", 725, -5, 210, "GameFontHighlightSmall")
        frame:SetScript("OnClick", function(self) if self.zoneRow then U.OpenLocationRoster(not self.zoneRow.unknown and self.zoneRow.name or nil, Overview.scope) end end)
        frame:SetScript("OnEnter", Native.OverviewTooltip)
        frame:EnableMouseWheel(true); frame:SetScript("OnMouseWheel", Native.OverviewScroll)
        local function Leave() if Overview.hover == frame then Overview.hover = nil; GameTooltip:Hide() end end
        frame:SetScript("OnLeave", Leave); frame:SetScript("OnHide", Leave)
        Overview.rows[i] = frame
    end
    Overview.empty = Label(p, "", 10, -286, 925, "GameFontHighlightSmall")
    Overview.previous = Button(p, ArrowText("left"), 0, -479, 40, function() Overview.offset = Overview.offset - #Overview.rows; Native.RenderOverview() end)
    Overview.previous.czuOverviewAction = "previous"
    Overview.range = Label(p, "", 55, -485, 150, "GameFontHighlightSmall")
    Overview.next = Button(p, ArrowText("right"), 220, -479, 40, function() Overview.offset = Overview.offset + #Overview.rows; Native.RenderOverview() end)
    Overview.next.czuOverviewAction = "next"
    p.range = Overview.range; p.summary = Overview.summary; p.empty = Overview.empty
    p:EnableMouseWheel(true); p:SetScript("OnMouseWheel", Native.OverviewScroll)
    p:SetScript("OnHide", function() if Overview.hover then Overview.hover = nil; GameTooltip:Hide() end end)
end
function U.BuildLinkApprovalControls(parent)
    local controls = {}
    controls.advanced = Button(parent, "Дополнительные действия", 0, -477, 240, function()
        Setup.advanced = not Setup.advanced; RenderLinks()
    end)
    controls.share = Button(parent, "Повторно раздать настройки", 255, -477, 310, function() U.ShareTrust(); RenderLinks() end)
    controls.share:Hide()
    controls.shareHint = Label(parent, "", 0, -443, 565, "GameFontHighlightSmall")
    controls.shareHint:SetHeight(30); controls.shareHint:SetJustifyV("TOP"); controls.shareHint:Hide()
    controls.info = Label(parent, "", 0, -253, 565, "GameFontHighlightSmall")
    controls.info:SetHeight(76); controls.info:SetJustifyV("TOP")
    controls.accept = Button(parent, "Разрешить запрос", 0, -339, 275)
    controls.decline = Button(parent, "Отклонить", 290, -339, 275)
    U.linkApprovalControls = controls
end
local function ActOnLinkRequest(name, guild, nonce, untilAt, accept)
    local request = U.PendingLink and U.PendingLink()
    local exact = U.PendingLink and U.PendingLink(name, nonce)
    if U.IsTrustOfficer and U.IsTrustOfficer() and request and request.name == name
        and request.nonce == nonce and request.guild == guild and request.untilAt == untilAt
        and exact and exact.name == name and exact.nonce == nonce then
        if accept then U.AcceptLink(name, nonce) else U.DeclineLink(name, nonce) end
    end
    RenderLinks()
end
local function RenderLinkApproval()
    local controls = U.linkApprovalControls
    if not controls then return end
    local officer = U.IsTrustOfficer and U.IsTrustOfficer()
    local view = ConnectionView()
    controls.advanced:SetShown(officer and true or false)
    controls.advanced:SetText(Setup.advanced and "Скрыть доп. действия" or "Дополнительные действия")
    controls.share:SetShown(officer and Setup.advanced and true or false)
    controls.shareHint:SetShown(officer and Setup.advanced and true or false)
    if controls.footer then controls.footer:SetShown(not (officer and Setup.advanced)) end
    controls.shareHint:SetText(view.hasContacts
        and "Повторно отправить подтверждённые контакты участникам своей гильдии. При обычном подключении это происходит автоматически."
        or "Сначала подтвердите первую связь. После этого здесь можно повторно раздать участникам проверенные настройки.")
    Enable(controls.share, officer and view.hasContacts == true and not U.ChatLocked())
    local request = officer and U.PendingLink and U.PendingLink() or nil
    controls.accept:SetShown(request ~= nil)
    controls.decline:SetShown(request ~= nil)
    Enable(controls.accept, request ~= nil and not U.ChatLocked())
    Enable(controls.decline, request ~= nil)
    controls.accept:SetScript("OnClick", nil); controls.decline:SetScript("OnClick", nil)
    if request then
        local name, guild, nonce, untilAt = request.name, request.guild, request.nonce, request.untilAt
        controls.info:SetText("Запрос от: " .. U.SafeDisplay(name)
            .. "\nЗаявленная гильдия: " .. U.SafeDisplay(U.GUILDS[guild] or "неизвестна") .. " (не проверена)."
            .. "\nСверьте полное имя в Discord или лично. Разрешайте доступ только знакомому связному.")
        controls.accept:SetScript("OnClick", function() ActOnLinkRequest(name, guild, nonce, untilAt, true) end)
        controls.decline:SetScript("OnClick", function() ActOnLinkRequest(name, guild, nonce, untilAt, false) end)
    elseif officer then
        controls.info:SetText("Новых запросов подключения нет.\nПосле первой настройки главы, офицеры и ветераны поддерживают связь автоматически.")
    else
        controls.info:SetText(view.connected
            and "Можно писать в обычный /г. Сообщения второй гильдии появятся в стандартном окне чата и на вкладке «Общий чат»."
            or "Обычный /г вашей гильдии работает уже сейчас. Сообщения другой гильдии появятся после соединения союза.")
    end
end
RenderLinks = function()
    if not window then return end
    local ready = U.guild and U.own[U.me] ~= nil
    local view = ConnectionView()
    local officer, relay = view.role == "officer", view.role == "relay"
    Setup.title:SetText((view.role == "member" or relay) and "Ручная настройка не требуется"
        or view.heading or "Связь между гильдиями")
    local step = view.stage == "pending" and 2 or view.connected and 3 or view.stage == "connecting" and 2 or 1
    for index, label in ipairs(Setup.steps) do
        label:SetShown(officer)
        if step == 3 then label:SetTextColor(0.3, 0.85, 0.57)
        elseif index == step then label:SetTextColor(1, 0.82, 0)
        else label:SetTextColor(0.57, 0.6, 0.64) end
    end
    if not U.guild then setupHint:SetText("Персонаж должен состоять в «Чиллзон» или «Чиллзон Навсегда».")
    elseif not ready then setupHint:SetText("Получаем состав и права вашей гильдии. Подождите несколько секунд.")
    elseif not officer and not relay then setupHint:SetText("Вводить имена и настраивать соединение не нужно. Аддон получит настройки автоматически от главы или офицера вашей гильдии.")
    elseif U.ChatLocked() then setupHint:SetText("Игра временно ограничила обмен сообщениями. Соединение станет доступно после снятия ограничения.")
    elseif relay then setupHint:SetText("Вы поддерживаете уже настроенную связь. Первое соединение и новые контакты подтверждают главы или офицеры; повторно настраивать союз не нужно.")
    elseif view.stage == "pending" then setupHint:SetText("Это входящий запрос. Сверьте полное имя отправителя с руководителем второй гильдии, затем нажмите «Разрешить запрос» ниже.")
    elseif view.connected then setupHint:SetText("Соединение настроено. Общий чат и состав работают; связные выбираются автоматически. Можно пользоваться обычным /г.")
    elseif view.stage == "connecting" then setupHint:SetText("Дождитесь завершения соединения. Повторно вводить имя и раздавать настройки вручную обычно не требуется.")
    else setupHint:SetText("Введите полное имя главы или офицера другой гильдии и нажмите «Подключить». Вторая сторона проверит имя и вручную разрешит запрос.") end
    Setup.contactHint:SetShown(officer or relay)
    contact:SetShown(officer or relay); connectButton:SetShown(officer or relay)
    Enable(contact, ready and U.CanRelay and U.CanRelay())
    local target = U.Name(contact:GetText() or "")
    Enable(connectButton, ready and target and U.CanStartLink and U.CanStartLink(target) and not U.ChatLocked())
    RenderLinkApproval()
    if view.message then
        setupProgress:SetText(view.message)
    elseif U.SetupState then
        local setup = U.SetupState()
        local text = setup.message or "Ожидаем соединение со второй гильдией."
        if U.Connected() then
            local cache = U.db.rosters[U.OtherGuild()]
            text = text .. "\n" .. (cache and ("Состав второй гильдии: " .. Age(cache.at) .. ".") or "Получаем состав второй гильдии…")
        end
        setupProgress:SetText(text)
    elseif U.LinkProgress then setupProgress:SetText(U.LinkProgress())
    else setupProgress:SetText(U.Connected() and "Общий чат подключён. Состав загружается автоматически." or "Ожидаем соединение со второй гильдией.") end
    Setup.chat:SetShown(PendingRequest() == nil)
    Setup.chat:ClearAllPoints(); Setup.chat:SetPoint("TOPLEFT", (officer or relay) and 290 or 0, (officer or relay) and -339 or -140)
    diagnostics:SetText("Состояние соединения\n" .. U.Status() .. "\nВерсия аддона: " .. U.VERSION)
    badgeCheck:SetChecked(U.db.showGuildBadge == true)
    noticesCheck:SetChecked(U.db.memberNotices == true)
    Native.RefreshChoice(chatWindowButton)
    local a = RenderAnnouncement()
    local master = ready and U.IsMaster()
    Enable(announcementEdit, master); Enable(announcementSave, master); Enable(announcementClear, master)
    if not announcementDirty and not announcementEdit:HasFocus() then announcementEdit:SetText(a and a.text or "") end
    announcementHint:SetText(master and "Сообщение видят обе гильдии. «Убрать» очищает его для всех." or "Сообщение видят обе гильдии. Изменить его может глава гильдии.")
    local leader = U.ExpectedLeader and U.ExpectedLeader(1) or (U.GUILD_LEADERS and U.GUILD_LEADERS[1])
    local leaderText = leader and ("Глава «Чиллзон»: " .. U.SafeDisplay(leader)) or ""
    if U.IsUnionLeader() then leaderText = leaderText .. "\nВы руководитель союза. Переходы доступны в обе стороны." end
    leaderInfo:SetText(leaderText)
end

function U.RefreshChat()
    local reading = ReadingChat()
    local nextSeen, lines, keys = {}, {}, {}
    for i, h in ipairs(U.history) do
        -- A native observation keeps its identity when the gateway supplies its ID.
        local key = h
        nextSeen[key], keys[i] = true, key
        if not seenHistory[key] then
            if not reading and h.name ~= U.me and not h.replayed then unread = unread + 1 end
        end
        if chatLog then lines[i] = U.ChatLine and U.ChatLine(h, true) or (U.SafeDisplay(h.name) .. ": " .. U.ChatText(h.text)) end
    end
    seenHistory = nextSeen
    if chatLog then
        local oldOffset, bottom, prefix = ChatOffset(), AtBottom(), #lines >= #renderedLines
        local anchorIndex = math.max(1, #renderedKeys - math.floor(oldOffset))
        local anchor = renderedKeys[anchorIndex]
        for i, line in ipairs(renderedLines) do if keys[i] ~= renderedKeys[i] or lines[i] ~= line then prefix = false; break end end
        if prefix then
            for i = #renderedLines + 1, #lines do chatLog:AddMessage(lines[i], 0.25, 1, 0.25) end
        else
            chatLog:Clear()
            for _, line in ipairs(lines) do chatLog:AddMessage(line, 0.25, 1, 0.25) end
        end
        if bottom then chatLog:ScrollToBottom()
        elseif oldOffset > 0 then
            local positions = {}
            for index, key in ipairs(keys) do positions[key] = index end
            local position = anchor and positions[anchor]
            -- The bounded history may have evicted the anchor. Keep the nearest
            -- retained neighbour, preferring the next newer message.
            if not position then
                for distance = 1, #renderedKeys do
                    local newer, older = renderedKeys[anchorIndex + distance], renderedKeys[anchorIndex - distance]
                    position = newer and positions[newer] or older and positions[older]
                    if position then break end
                end
            end
            chatLog:SetScrollOffset(position and math.max(0, #keys - position) or math.min(oldOffset, math.max(0, #keys - 1)))
        end
        renderedLines, renderedKeys = lines, keys
        RenderAnnouncement()
    end
    if reading then unread = 0 end
    UpdateUnread()
end
function U.Refresh()
    if U.MarkMapDirty then U.MarkMapDirty() end
    RefreshConnection()
    if not window or not window:IsShown() then return end
    local state = Connection()
    status:SetText(state .. "  •  Общий чат: /czu текст  •  Подробности — «Связь»")
    RenderAnnouncement()
    if page == "roster" then RenderRoster()
    elseif page == "overview" then Native.RenderOverview()
    elseif page == "stats" then RenderClassStats()
    elseif page == "levels" then Native.RenderLevelStats()
    elseif page == "transfers" then RenderTickets()
    elseif page == "link" then RenderLinks() end
end

Build = function()
    window = Native.Frame("Frame", "ChillZoneUnionWindow", UIParent,
        { "ButtonFrameTemplate", "PortraitFrameTemplate", "BasicFrameTemplateWithInset" })
    if not window then
        window = CreateFrame("Frame", "ChillZoneUnionWindowFallback", UIParent, "BackdropTemplate")
        window:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    end
    _G.ChillZoneUnionWindow = window
    window:SetSize(1000, 650); window:SetPoint("CENTER"); window:SetFrameStrata("DIALOG")
    window:SetToplevel(true); window:SetClampedToScreen(true)
    if window.SetClampRectInsets then window:SetClampRectInsets(0, 0, 0, 30) end
    window:EnableMouse(true); window:SetMovable(true); window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving); window:SetScript("OnDragStop", window.StopMovingOrSizing)
    table.insert(UISpecialFrames, "ChillZoneUnionWindow")
    local title = "Чиллзон — Союз гильдий"
    if Native.HasMethod(window, "SetTitle") then window:SetTitle(title)
    elseif Native.HasMethod(window.TitleText, "SetText") then window.TitleText:SetText(title)
    elseif Native.HasMethod(window.TitleContainer, "GetObjectType") and Native.HasMethod(window.TitleContainer.TitleText, "SetText") then
        window.TitleContainer.TitleText:SetText(title)
    else Label(window, title, 80, -7, 780, "GameFontNormal") end
    local portrait = window.portrait
    if not Native.HasMethod(portrait, "SetTexture") then portrait = window.Portrait end
    if not Native.HasMethod(portrait, "SetTexture") and Native.HasMethod(window.PortraitContainer, "GetObjectType") then
        portrait = window.PortraitContainer.portrait
    end
    if Native.HasMethod(portrait, "SetTexture") then
        portrait:SetTexture("Interface\\AddOns\\ChillZoneUnion\\Media\\minimap")
        if type(SetPortraitToTexture) == "function" then
            pcall(SetPortraitToTexture, portrait, "Interface\\AddOns\\ChillZoneUnion\\Media\\minimap")
        end
    end
    if Native.HasMethod(window.Inset, "Hide") then window.Inset:Hide() end
    local body = Native.Inset(window, 14, -66, 972, 540)
    body:SetFrameLevel(window:GetFrameLevel() + 1)
    window.czuBody = body
    Label(window, "Чиллзон  /  Чиллзон Навсегда", 80, -40, 625, "GameFontHighlightSmall")
    local indicator = CreateFrame("Button", nil, window)
    indicator:SetSize(245, 24); indicator:SetPoint("TOPLEFT", 725, -34)
    indicator:SetScript("OnClick", function() Switch("link") end)
    headerDot = indicator:CreateTexture(nil, "OVERLAY"); headerDot:SetSize(7, 7); headerDot:SetPoint("LEFT", 7, 0)
    headerDot:SetTexture("Interface\\AddOns\\ChillZoneUnion\\Media\\status-dot")
    headerState = Label(indicator, "", 23, -6, 220, "GameFontHighlightSmall")
    local close = window.CloseButton
    if not Native.HasMethod(close, "SetScript") then
        close = CreateFrame("Button", nil, window, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -6, -5)
    end
    close:SetScript("OnClick", function() window:Hide() end)
    local definitions = { { "overview", "Обзор", 100, 5 }, { "roster", "Состав", 110, 1 }, { "chat", "Общий чат", 160, 2 }, { "transfers", "Переходы", 125, 3 }, { "link", "Связь", 110, 4 } }
    local previous
    for index, tab in ipairs(definitions) do
        local key = tab[1]
        local button = Native.Frame("Button", "ChillZoneUnionWindowTab" .. tab[4], window,
            { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate", "TabButtonTemplate" })
        if button then
            button.czuNative = true
        else
            button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        end
        button:SetID(tab[4]); button:SetSize(tab[3], 32); button:SetText(tab[2])
        button:SetScript("OnClick", function() Switch(key) end)
        if previous then
            local modern = Native.HasMethod(button.LeftActive, "Show") and type(PanelTemplates_AnchorTabs) == "function"
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", modern and 3 or -15, 0)
        else button:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 16, 2) end
        tabs[key] = button; previous = button; Native.ResizeTab(button)
        local p = CreateFrame("Frame", nil, window); p:SetPoint("TOPLEFT", 24, -86); p:SetPoint("BOTTOMRIGHT", -24, 54); p:Hide(); pages[key] = p
        p:SetFrameLevel(body:GetFrameLevel() + 2)
    end
    local stats = CreateFrame("Frame", nil, window)
    stats:SetPoint("TOPLEFT", 24, -86); stats:SetPoint("BOTTOMRIGHT", -24, 54); stats:Hide(); pages.stats = stats
    stats:SetFrameLevel(body:GetFrameLevel() + 2)
    status = Label(window, "", 25, -628, 950, "GameFontHighlightSmall")
    local r = pages.roster
    counts = Label(r, "", 0, 0, 950, "GameFontNormalLarge")
    guildCounts = Label(r, "", 0, -21, 950, "GameFontHighlightSmall")
    search = Edit(r, 7, -60, 220, "Имя, класс, звание или локация")
    search.czuRosterSearch = true; window.czuRosterSearch = search
    search:SetScript("OnTextChanged", function() U.CloseRosterContextMenu(); Native.ClearLocationFilter(); offset = 0; RenderRoster() end)
    guildButton = Native.Choice(r, "roster-scope", "Весь союз", 240, -61, 165, Native.GuildChoices,
        function() return guildFilter end,
        function(value) guildFilter, offset, selected = value, 0, nil; RenderRoster() end)
    Label(r, "Гильдия", 240, -38, 165, "GameFontNormalSmall")
    Native.Choice(r, "roster-activity", "Все участники", 415, -61, 190, Native.ActivityChoices,
        function() return Native.activity.days end,
        function(value)
            Native.activity.days, offset, selected = value, 0, nil
            if value > 0 then offline:SetChecked(true); Native.ClearLocationFilter() end
            RenderRoster()
        end)
    Label(r, "Неактивность", 415, -38, 190, "GameFontNormalSmall")
    offline = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate"); offline:SetSize(24, 24); offline:SetPoint("TOPLEFT", 615, -60)
    offline.czuRosterOffline = true; window.czuRosterOffline = offline
    Label(r, "Показывать офлайн", 643, -67, 100, "GameFontHighlightSmall")
    offline:SetScript("OnClick", function(self)
        if Native.activity.days > 0 then self:SetChecked(true); return end
        U.CloseRosterContextMenu(); Native.ClearLocationFilter(); offset = 0; RenderRoster()
    end)
    Button(r, "Обновить", 865, -61, 85, function() U.RequestRoster(); U.snapshotDue = 0 end)
    Native.Choice(r, "roster-statistics", "Статистика", 750, -61, 105,
        function() return { { value = "classes", text = "По классам" }, { value = "levels", text = "По уровням" } } end,
        nil, function(value) if value == "classes" then U.OpenClassStats() else U.OpenLevelStats() end end, true)
    Native.Inset(r, -8, -94, 966, 320)
    local function SortHeader(key, title, x, width)
        local b = Native.Frame("Button", "ChillZoneUnionColumn" .. key, r,
            { "WhoFrameColumnHeaderTemplate", "GuildFrameColumnHeaderTemplate" })
            or CreateFrame("Button", nil, r)
        b:SetSize(width, 24); b:SetPoint("TOPLEFT", x, -100)
        if type(WhoFrameColumn_SetWidth) == "function" then pcall(WhoFrameColumn_SetWidth, b, width) end
        b:SetWidth(width)
        local label = Label(b, title, 0, -7, width - 15, "GameFontNormalSmall")
        b:SetFontString(label)
        b:SetText(title); b.sortTitle = title; sortHeaders[key] = b
        b.sortArrow = b:CreateTexture(nil, "OVERLAY")
        b.sortArrow:SetSize(10, 10); b.sortArrow:SetPoint("RIGHT", -1, 0)
        b.sortArrow:Hide()
        b:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
        b:SetScript("OnLeave", function() label:SetTextColor(1, 0.82, 0) end)
        b:SetScript("OnClick", function()
            U.CloseChoiceMenu()
            U.CloseRosterContextMenu()
            if sortKey == key then sortDirection = -sortDirection
            else sortKey, sortDirection = key, key == "level" and -1 or 1 end
            offset = 0; RenderRoster()
        end)
        return b
    end
    SortHeader("name", "Имя", 4, 201)
    SortHeader("class", "Класс", 215, 85)
    SortHeader("level", "Ур.", 310, 32)
    SortHeader("zone", "Локация", 350, 145)
    SortHeader("rank", "Звание", 505, 110)
    Label(r, "Гильдия", 625, -107, 150, "GameFontNormalSmall")
    SortHeader("lastSeen", "Последний вход", 785, 160)
    Native.activity.empty = Label(r, "Нет участников с подтверждённой неактивностью.\nОбновите состав или выберите «Все участники»; неизвестные и устаревшие данные в фильтр не включаются.", 12, -146, 925, "GameFontHighlightSmall")
    Native.activity.empty:SetHeight(40); Native.activity.empty:SetJustifyV("TOP"); Native.activity.empty:Hide()
    for i = 1, 11 do
        local b = CreateFrame("Button", nil, r); b:SetSize(950, 24); b:SetPoint("TOPLEFT", 0, -128 - (i - 1) * 25)
        Native.RowArt(b, i)
        b.addonBadge = Label(b, "CZ", 5, -6, 20, "GameFontNormalSmall"); b.addonBadge:Hide()
        b.name = Label(b, "", 29, -5, 176); b.classText = Label(b, "", 215, -6, 85, "GameFontHighlightSmall")
        b.level = Label(b, "", 310, -5, 32)
        b.zone = Label(b, "", 350, -5, 145, "GameFontHighlightSmall"); b.rank = Label(b, "", 505, -5, 110, "GameFontHighlightSmall")
        b.guild = Label(b, "", 625, -5, 150, "GameFontHighlightSmall")
        b.activity = Label(b, "", 785, -5, 160, "GameFontHighlightSmall")
        for _, label in ipairs({ b.name, b.classText, b.level, b.zone, b.rank, b.guild, b.activity }) do
            label:SetHeight(16); label:SetWordWrap(false)
        end
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", U.RosterRowClick)
        b:SetScript("OnDoubleClick", U.RosterRowDoubleClick)
        b:SetScript("OnEnter", U.RosterRowEnter)
        b:SetScript("OnLeave", U.RosterRowLeave)
        b:SetScript("OnHide", U.RosterRowHide)
        rows[i] = b
    end
    r:EnableMouseWheel(true); r:SetScript("OnMouseWheel", function(_, delta) U.CloseRosterContextMenu(); offset = offset - delta * 3; RenderRoster() end)
    Button(r, ArrowText("left"), 0, -416, 40, function() U.CloseRosterContextMenu(); offset = offset - #rows; RenderRoster() end)
    r.range = Label(r, "", 55, -422, 150, "GameFontHighlightSmall")
    Button(r, ArrowText("right"), 220, -416, 40, function() U.CloseRosterContextMenu(); offset = offset + #rows; RenderRoster() end)
    Button(r, "В группу", 525, -416, 110, function() if selected then ChatFrame_OpenChat("/invite " .. selected.name) end end)
    Button(r, "Шёпот", 645, -416, 100, function() if selected then ChatFrame_OpenChat("/w " .. selected.name .. " ") end end)
    r.move = Button(r, "Предложить переход", 755, -416, 195, function() if selected then U.CreateTransfer(selected.name, selected.guild); ticketOffset = 0; Switch("transfers") end end)
    r.selection = Label(r, "", 0, -453, 950, "GameFontHighlightSmall")
    Native.BuildLocationFilter(r)

    BuildClassStats(stats)
    Native.BuildLevelStats(body)
    Native.BuildOverview(body)

    local c = pages.chat
    Native.Inset(c, -8, 8, 966, 44)
    Native.Inset(c, -8, -61, 966, 349)
    local banner = CreateFrame("Button", nil, c); banner:SetPoint("TOPLEFT", 0, 0); banner:SetSize(945, 36)
    announcementBanner = Label(banner, "", 0, 0, 945, "GameFontHighlightSmall"); announcementBanner:SetHeight(36); announcementBanner:SetJustifyV("TOP")
    banner:SetScript("OnEnter", function(self)
        local a = U.GetAnnouncement and U.GetAnnouncement()
        if not a or a.text == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Сообщение союза")
        GameTooltip:AddLine(U.SafeDisplay(a.text), 1, 1, 1, true)
        if a.author then GameTooltip:AddLine(U.SafeDisplay(a.author) .. " • " .. Age(a.at), 0.7, 0.75, 0.8) end
        GameTooltip:Show()
    end)
    banner:SetScript("OnLeave", function() GameTooltip:Hide() end)
    banner:SetScript("OnClick", function() GameTooltip:Hide(); Switch("link") end)
    Label(c, "Один чат для обеих гильдий. Нажмите имя для шёпота; ссылки на предметы работают как обычно.", 0, -43, 945, "GameFontNormalSmall")
    chatLog = CreateFrame("ScrollingMessageFrame", nil, c); chatLog:SetPoint("TOPLEFT", 4, -69); chatLog:SetSize(935, 333)
    chatLog:SetFontObject(GameFontHighlight); chatLog:SetJustifyH("LEFT"); chatLog:SetFading(false); chatLog:SetMaxLines(200)
    chatLog:EnableMouseWheel(true); chatLog:SetScript("OnMouseWheel", function(self, d)
        if d > 0 then self:ScrollUp() else self:ScrollDown() end
        MarkRead()
    end)
    chatLog:SetHyperlinksEnabled(true)
    chatLog:SetScript("OnHyperlinkClick", function(self, link, text, button) SetItemRef(link, text, button, self) end)
    chatJump = Button(c, "В конец " .. ArrowText("down"), 785, -415, 160, function() chatLog:ScrollToBottom(); MarkRead() end)
    chatBox = Edit(c, 7, -443, 780)
    if hooksecurefunc and type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", function(link)
        if chatBox:HasFocus() and U.Text(link, 1000) then chatBox:Insert(link) end
    end) end
    local function Send()
        if U.SendChat(chatBox:GetText()) then chatBox:SetText(""); chatBox:ClearFocus() end
    end
    chatBox:SetScript("OnEnterPressed", Send)
    Button(c, "Отправить", 815, -444, 130, Send)
    Label(c, "История сохраняется до перезагрузки интерфейса. Сообщения видны участникам обеих гильдий с аддоном.", 0, -483, 945, "GameFontHighlightSmall")

    local t = pages.transfers
    Native.Inset(t, -8, -28, 606, 374)
    Label(t, "Переходы по согласию участника", 0, 0, 950, "GameFontNormal")
    for i = 1, 12 do
        local b = CreateFrame("Button", nil, t)
        b:SetSize(590, 26); b:SetPoint("TOPLEFT", 0, -35 - (i - 1) * 30)
        Native.RowArt(b, i)
        local label = Label(b, "", 8, -6, 574, "GameFontHighlightSmall")
        b:SetFontString(label)
        b:SetScript("OnClick", function(self)
            if self.ticket then selectedTicket = self.ticket.id; RenderTickets() end
        end)
        ticketRows[i] = b
    end
    t:EnableMouseWheel(true); t:SetScript("OnMouseWheel", function(_, d) ticketOffset = ticketOffset - d * 3; RenderTickets() end)
    Button(t, ArrowText("left"), 0, -410, 40, function() ticketOffset = ticketOffset - #ticketRows; RenderTickets() end)
    t.range = Label(t, "", 55, -416, 150, "GameFontHighlightSmall")
    Button(t, ArrowText("right"), 220, -410, 40, function() ticketOffset = ticketOffset + #ticketRows; RenderTickets() end)
    ticketInfo = Label(t, "", 620, -35, 325); ticketInfo:SetJustifyV("TOP"); ticketInfo:SetHeight(310)
    acceptButton = Button(t, "Согласиться", 620, -370, 150, function() U.AcceptTransfer(selectedTicket, true) end)
    declineButton = Button(t, "Отказаться", 790, -370, 150, function() U.AcceptTransfer(selectedTicket, false) end)
    leaveButton = Button(t, "Подготовить выход", 620, -405, 320, function() U.LeaveForTransfer(selectedTicket) end)
    inviteButton = Button(t, "Подготовить приглашение", 620, -440, 320, function() U.InviteTransfer(selectedTicket) end)
    Label(t, "После нажатия кнопки проверьте штатную команду игры и нажмите Enter. Сам переход требует согласия участника.", 0, -483, 950, "GameFontHighlightSmall")

    local l = pages.link
    Native.Inset(l, -8, 8, 585, 518)
    Native.Inset(l, 600, 8, 355, 518)
    Setup.title = Label(l, "Связь между гильдиями", 0, 0, 565, "GameFontNormalLarge")
    Setup.steps[1] = Label(l, "1. Выбрать офицера", 0, -30, 170, "GameFontNormalSmall")
    Setup.steps[2] = Label(l, "2. Дождаться подтверждения", 175, -30, 230, "GameFontNormalSmall")
    Setup.steps[3] = Label(l, "3. Союз подключён", 410, -30, 155, "GameFontNormalSmall")
    setupHint = Label(l, "", 0, -57, 565); setupHint:SetHeight(48); setupHint:SetJustifyV("TOP")
    Setup.contactHint = Label(l, "Полное имя офицера второй гильдии", 7, -117, 350, "GameFontNormalSmall")
    contact = Edit(l, 7, -140, 350)
    local prefill = U.db.setupContact
    if (not prefill or prefill == "") and U.guild and U.OtherGuild() == 1 and U.GUILD_LEADERS then prefill = U.GUILD_LEADERS[1] end
    contact:SetMaxBytes(160); contact:SetText(prefill or "")
    local function Connect() U.Link(contact:GetText()); contact:ClearFocus(); RenderLinks() end
    contact:SetScript("OnEnterPressed", Connect)
    contact:SetScript("OnTextChanged", function() RenderLinks() end)
    connectButton = Button(l, "Подключить", 380, -141, 185, Connect)
    setupProgress = Label(l, "", 0, -187, 565); setupProgress:SetHeight(60); setupProgress:SetJustifyV("TOP")
    U.BuildLinkApprovalControls(l)
    Setup.chat = Button(l, "Открыть чат", 0, -140, 275, function() U.OpenChat() end)
    diagnostics = Label(l, "", 0, -379, 565, "GameFontHighlightSmall"); diagnostics:SetHeight(55); diagnostics:SetJustifyV("TOP")
    U.linkApprovalControls.footer = Label(l, "Для связи нужен глава, офицер или ветеран онлайн с каждой стороны. Новая установка получает настройки от своего главы или офицера.", 0, -443, 565, "GameFontHighlightSmall")
    U.linkApprovalControls.footer:SetHeight(30); U.linkApprovalControls.footer:SetJustifyV("TOP")
    window.czuSetupTitle, window.czuSetupHint, window.czuSetupProgress = Setup.title, setupHint, setupProgress
    window.czuSetupChat, window.czuSetupSteps = Setup.chat, Setup.steps
    window.czuContact, window.czuConnect = contact, connectButton
    Label(l, "Отображение", 610, 0, 335, "GameFontNormal")
    badgeCheck = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate"); badgeCheck:SetSize(24, 24); badgeCheck:SetPoint("TOPLEFT", 610, -33)
    Label(l, "Показывать гильдию рядом с именем в чате", 638, -40, 307, "GameFontHighlightSmall")
    badgeCheck:SetScript("OnClick", function(self)
        if U.SetGuildBadge then U.SetGuildBadge(self:GetChecked() == true) else U.db.showGuildBadge = self:GetChecked() == true; U.RefreshChat() end
    end)
    Label(l, "Вкладка обычного чата", 610, -77, 335, "GameFontNormalSmall")
    chatWindowButton = Native.Choice(l, "chat-window", "Автоматически", 610, -99, 335, Native.ChatChoices,
        Native.ChatChoiceValue,
        function(value)
            local name
            if value ~= false then name = value end
            if U.SetChatWindow then local ok, why = U.SetChatWindow(name); if not ok and why then U.Print(why) end end
            RenderLinks()
        end)
    noticesCheck = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate"); noticesCheck:SetSize(24, 24); noticesCheck:SetPoint("TOPLEFT", 610, -139)
    Label(l, "Сообщать о вступлениях и выходах из гильдий", 638, -146, 307, "GameFontHighlightSmall")
    noticesCheck:SetScript("OnClick", function(self) U.db.memberNotices = self:GetChecked() == true end)
    Label(l, "Сообщение дня союза", 610, -191, 335, "GameFontNormal")
    announcementEdit = Edit(l, 617, -232, 328, "Общее для обеих гильдий")
    announcementEdit:SetMaxBytes(1000)
    announcementEdit:SetScript("OnTextChanged", function(_, userInput) if userInput then announcementDirty = true end end)
    local function SaveAnnouncement(text)
        if U.SetAnnouncement and U.SetAnnouncement(text) then
            announcementDirty = false; announcementEdit:ClearFocus(); RenderLinks(); RenderAnnouncement()
        end
    end
    announcementSave = Button(l, "Сохранить", 610, -270, 160, function() SaveAnnouncement(announcementEdit:GetText()) end)
    announcementClear = Button(l, "Убрать", 785, -270, 160, function() SaveAnnouncement("") end)
    announcementHint = Label(l, "", 610, -311, 335, "GameFontHighlightSmall"); announcementHint:SetHeight(65); announcementHint:SetJustifyV("TOP")
    leaderInfo = Label(l, "", 610, -397, 335, "GameFontHighlightSmall"); leaderInfo:SetHeight(55); leaderInfo:SetJustifyV("TOP")
    window:SetScript("OnHide", function() U.CloseChoiceMenu(); U.CloseRosterContextMenu(); Native.ClearPageFocus() end)
    window:SetScript("OnShow", function() U.Refresh(); U.RefreshChat(); MarkRead() end)
    local tick = 0
    window:SetScript("OnUpdate", function(_, dt) tick = tick + dt; if tick > 2 then tick = 0; U.Refresh(); MarkRead() end end)
    page = "roster"; pages[page]:Show()
    Native.RefreshTabs()
    U.Refresh(); U.RefreshChat()
end
function U.Toggle()
    if not U.db then return end
    if PendingRequest() and (not window or not window:IsShown() or page ~= "link") then U.OpenMain()
    elseif window and window:IsShown() then window:Hide() else U.OpenMain() end
end
function U.OpenMain()
    if not U.db then return end
    local created = not window
    if created then Build() end
    local view = ConnectionView()
    local seen = U.db.connectionIntroSeen
    if type(seen) ~= "table" then seen = {}; U.db.connectionIntroSeen = seen end
    local key = U.Fold(U.me or "") .. ":" .. tostring(U.guild or 0)
    local firstMemberView = not seen[key] and view.role ~= "officer"
    if PendingRequest() or firstMemberView or view.role == "officer" and not view.hasContacts then
        window:Show(); Switch("link")
        if view.role ~= "loading" and U.me then seen[key] = true end
    else
        window:Show()
        if created then Switch("roster") end
    end
end
function U.OpenRoster()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("roster")
end
function U.OpenChat()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("chat")
end
function U.OpenSettings()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("link")
end
function U.OpenClassStats()
    if not U.db then return end
    if not window then Build() end
    classOffset = 0
    window:Show(); Switch("stats")
end
function U.OpenLevelStats()
    if not U.db then return end
    if not window then Build() end
    Level.offset = 0
    window:Show(); Switch("levels")
end
function U.OpenOverview()
    if not U.db then return end
    if not window then Build() end
    Overview.offset = 0
    window:Show(); Switch("overview")
end
function U.OpenLocationRoster(name, scope)
    if not U.db or (name ~= nil and not U.Text(name, 500)) then return false end
    if not window then Build() end
    local label = name and U.Trim(name) or ""
    if scope ~= 1 and scope ~= 2 then scope = 0 end
    Native.activity.days = 0
    search:SetText(""); offline:SetChecked(false)
    guildFilter, offset, selected = scope, 0, nil
    Native.RefreshChoice(guildButton)
    Overview.location = { name = label, key = U.Fold(label), unknown = label == "" }
    window:Show(); Switch("roster")
    return true
end

local setupIntroPending = false
function U.MaybeShowSetup()
    if not setupIntroPending or not U.db or not U.me then return end
    if U.Fold(U.me) ~= U.Fold(U.UNION_LEADER) then setupIntroPending = false; return end
    if not U.guild or not U.own[U.me] then return end
    if not U.IsUnionLeader() then setupIntroPending = false; return end
    local seen = U.db.setupIntroSeen
    if type(seen) ~= "table" then seen = {}; U.db.setupIntroSeen = seen end
    local key = U.Fold(U.me)
    if seen[key] then setupIntroPending = false; return end
    local configured = U.Connected()
    for name, entry in pairs(U.db.contacts) do
        if name ~= U.me and entry.approved == true and entry.guild == U.OtherGuild() then configured = true; break end
    end
    if configured then seen[key] = true; setupIntroPending = false; return end
    if InCombatLockdown() then return end
    U.OpenSettings()
    seen[key] = true
    setupIntroPending = false
end
U.On("PLAYER_LOGIN", function() setupIntroPending = true; U.MaybeShowSetup() end)
U.On("GUILD_ROSTER_UPDATE", function() U.MaybeShowSetup() end)
U.On("PLAYER_GUILD_UPDATE", function() U.MaybeShowSetup() end)

local connectionNotices, connectionNoticeWindow, connectionNoticeCount = {}, -100, 0
local function ConnectionRequestLink(name, nonce)
    local encoded = name:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
    return "addon:ChillZoneUnion:connection:" .. encoded .. ":" .. nonce
end
local function OpenConnectionRequestLink(link)
    if not U.Text(link, 430) then return false end
    local encoded, nonce = link:match("^addon:ChillZoneUnion:connection:([0-9a-f]+):([%d%.]+)$")
    if not encoded or #encoded > 320 or #encoded % 2 ~= 0 or #nonce > 40 then return false end
    local name = encoded:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)
    if U.Name(name) ~= name or not U.IsTrustOfficer or not U.IsTrustOfficer()
        or not U.PendingLink or not U.SelectPendingLink then return false end
    local request = U.PendingLink(name, nonce)
    if not request or request.name ~= name or request.nonce ~= nonce then return false end
    if not U.SelectPendingLink(name, nonce) then return false end
    U.OpenSettings()
    return true
end
function U.NotifyConnectionRequest(request)
    if type(request) ~= "table" or not U.IsTrustOfficer or not U.IsTrustOfficer() then return false end
    local name, now = U.Name(request.name), U.clock()
    local actual = name and U.inboundLinks and U.inboundLinks[name]
    if not actual or actual.approved or actual.nonce ~= request.nonce or actual.guild ~= request.guild
        or actual.untilAt ~= request.untilAt or now > actual.untilAt
        or not U.Text(actual.nonce, 40) or not actual.nonce:match("^[%d%.]+$") then return false end
    RefreshConnection()
    local key = name .. ":" .. tostring(actual.nonce)
    if connectionNotices[key] then return false end
    if now - connectionNoticeWindow >= 60 then connectionNoticeWindow, connectionNoticeCount = now, 0 end
    if connectionNoticeCount >= 6 then return false end
    for previous, untilAt in pairs(connectionNotices) do if now > untilAt then connectionNotices[previous] = nil end end
    connectionNotices[key], connectionNoticeCount = actual.untilAt, connectionNoticeCount + 1
    U.Print("Запрос соединения от " .. U.SafeDisplay(name)
        .. " — |cff71d5ff|H" .. ConnectionRequestLink(name, actual.nonce) .. "|h[Открыть]|h|r")
    return true
end
if hooksecurefunc and type(SetItemRef) == "function" then
    hooksecurefunc("SetItemRef", function(link)
        OpenConnectionRequestLink(link)
    end)
end

local DEFAULT_MINIMAP_ANGLE = 225
local function PositionMinimapButton(button)
    if not button or not Minimap or not U.db then return end
    local angle = U.db.minimapAngle
    if type(angle) ~= "number" or angle ~= angle or math.abs(angle) == math.huge then angle = DEFAULT_MINIMAP_ANGLE end
    angle = angle % 360
    U.db.minimapAngle = angle
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    width = type(width) == "number" and width > 0 and width or 140
    height = type(height) == "number" and height > 0 and height or width
    local radians = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * (width / 2 + 8), math.sin(radians) * (height / 2 + 8))
end
local function DragMinimapButton(button)
    if not U.db or type(GetCursorPosition) ~= "function" then return end
    local cx, cy = Minimap:GetCenter()
    if type(cx) ~= "number" or type(cy) ~= "number" then return end
    local scale = Minimap:GetEffectiveScale()
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local x, y = GetCursorPosition()
    if type(x) ~= "number" or type(y) ~= "number" then return end
    x, y = x / scale - cx, y / scale - cy
    if x == 0 and y == 0 then return end
    local angle
    if math.atan2 then angle = math.atan2(y, x)
    elseif x == 0 then angle = y > 0 and math.pi / 2 or -math.pi / 2
    else
        angle = math.atan(y / x)
        if x < 0 then angle = angle + math.pi end
    end
    U.db.minimapAngle = math.deg(angle) % 360
    PositionMinimapButton(button)
end
function U.ResetMinimapPosition()
    if not U.db then return end
    U.db.minimapAngle = DEFAULT_MINIMAP_ANGLE
    PositionMinimapButton(U.minimapButton)
end
U.On("PLAYER_LOGIN", function()
    if not Minimap or U.minimapButton then return end
    local b = CreateFrame("Button", "ChillZoneUnionMinimapButton", Minimap)
    U.minimapButton = b
    b:SetSize(32, 32); b:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    b:EnableMouse(true); b:SetMovable(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp"); b:RegisterForDrag("LeftButton")
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetSize(28, 28); b.icon:SetPoint("CENTER")
    b.icon:SetTexture("Interface\\AddOns\\ChillZoneUnion\\Media\\minimap")
    b.pendingMark = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.pendingMark:SetPoint("TOPRIGHT", -1, 2); b.pendingMark:SetText("!"); b.pendingMark:SetTextColor(1, 0.82, 0)
    b.pendingMark:Hide()
    local highlight = b:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(); highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD"); highlight:SetVertexColor(1, 0.78, 0.35, 0.7)
    b:SetScript("OnClick", function(self, button)
        if self.dragging or (self.dragStopTime and GetTime() - self.dragStopTime < 0.15) then return end
        if button == "RightButton" then
            if IsShiftKeyDown and IsShiftKeyDown() then U.ResetMinimapPosition() else U.OpenSettings() end
        else U.Toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        self.dragging = true; GameTooltip:Hide(); DragMinimapButton(self)
    end)
    b:SetScript("OnDragStop", function(self)
        DragMinimapButton(self); self.dragging = false; self.dragStopTime = GetTime()
    end)
    b:SetScript("OnEnter", function(self)
        if self.dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("Чиллзон — Союз гильдий")
        local text, r, g, blue = Connection()
        GameTooltip:AddLine(text, r, g, blue)
        GameTooltip:AddLine(PendingRequest() and "ЛКМ — открыть запрос" or "ЛКМ — открыть или закрыть окно", 0.8, 0.85, 0.9)
        GameTooltip:AddLine("ПКМ — настройки", 0.8, 0.85, 0.9)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local tick = 0
    b:SetScript("OnUpdate", function(self, dt)
        if self.dragging then DragMinimapButton(self) end
        tick = tick + dt
        if tick >= 2 then tick = 0; RefreshConnection(); U.MaybeShowSetup(); if not self.dragging then PositionMinimapButton(self) end end
    end)
    PositionMinimapButton(b); RefreshConnection()
end)
