# ChillZoneUnion

ChillZoneUnion connects the **Чиллзон** and **Чиллзон Навсегда** guilds in **WoW Forever** with a shared chat and roster. It is designed for these two guilds; the in-game interface is in Russian.

## Features

- Shared guild chat in the normal chat window, with a dedicated conversation tab in the addon.
- Combined roster with search, guild and offline filters, and sorting by name, level, zone or rank.
- Class statistics for each guild and the union, showing online and total character counts.
- Addon presence badges and detected versions in roster tooltips.
- Minimap access for all members, plus whispers, group invitations and transfer proposals from the roster.
- A union announcement and guided, voluntary transfers between the guilds.

## Setup and connection

Install the addon for everyone who wants to read messages from the other guild and use the combined roster. Open the window with `/cz`, `/чз` or the CZ minimap button.

For the first connection, a guild master or an officer from each guild must be online with the addon. One enters the other character's full name in the **Связь** tab. The recipient verifies the exact identity with a known guild leader outside the request and explicitly approves it. The guilds must share a realm and faction.

After setup, the addon automatically selects relays from guild masters, officers and characters whose actual guild rank is **Ветеран**. The guild master can go offline: the connection continues while at least one configured, eligible relay with the addon remains online in each guild. Existing configured clients can operate with only Veteran relays online. A new installation needs a configured guild master or officer from its own guild online to receive the initial trusted configuration.

## Chat and controls

Use the normal `/g` guild chat when the game makes its text available to addons. You can also send union messages with `/czu text`, `/cz text` or `/чз text`. `/cz` or `/чз` without text opens the window. Left-click the minimap button for the roster; right-click for connection settings and status.

Players without the addon only see their own guild's normal chat. The addon does not merge the guilds on the game server or grant native guild permissions. Transfers require the member's consent and manual confirmation of the game commands and invitation.

## Beta status

This is a beta build for WoW Forever 1.60.1. Versions 0.6.0, 0.6.1 and 0.6.2 share the same connection protocol and trusted settings. Upgrading from 0.5 or earlier requires all participants to update and the initial connection to be approved again. Relay characters are trusted operators who can access the chat and roster they forward. Please test a real connection between the two guilds before a wider rollout.

---

## Русский

**ChillZoneUnion** объединяет общение и состав «Чиллзон» и «Чиллзон Навсегда» в WoW Forever. Интерфейс аддона на русском языке; настройка рассчитана именно на эти две гильдии.

### Возможности

- Общий чат в обычном окне игры и отдельная вкладка переписки.
- Общий состав с поиском, фильтрами и сортировкой по имени, уровню, локации и званию.
- Статистика классов: в сети / всего по каждой гильдии и всему союзу.
- Отметка CZ и обнаруженная версия аддона в подсказке участника.
- Кнопка у миникарты для всех участников, шёпот, приглашения в группу и предложения перехода из состава.
- Общее объявление и согласованные добровольные переходы между гильдиями.

### Первое подключение

Аддон нужен каждому, кто хочет видеть сообщения другой гильдии и общий состав. Окно открывается через `/cz`, `/чз` или CZ у миникарты.

Для первой настройки нужны глава или офицер с аддоном онлайн от каждой гильдии. Первый вводит полное имя второго во вкладке «Связь». Второй проверяет имя с известным руководителем гильдии вне запроса и явно подтверждает подключение. Гильдии должны быть на одном игровом мире и одной фракции.

После настройки связные выбираются автоматически среди глав, офицеров и участников с настоящим игровым званием «Ветеран». Глава может выходить из игры: достаточно хотя бы одного настроенного подходящего связного с аддоном онлайн в каждой гильдии. Уже настроенные клиенты работают и при одних ветеранах онлайн. Новой установке для получения начальных доверенных настроек нужен настроенный глава или офицер своей гильдии онлайн.

### Общение и управление

Пишите в привычный `/г` или `/g`, если игра позволяет аддону читать текст. Также доступны `/czu текст`, `/cz текст`, `/чз текст` и вкладка «Общий чат». Без текста `/cz` и `/чз` открывают окно. ЛКМ по CZ у миникарты открывает состав, ПКМ — настройки и состояние связи.

Без аддона игрок видит только обычный чат своей гильдии. Аддон не объединяет гильдии на сервере и не выдаёт игровых прав. Для перехода нужны согласие участника и ручное подтверждение игровых команд и приглашения.

### Бета-версия

Сборка предназначена для WoW Forever 1.60.1. Версии 0.6.0, 0.6.1 и 0.6.2 совместимы: повторная настройка связи не требуется. При переходе с 0.5 и более ранних версий обновиться должны все участники, а первую связь нужно подтвердить заново. Связные — доверенные операторы: они имеют доступ к передаваемым чату и составу. Перед массовой установкой проверьте работу на двух настоящих клиентах из обеих гильдий.
