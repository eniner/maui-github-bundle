local mq = require('mq')
local ImGui = require('ImGui')
local Icons = require('mq/Icons')

--[[
    LuaConsole Pro (single-file init.lua)
    -------------------------------------
    Professional in-game REPL / debugger for MacroQuest Lua.

    Highlights:
    - Persistent REPL environment (true stateful evaluation).
    - Multi-line / chunk continuation support (chat + UI).
    - Safe-ish execution model with dangerous API stubs and warnings.
    - xpcall + traceback error reporting with friendlier formatting.
    - Deep pretty-printer / inspector with recursion protection.
    - Input history with /luaprev and /luanext.
    - ImGui console with colored log, multiline editor, and eval controls.
    - Chat fallback mode with lua> prefix support.
    - Debug toggle and optional session save/load (JSON file).
]]

local SCRIPT_NAME = 'LuaConsole Pro'
local VERSION = '2.0.0'

local SESSION_FILE = mq.configDir .. '/luaconsole_session.json'
local SETTINGS_FILE = mq.configDir .. '/luaconsole_settings.lua'
local LU_UNPACK = table.unpack or unpack

local MAX_HISTORY = 100
local MAX_LOG = 4000
local MAX_TRACE_CHARS = 2500
local MAX_INSPECT_DEPTH = 6
local DEFAULT_WATCH_INTERVAL_MS = 250
local DEFAULT_TRIGGER_INTERVAL_MS = 150
local DEFAULT_TRIGGER_COOLDOWN_MS = 3000
local WATCHES_FILE = mq.configDir .. '/luaconsole_watches.json'
local TRIGGERS_FILE = mq.configDir .. '/luaconsole_triggers.json'
local SNIPPETS_FILE = mq.configDir .. '/luaconsole_snippets.json'
local LOG_EXPORT_FILE = mq.configDir .. '/luaconsole_log.txt'
local SESSION_STATE_FILE = mq.configDir .. '/luaconsole_state.json'
local SHARE_FILE = mq.configDir .. '/luaconsole_share.json'
local AUTO_SAVE_FILE = mq.configDir .. '/luaconsole_autosave.json'
local REMOTE_EVAL_FILE = mq.configDir .. '/luaconsole_remote_eval.lua'

local BASE_FILES = {
    SESSION_FILE = SESSION_FILE,
    SETTINGS_FILE = SETTINGS_FILE,
    WATCHES_FILE = WATCHES_FILE,
    TRIGGERS_FILE = TRIGGERS_FILE,
    SNIPPETS_FILE = SNIPPETS_FILE,
    LOG_EXPORT_FILE = LOG_EXPORT_FILE,
    SESSION_STATE_FILE = SESSION_STATE_FILE,
    SHARE_FILE = SHARE_FILE,
    AUTO_SAVE_FILE = AUTO_SAVE_FILE,
    REMOTE_EVAL_FILE = REMOTE_EVAL_FILE,
}

local DEFAULT_SNIPPETS = {
    {
        name = 'Combat: List active AAs',
        code = [[
local me = T.Me
for i = 1, 500 do
    local aa = me.AltAbility(i)
    if aa() and me.AltAbilityReady(i)() then
        print(i, aa.Name(), 'ready')
    end
end
]],
    },
    {
        name = 'Merc: state + target',
        code = [[
print('MercState:', T.Me.Mercenary.State())
print('MercTarget:', T.Me.Mercenary.Target.CleanName())
print('MercPctHP:', T.Me.Mercenary.PctHPs())
]],
    },
    {
        name = 'Nav: path status',
        code = [[
print('Nav Active:', T.Navigation.Active())
print('Nav Paused:', T.Navigation.Paused())
print('Nav PathExists:', T.Navigation.PathExists())
print('Nav Distance:', T.Navigation.PathLength())
]],
    },
    {
        name = 'UI: chat window check',
        code = [[
print('ChatWnd Open:', T.Window['ChatWindow'].Open())
print('MainChat Open:', T.Window['MainChatWnd'].Open())
]],
    },
    {
        name = 'Utility: inventory slots',
        code = [[
for i = 1, 34 do
    local item = T.Me.Inventory(i)
    if item() then
        print(i, item.Name(), item.Stack())
    end
end
]],
    },
    {
        name = 'Target: buff timers',
        code = [[
if not T.Target() then print('No target.') return end
for i = 1, 97 do
    local b = T.Target.Buff(i)
    if b() then print(i, b.Name(), b.Duration.TimeHMS()) end
end
]],
    },
    {
        name = 'Group: HP snapshot',
        code = [[
for i = 1, 6 do
    local m = T.Group.Member(i)
    if m() then
        print(i, m.CleanName(), m.PctHPs(), m.Class.ShortName())
    end
end
]],
    },
    {
        name = 'Spawn: nearest named',
        code = [[
local s = T.Spawn('npc named radius 200')
print('Nearest named:', s.CleanName(), 'Dist:', s.Distance())
]],
    },
    {
        name = 'Buffs: self long buffs',
        code = [[
for i = 1, 42 do
    local b = T.Me.Buff(i)
    if b() then print(i, b.Name(), b.Duration.TimeHMS()) end
end
]],
    },
    {
        name = 'Debug: zone + spawn count',
        code = [[
print('Zone:', T.Zone.ShortName(), T.Zone.ID())
print('SpawnCount:', T.SpawnCount())
]],
    },
}

local function migrateSnippetRow(row)
    if type(row) ~= 'table' then return row end
    if row.name == 'Combat: List active AAs' and type(row.code) == 'string' and row.code:find('aa.Ready()', 1, true) then
        row.code = [[
local me = T.Me
for i = 1, 500 do
    local aa = me.AltAbility(i)
    if aa() and me.AltAbilityReady(i)() then
        print(i, aa.Name(), 'ready')
    end
end
]]
    end
    return row
end

local COLOR = {
    INFO = '\aw',
    OK = '\ag',
    WARN = '\ay',
    ERR = '\ar',
    INPUT = '\at',
}

local UI_COLOR = {
    INFO = { 0.85, 0.85, 0.85, 1.0 },
    OK = { 0.35, 1.00, 0.45, 1.0 },
    WARN = { 1.00, 0.90, 0.35, 1.0 },
    ERR = { 1.00, 0.45, 0.45, 1.0 },
    INPUT = { 0.45, 0.90, 1.00, 1.0 },
}

local UI_THEMES = {
    {
        key = 'maui_gold',
        label = 'Maui Gold',
        windowBg = { 0.03, 0.05, 0.10, 0.98 },
        titleBg = { 0.02, 0.03, 0.07, 1.00 },
        titleBgActive = { 0.03, 0.05, 0.12, 1.00 },
        button = { 0.10, 0.18, 0.31, 0.95 },
        buttonHovered = { 0.16, 0.27, 0.44, 1.00 },
        buttonActive = { 0.21, 0.33, 0.52, 1.00 },
        frameBg = { 0.09, 0.15, 0.26, 0.95 },
        header = { 0.10, 0.18, 0.31, 0.95 },
        text = { 1.00, 0.95, 0.20, 1.00 },
        border = { 0.74, 0.66, 0.34, 0.95 },
    },
    {
        key = 'blueprint',
        label = 'Blueprint',
        windowBg = { 0.03, 0.08, 0.12, 0.98 },
        titleBg = { 0.02, 0.06, 0.10, 1.00 },
        titleBgActive = { 0.03, 0.10, 0.16, 1.00 },
        button = { 0.09, 0.30, 0.42, 0.95 },
        buttonHovered = { 0.14, 0.41, 0.56, 1.00 },
        buttonActive = { 0.18, 0.48, 0.66, 1.00 },
        frameBg = { 0.07, 0.21, 0.30, 0.95 },
        header = { 0.09, 0.30, 0.42, 0.95 },
        text = { 0.90, 0.97, 1.00, 1.00 },
        border = { 0.52, 0.72, 0.86, 0.95 },
    },
    {
        key = 'emerald',
        label = 'Emerald Ops',
        windowBg = { 0.03, 0.09, 0.06, 0.98 },
        titleBg = { 0.02, 0.06, 0.04, 1.00 },
        titleBgActive = { 0.03, 0.10, 0.06, 1.00 },
        button = { 0.08, 0.31, 0.19, 0.95 },
        buttonHovered = { 0.12, 0.44, 0.26, 1.00 },
        buttonActive = { 0.18, 0.55, 0.33, 1.00 },
        frameBg = { 0.07, 0.22, 0.14, 0.95 },
        header = { 0.08, 0.31, 0.19, 0.95 },
        text = { 0.90, 1.00, 0.92, 1.00 },
        border = { 0.50, 0.78, 0.62, 0.95 },
    },
}

local state = {
    running = true,
    showUI = true,
    autoscroll = true,
    debug = false,
    showTimestamps = true,
    status = 'Idle',

    pendingBuffer = '',
    inputBuffer = '',

    logs = {},
    logFilter = 'Show All',
    logSearch = '',
    history = {},
    historyIndex = 0,

    env = nil,
    envReserved = {},

    chatModeEnabled = false,
    chatEvalToken = '!',
    allowUnsafeMqEnv = false,

    watches = {},
    watchInput = '',
    watchLabelInput = '',
    watchIntervalMs = DEFAULT_WATCH_INTERVAL_MS,
    watchLastTickMs = 0,
    nextWatchId = 1,

    triggers = {},
    triggerCondInput = '',
    triggerActionInput = '',
    triggerCooldownSecInput = '3',
    triggerCombatOnly = false,
    triggerIntervalMs = DEFAULT_TRIGGER_INTERVAL_MS,
    triggerLastTickMs = 0,
    nextTriggerId = 1,

    inspectInput = 'Target',

    snippets = {},
    snippetNameInput = '',
    snippetCodeInput = '',
    selectedSnippet = 0,

    eventTypeInput = 'combat',
    eventArgsInput = 'You hit TARGET for 500 damage.',
    eventHandlerInput = 'print("event:", EVENT_TYPE, EVENT_ARGS[1])',

    lastEvalMs = 0,
    slowEvalWarnMs = 75,
    profileLastAvgMs = 0,
    profileLastGC = 0,

    showInspectTree = false,
    inspectTreeValue = nil,
    inspectTreeLabel = '',

    currentTab = 'Console',
    openSections = {
        watches = true,
        triggers = true,
        inspect = true,
        snippets = true,
        events = true,
        perf = true,
        systems = true,
    },

    theme = 'maui_gold',
    themeIndex = 1,
    layoutPreset = 'default',
    topLogRatio = 0.58,
    windowState = {
        x = nil,
        y = nil,
        w = 1180,
        h = 760,
        collapsed = false,
    },

    pluginMessages = {},
    pluginQueueLimit = 250,

    autocomplete = {
        enabled = true,
        candidates = {},
        index = 1,
        lastPrefix = '',
        showPopup = false,
    },

    customTabs = {},
    nextCustomTabId = 1,
    eventBus = {},

    plots = {},
    nextPlotId = 1,
    plotIntervalMs = 250,
    plotLastTickMs = 0,

    bench = {
        code = '',
        iterations = 200,
        result = nil,
    },

    autoSave = {
        enabled = true,
        intervalMs = 30000,
        lastTickMs = 0,
        restorePrompt = false,
        restoreChecked = false,
    },

    remoteEval = {
        enabled = true,
        intervalMs = 1000,
        lastTickMs = 0,
        lastContent = '',
    },

    usePerCharacterFiles = true,

    macroSync = {},
    nextMacroSyncId = 1,
    macroSyncIntervalMs = 300,
    macroSyncLastTickMs = 0,
    macroVarInput = '',
    macroAliasInput = '',

    merc = {
        selectedStance = 'Balanced',
        stances = { 'Passive', 'Balanced', 'Efficient', 'Aggressive', 'Assist' },
        lastCmd = '',
    },

    navDebug = {
        enabled = false,
    },

    quickCommands = {
        '/lua run smartloot',
        '/lua run ezinventory',
        '/lua run ezbots',
        '/lua run spawnwatch',
        '/sl_doloot',
        '/mqp on',
        '/mqp off',
        '/end',
    },
}

-- =========================================================
-- Utility helpers
-- =========================================================

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function splitLines(s)
    local out = {}
    for line in (s .. '\n'):gmatch('(.-)\n') do
        table.insert(out, line)
    end
    return out
end

local function tableCount(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function safeToString(v)
    local ok, str = pcall(tostring, v)
    if ok then return str end
    return '<tostring error>'
end

local function startsWith(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function stripQuotes(s)
    s = trim(s or '')
    if #s >= 2 then
        local a = s:sub(1, 1)
        local b = s:sub(-1)
        if (a == '"' and b == '"') or (a == "'" and b == "'") then
            return s:sub(2, -2)
        end
    end
    return s
end

local function parseQuotedStrings(s)
    local out = {}
    for _, value in (s or ''):gmatch("([\"'])(.-)%1") do
        out[#out + 1] = value
    end
    return out
end

local function fileExists(path)
    local f = io.open(path, 'rb')
    if f then f:close() return true end
    return false
end

local function safeFileName(s)
    s = tostring(s or 'global')
    s = s:gsub('[^%w_%-]', '_')
    if s == '' then s = 'global' end
    return s
end

local function scopedPath(basePath, scope)
    local dir, file = basePath:match('^(.*)/([^/]+)$')
    if not dir or not file then return basePath end
    local stem, ext = file:match('^(.*)%.([^%.]+)$')
    if not stem then
        return ('%s/%s_%s'):format(dir, file, scope)
    end
    return ('%s/%s_%s.%s'):format(dir, stem, scope, ext)
end

local function normalizePath(path)
    return tostring(path or ''):gsub('\\', '/')
end

local function managedStorageDir()
    return normalizePath(mq.configDir)
end

local function resolveManagedPath(path, defaultPath)
    local raw = trim(path or '')
    if raw == '' then
        return defaultPath, nil
    end

    local normalized = normalizePath(raw)
    local baseDir = managedStorageDir()

    if normalized:find('%.%.') then
        return nil, 'Path traversal is not allowed.'
    end

    if normalized:find('/') or normalized:find(':') then
        if normalized:sub(1, #baseDir):lower() ~= baseDir:lower() then
            return nil, 'Path must stay under ' .. baseDir
        end
        return normalized, nil
    end

    return baseDir .. '/' .. safeFileName(normalized), nil
end

local function applyPerCharacterFileScope()
    if not state.usePerCharacterFiles then
        return
    end
    local ok, meName = pcall(function() return mq.TLO.Me.CleanName() end)
    if not ok then meName = nil end
    if not meName or trim(tostring(meName)) == '' then
        return
    end
    local scope = safeFileName(meName)
    SESSION_FILE = scopedPath(BASE_FILES.SESSION_FILE, scope)
    SETTINGS_FILE = scopedPath(BASE_FILES.SETTINGS_FILE, scope)
    WATCHES_FILE = scopedPath(BASE_FILES.WATCHES_FILE, scope)
    TRIGGERS_FILE = scopedPath(BASE_FILES.TRIGGERS_FILE, scope)
    SNIPPETS_FILE = scopedPath(BASE_FILES.SNIPPETS_FILE, scope)
    LOG_EXPORT_FILE = scopedPath(BASE_FILES.LOG_EXPORT_FILE, scope)
    SESSION_STATE_FILE = scopedPath(BASE_FILES.SESSION_STATE_FILE, scope)
    SHARE_FILE = scopedPath(BASE_FILES.SHARE_FILE, scope)
    AUTO_SAVE_FILE = scopedPath(BASE_FILES.AUTO_SAVE_FILE, scope)
    REMOTE_EVAL_FILE = scopedPath(BASE_FILES.REMOTE_EVAL_FILE, scope)
end

local function findThemeByKey(key)
    for i, t in ipairs(UI_THEMES) do
        if t.key == key then return t, i end
    end
    return UI_THEMES[1], 1
end

local function pushConsoleTheme()
    local t, idx = findThemeByKey(state.theme)
    state.themeIndex = idx
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 0.0)
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
    ImGui.PushStyleVar(ImGuiStyleVar.TabRounding, 0.0)
    ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 1.0)
    ImGui.PushStyleColor(ImGuiCol.WindowBg, t.windowBg[1], t.windowBg[2], t.windowBg[3], t.windowBg[4])
    ImGui.PushStyleColor(ImGuiCol.TitleBg, t.titleBg[1], t.titleBg[2], t.titleBg[3], t.titleBg[4])
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, t.titleBgActive[1], t.titleBgActive[2], t.titleBgActive[3], t.titleBgActive[4])
    ImGui.PushStyleColor(ImGuiCol.Button, t.button[1], t.button[2], t.button[3], t.button[4])
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, t.buttonHovered[1], t.buttonHovered[2], t.buttonHovered[3], t.buttonHovered[4])
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, t.buttonActive[1], t.buttonActive[2], t.buttonActive[3], t.buttonActive[4])
    ImGui.PushStyleColor(ImGuiCol.FrameBg, t.frameBg[1], t.frameBg[2], t.frameBg[3], t.frameBg[4])
    ImGui.PushStyleColor(ImGuiCol.Header, t.header[1], t.header[2], t.header[3], t.header[4])
    ImGui.PushStyleColor(ImGuiCol.Text, t.text[1], t.text[2], t.text[3], t.text[4])
    ImGui.PushStyleColor(ImGuiCol.Border, t.border[1], t.border[2], t.border[3], t.border[4])
    return 4, 10
end

local function popConsoleTheme(vars, colors)
    if colors and colors > 0 then ImGui.PopStyleColor(colors) end
    if vars and vars > 0 then ImGui.PopStyleVar(vars) end
end

local function safeTLO(fn, fallback)
    local ok, v = pcall(fn)
    if ok then return v end
    return fallback
end

local function writeTextFile(path, text)
    local ok, err = pcall(function()
        local f = assert(io.open(path, 'wb'))
        f:write(text or '')
        f:close()
    end)
    return ok, err
end

local function readTextFile(path)
    local ok, data = pcall(function()
        local f = assert(io.open(path, 'rb'))
        local t = f:read('*a')
        f:close()
        return t
    end)
    if ok then return data end
    return nil
end

local function truncate(s, maxLen)
    if #s <= maxLen then return s end
    return s:sub(1, maxLen) .. '\n... <truncated>'
end

local function nowMs()
    return mq.gettime()
end

local function debugLog(msg)
    if not state.debug then return end
    local text = ('[debug] %s'):format(msg)
    table.insert(state.logs, { level = 'WARN', text = text, ts = os.date('%H:%M:%S') })
end

-- =========================================================
-- Logging (chat + ImGui)
-- =========================================================

local function mqEcho(text)
    local ok = pcall(mq.msg, text, true)
    if not ok then
        mq.cmdf('/echo %s', text)
    end
end

local function pushLog(level, text, alsoChat, tag)
    local entry = {
        level = level or 'INFO',
        text = tostring(text or ''),
        ts = os.date('%H:%M:%S'),
        tag = tag or '',
    }
    table.insert(state.logs, entry)
    if #state.logs > MAX_LOG then
        table.remove(state.logs, 1)
    end

    if alsoChat ~= false then
        local c = COLOR[entry.level] or COLOR.INFO
        if state.showTimestamps then
            mqEcho(('%s[%s] %s'):format(c, entry.ts, entry.text))
        else
            mqEcho(('%s%s'):format(c, entry.text))
        end
    end
end

local function logInfo(text, tag) pushLog('INFO', text, true, tag) end
local function logOk(text, tag) pushLog('OK', text, true, tag) end
local function logWarn(text, tag) pushLog('WARN', text, true, tag) end
local function logErr(text, tag) pushLog('ERR', text, true, tag) end

local function eventSubscribe(eventName, callback, owner)
    eventName = trim(tostring(eventName or ''))
    if eventName == '' or type(callback) ~= 'function' then
        return nil
    end
    if not state.eventBus[eventName] then
        state.eventBus[eventName] = {}
    end
    local sub = {
        id = tostring(nowMs()) .. '_' .. tostring(math.random(1000, 9999)),
        owner = owner or 'unknown',
        cb = callback,
    }
    table.insert(state.eventBus[eventName], sub)
    return sub.id
end

local function eventUnsubscribe(subId)
    for evt, list in pairs(state.eventBus) do
        for i, sub in ipairs(list) do
            if sub.id == subId then
                table.remove(list, i)
                if #list == 0 then state.eventBus[evt] = nil end
                return true
            end
        end
    end
    return false
end

local function eventPublish(eventName, payload)
    local list = state.eventBus[eventName]
    if not list then return 0 end
    local fired = 0
    for _, sub in ipairs(list) do
        local ok, err = pcall(sub.cb, payload, eventName)
        if ok then
            fired = fired + 1
        else
            logErr(('event bus callback error [%s]: %s'):format(eventName, tostring(err)), 'event')
        end
    end
    return fired
end

local function registerCustomTab(name, callback, owner)
    name = trim(tostring(name or ''))
    if name == '' or type(callback) ~= 'function' then
        return nil
    end
    local row = {
        id = state.nextCustomTabId,
        name = name,
        cb = callback,
        owner = owner or 'external',
    }
    state.nextCustomTabId = state.nextCustomTabId + 1
    table.insert(state.customTabs, row)
    return row.id
end

local function unregisterCustomTab(id)
    for i, t in ipairs(state.customTabs) do
        if t.id == id then
            table.remove(state.customTabs, i)
            return true
        end
    end
    return false
end

-- =========================================================
-- JSON (small built-in serializer/parser for session save/load)
-- =========================================================

local json = {}

local function jsonEscape(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

local function isArray(t)
    local max = 0
    local count = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max then max = k end
        count = count + 1
    end
    if max > count * 2 and count > 0 then
        return false
    end
    return true, max
end

function json.encode(v)
    local tv = type(v)
    if tv == 'nil' then
        return 'null'
    elseif tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            return 'null'
        end
        return tostring(v)
    elseif tv == 'string' then
        return '"' .. jsonEscape(v) .. '"'
    elseif tv == 'table' then
        local arrayLike, max = isArray(v)
        local parts = {}
        if arrayLike then
            for i = 1, max do
                parts[#parts + 1] = json.encode(v[i])
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            for k, val in pairs(v) do
                if type(k) == 'string' then
                    parts[#parts + 1] = '"' .. jsonEscape(k) .. '":' .. json.encode(val)
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

function json.decode(str)
    local i = 1
    local n = #str

    local function skipWs()
        while i <= n do
            local c = str:sub(i, i)
            if c == ' ' or c == '\n' or c == '\r' or c == '\t' then
                i = i + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        i = i + 1 -- opening quote
        local out = {}
        while i <= n do
            local c = str:sub(i, i)
            if c == '"' then
                i = i + 1
                return table.concat(out)
            elseif c == '\\' then
                local nxt = str:sub(i + 1, i + 1)
                if nxt == '"' or nxt == '\\' or nxt == '/' then
                    out[#out + 1] = nxt
                    i = i + 2
                elseif nxt == 'b' then
                    out[#out + 1] = '\b'
                    i = i + 2
                elseif nxt == 'f' then
                    out[#out + 1] = '\f'
                    i = i + 2
                elseif nxt == 'n' then
                    out[#out + 1] = '\n'
                    i = i + 2
                elseif nxt == 'r' then
                    out[#out + 1] = '\r'
                    i = i + 2
                elseif nxt == 't' then
                    out[#out + 1] = '\t'
                    i = i + 2
                elseif nxt == 'u' then
                    -- Minimal \u handling: replace with '?'
                    out[#out + 1] = '?'
                    i = i + 6
                else
                    error('Invalid escape sequence at position ' .. i)
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        error('Unterminated string')
    end

    local function parseNumber()
        local start = i
        local c = str:sub(i, i)
        if c == '-' then i = i + 1 end
        while i <= n and str:sub(i, i):match('%d') do i = i + 1 end
        if str:sub(i, i) == '.' then
            i = i + 1
            while i <= n and str:sub(i, i):match('%d') do i = i + 1 end
        end
        local e = str:sub(i, i)
        if e == 'e' or e == 'E' then
            i = i + 1
            local sgn = str:sub(i, i)
            if sgn == '+' or sgn == '-' then i = i + 1 end
            while i <= n and str:sub(i, i):match('%d') do i = i + 1 end
        end
        local num = tonumber(str:sub(start, i - 1))
        if num == nil then
            error('Invalid number near position ' .. start)
        end
        return num
    end

    local function parseArray()
        i = i + 1 -- [
        local arr = {}
        skipWs()
        if str:sub(i, i) == ']' then
            i = i + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parseValue()
            skipWs()
            local c = str:sub(i, i)
            if c == ']' then
                i = i + 1
                return arr
            elseif c ~= ',' then
                error('Expected "," or "]" at position ' .. i)
            end
            i = i + 1
            skipWs()
        end
    end

    local function parseObject()
        i = i + 1 -- {
        local obj = {}
        skipWs()
        if str:sub(i, i) == '}' then
            i = i + 1
            return obj
        end
        while true do
            skipWs()
            if str:sub(i, i) ~= '"' then
                error('Expected string key at position ' .. i)
            end
            local key = parseString()
            skipWs()
            if str:sub(i, i) ~= ':' then
                error('Expected ":" at position ' .. i)
            end
            i = i + 1
            skipWs()
            obj[key] = parseValue()
            skipWs()
            local c = str:sub(i, i)
            if c == '}' then
                i = i + 1
                return obj
            elseif c ~= ',' then
                error('Expected "," or "}" at position ' .. i)
            end
            i = i + 1
            skipWs()
        end
    end

    function parseValue()
        skipWs()
        local c = str:sub(i, i)
        if c == '"' then
            return parseString()
        elseif c == '{' then
            return parseObject()
        elseif c == '[' then
            return parseArray()
        elseif c == '-' or c:match('%d') then
            return parseNumber()
        elseif startsWith(str:sub(i), 'true') then
            i = i + 4
            return true
        elseif startsWith(str:sub(i), 'false') then
            i = i + 5
            return false
        elseif startsWith(str:sub(i), 'null') then
            i = i + 4
            return nil
        end
        error('Unexpected token at position ' .. i)
    end

    local value = parseValue()
    skipWs()
    if i <= n then
        error('Trailing data at position ' .. i)
    end
    return value
end

-- =========================================================
-- Pretty inspector (compact deep dump with recursion protection)
-- =========================================================

local function inspectValue(value, opts, depth, seen)
    opts = opts or {}
    depth = depth or 0
    seen = seen or {}

    local maxDepth = opts.maxDepth or MAX_INSPECT_DEPTH
    local indent = opts.indent or '  '
    local tv = type(value)

    if tv == 'nil' then return 'nil' end
    if tv == 'boolean' or tv == 'number' then return tostring(value) end
    if tv == 'string' then return ('%q'):format(value) end

    if tv == 'function' or tv == 'userdata' or tv == 'thread' then
        return ('<%s %s>'):format(tv, safeToString(value))
    end

    if tv ~= 'table' then
        return '<' .. tv .. '>'
    end

    if seen[value] then
        return '<recursion>'
    end

    if depth >= maxDepth then
        return '{ ... }'
    end

    seen[value] = true

    local keys = {}
    for k in pairs(value) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then return tostring(a) < tostring(b) end
        return ta < tb
    end)

    local lines = {}
    lines[#lines + 1] = '{'
    for _, k in ipairs(keys) do
        local kText
        if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
            kText = k
        else
            kText = '[' .. inspectValue(k, opts, depth + 1, seen) .. ']'
        end

        local vText = inspectValue(value[k], opts, depth + 1, seen)
        lines[#lines + 1] = string.rep(indent, depth + 1) .. kText .. ' = ' .. vText .. ','
    end
    lines[#lines + 1] = string.rep(indent, depth) .. '}'

    seen[value] = nil
    return table.concat(lines, '\n')
end

local function inspectAlias(o)
    return inspectValue(o, { maxDepth = MAX_INSPECT_DEPTH })
end

-- =========================================================
-- Safer environment construction
-- =========================================================

local function blockedApi(name)
    return function(...)
        local msg = ('Blocked API call: %s'):format(name)
        logWarn(msg)
        error(msg, 2)
    end
end

local function buildSafeBase()
    local base = {}

    local allow = {
        'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'select', 'tonumber', 'tostring',
        'type', 'unpack', 'xpcall',
        'coroutine', 'math', 'string', 'table',
    }

    for _, key in ipairs(allow) do
        base[key] = _G[key]
    end

    -- Safe subsets of os/io: no shell/process launching.
    base.os = {
        clock = os.clock,
        date = os.date,
        difftime = os.difftime,
        time = os.time,
        exit = blockedApi('os.exit'),
        execute = blockedApi('os.execute'),
        remove = blockedApi('os.remove'),
        rename = blockedApi('os.rename'),
        setlocale = os.setlocale,
        getenv = blockedApi('os.getenv'),
    }

    base.io = {
        write = io.write,
        flush = io.flush,
        stdout = io.stdout,
        stderr = io.stderr,
        open = blockedApi('io.open'),
        popen = blockedApi('io.popen'),
        input = blockedApi('io.input'),
        output = blockedApi('io.output'),
        read = blockedApi('io.read'),
        lines = blockedApi('io.lines'),
        tmpfile = blockedApi('io.tmpfile'),
    }

    base.debug = {
        traceback = debug.traceback,
    }

    return base
end

local function mkPrint(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = safeToString(select(i, ...))
    end
    pushLog('INFO', table.concat(parts, '\t'), true, 'print')
end

local function makeEnv()
    local safeBase = buildSafeBase()

    local env = {
        -- Core MQ shortcuts
        T = mq.TLO,
        Me = mq.TLO.Me,
        Target = mq.TLO.Target,
        Group = mq.TLO.Group,
        Spawn = mq.TLO.Spawn,
        Zone = mq.TLO.Zone,

        -- Print / inspect aliases
        print = mkPrint,            -- requirement: print -> mq-style output
        inspect = inspectAlias,
        dump = inspectAlias,
        pp = inspectAlias,
    }

    if state.allowUnsafeMqEnv then
        env.mq = mq
        env.cmd = function(command) return mq.cmd(command) end
        env.cmdf = function(fmt, ...) return mq.cmdf(fmt, ...) end
        env.delay = function(ms, condition) return mq.delay(ms, condition) end
        env.echo = function(msg) return mq.cmdf('/echo %s', tostring(msg)) end
    end

    setmetatable(env, {
        __index = safeBase,
        __newindex = rawset,
    })

    -- Reserve built-ins so session save can skip them.
    for k in pairs(env) do
        state.envReserved[k] = true
    end
    for k in pairs(safeBase) do
        state.envReserved[k] = true
    end

    return env
end

state.env = makeEnv()

-- =========================================================
-- Compilation / completeness checks
-- =========================================================

local function applyEnv(func, env)
    if setfenv then
        setfenv(func, env)
        return func
    end
    return func
end

local function compileChunk(code, chunkName, env)
    local loader = loadstring or load
    if not loader then
        return nil, 'Lua runtime has no load/loadstring'
    end

    if loader == load and _VERSION ~= 'Lua 5.1' then
        return loader(code, chunkName, 't', env)
    end

    local fn, err = loader(code, chunkName)
    if not fn then return nil, err end
    fn = applyEnv(fn, env)
    return fn, nil
end

local function isIncompleteSyntaxError(err)
    if not err then return false end
    err = tostring(err)
    return err:find('<eof>') ~= nil or err:find('near <eof>') ~= nil
end

local function isChunkComplete(code, env)
    local fn, err = compileChunk(code, 'luaconsole_check', env)
    if fn then return true, nil end
    if isIncompleteSyntaxError(err) then
        return false, nil
    end
    return true, err
end

-- =========================================================
-- Friendly error formatting
-- =========================================================

local function extractLineNum(err)
    local line = tostring(err):match(':(%d+):')
    if line then return tonumber(line) end
    return nil
end

local function makeCodeSnippet(code, lineNum)
    if not lineNum then return nil end
    local lines = splitLines(code)
    if lineNum < 1 or lineNum > #lines then return nil end

    local startL = math.max(1, lineNum - 1)
    local endL = math.min(#lines, lineNum + 1)
    local out = {}
    for i = startL, endL do
        local mark = (i == lineNum) and '>>' or '  '
        out[#out + 1] = ('%s %4d | %s'):format(mark, i, lines[i])
    end
    return table.concat(out, '\n')
end

local function formatRuntimeError(err, code)
    local errStr = tostring(err)
    local lineNum = extractLineNum(errStr)
    local snippet = makeCodeSnippet(code or '', lineNum)

    local final = {}
    final[#final + 1] = errStr
    if snippet then
        final[#final + 1] = 'Failing area:'
        final[#final + 1] = snippet
    end
    return table.concat(final, '\n')
end

-- =========================================================
-- History
-- =========================================================

local function pushHistory(line)
    line = trim(line or '')
    if line == '' then return end

    if state.history[#state.history] ~= line then
        table.insert(state.history, line)
        if #state.history > MAX_HISTORY then
            table.remove(state.history, 1)
        end
    end

    state.historyIndex = #state.history + 1
end

local function historyPrev()
    if #state.history == 0 then
        logWarn('History empty.')
        return nil
    end

    state.historyIndex = math.max(1, state.historyIndex - 1)
    local line = state.history[state.historyIndex]
    if line then
        logInfo('history[' .. state.historyIndex .. ']: ' .. line)
    end
    return line
end

local function historyNext()
    if #state.history == 0 then
        logWarn('History empty.')
        return nil
    end

    state.historyIndex = math.min(#state.history + 1, state.historyIndex + 1)
    if state.historyIndex == #state.history + 1 then
        logInfo('history[end]')
        return ''
    end

    local line = state.history[state.historyIndex]
    if line then
        logInfo('history[' .. state.historyIndex .. ']: ' .. line)
    end
    return line
end

-- =========================================================
-- Session save/load
-- =========================================================

local function serializableCopy(value, seen, depth)
    depth = depth or 0
    seen = seen or {}

    if depth > 12 then return nil end

    local tv = type(value)
    if tv == 'nil' or tv == 'boolean' or tv == 'number' or tv == 'string' then
        return value
    end

    if tv ~= 'table' then
        return nil
    end

    if seen[value] then
        return nil
    end
    seen[value] = true

    local out = {}
    local arrLike, max = isArray(value)
    if arrLike then
        for i = 1, max do
            out[i] = serializableCopy(value[i], seen, depth + 1)
        end
    else
        for k, v in pairs(value) do
            if type(k) == 'string' and not startsWith(k, '__') then
                local c = serializableCopy(v, seen, depth + 1)
                if c ~= nil then
                    out[k] = c
                end
            end
        end
    end

    seen[value] = nil
    return out
end

local function collectSessionData()
    local saved = {}
    for k, v in pairs(state.env) do
        if not state.envReserved[k] then
            local c = serializableCopy(v)
            if c ~= nil then
                saved[k] = c
            end
        end
    end
    return {
        meta = {
            script = SCRIPT_NAME,
            version = VERSION,
            savedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        },
        env = saved,
        watches = (function()
            local out = {}
            for _, w in ipairs(state.watches) do out[#out + 1] = { id = w.id, expr = w.expr, label = w.label or w.expr } end
            return out
        end)(),
        triggers = (function()
            local out = {}
            for _, t in ipairs(state.triggers) do
                out[#out + 1] = {
                    id = t.id,
                    condition = t.condition,
                    action = t.action,
                    cooldownMs = t.cooldownMs,
                    combatOnly = t.combatOnly == true,
                }
            end
            return out
        end)(),
        snippets = state.snippets,
        plots = (function()
            local out = {}
            for _, p in ipairs(state.plots) do
                out[#out + 1] = { id = p.id, expr = p.expr, label = p.label, samples = p.samples }
            end
            return out
        end)(),
        ui = {
            currentTab = state.currentTab,
            layoutPreset = state.layoutPreset,
            topLogRatio = state.topLogRatio,
            theme = state.theme,
        },
    }
end

local function saveSession(file)
    local resolved, pathErr = resolveManagedPath(file, SESSION_FILE)
    if not resolved then
        logErr('Session save failed: ' .. tostring(pathErr))
        return false
    end
    file = resolved

    local data = collectSessionData()
    local encoded = json.encode(data)

    local ok, err = pcall(function()
        local f = assert(io.open(file, 'wb'))
        f:write(encoded)
        f:close()
    end)

    if not ok then
        logErr('Session save failed: ' .. tostring(err))
        return false
    end

    logOk(('Session saved: %s (%d env keys)'):format(file, tableCount(data.env)))
    return true
end

local function loadSession(file)
    local resolved, pathErr = resolveManagedPath(file, SESSION_FILE)
    if not resolved then
        logErr('Session load failed: ' .. tostring(pathErr))
        return false
    end
    file = resolved

    local ok, payloadOrErr = pcall(function()
        local f = assert(io.open(file, 'rb'))
        local text = f:read('*a')
        f:close()
        return text
    end)

    if not ok then
        logErr('Session load failed: ' .. tostring(payloadOrErr))
        return false
    end

    local okDecode, decoded = pcall(json.decode, payloadOrErr)
    if not okDecode or type(decoded) ~= 'table' or type(decoded.env) ~= 'table' then
        logErr('Session parse failed: invalid JSON session content.')
        return false
    end

    local restored = 0
    for k, v in pairs(decoded.env) do
        if not state.envReserved[k] then
            state.env[k] = v
            restored = restored + 1
        end
    end

    if type(decoded.watches) == 'table' then
        state.watches = {}
        state.nextWatchId = 1
        for _, w in ipairs(decoded.watches) do
            if type(w) == 'table' and type(w.expr) == 'string' then
                addWatch(w.expr, w.label or '')
            end
        end
    end
    if type(decoded.triggers) == 'table' then
        state.triggers = {}
        state.nextTriggerId = 1
        for _, t in ipairs(decoded.triggers) do
            if type(t) == 'table' then
                addTrigger(t.condition or '', t.action or '', t.cooldownMs, t.combatOnly == true)
            end
        end
    end
    if type(decoded.snippets) == 'table' then
        state.snippets = {}
        for _, s in ipairs(decoded.snippets) do
            if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
                table.insert(state.snippets, { name = s.name, code = s.code })
            end
        end
    end
    if type(decoded.plots) == 'table' then
        state.plots = {}
        state.nextPlotId = 1
        for _, p in ipairs(decoded.plots) do
            if type(p) == 'table' and type(p.expr) == 'string' then
                addPlot(p.expr, p.label or '', p.samples)
            end
        end
    end
    if type(decoded.ui) == 'table' then
        state.currentTab = type(decoded.ui.currentTab) == 'string' and decoded.ui.currentTab or state.currentTab
        state.layoutPreset = type(decoded.ui.layoutPreset) == 'string' and decoded.ui.layoutPreset or state.layoutPreset
        state.topLogRatio = tonumber(decoded.ui.topLogRatio) or state.topLogRatio
        state.theme = type(decoded.ui.theme) == 'string' and decoded.ui.theme or state.theme
    end

    logOk(('Session loaded: %s (%d env keys restored)'):format(file, restored))
    return true
end

-- Forward declarations so early-defined helpers capture locals, not globals.
local saveSettings
local loadSettings

local function savePersistentState()
    local hist = {}
    local startIdx = math.max(1, #state.history - 99)
    for i = startIdx, #state.history do
        hist[#hist + 1] = state.history[i]
    end
    local data = {
        env = collectSessionData().env,
        currentTab = state.currentTab,
        theme = state.theme,
        themeIndex = state.themeIndex,
        layoutPreset = state.layoutPreset,
        topLogRatio = state.topLogRatio,
        windowState = state.windowState,
        history = hist,
        watchInput = state.watchInput,
        watchLabelInput = state.watchLabelInput,
        triggerCondInput = state.triggerCondInput,
        triggerActionInput = state.triggerActionInput,
        snippetNameInput = state.snippetNameInput,
        snippetCodeInput = state.snippetCodeInput,
    }
    local ok, err = writeTextFile(SESSION_STATE_FILE, json.encode(data))
    if not ok then
        debugLog('persistent state save failed: ' .. tostring(err))
    end
end

local sanitizeWindowState -- UPDATED: forward declaration so loadPersistentState can safely call this helper

local function loadPersistentState()
    local text = readTextFile(SESSION_STATE_FILE)
    if not text or text == '' then return end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= 'table' then return end
    if type(decoded.env) == 'table' then
        for k, v in pairs(decoded.env) do
            if not state.envReserved[k] then
                state.env[k] = v
            end
        end
    end
    if type(decoded.currentTab) == 'string' then state.currentTab = decoded.currentTab end
    if type(decoded.theme) == 'string' then state.theme = decoded.theme end
    if type(decoded.themeIndex) == 'number' then state.themeIndex = decoded.themeIndex end
    if type(decoded.layoutPreset) == 'string' then state.layoutPreset = decoded.layoutPreset end
    if type(decoded.topLogRatio) == 'number' then state.topLogRatio = decoded.topLogRatio end
    if type(decoded.windowState) == 'table' then
        state.windowState = sanitizeWindowState(decoded.windowState) or state.windowState
    end
    if type(decoded.history) == 'table' then
        state.history = {}
        for _, v in ipairs(decoded.history) do
            if type(v) == 'string' then state.history[#state.history + 1] = v end
        end
        state.historyIndex = #state.history + 1
    end
    if type(decoded.watchInput) == 'string' then state.watchInput = decoded.watchInput end
    if type(decoded.watchLabelInput) == 'string' then state.watchLabelInput = decoded.watchLabelInput end
    if type(decoded.triggerCondInput) == 'string' then state.triggerCondInput = decoded.triggerCondInput end
    if type(decoded.triggerActionInput) == 'string' then state.triggerActionInput = decoded.triggerActionInput end
    if type(decoded.snippetNameInput) == 'string' then state.snippetNameInput = decoded.snippetNameInput end
    if type(decoded.snippetCodeInput) == 'string' then state.snippetCodeInput = decoded.snippetCodeInput end
end

sanitizeWindowState = function(ws) -- UPDATED: assign to forward-declared local to avoid nil-call at startup
    if type(ws) ~= 'table' then
        return nil
    end

    local x = tonumber(ws.x)
    local y = tonumber(ws.y)
    local w = tonumber(ws.w)
    local h = tonumber(ws.h)

    if not w or w < 720 then
        w = 1180
    end
    if not h or h < 420 then
        h = 760
    end

    return {
        x = x,
        y = y,
        w = w,
        h = h,
        collapsed = false,
    }
end

local function saveAutoSnapshot()
    local payload = {
        savedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        session = collectSessionData(),
        settings = {
            currentTab = state.currentTab,
            theme = state.theme,
            layoutPreset = state.layoutPreset,
            topLogRatio = state.topLogRatio,
            windowState = state.windowState,
            history = state.history,
        },
    }
    local ok, err = writeTextFile(AUTO_SAVE_FILE, json.encode(payload))
    if not ok then
        debugLog('autosave failed: ' .. tostring(err))
    end
end

local function maybeAutoSave()
    if not state.autoSave.enabled then return end
    local now = nowMs()
    if now - (state.autoSave.lastTickMs or 0) < (state.autoSave.intervalMs or 30000) then return end
    state.autoSave.lastTickMs = now
    savePersistentState()
    saveSettings()
    saveAutoSnapshot()
end

local function restoreFromAutoSnapshot()
    local text = readTextFile(AUTO_SAVE_FILE)
    if not text or text == '' then return false end
    local ok, payload = pcall(json.decode, text)
    if not ok or type(payload) ~= 'table' then return false end
    if type(payload.session) == 'table' and type(payload.session.env) == 'table' then
        for k, v in pairs(payload.session.env) do
            if not state.envReserved[k] then
                state.env[k] = v
            end
        end
    end
    if type(payload.session) == 'table' and type(payload.session.watches) == 'table' then
        state.watches = {}
        state.nextWatchId = 1
        for _, w in ipairs(payload.session.watches) do
            if type(w) == 'table' and type(w.expr) == 'string' then
                addWatch(w.expr, w.label or '')
            end
        end
    end
    if type(payload.session) == 'table' and type(payload.session.snippets) == 'table' then
        state.snippets = {}
        for _, s in ipairs(payload.session.snippets) do
            if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
                table.insert(state.snippets, { name = s.name, code = s.code })
            end
        end
    end
    if type(payload.settings) == 'table' then
        if type(payload.settings.currentTab) == 'string' then state.currentTab = payload.settings.currentTab end
        if type(payload.settings.theme) == 'string' then state.theme = payload.settings.theme end
        if type(payload.settings.layoutPreset) == 'string' then state.layoutPreset = payload.settings.layoutPreset end
        if type(payload.settings.topLogRatio) == 'number' then state.topLogRatio = payload.settings.topLogRatio end
        if type(payload.settings.windowState) == 'table' then state.windowState = payload.settings.windowState end
        if type(payload.settings.history) == 'table' then state.history = payload.settings.history end
        state.historyIndex = #state.history + 1
    end
    return true
end

local function pollRemoteEvalFile()
    if not state.remoteEval.enabled then return end
    local now = nowMs()
    if now - (state.remoteEval.lastTickMs or 0) < (state.remoteEval.intervalMs or 1000) then return end
    state.remoteEval.lastTickMs = now
    local text = readTextFile(REMOTE_EVAL_FILE)
    if not text then return end
    local trimmed = trim(text)
    if trimmed == '' then
        state.remoteEval.lastContent = ''
        return
    end
    if trimmed ~= (state.remoteEval.lastContent or '') then
        state.remoteEval.lastContent = trimmed
        submitChunkText(trimmed, 'remote')
    end
end

-- =========================================================
-- Evaluator
-- =========================================================

local function renderResult(...)
    local n = select('#', ...)
    if n == 0 then
        return nil
    end

    if n == 1 then
        local v = select(1, ...)
        if type(v) == 'table' then
            return inspectValue(v)
        end
        return safeToString(v)
    end

    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        if type(v) == 'table' then
            parts[#parts + 1] = inspectValue(v)
        else
            parts[#parts + 1] = safeToString(v)
        end
    end
    return table.concat(parts, '\t')
end

local function evalChunk(code)
    local chunkName = 'LuaConsoleChunk'
    local started = nowMs()

    -- Expression-first mode: try return <code>, then plain chunk.
    local fn, err = compileChunk('return ' .. code, chunkName, state.env)
    if not fn then
        fn, err = compileChunk(code, chunkName, state.env)
    end

    if not fn then
        return false, formatRuntimeError(err, code), nowMs() - started
    end

    local function tracebackHandler(e)
        return debug.traceback(e, 2)
    end

    local results = { xpcall(fn, tracebackHandler) }
    local ok = table.remove(results, 1)

    if not ok then
        local trace = truncate(formatRuntimeError(results[1], code), MAX_TRACE_CHARS)
        return false, trace, nowMs() - started
    end

    return true, renderResult(LU_UNPACK(results)), nowMs() - started
end

local function submitChunkText(text, source)
    source = source or 'unknown'
    text = text or ''

    if trim(text) == '' then return end

    state.status = 'Compiling'
    pushLog('INPUT', ('%s> %s'):format(source, text), true, source == 'chat' and 'combat' or 'input')

    local candidate
    if state.pendingBuffer ~= '' then
        candidate = state.pendingBuffer .. '\n' .. text
    else
        candidate = text
    end

    local complete, syntaxErr = isChunkComplete(candidate, state.env)
    if syntaxErr then
        state.pendingBuffer = ''
        state.status = 'Syntax Error'
        logErr(formatRuntimeError(syntaxErr, candidate))
        return
    end

    if not complete then
        state.pendingBuffer = candidate
        state.status = 'Awaiting continuation'
        logWarn('.. continuation (chunk incomplete; enter next line)')
        return
    end

    state.pendingBuffer = ''
    pushHistory(candidate)

    local ok, result, evalMs = evalChunk(candidate)
    state.lastEvalMs = evalMs or 0
    if ok then
        state.status = 'Idle'
        if result and result ~= '' then
            logOk(result)
        else
            logOk('<ok>')
        end
        local timingText = ('(took %d ms)'):format(state.lastEvalMs)
        if state.lastEvalMs >= 200 then
            logErr(timingText, 'timing')
        elseif state.lastEvalMs >= 50 then
            logWarn(timingText, 'timing')
        else
            logInfo(timingText, 'timing')
        end
        if state.lastEvalMs >= (state.slowEvalWarnMs or 75) then
            logWarn(('slow eval: %dms (threshold %dms)'):format(state.lastEvalMs, state.slowEvalWarnMs or 75))
        end
        eventPublish('eval_completed', { ok = true, source = source, code = candidate, elapsedMs = state.lastEvalMs, result = result })
    else
        state.status = 'Runtime Error'
        logErr(result)
        eventPublish('eval_completed', { ok = false, source = source, code = candidate, elapsedMs = state.lastEvalMs, error = result })
    end
end

local function evalExpressionSilent(expr)
    expr = trim(expr or '')
    if expr == '' then
        return false, nil, 'empty expression', 0
    end

    local started = nowMs()
    local fn = compileChunk('return ' .. expr, 'LuaConsoleWatchExpr', state.env)
    if not fn then
        fn = compileChunk(expr, 'LuaConsoleWatchExpr', state.env)
    end
    if not fn then
        return false, nil, 'compile failed', nowMs() - started
    end

    local function tracebackHandler(e)
        return debug.traceback(e, 2)
    end

    local results = { xpcall(fn, tracebackHandler) }
    local ok = table.remove(results, 1)
    if not ok then
        return false, nil, tostring(results[1]), nowMs() - started
    end

    return true, results[1], nil, nowMs() - started
end

local function valueToWatchText(v)
    local t = type(v)
    if t == 'table' then
        return truncate(inspectValue(v), 220)
    end
    if t == 'userdata' then
        return safeToString(v)
    end
    return safeToString(v)
end

local function isInCombat()
    local ok, v = pcall(function()
        return mq.TLO.Me.Combat() == true
    end)
    return ok and v == true
end

local function addWatch(expr, label)
    expr = stripQuotes(expr or '')
    label = stripQuotes(label or '')
    if expr == '' then
        logWarn('Watch add failed: empty expression.')
        return
    end
    local row = {
        id = state.nextWatchId,
        label = label ~= '' and label or expr,
        expr = expr,
        valueText = '<pending>',
        lastValue = nil,
        valueType = 'nil',
        changed = false,
        hasError = false,
        error = '',
        evalMs = 0,
        lastChangedMs = 0,
        lastUpdatedMs = 0,
        lastUpdatedText = '-',
    }
    state.nextWatchId = state.nextWatchId + 1
    table.insert(state.watches, row)
    if saveWatchesPersistent and not state._suspendWatchSave then saveWatchesPersistent() end
    logOk(('Watch #%d added: %s'):format(row.id, row.label), 'watch')
end

local function removeWatch(id)
    for i, w in ipairs(state.watches) do
        if w.id == id then
            table.remove(state.watches, i)
            if saveWatchesPersistent then saveWatchesPersistent() end
            logOk(('Watch #%d removed.'):format(id), 'watch')
            return true
        end
    end
    logWarn(('Watch #%d not found.'):format(id), 'watch')
    return false
end

local function listWatches()
    if #state.watches == 0 then
        logInfo('No watches configured.')
        return
    end
    for _, w in ipairs(state.watches) do
        logInfo(('#%d [%s] %s => %s'):format(w.id, w.label or w.expr, w.expr, w.valueText or '<pending>'), 'watch')
    end
end

local function addPlot(expr, label, samples)
    expr = stripQuotes(expr or '')
    label = stripQuotes(label or '')
    samples = tonumber(samples) or 120
    samples = math.max(30, math.min(1200, math.floor(samples)))
    if expr == '' then
        logWarn('Plot add failed: expression required.')
        return false
    end
    local p = {
        id = state.nextPlotId,
        expr = expr,
        label = label ~= '' and label or expr,
        samples = samples,
        data = {},
        hasError = false,
        error = '',
        lastValue = nil,
        lastUpdated = '-',
    }
    state.nextPlotId = state.nextPlotId + 1
    table.insert(state.plots, p)
    logOk(('Plot #%d added: %s'):format(p.id, p.label), 'plot')
    return true
end

local function removePlot(id)
    for i, p in ipairs(state.plots) do
        if p.id == id then
            table.remove(state.plots, i)
            logOk(('Plot #%d removed.'):format(id), 'plot')
            return true
        end
    end
    logWarn(('Plot #%d not found.'):format(id), 'plot')
    return false
end

local function updatePlots()
    local now = nowMs()
    if now - state.plotLastTickMs < state.plotIntervalMs then return end
    state.plotLastTickMs = now
    for _, p in ipairs(state.plots) do
        local ok, value, err = evalExpressionSilent(p.expr)
        if ok then
            local n = tonumber(value)
            if n then
                p.data[#p.data + 1] = n
                if #p.data > p.samples then
                    table.remove(p.data, 1)
                end
                p.lastValue = n
                p.lastUpdated = os.date('%H:%M:%S')
                p.hasError = false
                p.error = ''
            else
                p.hasError = true
                p.error = 'non-numeric value'
            end
        else
            p.hasError = true
            p.error = tostring(err)
        end
    end
end

local function addTrigger(conditionExpr, actionCode, cooldownMs, combatOnly)
    conditionExpr = stripQuotes(conditionExpr or '')
    actionCode = stripQuotes(actionCode or '')
    if conditionExpr == '' or actionCode == '' then
        logWarn('Trigger add failed: condition and action are required.')
        return
    end
    local row = {
        id = state.nextTriggerId,
        condition = conditionExpr,
        action = actionCode,
        cooldownMs = tonumber(cooldownMs) or DEFAULT_TRIGGER_COOLDOWN_MS,
        combatOnly = combatOnly == true,
        lastState = false,
        lastFireMs = 0,
        fireCount = 0,
        hasError = false,
        error = '',
        lastEvalMs = 0,
    }
    state.nextTriggerId = state.nextTriggerId + 1
    table.insert(state.triggers, row)
    logOk(('Trigger #%d added.'):format(row.id))
end

local function removeTrigger(id)
    for i, t in ipairs(state.triggers) do
        if t.id == id then
            table.remove(state.triggers, i)
            logOk(('Trigger #%d removed.'):format(id))
            return true
        end
    end
    logWarn(('Trigger #%d not found.'):format(id))
    return false
end

local function listTriggers()
    if #state.triggers == 0 then
        logInfo('No triggers configured.')
        return
    end
    for _, t in ipairs(state.triggers) do
        logInfo(('#%d if %s then %s [cooldown=%dms combatOnly=%s fired=%d]'):format(
            t.id, t.condition, t.action, t.cooldownMs, tostring(t.combatOnly), t.fireCount or 0))
    end
end

local function updateWatchesAndTriggers()
    local now = nowMs()

    if now - state.watchLastTickMs >= state.watchIntervalMs then
        state.watchLastTickMs = now
        for _, w in ipairs(state.watches) do
            local ok, value, err, evalMs = evalExpressionSilent(w.expr)
            w.evalMs = evalMs
            if ok then
                local newText = valueToWatchText(value)
                w.valueType = type(value)
                w.hasError = false
                w.error = ''
                w.changed = (w.valueText ~= '<pending>' and newText ~= w.valueText)
                if w.changed then
                    w.lastChangedMs = now
                    eventPublish('watch_changed', {
                        id = w.id,
                        label = w.label,
                        expr = w.expr,
                        value = w.lastValue,
                        valueText = newText,
                    })
                end
                w.lastValue = value
                w.valueText = newText
                w.lastUpdatedMs = now
                w.lastUpdatedText = os.date('%H:%M:%S')
            else
                w.hasError = true
                w.error = tostring(err)
                w.valueType = 'error'
                w.valueText = '<error>'
                w.changed = false
                w.lastUpdatedMs = now
                w.lastUpdatedText = os.date('%H:%M:%S')
            end
        end
    end

    if now - state.triggerLastTickMs >= state.triggerIntervalMs then
        state.triggerLastTickMs = now
        for _, t in ipairs(state.triggers) do
            local condOk, condValue, condErr, evalMs = evalExpressionSilent(t.condition)
            t.lastEvalMs = evalMs
            if not condOk then
                t.hasError = true
                t.error = tostring(condErr)
                t.lastState = false
            else
                t.hasError = false
                t.error = ''
                local condTrue = condValue and true or false
                local rising = condTrue and not t.lastState
                t.lastState = condTrue
                if rising then
                    local cooldownReady = (now - (t.lastFireMs or 0)) >= (t.cooldownMs or DEFAULT_TRIGGER_COOLDOWN_MS)
                    local combatReady = (not t.combatOnly) or isInCombat()
                    if cooldownReady and combatReady then
                        local actionOk, actionResult = executeTriggerAction(t.action)
                        if actionOk then
                            t.lastFireMs = now
                            t.fireCount = (t.fireCount or 0) + 1
                            state.showUI = true
                            state.status = 'Trigger fired #' .. tostring(t.id)
                            local resultText = actionResult and actionResult ~= '' and actionResult or '<ok>'
                            logWarn(('Trigger #%d fired: %s -> %s'):format(t.id, t.condition, resultText), 'combat')
                            eventPublish('trigger_fired', {
                                id = t.id,
                                condition = t.condition,
                                action = t.action,
                                result = resultText,
                            })
                        else
                            t.hasError = true
                            t.error = tostring(actionResult)
                            logErr(('Trigger #%d action error: %s'):format(t.id, t.error))
                        end
                    end
                end
            end
        end
    end
end

local function inspectExpression(expr)
    expr = stripQuotes(expr or '')
    if expr == '' then
        logWarn('Inspect failed: empty expression.')
        return
    end
    local ok, value, err = evalExpressionSilent(expr)
    if not ok then
        logErr(('Inspect failed for "%s": %s'):format(expr, tostring(err)))
        return
    end
    logInfo(('inspect(%s):'):format(expr))
    state.inspectTreeValue = value
    state.inspectTreeLabel = expr
    state.showInspectTree = true
    if type(value) == 'table' then
        logOk(inspectValue(value))
    else
        logOk(valueToWatchText(value))
    end
end

local function inspectMeSnapshot()
    local snap = {
        Name = mq.TLO.Me.CleanName() or 'Unknown',
        Class = mq.TLO.Me.Class.ShortName() or '?',
        Level = mq.TLO.Me.Level() or 0,
        PctHPs = mq.TLO.Me.PctHPs() or 0,
        PctMana = mq.TLO.Me.PctMana() or 0,
        PctEndurance = mq.TLO.Me.PctEndurance() or 0,
        Combat = mq.TLO.Me.Combat() == true,
        Zone = mq.TLO.Zone.ShortName() or 'Unknown',
    }
    logInfo('Inspect Me snapshot:')
    logOk(inspectValue(snap))
end

local function inspectTargetSnapshot()
    local target = mq.TLO.Target
    if not target() then
        logWarn('No target selected.')
        return
    end
    local snap = {
        Name = target.CleanName() or target.Name() or 'Unknown',
        ID = target.ID() or 0,
        Type = target.Type() or 'Unknown',
        PctHPs = target.PctHPs() or 0,
        Distance = target.Distance() or 0,
        Level = target.Level() or 0,
        Class = target.Class.ShortName() or '?',
    }
    logInfo('Inspect Target snapshot:')
    logOk(inspectValue(snap))
end

local function inspectGroupAverageSnapshot()
    local members = 0
    local hpSum = 0
    local manaSum = 0
    local endSum = 0
    for i = 1, 6 do
        local m = mq.TLO.Group.Member(i)
        if m() then
            members = members + 1
            hpSum = hpSum + (tonumber(m.PctHPs()) or 0)
            manaSum = manaSum + (tonumber(m.PctMana()) or 0)
            endSum = endSum + (tonumber(m.PctEndurance()) or 0)
        end
    end
    if members == 0 then
        logWarn('No group members available for average snapshot.')
        return
    end
    local snap = {
        Members = members,
        AvgPctHPs = hpSum / members,
        AvgPctMana = manaSum / members,
        AvgPctEndurance = endSum / members,
        GroupMainTank = mq.TLO.Group.MainTank.CleanName() or 'None',
        GroupAssist = mq.TLO.Group.MainAssist.CleanName() or 'None',
    }
    logInfo('Inspect Group Avg snapshot:')
    logOk(inspectValue(snap))
end

local saveSimpleListJson
local loadSimpleListJson
local saveWatchesPersistent
local loadWatchesPersistent
local saveSnippetsPersistent
local loadSnippetsPersistent
local ensureDefaultSnippets

local function addSnippet(name, code)
    name = trim(name or '')
    code = tostring(code or '')
    if name == '' or trim(code) == '' then
        logWarn('Snippet add failed: name/code required.')
        return false
    end
    for _, s in ipairs(state.snippets) do
        if s.name:lower() == name:lower() then
            s.code = code
            if saveSnippetsPersistent then saveSnippetsPersistent() end
            logOk(('Snippet updated: %s'):format(name))
            return true
        end
    end
    table.insert(state.snippets, { name = name, code = code })
    if saveSnippetsPersistent then saveSnippetsPersistent() end
    logOk(('Snippet added: %s'):format(name))
    return true
end

local function removeSnippet(index)
    if index < 1 or index > #state.snippets then
        logWarn('Snippet remove failed: invalid index.')
        return false
    end
    local name = state.snippets[index].name
    table.remove(state.snippets, index)
    if saveSnippetsPersistent then saveSnippetsPersistent() end
    logOk(('Snippet removed: %s'):format(name))
    return true
end

local function runSnippet(index)
    if index < 1 or index > #state.snippets then
        logWarn('Snippet run failed: invalid index.')
        return
    end
    local sn = state.snippets[index]
    submitChunkText(sn.code, 'snippet:' .. sn.name)
end

local function runSnippetByName(name)
    name = trim(name or ''):lower()
    if name == '' then return false end
    for i, s in ipairs(state.snippets) do
        if (s.name or ''):lower() == name then
            runSnippet(i)
            return true
        end
    end
    return false
end

local function executeTriggerAction(action)
    local a = trim(action or '')
    local lower = a:lower()
    if lower == 'open console' then
        state.showUI = true
        return true, '<opened console>'
    end

    local snippetName = a:match('^run%s+snippet%s*:%s*(.+)$') or a:match('^snippet%s*:%s*(.+)$')
    if snippetName then
        if runSnippetByName(snippetName) then
            return true, '<ran snippet:' .. trim(snippetName) .. '>'
        end
        return false, 'snippet not found: ' .. trim(snippetName)
    end

    local snippetIndex = tonumber(a:match('^run%s+snippet%s+(%d+)$') or '')
    if snippetIndex then
        if snippetIndex >= 1 and snippetIndex <= #state.snippets then
            runSnippet(snippetIndex)
            return true, '<ran snippet #' .. tostring(snippetIndex) .. '>'
        end
        return false, 'snippet index out of range: ' .. tostring(snippetIndex)
    end

    local ok, result = evalChunk(a)
    return ok, result
end

local function exportSnippets(path)
    path = path or SNIPPETS_FILE
    if saveSimpleListJson(path, state.snippets) then
        logOk(('Exported %d snippets -> %s'):format(#state.snippets, path))
    end
end

local function importSnippets(path)
    path = path or SNIPPETS_FILE
    local rows = loadSimpleListJson(path)
    if not rows then return end
    state.snippets = {}
    for _, s in ipairs(rows) do
        if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
            addSnippet(s.name, s.code)
        end
    end
    if saveSnippetsPersistent then saveSnippetsPersistent() end
    logOk(('Imported %d snippets from %s'):format(#state.snippets, path))
end

ensureDefaultSnippets = function()
    if #state.snippets > 0 then return end
    for _, s in ipairs(DEFAULT_SNIPPETS) do
        table.insert(state.snippets, { name = s.name, code = s.code })
    end
    saveSnippetsPersistent()
    logInfo(('Loaded %d default snippets.'):format(#DEFAULT_SNIPPETS))
end

local function runEventTest()
    local evt = trim(state.eventTypeInput)
    local argsLine = tostring(state.eventArgsInput or '')
    local handler = tostring(state.eventHandlerInput or '')
    if evt == '' or trim(handler) == '' then
        logWarn('Event test requires event type + handler code.')
        return
    end

    local args = {}
    for token in argsLine:gmatch('[^|]+') do
        args[#args + 1] = trim(token)
    end
    if #args == 0 and argsLine ~= '' then args[1] = argsLine end

    state.env.EVENT_TYPE = evt
    state.env.EVENT_ARGS = args
    state.env.EVENT_LINE = args[1] or ''
    submitChunkText(handler, 'event:' .. evt)
end

local function profileLastInput(times)
    times = tonumber(times) or 10
    times = math.max(1, math.min(500, math.floor(times)))
    local code = trim(state.inputBuffer or '')
    if code == '' and #state.history > 0 then
        code = state.history[#state.history]
    end
    if code == '' then
        logWarn('Profile failed: no input/history code to run.')
        return
    end

    local gcBefore = collectgarbage('count')
    local started = nowMs()
    local okCount = 0
    for _ = 1, times do
        local ok = evalChunk(code)
        if ok then okCount = okCount + 1 end
    end
    local total = nowMs() - started
    local gcAfter = collectgarbage('count')
    state.profileLastAvgMs = total / times
    state.profileLastGC = gcAfter - gcBefore
    logInfo(('/luaprofile %d -> avg %.2fms, total %dms, gc %+0.2fKB, ok %d/%d'):format(
        times, state.profileLastAvgMs, total, state.profileLastGC, okCount, times))
end

local function runBenchmark(code, iterations)
    code = tostring(code or '')
    iterations = tonumber(iterations) or 200
    iterations = math.max(1, math.min(10000, math.floor(iterations)))
    if trim(code) == '' then
        logWarn('Benchmark failed: empty code.')
        return nil
    end

    local memBefore = collectgarbage('count')
    local stats = { min = math.huge, max = 0, total = 0, values = {} }
    for i = 1, iterations do
        local ok, _, elapsed = evalChunk(code)
        local ms = tonumber(elapsed) or 0
        if not ok then
            logErr(('Benchmark aborted at iter %d due to runtime error.'):format(i))
            return nil
        end
        stats.values[#stats.values + 1] = ms
        stats.total = stats.total + ms
        if ms < stats.min then stats.min = ms end
        if ms > stats.max then stats.max = ms end
    end

    local avg = stats.total / iterations
    local variance = 0
    for _, ms in ipairs(stats.values) do
        local d = ms - avg
        variance = variance + (d * d)
    end
    variance = variance / iterations
    local stddev = math.sqrt(variance)
    local memAfter = collectgarbage('count')
    local result = {
        iterations = iterations,
        avg = avg,
        min = stats.min,
        max = stats.max,
        stddev = stddev,
        memDeltaKB = memAfter - memBefore,
    }
    state.bench.result = result
    logOk(('bench: n=%d avg=%.3fms min=%.3f max=%.3f std=%.3f memΔ=%.1fKB'):format(
        iterations, avg, stats.min, stats.max, stddev, result.memDeltaKB))
    return result
end

local function exportLog(path)
    path = trim(path or '')
    if path == '' then path = LOG_EXPORT_FILE end
    local lines = {}
    for _, row in ipairs(state.logs) do
        lines[#lines + 1] = ('[%s][%s] %s'):format(row.ts, row.level, row.text)
    end
    local ok, err = writeTextFile(path, table.concat(lines, '\n'))
    if not ok then
        logErr('Log export failed: ' .. tostring(err))
        return
    end
    logOk(('Log exported: %s (%d lines)'):format(path, #lines))
end

local function exportShareBundle(path)
    local resolved, pathErr = resolveManagedPath(path, SHARE_FILE)
    if not resolved then
        logErr('Share export failed: ' .. tostring(pathErr))
        return false
    end
    path = resolved
    local bundle = {
        meta = {
            script = SCRIPT_NAME,
            version = VERSION,
            exportedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        },
        watches = {},
        triggers = {},
        snippets = state.snippets,
        plots = {},
        ui = {
            theme = state.theme,
            layoutPreset = state.layoutPreset,
            topLogRatio = state.topLogRatio,
            currentTab = state.currentTab,
        },
    }
    for _, w in ipairs(state.watches) do
        bundle.watches[#bundle.watches + 1] = { expr = w.expr, label = w.label or w.expr }
    end
    for _, t in ipairs(state.triggers) do
        bundle.triggers[#bundle.triggers + 1] = {
            condition = t.condition,
            action = t.action,
            cooldownMs = t.cooldownMs,
            combatOnly = t.combatOnly == true,
        }
    end
    for _, p in ipairs(state.plots) do
        bundle.plots[#bundle.plots + 1] = {
            expr = p.expr,
            label = p.label,
            samples = p.samples,
        }
    end
    local ok, err = writeTextFile(path, json.encode(bundle))
    if not ok then
        logErr('Share export failed: ' .. tostring(err))
        return false
    end
    logOk(('Share bundle exported: %s'):format(path))
    return true
end

local function importShareBundle(path)
    local resolved, pathErr = resolveManagedPath(path, SHARE_FILE)
    if not resolved then
        logErr('Share import failed: ' .. tostring(pathErr))
        return false
    end
    path = resolved
    local text = readTextFile(path)
    if not text or text == '' then
        logErr('Share import failed: file missing or empty: ' .. path)
        return false
    end
    local ok, bundle = pcall(json.decode, text)
    if not ok or type(bundle) ~= 'table' then
        logErr('Share import failed: invalid JSON bundle.')
        return false
    end
    if type(bundle.watches) == 'table' then
        state.watches = {}
        state.nextWatchId = 1
        state._suspendWatchSave = true
        for _, w in ipairs(bundle.watches) do
            if type(w) == 'table' and type(w.expr) == 'string' then
                addWatch(w.expr, w.label or '')
            end
        end
        state._suspendWatchSave = false
        saveWatchesPersistent()
    end
    if type(bundle.triggers) == 'table' then
        state.triggers = {}
        state.nextTriggerId = 1
        for _, t in ipairs(bundle.triggers) do
            if type(t) == 'table' then
                addTrigger(t.condition or '', t.action or '', t.cooldownMs, t.combatOnly == true)
            end
        end
    end
    if type(bundle.snippets) == 'table' then
        state.snippets = {}
        for _, s in ipairs(bundle.snippets) do
            if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
                table.insert(state.snippets, { name = s.name, code = s.code })
            end
        end
        saveSnippetsPersistent()
    end
    if type(bundle.plots) == 'table' then
        state.plots = {}
        state.nextPlotId = 1
        for _, p in ipairs(bundle.plots) do
            if type(p) == 'table' and type(p.expr) == 'string' then
                addPlot(p.expr, p.label or '', p.samples)
            end
        end
    end
    if type(bundle.ui) == 'table' then
        if type(bundle.ui.theme) == 'string' then state.theme = bundle.ui.theme end
        if type(bundle.ui.layoutPreset) == 'string' then state.layoutPreset = bundle.ui.layoutPreset end
        if type(bundle.ui.topLogRatio) == 'number' then state.topLogRatio = bundle.ui.topLogRatio end
        if type(bundle.ui.currentTab) == 'string' then state.currentTab = bundle.ui.currentTab end
    end
    logOk(('Share bundle imported: %s'):format(path))
    return true
end

local function enqueuePluginMessage(level, text)
    local entry = {
        level = level or 'INFO',
        text = tostring(text or ''),
        ts = os.date('%H:%M:%S'),
    }
    table.insert(state.pluginMessages, entry)
    if #state.pluginMessages > state.pluginQueueLimit then
        table.remove(state.pluginMessages, 1)
    end
    pushLog(entry.level, '[plugin] ' .. entry.text, false)
end

_G.LuaConsolePost = function(level, text)
    enqueuePluginMessage(level, text)
end

local function macroVariableValue(name)
    name = trim(name or '')
    if name == '' then return nil end
    local ok, v = pcall(function()
        return mq.TLO.Macro.Variable(name)()
    end)
    if ok then return v end
    return nil
end

local function addMacroSync(varName, aliasName)
    varName = trim(varName or '')
    aliasName = trim(aliasName or '')
    if varName == '' then
        logWarn('Macro sync add failed: variable name required.')
        return
    end
    if aliasName == '' then aliasName = varName end
    local row = {
        id = state.nextMacroSyncId,
        varName = varName,
        alias = aliasName,
        lastValue = nil,
    }
    state.nextMacroSyncId = state.nextMacroSyncId + 1
    table.insert(state.macroSync, row)
    logOk(('Macro sync #%d added: %s -> env.%s'):format(row.id, varName, aliasName))
end

local function removeMacroSync(id)
    for i, row in ipairs(state.macroSync) do
        if row.id == id then
            table.remove(state.macroSync, i)
            logOk(('Macro sync #%d removed.'):format(id))
            return true
        end
    end
    logWarn(('Macro sync #%d not found.'):format(id))
    return false
end

local function updateMacroSync()
    local now = nowMs()
    if now - state.macroSyncLastTickMs < state.macroSyncIntervalMs then return end
    state.macroSyncLastTickMs = now
    for _, row in ipairs(state.macroSync) do
        local v = macroVariableValue(row.varName)
        row.lastValue = v
        state.env[row.alias] = v
    end
end

local CHAIN_HINTS = {
    ['Me'] = { 'PctHPs()', 'PctMana()', 'PctEndurance()', 'CombatState()', 'Combat()', 'Level()', 'Class.ShortName()', 'Buff(', 'X()', 'Y()', 'Z()' },
    ['Target'] = { 'CleanName()', 'ID()', 'Distance()', 'PctHPs()', 'Type()', 'Buff(', 'Debuff(' },
    ['Group'] = { 'Members()', 'MainTank.CleanName()', 'MainAssist.CleanName()', 'Member(' },
    ['Zone'] = { 'ShortName()', 'Name()', 'ID()' },
    ['Spawn'] = { 'ID()', 'Distance()', 'CleanName()', 'Type()', 'Level()' },
    ['mq'] = { 'cmd(', 'cmdf(', 'delay(', 'TLO.' },
    ['mq.TLO'] = { 'Me', 'Target', 'Group', 'Spawn', 'Zone', 'Window', 'Navigation', 'CursorAttachment' },
}

local function envAutocompleteCandidates(prefix, baseExpr)
    local out = {}
    local seen = {}
    local function add(c)
        if c and c ~= '' and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end

    local common = {
        'mq.', 'mq.TLO.', 'Me.', 'Target.', 'Group.', 'Spawn(', 'Zone.',
        'cmd(', 'cmdf(', 'delay(', 'inspect(', 'print(',
    }
    for _, c in ipairs(common) do
        add(c)
    end
    if baseExpr and CHAIN_HINTS[baseExpr] then
        for _, item in ipairs(CHAIN_HINTS[baseExpr]) do
            add(item)
        end
    else
        for k in pairs(state.env or {}) do
            add(k)
            add(k .. '.')
        end
        -- Include chain hints at top-level too.
        for base, _ in pairs(CHAIN_HINTS) do
            add(base .. '.')
        end
    end
    table.sort(out)
    if prefix == '' then return out end

    local filtered = {}
    local p = prefix:lower()
    for _, c in ipairs(out) do
        if c:lower():find('^' .. p) then
            filtered[#filtered + 1] = c
        end
    end
    return filtered
end

local function autocompleteToken()
    if not state.autocomplete.enabled then return end
    local s = state.inputBuffer or ''
    local token = s:match('([%w_%.:]+)$') or ''
    local baseExpr, prefix = token:match('^(.-)[%.:]([%w_]*)$')
    if not prefix then
        prefix = token
        baseExpr = nil
    end
    if prefix == '' then return end

    local cacheKey = (baseExpr or '') .. '|' .. prefix
    if state.autocomplete.lastPrefix ~= cacheKey then
        state.autocomplete.candidates = envAutocompleteCandidates(prefix, baseExpr)
        state.autocomplete.index = 1
        state.autocomplete.lastPrefix = cacheKey
    end

    local cands = state.autocomplete.candidates
    if #cands == 0 then
        logWarn('autocomplete: no matches for ' .. prefix)
        state.autocomplete.showPopup = false
        return
    end
    local pick = cands[state.autocomplete.index] or cands[1]
    state.autocomplete.index = (state.autocomplete.index % #cands) + 1
    local removeLen = #prefix
    state.inputBuffer = s:sub(1, #s - removeLen) .. pick
    state.autocomplete.showPopup = true
    logInfo(('autocomplete: %s'):format(pick))
end

local function refreshAutocompleteCandidates()
    if not state.autocomplete.enabled then
        state.autocomplete.showPopup = false
        return
    end
    local s = state.inputBuffer or ''
    local token = s:match('([%w_%.:]+)$') or ''
    local baseExpr, prefix = token:match('^(.-)[%.:]([%w_]*)$')
    if not prefix then
        prefix = token
        baseExpr = nil
    end
    if prefix == '' then
        state.autocomplete.lastPrefix = ''
        state.autocomplete.candidates = {}
        state.autocomplete.showPopup = false
        return
    end
    state.autocomplete.lastPrefix = (baseExpr or '') .. '|' .. prefix
    state.autocomplete.candidates = envAutocompleteCandidates(prefix, baseExpr)
    state.autocomplete.index = 1
    state.autocomplete.showPopup = #state.autocomplete.candidates > 0
end

-- =========================================================
-- Settings (UI persistence)
-- =========================================================

saveSettings = function()
    local watchSave = {}
    for _, w in ipairs(state.watches) do
        watchSave[#watchSave + 1] = { id = w.id, expr = w.expr, label = w.label or w.expr }
    end
    local triggerSave = {}
    for _, t in ipairs(state.triggers) do
        triggerSave[#triggerSave + 1] = {
            id = t.id,
            condition = t.condition,
            action = t.action,
            cooldownMs = t.cooldownMs,
            combatOnly = t.combatOnly == true,
        }
    end
    local snippetSave = {}
    for _, s in ipairs(state.snippets) do
        snippetSave[#snippetSave + 1] = { name = s.name, code = s.code }
    end
    local macroSyncSave = {}
    for _, m in ipairs(state.macroSync) do
        macroSyncSave[#macroSyncSave + 1] = {
            id = m.id,
            varName = m.varName,
            alias = m.alias,
        }
    end

    local data = {
        showUI = state.showUI,
        debug = state.debug,
        autoscroll = state.autoscroll,
        showTimestamps = state.showTimestamps,
        chatModeEnabled = state.chatModeEnabled,
        chatEvalToken = state.chatEvalToken,
        inputBuffer = state.inputBuffer,
        history = state.history,
        watches = watchSave,
        triggers = triggerSave,
        watchIntervalMs = state.watchIntervalMs,
        triggerIntervalMs = state.triggerIntervalMs,
        nextWatchId = state.nextWatchId,
        nextTriggerId = state.nextTriggerId,
        snippets = snippetSave,
        plots = (function()
            local out = {}
            for _, p in ipairs(state.plots) do
                out[#out + 1] = { id = p.id, expr = p.expr, label = p.label, samples = p.samples }
            end
            return out
        end)(),
        nextPlotId = state.nextPlotId,
        plotIntervalMs = state.plotIntervalMs,
        selectedSnippet = state.selectedSnippet,
        theme = state.theme,
        themeIndex = state.themeIndex,
        layoutPreset = state.layoutPreset,
        topLogRatio = state.topLogRatio,
        logFilter = state.logFilter,
        logSearch = state.logSearch,
        windowState = state.windowState,
        openSections = state.openSections,
        currentTab = state.currentTab,
        autocompleteEnabled = state.autocomplete.enabled,
        macroSync = macroSyncSave,
        nextMacroSyncId = state.nextMacroSyncId,
        slowEvalWarnMs = state.slowEvalWarnMs,
        autoSaveEnabled = state.autoSave.enabled,
        autoSaveIntervalMs = state.autoSave.intervalMs,
        usePerCharacterFiles = state.usePerCharacterFiles,
        allowUnsafeMqEnv = state.allowUnsafeMqEnv,
        remoteEvalEnabled = state.remoteEval.enabled,
        remoteEvalIntervalMs = state.remoteEval.intervalMs,
    }
    mq.pickle(SETTINGS_FILE, data)
end

loadSettings = function()
    local fn = loadfile(SETTINGS_FILE)
    if not fn then return end

    local ok, data = pcall(fn)
    if not ok or type(data) ~= 'table' then return end

    -- Keep the console visible on startup even if an older settings file saved it hidden.
    state.showUI = true
    state.debug = data.debug == true
    state.autoscroll = data.autoscroll ~= false
    state.showTimestamps = data.showTimestamps ~= false
    state.chatModeEnabled = data.chatModeEnabled == true
    state.chatEvalToken = trim(data.chatEvalToken or '!') ~= '' and trim(data.chatEvalToken or '!') or '!'
    state.inputBuffer = data.inputBuffer or ''
    state.history = type(data.history) == 'table' and data.history or {}
    if #state.history > MAX_HISTORY then
        while #state.history > MAX_HISTORY do
            table.remove(state.history, 1)
        end
    end
    state.historyIndex = #state.history + 1

    state.watchIntervalMs = tonumber(data.watchIntervalMs) or DEFAULT_WATCH_INTERVAL_MS
    state.triggerIntervalMs = tonumber(data.triggerIntervalMs) or DEFAULT_TRIGGER_INTERVAL_MS
    state.nextWatchId = tonumber(data.nextWatchId) or 1
    state.nextTriggerId = tonumber(data.nextTriggerId) or 1

    state.watches = {}
    if type(data.watches) == 'table' then
        for _, w in ipairs(data.watches) do
            if type(w) == 'table' and type(w.expr) == 'string' and trim(w.expr) ~= '' then
                table.insert(state.watches, {
                    id = tonumber(w.id) or state.nextWatchId,
                    label = type(w.label) == 'string' and trim(w.label) ~= '' and trim(w.label) or trim(w.expr),
                    expr = trim(w.expr),
                    valueText = '<pending>',
                    lastValue = nil,
                    valueType = 'nil',
                    changed = false,
                    hasError = false,
                    error = '',
                    evalMs = 0,
                    lastChangedMs = 0,
                    lastUpdatedMs = 0,
                    lastUpdatedText = '-',
                })
            end
        end
    end

    state.triggers = {}
    if type(data.triggers) == 'table' then
        for _, t in ipairs(data.triggers) do
            if type(t) == 'table' and type(t.condition) == 'string' and type(t.action) == 'string' then
                table.insert(state.triggers, {
                    id = tonumber(t.id) or state.nextTriggerId,
                    condition = trim(t.condition),
                    action = trim(t.action),
                    cooldownMs = tonumber(t.cooldownMs) or DEFAULT_TRIGGER_COOLDOWN_MS,
                    combatOnly = t.combatOnly == true,
                    lastState = false,
                    lastFireMs = 0,
                    fireCount = 0,
                    hasError = false,
                    error = '',
                    lastEvalMs = 0,
                })
            end
        end
    end

    for _, w in ipairs(state.watches) do
        if w.id >= state.nextWatchId then state.nextWatchId = w.id + 1 end
    end
    for _, t in ipairs(state.triggers) do
        if t.id >= state.nextTriggerId then state.nextTriggerId = t.id + 1 end
    end

    state.snippets = {}
    if type(data.snippets) == 'table' then
        for _, s in ipairs(data.snippets) do
            if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
                s = migrateSnippetRow(s)
                table.insert(state.snippets, { name = s.name, code = s.code })
            end
        end
    end
    state.selectedSnippet = tonumber(data.selectedSnippet) or 0

    state.plots = {}
    state.nextPlotId = tonumber(data.nextPlotId) or 1
    state.plotIntervalMs = tonumber(data.plotIntervalMs) or state.plotIntervalMs
    if type(data.plots) == 'table' then
        for _, p in ipairs(data.plots) do
            if type(p) == 'table' and type(p.expr) == 'string' then
                table.insert(state.plots, {
                    id = tonumber(p.id) or state.nextPlotId,
                    expr = p.expr,
                    label = type(p.label) == 'string' and p.label or p.expr,
                    samples = tonumber(p.samples) or 120,
                    data = {},
                    hasError = false,
                    error = '',
                    lastValue = nil,
                    lastUpdated = '-',
                })
            end
        end
    end
    for _, p in ipairs(state.plots) do
        if p.id >= state.nextPlotId then state.nextPlotId = p.id + 1 end
    end

    state.theme = type(data.theme) == 'string' and data.theme or state.theme
    local _, idx = findThemeByKey(state.theme)
    state.themeIndex = idx
    state.layoutPreset = type(data.layoutPreset) == 'string' and data.layoutPreset or 'default'
    state.topLogRatio = tonumber(data.topLogRatio) or state.topLogRatio
    if type(data.logFilter) == 'string' then state.logFilter = data.logFilter end
    if type(data.logSearch) == 'string' then state.logSearch = data.logSearch end
    if type(data.windowState) == 'table' then
        state.windowState = sanitizeWindowState(data.windowState) or state.windowState
    end
    if type(data.openSections) == 'table' then
        state.openSections = data.openSections
    end
    state.currentTab = type(data.currentTab) == 'string' and data.currentTab or 'Console'
    state.autocomplete.enabled = data.autocompleteEnabled ~= false
    state.slowEvalWarnMs = tonumber(data.slowEvalWarnMs) or state.slowEvalWarnMs
    state.autoSave.enabled = data.autoSaveEnabled ~= false
    state.autoSave.intervalMs = tonumber(data.autoSaveIntervalMs) or state.autoSave.intervalMs
    if data.usePerCharacterFiles ~= nil then
        state.usePerCharacterFiles = data.usePerCharacterFiles == true
    end
    if data.allowUnsafeMqEnv ~= nil then
        state.allowUnsafeMqEnv = data.allowUnsafeMqEnv == true
    end
    if data.remoteEvalEnabled ~= nil then
        state.remoteEval.enabled = data.remoteEvalEnabled == true
    end
    state.remoteEval.intervalMs = tonumber(data.remoteEvalIntervalMs) or state.remoteEval.intervalMs

    state.macroSync = {}
    state.nextMacroSyncId = tonumber(data.nextMacroSyncId) or 1
    if type(data.macroSync) == 'table' then
        for _, m in ipairs(data.macroSync) do
            if type(m) == 'table' and type(m.varName) == 'string' then
                table.insert(state.macroSync, {
                    id = tonumber(m.id) or state.nextMacroSyncId,
                    varName = m.varName,
                    alias = type(m.alias) == 'string' and m.alias or m.varName,
                    lastValue = nil,
                })
            end
        end
    end
    for _, m in ipairs(state.macroSync) do
        if m.id >= state.nextMacroSyncId then state.nextMacroSyncId = m.id + 1 end
    end
end

-- =========================================================
-- Command handling
-- =========================================================

local function printHelp()
    logInfo('LuaConsole commands:')
    logInfo('/luaconsole - toggle ImGui window')
    logInfo('/luaeval <code> - evaluate chunk (supports multiline continuation)')
    logInfo('/lceval <code> - alias for /luaeval')
    logInfo('/luachat on|off|token <prefix> - control chat-eval fallback')
    logInfo('/luamqenv on|off - expose/remove mq/cmd/cmdf in eval env')
    logInfo('/luaprev, /luanext - browse command history')
    logInfo('/luadebug on|off - toggle internal debug mode')
    logInfo('/luats on|off - toggle timestamps in UI/chat output')
    logInfo('/luasave [path], /luaload [path] - save/load session JSON')
    logInfo('/luaclear - clear output log')
    logInfo('/luawatch add "<expr>" "<label>" | del|clear|list|export|import')
    logInfo('/luatrigger add|del|clear|list|export|import')
    logInfo('/luaplot add|del|clear|list')
    logInfo('/luainspect <expr> | /luainspect me|target|cursor|groupavg')
    logInfo('/luasnippet add|run|del|list|clear|export|import')
    logInfo('/luabench run|last')
    logInfo('/luashare export|import')
    logInfo('/luamode combat|merc|nav|repl|monitor')
    logInfo('/luaeventtest - execute event tester handler now')
    logInfo('/luaprofile [n] - run current/last input n times')
    logInfo('/luavar sync|unsync|list|set')
    logInfo('/luaexportlog [path] - export log to txt')
    logInfo('Chat fallback: type "lua> <code>" in chat to evaluate.')
end

saveSimpleListJson = function(path, rows)
    local payload = json.encode(rows or {})
    local ok, err = pcall(function()
        local f = assert(io.open(path, 'wb'))
        f:write(payload)
        f:close()
    end)
    if not ok then
        logErr('Save failed: ' .. tostring(err))
        return false
    end
    return true
end

loadSimpleListJson = function(path)
    local ok, textOrErr = pcall(function()
        local f = assert(io.open(path, 'rb'))
        local text = f:read('*a')
        f:close()
        return text
    end)
    if not ok then
        logErr('Load failed: ' .. tostring(textOrErr))
        return nil
    end
    local okDecode, decoded = pcall(json.decode, textOrErr)
    if not okDecode or type(decoded) ~= 'table' then
        logErr('Load failed: invalid JSON in ' .. path)
        return nil
    end
    return decoded
end

saveWatchesPersistent = function()
    local rows = {}
    for _, w in ipairs(state.watches) do
        rows[#rows + 1] = {
            id = w.id,
            expr = w.expr,
            label = w.label or w.expr,
        }
    end
    if not saveSimpleListJson(WATCHES_FILE, rows) then
        return false
    end
    return true
end

loadWatchesPersistent = function()
    local text = readTextFile(WATCHES_FILE)
    if not text or trim(text) == '' then return false end
    local okDecode, rows = pcall(json.decode, text)
    if not okDecode or type(rows) ~= 'table' then
        logWarn('Failed to parse watch file: ' .. WATCHES_FILE)
        return false
    end
    state._suspendWatchSave = true
    state.watches = {}
    state.nextWatchId = 1
    for _, w in ipairs(rows) do
        if type(w) == 'table' and type(w.expr) == 'string' and trim(w.expr) ~= '' then
            addWatch(w.expr, w.label or '')
        end
    end
    state._suspendWatchSave = false
    return true
end

saveSnippetsPersistent = function()
    return saveSimpleListJson(SNIPPETS_FILE, state.snippets)
end

loadSnippetsPersistent = function()
    local text = readTextFile(SNIPPETS_FILE)
    if not text or trim(text) == '' then return false end
    local okDecode, rows = pcall(json.decode, text)
    if not okDecode or type(rows) ~= 'table' then
        logWarn('Failed to parse snippet file: ' .. SNIPPETS_FILE)
        return false
    end
    state.snippets = {}
    for _, s in ipairs(rows) do
        if type(s) == 'table' and type(s.name) == 'string' and type(s.code) == 'string' then
            s = migrateSnippetRow(s)
            table.insert(state.snippets, { name = s.name, code = s.code })
        end
    end
    return true
end

local function handleWatchCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''
    if cmd == '' or cmd == 'help' then
        logInfo('/luawatch add "<expr>" "<label>"')
        logInfo('/luawatch add <expr>')
        logInfo('/luawatch del <id>')
        logInfo('/luawatch list')
        logInfo('/luawatch clear')
        logInfo('/luawatch export [path]')
        logInfo('/luawatch import [path]')
        return
    end

    if cmd == 'add' then
        local quoted = parseQuotedStrings(args)
        if #quoted >= 2 then
            addWatch(quoted[1], quoted[2])
        elseif #quoted == 1 then
            addWatch(quoted[1], '')
        else
            local expr, label = args:match('^(.-)%s*;;%s*(.+)$')
            if expr and label then
                addWatch(expr, label)
            else
                addWatch(args, '')
            end
        end
    elseif cmd == 'del' or cmd == 'remove' then
        removeWatch(tonumber(trim(args) or '') or -1)
    elseif cmd == 'list' then
        listWatches()
    elseif cmd == 'clear' then
        state.watches = {}
        saveWatchesPersistent()
        logOk('All watches cleared.')
    elseif cmd == 'export' then
        local path = trim(args)
        if path == '' then path = WATCHES_FILE end
        local rows = {}
        for _, w in ipairs(state.watches) do
            rows[#rows + 1] = { id = w.id, expr = w.expr, label = w.label or w.expr }
        end
        if saveSimpleListJson(path, rows) then
            logOk(('Exported %d watches -> %s'):format(#rows, path))
        end
    elseif cmd == 'import' then
        local path = trim(args)
        if path == '' then path = WATCHES_FILE end
        local rows = loadSimpleListJson(path)
        if not rows then return end
        state.watches = {}
        state.nextWatchId = 1
        for _, w in ipairs(rows) do
            if type(w) == 'table' and type(w.expr) == 'string' then
                addWatch(w.expr, w.label or '')
            end
        end
        saveWatchesPersistent()
        logOk(('Imported %d watches from %s'):format(#state.watches, path))
    else
        logWarn('Unknown /luawatch subcommand: ' .. cmd)
    end
end

local function handleTriggerCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''

    if cmd == '' or cmd == 'help' then
        logInfo('/luatrigger add "<condition>" "<action>"')
        logInfo('/luatrigger add <condition> ;; <action>')
        logInfo('/luatrigger addc <cooldownSec> <condition> ;; <action>')
        logInfo('/luatrigger addcombat <condition> ;; <action>')
        logInfo('Actions can be code, "open console", "run snippet:Name", or "run snippet 2"')
        logInfo('/luatrigger del <id> | list | clear | export [path] | import [path]')
        return
    end

    local function parseCondAction(payload)
        local cond, action = payload:match('^(.-)%s*;;%s*(.+)$')
        return trim(cond or ''), trim(action or '')
    end

    if cmd == 'add' or cmd == 'addcombat' then
        local cond, action
        local quoted = parseQuotedStrings(args)
        if #quoted >= 2 then
            cond, action = quoted[1], quoted[2]
        else
            cond, action = parseCondAction(args)
        end
        addTrigger(cond, action, DEFAULT_TRIGGER_COOLDOWN_MS, cmd == 'addcombat')
    elseif cmd == 'addc' then
        local cooldownText, payload = args:match('^(%S+)%s+(.+)$')
        local cooldownMs = (tonumber(cooldownText) or 3) * 1000
        local cond, action = parseCondAction(payload or '')
        addTrigger(cond, action, cooldownMs, false)
    elseif cmd == 'del' or cmd == 'remove' then
        removeTrigger(tonumber(trim(args) or '') or -1)
    elseif cmd == 'list' then
        listTriggers()
    elseif cmd == 'clear' then
        state.triggers = {}
        logOk('All triggers cleared.')
    elseif cmd == 'export' then
        local path = trim(args)
        if path == '' then path = TRIGGERS_FILE end
        local rows = {}
        for _, t in ipairs(state.triggers) do
            rows[#rows + 1] = {
                id = t.id,
                condition = t.condition,
                action = t.action,
                cooldownMs = t.cooldownMs,
                combatOnly = t.combatOnly == true,
            }
        end
        if saveSimpleListJson(path, rows) then
            logOk(('Exported %d triggers -> %s'):format(#rows, path))
        end
    elseif cmd == 'import' then
        local path = trim(args)
        if path == '' then path = TRIGGERS_FILE end
        local rows = loadSimpleListJson(path)
        if not rows then return end
        state.triggers = {}
        state.nextTriggerId = 1
        for _, t in ipairs(rows) do
            if type(t) == 'table' then
                addTrigger(t.condition or '', t.action or '', t.cooldownMs, t.combatOnly == true)
            end
        end
        logOk(('Imported %d triggers from %s'):format(#state.triggers, path))
    else
        logWarn('Unknown /luatrigger subcommand: ' .. cmd)
    end
end

local function handlePlotCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''
    if cmd == '' or cmd == 'help' then
        logInfo('/luaplot add "<expr>" ["<label>"] [samples]')
        logInfo('/luaplot del <id> | list | clear')
        return
    end
    if cmd == 'add' then
        local quoted = parseQuotedStrings(args)
        local expr = quoted[1] or ''
        local label = quoted[2] or ''
        local samples = tonumber(args:match('(%d+)%s*$') or '') or 120
        if expr == '' then
            expr = trim(args)
        end
        addPlot(expr, label, samples)
    elseif cmd == 'del' or cmd == 'remove' then
        removePlot(tonumber(trim(args) or '') or -1)
    elseif cmd == 'clear' then
        state.plots = {}
        logOk('All plots cleared.', 'plot')
    elseif cmd == 'list' then
        if #state.plots == 0 then
            logInfo('No plots configured.', 'plot')
        else
            for _, p in ipairs(state.plots) do
                logInfo(('#%d [%s] %s samples=%d'):format(p.id, p.label, p.expr, p.samples), 'plot')
            end
        end
    else
        logWarn('Unknown /luaplot subcommand: ' .. cmd)
    end
end

local function handleInspectCommand(line)
    local expr = trim(line or '')
    if expr == '' then
        logInfo('/luainspect me|target|<expression>')
        return
    end
    local lower = expr:lower()
    if lower == 'me' then
        inspectMeSnapshot()
    elseif lower == 'target' then
        inspectTargetSnapshot()
    elseif lower == 'cursor' then
        inspectExpression('mq.TLO.CursorAttachment()')
    elseif lower == 'groupavg' or lower == 'group avg' then
        inspectGroupAverageSnapshot()
    else
        inspectExpression(expr)
    end
end

local function handleSnippetCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''
    if cmd == '' or cmd == 'help' then
        logInfo('/luasnippet add <name> ;; <code>')
        logInfo('/luasnippet run <index>')
        logInfo('/luasnippet del <index>')
        logInfo('/luasnippet list | clear | export [path] | import [path]')
        return
    end
    if cmd == 'add' then
        local name, code = args:match('^(.-)%s*;;%s*(.+)$')
        addSnippet(name or '', code or '')
    elseif cmd == 'run' then
        runSnippet(tonumber(args) or -1)
    elseif cmd == 'del' or cmd == 'remove' then
        removeSnippet(tonumber(args) or -1)
    elseif cmd == 'list' then
        if #state.snippets == 0 then
            logInfo('No snippets configured.')
        else
            for i, s in ipairs(state.snippets) do
                logInfo(('#%d %s'):format(i, s.name))
            end
        end
    elseif cmd == 'clear' then
        state.snippets = {}
        saveSnippetsPersistent()
        logOk('All snippets cleared.')
    elseif cmd == 'export' then
        local path = trim(args)
        if path == '' then path = SNIPPETS_FILE end
        exportSnippets(path)
    elseif cmd == 'import' then
        local path = trim(args)
        if path == '' then path = SNIPPETS_FILE end
        importSnippets(path)
    else
        logWarn('Unknown /luasnippet subcommand: ' .. cmd)
    end
end

local function handleBenchCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''
    if cmd == '' or cmd == 'help' then
        logInfo('/luabench run "<code>" [iterations]')
        logInfo('/luabench last [iterations]')
        return
    end
    if cmd == 'run' then
        local quoted = parseQuotedStrings(args)
        local code = quoted[1] or args
        local iterations = tonumber(args:match('(%d+)%s*$') or '') or state.bench.iterations
        state.bench.code = code
        state.bench.iterations = iterations
        runBenchmark(code, iterations)
    elseif cmd == 'last' then
        local code = trim(state.inputBuffer or '')
        if code == '' and #state.history > 0 then
            code = state.history[#state.history]
        end
        local iterations = tonumber(args) or state.bench.iterations
        state.bench.code = code
        state.bench.iterations = iterations
        runBenchmark(code, iterations)
    else
        logWarn('Unknown /luabench subcommand: ' .. cmd)
    end
end

local function handleShareCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = trim(args or '')
    if cmd == '' or cmd == 'help' then
        logInfo('/luashare export [path]')
        logInfo('/luashare import [path]')
        return
    end
    if cmd == 'export' then
        exportShareBundle(args ~= '' and args or SHARE_FILE)
    elseif cmd == 'import' then
        importShareBundle(args ~= '' and args or SHARE_FILE)
    else
        logWarn('Unknown /luashare subcommand: ' .. cmd)
    end
end

local function handleModeCommand(line)
    local mode = trim((line or ''):lower())
    if mode == '' then
        logInfo('/luamode combat|merc|nav|repl|monitor')
        return
    end
    if mode == 'combat' then
        state.layoutPreset = 'combat'
        state.currentTab = 'Watches'
        state.topLogRatio = 0.50
    elseif mode == 'merc' then
        state.layoutPreset = 'merc'
        state.currentTab = 'Systems'
        state.topLogRatio = 0.45
    elseif mode == 'nav' then
        state.layoutPreset = 'nav'
        state.currentTab = 'Systems'
        state.topLogRatio = 0.45
        state.navDebug.enabled = true
    elseif mode == 'repl' then
        state.layoutPreset = 'repl'
        state.currentTab = 'Console'
        state.topLogRatio = 0.68
    elseif mode == 'monitor' then
        state.layoutPreset = 'monitor'
        state.currentTab = 'Logs'
        state.topLogRatio = 0.40
    else
        logWarn('Unknown mode: ' .. mode)
        return
    end
    logOk('Mode switched: ' .. mode)
end

local function handleVarBridgeCommand(line)
    local rest = trim(line or '')
    local cmd, args = rest:match('^(%S+)%s*(.-)$')
    cmd = (cmd or ''):lower()
    args = args or ''
    if cmd == '' or cmd == 'help' then
        logInfo('/luavar sync <MacroVarName> [alias]')
        logInfo('/luavar unsync <id>')
        logInfo('/luavar list')
        logInfo('/luavar set <MacroVarName> <value>')
        return
    end
    if cmd == 'sync' then
        local n, a = args:match('^(%S+)%s*(.-)$')
        addMacroSync(n or '', a or '')
    elseif cmd == 'unsync' or cmd == 'del' then
        removeMacroSync(tonumber(args) or -1)
    elseif cmd == 'list' then
        if #state.macroSync == 0 then
            logInfo('No macro sync bindings.')
        else
            for _, m in ipairs(state.macroSync) do
                logInfo(('#%d %s -> env.%s (last=%s)'):format(m.id, m.varName, m.alias, safeToString(m.lastValue)))
            end
        end
    elseif cmd == 'set' then
        local varName, value = args:match('^(%S+)%s+(.+)$')
        if not varName or not value then
            logWarn('Usage: /luavar set <MacroVarName> <value>')
            return
        end
        mq.cmdf('/varset %s %s', varName, value)
        logOk(('Macro variable set requested: %s=%s'):format(varName, value))
    else
        logWarn('Unknown /luavar subcommand: ' .. cmd)
    end
end

local function handleLuaCommand(line)
    line = trim(line or '')
    if line == '' then
        printHelp()
        return
    end

    submitChunkText(line, 'lua')
end

local function onPrev()
    local line = historyPrev()
    if line ~= nil then
        state.inputBuffer = line
    end
end

local function onNext()
    local line = historyNext()
    if line ~= nil then
        state.inputBuffer = line
    end
end

local function handleDebug(arg)
    arg = trim((arg or ''):lower())
    if arg == 'on' then
        state.debug = true
        logOk('Debug mode enabled.')
    elseif arg == 'off' then
        state.debug = false
        logOk('Debug mode disabled.')
    else
        logInfo(('Debug mode is %s. Use /luadebug on|off'):format(state.debug and 'ON' or 'OFF'))
    end
end

local function handleTimestamps(arg)
    arg = trim((arg or ''):lower())
    if arg == 'on' then
        state.showTimestamps = true
        logOk('Timestamps enabled.')
    elseif arg == 'off' then
        state.showTimestamps = false
        logOk('Timestamps disabled.')
    else
        logInfo(('Timestamps are %s. Use /luats on|off'):format(state.showTimestamps and 'ON' or 'OFF'))
    end
end

local function handleChatMode(arg)
    local raw = trim(arg or '')
    local lower = raw:lower()
    if lower == 'on' then
        state.chatModeEnabled = true
        logOk(('Chat eval enabled. Use "lua> %s<code>" to execute.'):format(state.chatEvalToken))
    elseif lower == 'off' then
        state.chatModeEnabled = false
        logOk('Chat eval disabled.')
    elseif raw:match('^token%s+') then
        local token = trim(raw:sub(7))
        if token == '' then
            logWarn('Usage: /luachat token <prefix>')
        else
            state.chatEvalToken = token
            logOk(('Chat eval token set to: %s'):format(state.chatEvalToken))
        end
    else
        logInfo(('Chat eval is %s. Use /luachat on|off|token <prefix>. Current token: %s'):format(
            state.chatModeEnabled and 'ON' or 'OFF', state.chatEvalToken))
    end
end

local function handleUnsafeMqEnv(arg)
    arg = trim((arg or ''):lower())
    if arg == 'on' then
        state.allowUnsafeMqEnv = true
        state.env = makeEnv()
        logWarn('Unsafe MQ env enabled: mq/cmd/cmdf exposed to console code.')
    elseif arg == 'off' then
        state.allowUnsafeMqEnv = false
        state.env = makeEnv()
        logOk('Unsafe MQ env disabled: mq/cmd/cmdf removed from console code.')
    else
        logInfo(('Unsafe MQ env is %s. Use /luamqenv on|off'):format(state.allowUnsafeMqEnv and 'ON' or 'OFF'))
    end
end

local function handleChatFallbackLine(text)
    text = trim(text or '')
    if text == '' then return end
    local token = tostring(state.chatEvalToken or '!')
    if token == '' then token = '!' end
    if not startsWith(text, token) then
        logWarn(('Ignored chat-eval without token. Use "lua> %s<code>"'):format(token))
        return
    end
    local code = trim(text:sub(#token + 1))
    if code == '' then
        logWarn('Ignored chat-eval: empty code after token.')
        return
    end
    submitChunkText(code, 'chat')
end

-- =========================================================
-- ImGui UI
-- =========================================================

local function drawLogWindow(height)
    local filterOptions = { 'Show All', 'Errors Only', 'Watches', 'My Prints', 'Combat-related' }
    if ImGui.BeginCombo('Filter##LogFilter', state.logFilter) then
        for _, opt in ipairs(filterOptions) do
            local selected = state.logFilter == opt
            if ImGui.Selectable(opt, selected) then
                state.logFilter = opt
            end
            if selected then ImGui.SetItemDefaultFocus() end
        end
        ImGui.EndCombo()
    end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(320)
    local searchText, searchChanged = ImGui.InputText('Search##LogSearch', state.logSearch, 256)
    if searchChanged then state.logSearch = searchText end

    local function isCombatRow(row)
        local t = (row.text or ''):lower()
        if row.tag == 'combat' then return true end
        return t:find('combat', 1, true) ~= nil
            or t:find('aggro', 1, true) ~= nil
            or t:find('engage', 1, true) ~= nil
            or t:find('burn', 1, true) ~= nil
            or t:find('disc', 1, true) ~= nil
            or t:find('assist', 1, true) ~= nil
    end

    local function isWatchRow(row)
        if row.tag == 'watch' then return true end
        local t = (row.text or ''):lower()
        return t:find('watch', 1, true) ~= nil
    end

    local function passesFilter(row)
        if state.logFilter == 'Errors Only' then
            return row.level == 'ERR'
        elseif state.logFilter == 'Watches' then
            return isWatchRow(row)
        elseif state.logFilter == 'My Prints' then
            return row.tag == 'print'
        elseif state.logFilter == 'Combat-related' then
            return isCombatRow(row)
        end
        return true
    end

    local function passesSearch(row)
        local q = trim(state.logSearch or ''):lower()
        if q == '' then return true end
        return (row.text or ''):lower():find(q, 1, true) ~= nil
    end

    if ImGui.BeginChild('##LuaConsoleOutput', -1, height, true) then
        for _, row in ipairs(state.logs) do
            if passesFilter(row) and passesSearch(row) then
                local color = UI_COLOR[row.level] or UI_COLOR.INFO
                local text = state.showTimestamps and ('[%s] %s'):format(row.ts, row.text) or row.text
                ImGui.TextColored(color[1], color[2], color[3], color[4], text)
            end
        end

        if state.autoscroll then
            ImGui.SetScrollHereY(1.0)
        end
    end
    ImGui.EndChild()
end

local function watchTextMatches(text, patterns)
    text = (text or ''):lower()
    for _, p in ipairs(patterns) do
        if text:find(p, 1, true) then
            return true
        end
    end
    return false
end

local function watchValueColor(w)
    if w.hasError then return UI_COLOR.ERR end

    local label = (w.label or ''):lower()
    local expr = (w.expr or ''):lower()
    local merged = label .. ' ' .. expr
    local n = tonumber(w.lastValue)
    local changedRecently = (w.lastChangedMs or 0) > 0 and ((nowMs() - (w.lastChangedMs or 0)) <= 1500)

    -- Generic boolean: true is healthy, false is unhealthy.
    if w.valueType == 'boolean' then
        return w.lastValue and UI_COLOR.OK or UI_COLOR.ERR
    end

    -- Metric-specific numeric thresholding.
    if n then
        -- HP / Mana / Endurance percentages.
        if watchTextMatches(merged, { 'hp', 'hps', 'pcthp', 'mana', 'pctmana', 'end', 'endurance', 'pctend' }) then
            if n <= 25 then return UI_COLOR.ERR end
            if n <= 60 then return UI_COLOR.WARN end
            return UI_COLOR.OK
        end

        -- Aggro threat percentages.
        if watchTextMatches(merged, { 'aggro', 'pctaggro', 'threat' }) then
            if n >= 95 then return UI_COLOR.ERR end
            if n >= 80 then return UI_COLOR.WARN end
            return UI_COLOR.OK
        end

        -- Distances / ranges (bigger often means less ideal).
        if watchTextMatches(merged, { 'distance', 'dist', 'range', 'radius' }) then
            if n >= 200 then return UI_COLOR.ERR end
            if n >= 80 then return UI_COLOR.WARN end
            return UI_COLOR.OK
        end

        -- Delta / difference (near zero is stable, high magnitude is warning/error).
        if watchTextMatches(merged, { 'delta', 'diff', 'difference', 'gap' }) then
            local absn = math.abs(n)
            if absn >= 25 then return UI_COLOR.ERR end
            if absn >= 10 then return UI_COLOR.WARN end
            return UI_COLOR.OK
        end

        -- Cooldown/time remaining style numbers (lower is better in most workflows).
        if watchTextMatches(merged, { 'cooldown', 'cd', 'timer', 'remaining', 'recast' }) then
            if n <= 0 then return UI_COLOR.OK end
            if n <= 5 then return UI_COLOR.WARN end
            return UI_COLOR.ERR
        end

        -- Generic fallback for unknown numeric watch.
        if n <= 25 then return UI_COLOR.ERR end
        if n <= 60 then return UI_COLOR.WARN end
        return changedRecently and UI_COLOR.WARN or UI_COLOR.OK
    end

    -- Strings and other values: highlight recent changes.
    if changedRecently then
        return UI_COLOR.WARN
    end
    return UI_COLOR.INFO
end

local function drawWatchesPanel()
    if not ImGui.CollapsingHeader('Live Watches', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end

    ImGui.SetNextItemWidth(320)
    local watchText, changed = ImGui.InputText('Expression##WatchExpr', state.watchInput, 1024)
    if changed then state.watchInput = watchText end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)
    local watchLabel, changedLabel = ImGui.InputText('Label##WatchLabel', state.watchLabelInput, 128)
    if changedLabel then state.watchLabelInput = watchLabel end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_PLUS_CIRCLE or '') .. ' Add Watch', 118, 0) then
        addWatch(state.watchInput, state.watchLabelInput)
        state.watchInput = ''
        state.watchLabelInput = ''
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_LIST or '') .. ' List', 82, 0) then listWatches() end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ' Clear##Watches', 108, 0) then
        state.watches = {}
        saveWatchesPersistent()
        logInfo('Watches cleared.')
    end

    ImGui.TextDisabled('Format: /luawatch add "Me.PctHPs() < Target.PctHPs()" "HP Delta"')
    ImGui.Separator()

    if ImGui.BeginTable('##WatchTable', 6, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders, ImGuiTableFlags.Resizable)) then
        ImGui.TableSetupColumn('Label', ImGuiTableColumnFlags.WidthFixed, 150)
        ImGui.TableSetupColumn('Expression', ImGuiTableColumnFlags.WidthStretch, 280)
        ImGui.TableSetupColumn('Current Value', ImGuiTableColumnFlags.WidthStretch, 320)
        ImGui.TableSetupColumn('Last Updated', ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableSetupColumn('Eval', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableHeadersRow()

        for _, w in ipairs(state.watches) do
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.TextWrapped(w.label or w.expr)
            ImGui.TableSetColumnIndex(1); ImGui.TextWrapped(w.expr)
            ImGui.TableSetColumnIndex(2)
            if w.hasError then
                ImGui.TextColored(UI_COLOR.ERR[1], UI_COLOR.ERR[2], UI_COLOR.ERR[3], UI_COLOR.ERR[4], w.error or '<error>')
            else
                local c = watchValueColor(w)
                ImGui.TextColored(c[1], c[2], c[3], c[4], w.valueText or '<nil>')
            end
            ImGui.TableSetColumnIndex(3); ImGui.Text(w.lastUpdatedText or '-')
            ImGui.TableSetColumnIndex(4); ImGui.Text(('%dms'):format(tonumber(w.evalMs) or 0))
            ImGui.TableSetColumnIndex(5)
            if ImGui.SmallButton((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ('##Watch%d'):format(w.id)) then
                removeWatch(w.id)
                break
            end
        end

        ImGui.EndTable()
    end
end

local function drawPlotsPanel()
    if not ImGui.CollapsingHeader('Plots', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.SetNextItemWidth(280)
    local expr, ec = ImGui.InputText('Expression##PlotExpr', state.watchInput or '', 1024)
    if ec then state.watchInput = expr end
    ImGui.SameLine()
    ImGui.SetNextItemWidth(150)
    local label, lc = ImGui.InputText('Label##PlotLabel', state.watchLabelInput or '', 128)
    if lc then state.watchLabelInput = label end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_LINE_CHART or Icons.FA_PLUS or '') .. ' Add Plot', 106, 0) then
        addPlot(state.watchInput or '', state.watchLabelInput or '', 300)
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ' Clear##Plots', 116, 0) then
        state.plots = {}
    end

    for _, p in ipairs(state.plots) do
        ImGui.Separator()
        ImGui.Text(('#%d %s'):format(p.id, p.label))
        ImGui.TextDisabled(p.expr)
        ImGui.SameLine()
        ImGui.TextDisabled(('last: %s'):format(p.lastUpdated or '-'))
        if p.hasError then
            ImGui.TextColored(UI_COLOR.ERR[1], UI_COLOR.ERR[2], UI_COLOR.ERR[3], UI_COLOR.ERR[4], p.error or '<error>')
        end
        if #p.data > 1 then
            ImGui.PlotLines(('##Plot' .. p.id), p.data, #p.data, 0, nil, nil, nil, ImVec2(-1, 80))
        else
            ImGui.TextDisabled('Waiting for numeric samples...')
        end
        if ImGui.SmallButton((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ('##Plot' .. p.id)) then
            removePlot(p.id)
            break
        end
    end
end

local function drawTriggersPanel()
    if not ImGui.CollapsingHeader('Triggers', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end

    ImGui.SetNextItemWidth(300)
    local condText, cChanged = ImGui.InputText('Condition##TrigCond', state.triggerCondInput, 1024)
    if cChanged then state.triggerCondInput = condText end
    ImGui.SetNextItemWidth(300)
    local actText, aChanged = ImGui.InputText('Action##TrigAction', state.triggerActionInput, 1024)
    if aChanged then state.triggerActionInput = actText end
    ImGui.SetNextItemWidth(70)
    local coolText, coolChanged = ImGui.InputText('Cooldown(s)##TrigCd', state.triggerCooldownSecInput, 16)
    if coolChanged then state.triggerCooldownSecInput = coolText end
    state.triggerCombatOnly = ImGui.Checkbox('Combat only##TrigCombat', state.triggerCombatOnly)
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_BOLT or '') .. ' Add Trigger', 120, 0) then
        local cdMs = (tonumber(state.triggerCooldownSecInput) or 3) * 1000
        addTrigger(state.triggerCondInput, state.triggerActionInput, cdMs, state.triggerCombatOnly)
        state.triggerCondInput = ''
        state.triggerActionInput = ''
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_LIST or '') .. ' List##Trig', 86, 0) then listTriggers() end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ' Clear##Trig', 108, 0) then
        state.triggers = {}
        logInfo('Triggers cleared.')
    end

    ImGui.TextDisabled('CLI format: /luatrigger add "Target.PctHPs() < 30" ;; "print(\'Execute burn\')"')
    ImGui.Separator()

    if ImGui.BeginTable('##TriggerTable', 8, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders, ImGuiTableFlags.Resizable)) then
        ImGui.TableSetupColumn('ID', ImGuiTableColumnFlags.WidthFixed, 40)
        ImGui.TableSetupColumn('Condition', ImGuiTableColumnFlags.WidthStretch, 240)
        ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthStretch, 220)
        ImGui.TableSetupColumn('Cooldown', ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableSetupColumn('Combat', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableSetupColumn('State', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableSetupColumn('Fired', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableHeadersRow()

        for _, t in ipairs(state.triggers) do
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.Text(tostring(t.id))
            ImGui.TableSetColumnIndex(1); ImGui.TextWrapped(t.condition)
            ImGui.TableSetColumnIndex(2); ImGui.TextWrapped(t.action)
            ImGui.TableSetColumnIndex(3); ImGui.Text(('%0.1fs'):format((tonumber(t.cooldownMs) or 0) / 1000))
            ImGui.TableSetColumnIndex(4); ImGui.Text(t.combatOnly and 'yes' or 'no')
            ImGui.TableSetColumnIndex(5)
            if t.hasError then
                ImGui.TextColored(UI_COLOR.ERR[1], UI_COLOR.ERR[2], UI_COLOR.ERR[3], UI_COLOR.ERR[4], 'ERR')
            elseif t.lastState then
                ImGui.TextColored(UI_COLOR.WARN[1], UI_COLOR.WARN[2], UI_COLOR.WARN[3], UI_COLOR.WARN[4], 'TRUE')
            else
                ImGui.Text('false')
            end
            ImGui.TableSetColumnIndex(6); ImGui.Text(tostring(t.fireCount or 0))
            ImGui.TableSetColumnIndex(7)
            if ImGui.SmallButton((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ('##Trig%d'):format(t.id)) then
                removeTrigger(t.id)
                break
            end
        end

        ImGui.EndTable()
    end
end

local function drawInspectPanel()
    if not ImGui.CollapsingHeader('Quick Inspect', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end

    ImGui.SetNextItemWidth(420)
    local inspectText, changed = ImGui.InputText('Expression##InspectExpr', state.inspectInput, 1024)
    if changed then state.inspectInput = inspectText end
    ImGui.SameLine()
    if ImGui.Button('Inspect', 70, 0) then
        inspectExpression(state.inspectInput)
    end
    ImGui.SameLine()
    if ImGui.Button('Watch Expr', 85, 0) then
        addWatch(state.inspectInput, state.inspectInput)
    end
    ImGui.SameLine()
    if ImGui.Button('Inspect Me', 80, 0) then inspectMeSnapshot() end
    ImGui.SameLine()
    if ImGui.Button('Inspect Target', 96, 0) then inspectTargetSnapshot() end
    ImGui.SameLine()
    if ImGui.Button('Inspect Cursor', 96, 0) then inspectExpression('mq.TLO.CursorAttachment()') end
    ImGui.SameLine()
    if ImGui.Button('Inspect Group Avg', 120, 0) then inspectGroupAverageSnapshot() end

    if state.showInspectTree and state.inspectTreeValue ~= nil then
        ImGui.Separator()
        ImGui.Text(('Explorer: %s'):format(state.inspectTreeLabel or 'value'))
        local function drawNode(label, value, depth, seen)
            depth = depth or 0
            seen = seen or {}
            local t = type(value)
            if t ~= 'table' then
                ImGui.BulletText(('%s = %s'):format(tostring(label), safeToString(value)))
                return
            end
            if seen[value] then
                ImGui.BulletText(('%s = <recursion>'):format(tostring(label)))
                return
            end
            seen[value] = true
            if ImGui.TreeNode(tostring(label)) then
                local n = 0
                for k, v in pairs(value) do
                    n = n + 1
                    if n > 200 then
                        ImGui.TextDisabled('... truncated ...')
                        break
                    end
                    if type(v) == 'table' then
                        drawNode(k, v, depth + 1, seen)
                    else
                        ImGui.BulletText(('%s = %s'):format(tostring(k), safeToString(v)))
                    end
                end
                ImGui.TreePop()
            end
            seen[value] = nil
        end
        drawNode(state.inspectTreeLabel or 'value', state.inspectTreeValue, 0, {})
    end
end

local function drawSnippetsPanel()
    if not ImGui.CollapsingHeader('Snippets', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.SetNextItemWidth(220)
    local n, nc = ImGui.InputText('Name##SnippetName', state.snippetNameInput, 128)
    if nc then state.snippetNameInput = n end
    ImGui.SetNextItemWidth(520)
    local c, cc = ImGui.InputTextMultiline('Code##SnippetCode', state.snippetCodeInput, -1, 80, ImGuiInputTextFlags.AllowTabInput)
    if cc then state.snippetCodeInput = c end
    if ImGui.Button((Icons.FA_FLOPPY_O or '') .. ' Save Snippet', 132, 0) then
        if addSnippet(state.snippetNameInput, state.snippetCodeInput) then
            state.snippetNameInput = ''
            state.snippetCodeInput = ''
        end
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_DOWNLOAD or '') .. ' Import##Snip', 108, 0) then importSnippets(SNIPPETS_FILE) end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_UPLOAD or '') .. ' Export##Snip', 108, 0) then exportSnippets(SNIPPETS_FILE) end

    ImGui.Separator()
    if #state.snippets == 0 then
        ImGui.TextDisabled('No snippets saved.')
        return
    end
    if ImGui.BeginTable('##SnippetTable', 4, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders, ImGuiTableFlags.Resizable)) then
        ImGui.TableSetupColumn('Idx', ImGuiTableColumnFlags.WidthFixed, 36)
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch, 170)
        ImGui.TableSetupColumn('Preview', ImGuiTableColumnFlags.WidthStretch, 440)
        ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 160)
        ImGui.TableHeadersRow()
        for i, s in ipairs(state.snippets) do
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.Text(tostring(i))
            ImGui.TableSetColumnIndex(1); ImGui.Text(s.name)
            ImGui.TableSetColumnIndex(2); ImGui.TextWrapped(truncate(s.code:gsub('%s+', ' '), 120))
            ImGui.TableSetColumnIndex(3)
            if ImGui.SmallButton((Icons.FA_PLAY or '') .. ('##Snip%d'):format(i)) then runSnippet(i) end
            ImGui.SameLine()
            if ImGui.SmallButton((Icons.FA_FOLDER_OPEN_O or Icons.FA_FOLDER_OPEN or '') .. ('##Snip%d'):format(i)) then
                state.snippetNameInput = s.name
                state.snippetCodeInput = s.code
            end
            ImGui.SameLine()
            if ImGui.SmallButton((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ('##Snip%d'):format(i)) then
                removeSnippet(i)
                break
            end
        end
        ImGui.EndTable()
    end
end

local function drawEventTesterPanel()
    if not ImGui.CollapsingHeader('Event Tester', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.SetNextItemWidth(180)
    local et, etc = ImGui.InputText('Event Type##EventType', state.eventTypeInput, 64)
    if etc then state.eventTypeInput = et end
    ImGui.SetNextItemWidth(560)
    local ea, eac = ImGui.InputText('Args (| delimited)##EventArgs', state.eventArgsInput, 1024)
    if eac then state.eventArgsInput = ea end
    ImGui.SetNextItemWidth(740)
    local eh, ehc = ImGui.InputTextMultiline('Handler Code##EventHandler', state.eventHandlerInput, -1, 90, ImGuiInputTextFlags.AllowTabInput)
    if ehc then state.eventHandlerInput = eh end
    if ImGui.Button((Icons.FA_PLAY_CIRCLE_O or Icons.FA_PLAY or '') .. ' Run Event Test', 146, 0) then runEventTest() end
    ImGui.SameLine()
    if ImGui.Button('Template: Combat', 120, 0) then
        state.eventTypeInput = 'combat'
        state.eventArgsInput = 'You slash a foe for 500 points of damage.'
        state.eventHandlerInput = 'print("combat line:", EVENT_LINE)'
    end
    ImGui.SameLine()
    if ImGui.Button('Template: Zone', 110, 0) then
        state.eventTypeInput = 'zone'
        state.eventArgsInput = safeTLO(function() return mq.TLO.Zone.ShortName() end, 'unknown')
        state.eventHandlerInput = 'print("zone changed to:", EVENT_LINE)'
    end
end

local function drawPerformancePanel()
    if not ImGui.CollapsingHeader('Performance', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.Text(('Last Eval: %dms'):format(tonumber(state.lastEvalMs) or 0))
    ImGui.SameLine()
    ImGui.Text(('Profile Avg: %.2fms'):format(tonumber(state.profileLastAvgMs) or 0))
    ImGui.SameLine()
    ImGui.Text(('Profile GC: %+0.2fKB'):format(tonumber(state.profileLastGC) or 0))
    ImGui.SetNextItemWidth(80)
    local v, changed = ImGui.InputInt('Slow Eval Warn (ms)##SlowWarn', tonumber(state.slowEvalWarnMs) or 75)
    if changed then state.slowEvalWarnMs = math.max(1, tonumber(v) or 75) end
    if ImGui.Button('Profile x10', 80, 0) then profileLastInput(10) end
    ImGui.SameLine()
    if ImGui.Button('Profile x50', 80, 0) then profileLastInput(50) end
    state.autoSave.enabled = ImGui.Checkbox('Auto-save enabled##AutoSaveEnabled', state.autoSave.enabled)
    ImGui.SameLine()
    local intervalSec = math.floor((tonumber(state.autoSave.intervalMs) or 30000) / 1000)
    local isec, isChanged = ImGui.InputInt('Auto-save sec##AutoSaveSec', intervalSec)
    if isChanged then
        state.autoSave.intervalMs = math.max(5000, (tonumber(isec) or 30) * 1000)
    end
    state.usePerCharacterFiles = ImGui.Checkbox('Per-character files##PerCharFiles', state.usePerCharacterFiles)
    state.remoteEval.enabled = ImGui.Checkbox('Remote eval file watch##RemoteEvalEnabled', state.remoteEval.enabled)
    ImGui.SameLine()
    local rsec = math.floor((tonumber(state.remoteEval.intervalMs) or 1000) / 1000)
    local rv, rChanged = ImGui.InputInt('Remote eval sec##RemoteEvalSec', rsec)
    if rChanged then
        state.remoteEval.intervalMs = math.max(250, (tonumber(rv) or 1) * 1000)
    end
    ImGui.TextDisabled(('Remote file: %s'):format(REMOTE_EVAL_FILE))
end

local function drawBenchPanel()
    if not ImGui.CollapsingHeader('Benchmark', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.SetNextItemWidth(120)
    local it, changedIt = ImGui.InputInt('Iterations##BenchIter', tonumber(state.bench.iterations) or 200)
    if changedIt then state.bench.iterations = math.max(1, tonumber(it) or 200) end
    local code, changedCode = ImGui.InputTextMultiline('Code##BenchCode', state.bench.code or '', -1, 80, ImGuiInputTextFlags.AllowTabInput)
    if changedCode then state.bench.code = code end
    if ImGui.Button((Icons.FA_TACHOMETER or '') .. ' Run Benchmark', 146, 0) then
        runBenchmark(state.bench.code, state.bench.iterations)
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_ARROW_CIRCLE_O_UP or Icons.FA_ARROW_UP or '') .. ' Use Input Buffer', 156, 0) then
        state.bench.code = state.inputBuffer or ''
    end
    local r = state.bench.result
    if r then
        ImGui.TextDisabled(('avg %.3fms | min %.3f | max %.3f | std %.3f | memDelta %.1fKB'):format(
            r.avg or 0, r.min or 0, r.max or 0, r.stddev or 0, r.memDeltaKB or 0))
    end
end

local function drawSharePanel()
    if not ImGui.CollapsingHeader('Share & Presets', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    if ImGui.Button((Icons.FA_UPLOAD or '') .. ' Export Share Bundle', 176, 0) then
        exportShareBundle(SHARE_FILE)
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_DOWNLOAD or '') .. ' Import Share Bundle', 176, 0) then
        importShareBundle(SHARE_FILE)
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_FILE_TEXT_O or Icons.FA_UPLOAD or '') .. ' Export Log', 130, 0) then
        exportLog(LOG_EXPORT_FILE)
    end
    ImGui.TextDisabled(SHARE_FILE)
end

local function drawPluginPanel()
    if not ImGui.CollapsingHeader('Plugin Hooks', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    ImGui.Text('External scripts can call `_G.LuaConsolePost(level, text)`')
    ImGui.Text(('Buffered plugin msgs: %d'):format(#state.pluginMessages))
    if ImGui.Button('Clear Plugin Messages', 150, 0) then
        state.pluginMessages = {}
        logInfo('Plugin message buffer cleared.')
    end
end

local function drawSystemsPanel()
    if not ImGui.CollapsingHeader('Systems Dashboard', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    if ImGui.BeginTabBar('##SystemsTabs') then
        if ImGui.BeginTabItem('Combat') then
            local inCombat = safeTLO(function() return mq.TLO.Me.Combat() == true end, false)
            local hps = safeTLO(function() return mq.TLO.Me.PctHPs() end, 0)
            local mana = safeTLO(function() return mq.TLO.Me.PctMana() end, 0)
            local aggro = safeTLO(function() return mq.TLO.Me.PctAggro() end, 0)
            local targetName = safeTLO(function() return mq.TLO.Target.CleanName() end, 'None')
            ImGui.Text(('Combat: %s | HP:%s%% Mana:%s%% Aggro:%s%%'):format(tostring(inCombat), tostring(hps), tostring(mana), tostring(aggro)))
            ImGui.Text('Target: ' .. tostring(targetName or 'None'))
            ImGui.Text('XTarget (first 5):')
            for i = 1, 5 do
                local xt = safeTLO(function() return mq.TLO.Me.XTarget(i).Name() end, nil)
                if xt and xt ~= '' then
                    ImGui.BulletText(('#%d %s'):format(i, xt))
                end
            end
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Navigation') then
            local navActive = safeTLO(function() return mq.TLO.Navigation.Active() == true end, false)
            local navDest = safeTLO(function() return mq.TLO.Navigation.Destination() end, 'N/A')
            local navPathLen = safeTLO(function() return mq.TLO.Navigation.PathLength() end, 0)
            ImGui.Text(('Nav Active: %s'):format(tostring(navActive)))
            ImGui.Text(('Destination: %s'):format(tostring(navDest)))
            ImGui.Text(('Path Length: %s'):format(tostring(navPathLen)))
            state.navDebug.enabled = ImGui.Checkbox('Enable Nav Overlay', state.navDebug.enabled)
            if ImGui.Button('Nav Target', 90, 0) then mq.cmd('/nav target') end
            ImGui.SameLine()
            if ImGui.Button('Nav Stop', 80, 0) then mq.cmd('/nav stop') end
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Merc') then
            local mercName = safeTLO(function() return mq.TLO.Me.Mercenary.Name() end, 'None')
            local mercState = safeTLO(function() return mq.TLO.Me.Mercenary.State() end, 'Unknown')
            local mercPctHP = safeTLO(function() return mq.TLO.Me.Mercenary.PctHPs() end, 0)
            ImGui.Text(('Merc: %s | State: %s | HP: %s%%'):format(tostring(mercName), tostring(mercState), tostring(mercPctHP)))
            for _, cmd in ipairs({ '/mqp on', '/mqp off', '/mercassist', '/merc passive', '/merc balanced', '/merc efficient', '/merc aggressive' }) do
                if ImGui.SmallButton(cmd) then
                    mq.cmd(cmd)
                    state.merc.lastCmd = cmd
                end
                ImGui.SameLine()
            end
            ImGui.NewLine()
            if state.merc.lastCmd ~= '' then ImGui.TextDisabled('Last: ' .. state.merc.lastCmd) end
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Macro Bridge') then
            ImGui.Text('Macro Variable Sync')
            ImGui.SetNextItemWidth(220)
            local varName, changed1 = ImGui.InputText('Macro Var##MacroVarName', state.macroVarInput, 128)
            if changed1 then state.macroVarInput = varName end
            ImGui.SetNextItemWidth(180)
            local alias, changed2 = ImGui.InputText('Alias##MacroVarAlias', state.macroAliasInput, 128)
            if changed2 then state.macroAliasInput = alias end
            if ImGui.Button('Sync Var', 80, 0) then
                addMacroSync(state.macroVarInput, state.macroAliasInput)
                state.macroVarInput = ''
                state.macroAliasInput = ''
            end
            ImGui.SameLine()
            if ImGui.Button('List Vars', 80, 0) then handleVarBridgeCommand('list') end
            if #state.macroSync > 0 then
                if ImGui.BeginTable('##MacroSyncTable', 5, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders)) then
                    ImGui.TableSetupColumn('ID', ImGuiTableColumnFlags.WidthFixed, 35)
                    ImGui.TableSetupColumn('Macro Var', ImGuiTableColumnFlags.WidthStretch, 180)
                    ImGui.TableSetupColumn('Env Alias', ImGuiTableColumnFlags.WidthStretch, 120)
                    ImGui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch, 150)
                    ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableHeadersRow()
                    for _, row in ipairs(state.macroSync) do
                        ImGui.TableNextRow()
                        ImGui.TableSetColumnIndex(0); ImGui.Text(tostring(row.id))
                        ImGui.TableSetColumnIndex(1); ImGui.Text(row.varName)
                        ImGui.TableSetColumnIndex(2); ImGui.Text(row.alias)
                        ImGui.TableSetColumnIndex(3); ImGui.Text(safeToString(row.lastValue))
                        ImGui.TableSetColumnIndex(4)
                        if ImGui.SmallButton(('Del##MacroSync%d'):format(row.id)) then
                            removeMacroSync(row.id)
                            break
                        end
                    end
                    ImGui.EndTable()
                end
            end
            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
    end
end

local function drawThemeLayoutPanel()
    if not ImGui.CollapsingHeader('Theme & Layout', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    local labels = {}
    for i, t in ipairs(UI_THEMES) do
        labels[i] = t.label
    end
    if ImGui.BeginCombo('Theme##LcTheme', labels[state.themeIndex] or labels[1] or 'Theme') then
        for i, t in ipairs(UI_THEMES) do
            local selected = (i == state.themeIndex)
            if ImGui.Selectable(t.label, selected) then
                state.theme = t.key
                state.themeIndex = i
                logOk('Theme: ' .. t.label)
            end
            if selected then ImGui.SetItemDefaultFocus() end
        end
        ImGui.EndCombo()
    end
    ImGui.SetNextItemWidth(120)
    local ratio, changed = ImGui.SliderFloat('Log Ratio##LcLayout', state.topLogRatio, 0.30, 0.80, '%.2f')
    if changed then state.topLogRatio = ratio end
    if ImGui.Button('Combat Mode', 110, 0) then
        state.layoutPreset = 'combat'
        state.topLogRatio = 0.50
        state.currentTab = 'Observability'
        state.openSections.watches = true
        state.openSections.triggers = true
        state.openSections.inspect = true
        state.navDebug.enabled = false
    end
    ImGui.SameLine()
    if ImGui.Button('Merc Mode', 90, 0) then
        state.layoutPreset = 'merc'
        state.topLogRatio = 0.45
        state.currentTab = 'Systems'
        state.openSections.watches = true
        state.openSections.triggers = false
        state.navDebug.enabled = false
    end
    ImGui.SameLine()
    if ImGui.Button('Nav Mode', 90, 0) then
        state.layoutPreset = 'nav'
        state.topLogRatio = 0.45
        state.currentTab = 'Systems'
        state.navDebug.enabled = true
        state.openSections.watches = true
        state.openSections.triggers = false
    end
    ImGui.SameLine()
    if ImGui.Button('REPL Focus', 100, 0) then
        state.layoutPreset = 'repl'
        state.topLogRatio = 0.68
        state.currentTab = 'Console'
    end
    ImGui.SameLine()
    if ImGui.Button('Monitor', 90, 0) then
        state.layoutPreset = 'monitor'
        state.topLogRatio = 0.40
        state.currentTab = 'Observability'
    end
end

local function drawNavOverlay()
    if not state.navDebug.enabled then return end
    ImGui.SetNextWindowBgAlpha(0.35)
    ImGui.SetNextWindowPos(40, 120, ImGuiCond.FirstUseEver)
    local flags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.AlwaysAutoResize,
        ImGuiWindowFlags.NoFocusOnAppearing
    )
    local open = ImGui.Begin('LuaConsole Nav Overlay##LCNavOverlay', true, flags)
    if open then
        local navActive = safeTLO(function() return mq.TLO.Navigation.Active() == true end, false)
        local navDest = safeTLO(function() return mq.TLO.Navigation.Destination() end, 'N/A')
        local navPathLen = safeTLO(function() return mq.TLO.Navigation.PathLength() end, 0)
        ImGui.TextColored(UI_COLOR.INPUT[1], UI_COLOR.INPUT[2], UI_COLOR.INPUT[3], UI_COLOR.INPUT[4], 'Navigation Debug')
        ImGui.Text(('Active: %s'):format(tostring(navActive)))
        ImGui.Text(('Destination: %s'):format(tostring(navDest)))
        ImGui.Text(('PathLength: %s'):format(tostring(navPathLen)))
        if ImGui.SmallButton('Stop Nav') then mq.cmd('/nav stop') end
    end
    ImGui.End()
end

local function drawInputArea()
    ImGui.Text('Input (Enter = Eval, Shift+Enter = New Line)')

    local flags = ImGuiInputTextFlags.AllowTabInput + ImGuiInputTextFlags.EnterReturnsTrue
    local newText, changed = ImGui.InputTextMultiline('##LuaConsoleInput', state.inputBuffer, -1, 120, flags)
    if changed then
        state.inputBuffer = newText
        refreshAutocompleteCandidates()
    end

    local evalRequested = false

    if ImGui.IsItemFocused() and ImGui.IsKeyPressed(ImGuiKey.Enter) then
        if ImGui.GetIO().KeyShift then
            -- Shift+Enter: insert newline manually for predictable behavior.
            state.inputBuffer = state.inputBuffer .. '\n'
        else
            evalRequested = true
        end
    end
    if ImGui.IsItemFocused() and ImGui.IsKeyPressed(ImGuiKey.Tab) then
        autocompleteToken()
    end
    if ImGui.IsItemFocused() and ImGui.GetIO().KeyCtrl and ImGui.IsKeyPressed(ImGuiKey.Space) then
        refreshAutocompleteCandidates()
    end
    if ImGui.IsItemFocused() then
        if ImGui.IsKeyPressed(ImGuiKey.Period) or ImGui.IsKeyPressed(ImGuiKey.Semicolon) then
            refreshAutocompleteCandidates()
        end
    end
    if not ImGui.IsItemFocused() then
        state.autocomplete.showPopup = false
    end

    if state.autocomplete.showPopup and #state.autocomplete.candidates > 0 then
        ImGui.Separator()
        ImGui.TextDisabled('Autocomplete (TAB cycles, click to insert)')
        local showMax = math.min(8, #state.autocomplete.candidates)
        local token = (state.inputBuffer or ''):match('([%w_%.:]+)$') or ''
        local _, prefix = token:match('^(.-)[%.:]([%w_]*)$')
        prefix = prefix or token
        for i = 1, showMax do
            local cand = state.autocomplete.candidates[i]
            local label = cand
            if i == state.autocomplete.index then
                label = '> ' .. cand
            end
            if ImGui.Selectable(label, false) then
                local s = state.inputBuffer or ''
                state.inputBuffer = s:sub(1, #s - #prefix) .. cand
                state.autocomplete.showPopup = false
            end
        end
    end

    ImGui.Spacing()

    if ImGui.Button((Icons.FA_PLAY or '') .. ' Eval', 96, 0) then
        evalRequested = true
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_ERASER or Icons.FA_TIMES or '') .. ' Clear Input', 120, 0) then
        state.inputBuffer = ''
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_ARROW_LEFT or '') .. ' Prev', 84, 0) then
        onPrev()
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_ARROW_RIGHT or '') .. ' Next', 84, 0) then
        onNext()
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_TRASH_O or Icons.FA_TIMES or '') .. ' Clear Output', 126, 0) then
        state.logs = {}
        logInfo('Console log cleared.')
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_CLIPBOARD or Icons.FA_FILES_O or '') .. ' Copy output', 132, 0) then
        local lines = {}
        for _, row in ipairs(state.logs) do
            lines[#lines + 1] = ('[%s] %s'):format(row.ts, row.text)
        end
        ImGui.SetClipboardText(table.concat(lines, '\n'))
        logOk('Output copied to clipboard.')
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_FLOPPY_O or '') .. ' Save', 84, 0) then
        saveSession()
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_FOLDER_OPEN_O or Icons.FA_FOLDER_OPEN or '') .. ' Load', 88, 0) then
        loadSession()
    end

    ImGui.SameLine()
    if ImGui.Button((Icons.FA_TIMES or '') .. ' Close', 104, 0) then
        state.showUI = false
    end
    ImGui.SameLine()
    if ImGui.Button((Icons.FA_FILE_TEXT_O or Icons.FA_UPLOAD or '') .. ' Export Log', 126, 0) then
        exportLog(LOG_EXPORT_FILE)
    end

    local ts = state.showTimestamps
    state.showTimestamps = ImGui.Checkbox('Timestamps', ts)

    ImGui.SameLine()
    local auto = state.autoscroll
    state.autoscroll = ImGui.Checkbox('Auto-scroll', auto)

    ImGui.SameLine()
    local dbg = state.debug
    state.debug = ImGui.Checkbox('Debug', dbg)

    ImGui.SameLine()
    ImGui.TextDisabled('Status: ' .. state.status)
    ImGui.SameLine()
    ImGui.TextDisabled(('Last eval: %dms'):format(tonumber(state.lastEvalMs) or 0))

    if evalRequested then
        local payload = trim(state.inputBuffer)
        if payload ~= '' then
            submitChunkText(payload, 'ui')
            state.inputBuffer = ''
        end
    end
end

local function drawQuickCommandBar()
    if not ImGui.CollapsingHeader('Quick Commands', ImGuiTreeNodeFlags.DefaultOpen) then
        return
    end
    for i, cmd in ipairs(state.quickCommands) do
        if ImGui.SmallButton(cmd .. '##Quick' .. i) then
            mq.cmd(cmd)
            logOk('cmd: ' .. cmd)
        end
        if (i % 3) ~= 0 then ImGui.SameLine() end
    end
end

local function renderUI()
    if not state.showUI then return end
    local vars, colors = pushConsoleTheme()
    local ws = state.windowState or {}
    ImGui.SetNextWindowSize(ws.w or 1180, ws.h or 760, ImGuiCond.FirstUseEver)
    if ws.x and ws.y then
        ImGui.SetNextWindowPos(ws.x, ws.y, ImGuiCond.FirstUseEver)
    end
    if ws.collapsed ~= nil then
        ImGui.SetNextWindowCollapsed(ws.collapsed, ImGuiCond.FirstUseEver)
    end
    state.showUI, _ = ImGui.Begin(('Lua Console Pro##%s'):format(SCRIPT_NAME), state.showUI)
    local wx, wy = ImGui.GetWindowPos()
    local ww, wh = ImGui.GetWindowSize()
    state.windowState = {
        x = wx,
        y = wy,
        w = ww,
        h = wh,
        collapsed = ImGui.IsWindowCollapsed(),
    }

    ImGui.Text(('%s v%s'):format(SCRIPT_NAME, VERSION))
    ImGui.SameLine()
    ImGui.TextDisabled('Persistent REPL dev dashboard for MQNext')
    if state.pendingBuffer ~= '' then
        ImGui.SameLine()
        ImGui.TextColored(UI_COLOR.WARN[1], UI_COLOR.WARN[2], UI_COLOR.WARN[3], UI_COLOR.WARN[4], '.. continuation active')
    end
    ImGui.Separator()

    if state.autoSave.restorePrompt then
        ImGui.TextColored(UI_COLOR.WARN[1], UI_COLOR.WARN[2], UI_COLOR.WARN[3], UI_COLOR.WARN[4], 'Auto-snapshot detected. Restore previous session?')
        if ImGui.Button('Restore Auto Snapshot', 160, 0) then
            if restoreFromAutoSnapshot() then
                logOk('Auto snapshot restored.')
            else
                logErr('Auto snapshot restore failed.')
            end
            state.autoSave.restorePrompt = false
        end
        ImGui.SameLine()
        if ImGui.Button('Ignore', 80, 0) then
            state.autoSave.restorePrompt = false
        end
        ImGui.Separator()
    end

    if ImGui.BeginTabBar('##LuaConsoleTabs') then
        if ImGui.BeginTabItem('Console') then
            state.currentTab = 'Console'
            local _, availY = ImGui.GetContentRegionAvail()
            local logHeight = math.max(180, math.floor(availY * (state.topLogRatio or 0.58)))
            drawLogWindow(logHeight)
            ImGui.Separator()
            drawInputArea()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Watches') then
            state.currentTab = 'Watches'
            drawWatchesPanel()
            ImGui.Spacing()
            drawPlotsPanel()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Snippets') then
            state.currentTab = 'Snippets'
            drawSnippetsPanel()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Inspect') then
            state.currentTab = 'Inspect'
            drawInspectPanel()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Logs') then
            state.currentTab = 'Logs'
            local _, availY = ImGui.GetContentRegionAvail()
            drawLogWindow(math.max(220, availY - 6))
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Observability') then
            state.currentTab = 'Observability'
            drawWatchesPanel()
            ImGui.Spacing()
            drawTriggersPanel()
            ImGui.Spacing()
            drawInspectPanel()
            ImGui.Spacing()
            drawPlotsPanel()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Workflow') then
            state.currentTab = 'Workflow'
            drawSnippetsPanel()
            ImGui.Spacing()
            drawEventTesterPanel()
            ImGui.Spacing()
            drawQuickCommandBar()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Systems') then
            state.currentTab = 'Systems'
            drawSystemsPanel()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem('Settings') then
            state.currentTab = 'Settings'
            drawPerformancePanel()
            ImGui.Spacing()
            drawBenchPanel()
            ImGui.Spacing()
            drawThemeLayoutPanel()
            ImGui.Spacing()
            drawSharePanel()
            ImGui.Spacing()
            drawPluginPanel()
            ImGui.EndTabItem()
        end
        for _, tab in ipairs(state.customTabs) do
            if ImGui.BeginTabItem(tab.name .. '##CustomTab' .. tab.id) then
                local ok, err = pcall(tab.cb, state)
                if not ok then
                    ImGui.TextColored(UI_COLOR.ERR[1], UI_COLOR.ERR[2], UI_COLOR.ERR[3], UI_COLOR.ERR[4], tostring(err))
                end
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end

    ImGui.End()
    drawNavOverlay()
    popConsoleTheme(vars, colors)
end

-- =========================================================
-- Bindings / events / lifecycle
-- =========================================================

mq.bind('/luaconsole', function(line)
    local cmd = trim(tostring(line or '')):lower()
    if cmd == 'show' then
        state.showUI = true -- UPDATED: explicit show command for deterministic open behavior
    elseif cmd == 'hide' then
        state.showUI = false -- UPDATED: explicit hide command for deterministic close behavior
    elseif cmd == 'toggle' or cmd == '' then
        state.showUI = not state.showUI -- UPDATED: keep legacy toggle behavior on /luaconsole
    elseif cmd == 'quit' or cmd == 'stop' then
        state.running = false -- UPDATED: allow explicit script shutdown from bind command
    else
        state.showUI = true -- UPDATED: fallback to show for unknown args to avoid accidental hide
    end
    if state.showUI then
        state.windowState = sanitizeWindowState(state.windowState) or state.windowState
    end
    logInfo(('ImGui console %s.'):format(state.showUI and 'shown' or 'hidden'))
end)

-- Alias for convenience.
mq.bind('/lc', function(line)
    local cmd = trim(tostring(line or '')):lower()
    if cmd == '' or cmd == 'show' then
        state.showUI = true -- UPDATED: /lc now defaults to show to match MAUI Open button semantics
    elseif cmd == 'hide' then
        state.showUI = false -- UPDATED: explicit hide supported via /lc hide
    elseif cmd == 'toggle' then
        state.showUI = not state.showUI -- UPDATED: toggle still available via /lc toggle
    elseif cmd == 'quit' or cmd == 'stop' then
        state.running = false -- UPDATED: allow explicit shutdown via /lc stop
    else
        state.showUI = true -- UPDATED: unknown /lc args treated as show for safer UX
    end
    if state.showUI then
        state.windowState = sanitizeWindowState(state.windowState) or state.windowState
    end
end)

mq.bind('/luaeval', function(line)
    handleLuaCommand(line)
end)

mq.bind('/lceval', function(line)
    handleLuaCommand(line)
end)

mq.bind('/luaprev', onPrev)
mq.bind('/luanext', onNext)

mq.bind('/luaclear', function()
    state.logs = {}
    logInfo('Console log cleared.')
end)

mq.bind('/luadebug', function(line)
    handleDebug(line)
end)

mq.bind('/luats', function(line)
    handleTimestamps(line)
end)

mq.bind('/luachat', function(line)
    handleChatMode(line)
end)

mq.bind('/luamqenv', function(line)
    handleUnsafeMqEnv(line)
end)

mq.bind('/luasave', function(line)
    local file = trim(line or '')
    if file == '' then file = SESSION_FILE end
    saveSession(file)
end)

mq.bind('/luaload', function(line)
    local file = trim(line or '')
    if file == '' then file = SESSION_FILE end
    loadSession(file)
end)

mq.bind('/luawatch', function(line)
    handleWatchCommand(line)
end)

mq.bind('/luatrigger', function(line)
    handleTriggerCommand(line)
end)

mq.bind('/luaplot', function(line)
    handlePlotCommand(line)
end)

mq.bind('/luainspect', function(line)
    handleInspectCommand(line)
end)

mq.bind('/luasnippet', function(line)
    handleSnippetCommand(line)
end)

mq.bind('/luaeventtest', function()
    runEventTest()
end)

mq.bind('/luaprofile', function(line)
    profileLastInput(tonumber(trim(line or '')) or 10)
end)

mq.bind('/luabench', function(line)
    handleBenchCommand(line)
end)

mq.bind('/luashare', function(line)
    handleShareCommand(line)
end)

mq.bind('/luamode', function(line)
    handleModeCommand(line)
end)

mq.bind('/luavar', function(line)
    handleVarBridgeCommand(line)
end)

mq.bind('/luaexportlog', function(line)
    local path = trim(line or '')
    exportLog(path ~= '' and path or LOG_EXPORT_FILE)
end)

mq.bind('/luahelp', function()
    printHelp()
end)

local luaconsoleApi = {
    log = function(text, level)
        level = (level or 'info'):lower()
        if level == 'error' or level == 'err' then
            logErr(text, 'api')
        elseif level == 'warn' or level == 'warning' then
            logWarn(text, 'api')
        elseif level == 'ok' or level == 'success' then
            logOk(text, 'api')
        else
            logInfo(text, 'api')
        end
    end,
    watch_add = function(expr, label) return addWatch(expr, label) end,
    watch_remove = function(id) return removeWatch(tonumber(id) or -1) end,
    trigger_add = function(cond, action, cooldownMs, combatOnly) return addTrigger(cond, action, cooldownMs, combatOnly) end,
    trigger_remove = function(id) return removeTrigger(tonumber(id) or -1) end,
    run_snippet = function(nameOrIndex)
        if type(nameOrIndex) == 'number' then return runSnippet(nameOrIndex) end
        if type(nameOrIndex) == 'string' then return runSnippetByName(nameOrIndex) end
        return false
    end,
    inspect_push = function(value, label)
        state.inspectTreeValue = value
        state.inspectTreeLabel = label or 'external'
        state.showInspectTree = true
    end,
    tab_register = function(name, callback, owner)
        return registerCustomTab(name, callback, owner)
    end,
    tab_unregister = function(id)
        return unregisterCustomTab(id)
    end,
    subscribe = function(eventName, callback, owner)
        return eventSubscribe(eventName, callback, owner)
    end,
    unsubscribe = function(subId)
        return eventUnsubscribe(subId)
    end,
    publish = function(eventName, payload)
        return eventPublish(eventName, payload)
    end,
    set_unsafe_env = function(enabled)
        state.allowUnsafeMqEnv = enabled == true
        state.env = makeEnv()
        return state.allowUnsafeMqEnv
    end,
    get_state = function()
        return {
            running = state.running,
            showUI = state.showUI,
            status = state.status,
            theme = state.theme,
            currentTab = state.currentTab,
            chatModeEnabled = state.chatModeEnabled,
            chatEvalToken = state.chatEvalToken,
            allowUnsafeMqEnv = state.allowUnsafeMqEnv,
            watchCount = #state.watches,
            triggerCount = #state.triggers,
            snippetCount = #state.snippets,
            layoutPreset = state.layoutPreset,
        }
    end,
}

package.loaded['luaconsole'] = luaconsoleApi

-- Chat fallback: type: lua> print(Me.Name())
mq.event('LuaConsoleChatFallback', 'lua> #1#', function(payload)
    if state.chatModeEnabled then
        handleChatFallbackLine(payload)
    end
end)

mq.imgui.init('LuaConsoleProUI', renderUI)

-- =========================================================
-- Startup
-- =========================================================

applyPerCharacterFileScope()
loadSettings()
applyPerCharacterFileScope()
loadWatchesPersistent()
loadSnippetsPersistent()
ensureDefaultSnippets()
loadPersistentState()
if fileExists(AUTO_SAVE_FILE) then
    state.autoSave.restorePrompt = true
end
logOk(('%s loaded. Type /luahelp for commands.'):format(SCRIPT_NAME))
local shortcutMsg = 'REPL env shortcuts: T, Me, Target, Group, Spawn, Zone, inspect/dump/pp'
if state.allowUnsafeMqEnv then
    shortcutMsg = shortcutMsg .. ', mq, cmd, cmdf, delay, echo'
end
logInfo(shortcutMsg)

while state.running do
    local ok, err = xpcall(function()
        updateWatchesAndTriggers()
        updatePlots()
        updateMacroSync()
        maybeAutoSave()
        pollRemoteEvalFile()
        mq.doevents('LuaConsoleChatFallback')
    end, function(e)
        return debug.traceback(e, 2)
    end)
    if not ok then
        logErr('main tick error: ' .. tostring(err))
    end
    mq.delay(10)
end

saveSettings()
savePersistentState()
