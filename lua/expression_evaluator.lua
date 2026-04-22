local mq = require('mq')
local ImGui = require('ImGui')

local okTheme, themeBridge = pcall(require, 'lib.maui_theme_bridge')
if not okTheme then
    themeBridge = {
        push = function() return nil end,
        pop = function() end,
    }
end

local state = {
    running = true,
    open = true,
    expression = 'mq.TLO.Me.CleanName()',
    modeIndex = 1, -- 1 = expression, 2 = chunk
    lastValue = '',
    lastLuaType = '',
    lastMqType = '',
    lastOk = false,
    status = 'Ready.',
    history = {},
    historyLimit = 25,
}

local MODES = {
    { label = 'Expression (auto return)', id = 'expr' },
    { label = 'Lua Chunk (advanced)', id = 'chunk' },
}

local PRESETS = {
    { label = 'My Name', expr = 'mq.TLO.Me.CleanName()' },
    { label = 'HP %', expr = 'mq.TLO.Me.PctHPs()' },
    { label = 'Mana %', expr = 'mq.TLO.Me.PctMana()' },
    { label = 'Target Name', expr = 'mq.TLO.Target.CleanName()' },
    { label = 'Target Dist', expr = 'mq.TLO.Target.Distance()' },
    { label = 'In Combat', expr = 'mq.TLO.Me.Combat()' },
    { label = 'Nearby Named', expr = 'mq.TLO.SpawnCount("npc radius 120 named")()' },
}

local function toString(v)
    if v == nil then return 'nil' end
    local t = type(v)
    if t == 'boolean' then return v and 'true' or 'false' end
    if t == 'number' then return tostring(v) end
    return tostring(v)
end

local function addHistory(expr, ok, value, luaType, mqType, err)
    table.insert(state.history, 1, {
        ts = os.date('%H:%M:%S'),
        expr = expr,
        ok = ok,
        value = value,
        luaType = luaType or '',
        mqType = mqType or '',
        err = err or '',
    })
    while #state.history > state.historyLimit do
        table.remove(state.history)
    end
end

local function detectMqType(value)
    if type(value) ~= 'userdata' then return '' end
    local ok, t = pcall(mq.gettype, value)
    if ok then return tostring(t or '') end
    return 'unknown userdata'
end

local function evaluateExpression(input)
    if not input or input:gsub('%s+', '') == '' then
        state.status = 'Expression is empty.'
        return
    end

    if input:lower():find('mq.tlo') and not input:find('mq.TLO') then
        local warn = "'mq.TLO' is case sensitive. Use uppercase TLO."
        state.lastOk = false
        state.lastValue = warn
        state.lastLuaType = 'error'
        state.lastMqType = ''
        state.status = warn
        addHistory(input, false, warn, 'error', '', warn)
        return
    end

    local mode = MODES[state.modeIndex] and MODES[state.modeIndex].id or 'expr'
    local chunk = ''
    if mode == 'chunk' then
        chunk = 'local mq = require("mq")\n' .. input
    else
        chunk = 'local mq = require("mq")\nreturn ' .. input
    end

    local loader, loadErr = load(chunk, 'ExpressionEvaluator', 't')
    if not loader then
        state.lastOk = false
        state.lastValue = tostring(loadErr or 'compile error')
        state.lastLuaType = 'error'
        state.lastMqType = ''
        state.status = 'Compile error.'
        addHistory(input, false, state.lastValue, 'error', '', state.lastValue)
        return
    end

    local okRun, result = pcall(loader)
    if not okRun then
        state.lastOk = false
        state.lastValue = tostring(result or 'runtime error')
        state.lastLuaType = 'error'
        state.lastMqType = ''
        state.status = 'Runtime error.'
        addHistory(input, false, state.lastValue, 'error', '', state.lastValue)
        return
    end

    local luaType = type(result)
    local mqType = detectMqType(result)
    state.lastOk = true
    state.lastValue = toString(result)
    state.lastLuaType = luaType
    state.lastMqType = mqType
    state.status = 'Evaluation succeeded.'
    addHistory(input, true, state.lastValue, luaType, mqType, '')
end

local function copyText(text)
    local t = tostring(text or '')
    if t == '' then
        state.status = 'Nothing to copy.'
        return
    end
    ImGui.SetClipboardText(t)
    mq.cmdf('/clipboard set "%s"', t:gsub('"', '\\"'))
    state.status = 'Copied to clipboard.'
end

local function drawQuickButtons()
    if ImGui.Button('Evaluate', 110, 0) then
        evaluateExpression(state.expression)
    end
    ImGui.SameLine()
    if ImGui.Button('Copy Expr', 100, 0) then
        copyText(state.expression)
    end
    ImGui.SameLine()
    if ImGui.Button('Copy Result', 110, 0) then
        copyText(state.lastValue)
    end
    ImGui.SameLine()
    if ImGui.Button('Clear', 80, 0) then
        state.expression = ''
        state.lastValue = ''
        state.lastLuaType = ''
        state.lastMqType = ''
        state.lastOk = false
        state.status = 'Cleared.'
    end
    ImGui.SameLine()
    if ImGui.Button('Clear History', 110, 0) then
        state.history = {}
        state.status = 'History cleared.'
    end
end

local function drawPresets()
    ImGui.TextColored(0.72, 0.95, 1.00, 1.00, 'Presets')
    for i, p in ipairs(PRESETS) do
        if ImGui.Button(p.label .. '##EvalPreset' .. i, 130, 0) then
            state.expression = p.expr
        end
        if i % 4 ~= 0 then ImGui.SameLine() end
    end
end

local function drawResult()
    ImGui.Separator()
    local okColor = state.lastOk and {0.45, 0.95, 0.55, 1.0} or {1.0, 0.50, 0.35, 1.0}
    ImGui.TextColored(okColor[1], okColor[2], okColor[3], okColor[4], state.lastOk and 'Result: OK' or 'Result: Not evaluated / error')
    ImGui.TextWrapped('Value: ' .. (state.lastValue ~= '' and state.lastValue or '<none>'))
    ImGui.Text('Lua Type: ' .. (state.lastLuaType ~= '' and state.lastLuaType or '-'))
    ImGui.SameLine()
    ImGui.Text('MQ Type: ' .. (state.lastMqType ~= '' and state.lastMqType or '-'))
    if state.lastLuaType == 'userdata' then
        ImGui.TextColored(1.0, 0.65, 0.2, 1.0, 'Tip: add () to resolve TLO userdata into a concrete value.')
    end
end

local function drawHistory()
    ImGui.Separator()
    ImGui.TextColored(0.72, 0.95, 1.00, 1.00, 'History')
    if #state.history == 0 then
        ImGui.TextDisabled('No evaluations yet.')
        return
    end

    if ImGui.BeginTable('EvalHistoryTable', 5, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.ScrollY, 0, 180) then
        ImGui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableSetupColumn('Expr', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('OK', ImGuiTableColumnFlags.WidthFixed, 45)
        ImGui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Reuse', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableHeadersRow()

        for i, row in ipairs(state.history) do
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0)
            ImGui.Text(row.ts)

            ImGui.TableSetColumnIndex(1)
            ImGui.TextWrapped(row.expr)

            ImGui.TableSetColumnIndex(2)
            if row.ok then
                ImGui.TextColored(0.45, 0.95, 0.55, 1.0, 'Yes')
            else
                ImGui.TextColored(1.0, 0.50, 0.35, 1.0, 'No')
            end

            ImGui.TableSetColumnIndex(3)
            local v = row.ok and row.value or row.err
            ImGui.TextWrapped(v)

            ImGui.TableSetColumnIndex(4)
            if ImGui.SmallButton('Load##EvalHist' .. i) then
                state.expression = row.expr
            end
        end
        ImGui.EndTable()
    end
end

local function drawUI()
    if not state.running or not state.open then return end
    local token = themeBridge.push()
    ImGui.SetNextWindowSize(820, 700, ImGuiCond.FirstUseEver)
    state.open = ImGui.Begin('Lua Expression Evaluator###ExpressionEvaluator', state.open, ImGuiWindowFlags.NoCollapse)
    if state.open then
        ImGui.TextColored(0.45, 0.90, 0.98, 1.0, 'Evaluate MQ/Lua expressions safely before using them in conditions.')
        ImGui.Separator()

        if ImGui.BeginCombo('Mode', MODES[state.modeIndex].label) then
            for i, m in ipairs(MODES) do
                if ImGui.Selectable(m.label, i == state.modeIndex) then
                    state.modeIndex = i
                end
            end
            ImGui.EndCombo()
        end

        if MODES[state.modeIndex].id == 'chunk' then
            ImGui.TextColored(1.0, 0.65, 0.2, 1.0, 'Chunk mode is advanced. Add explicit return statements to get output values.')
        end

        state.expression = ImGui.InputTextMultiline('Expression / Chunk', state.expression, -1, 110)
        drawQuickButtons()
        drawPresets()
        drawResult()
        drawHistory()
        ImGui.Separator()
        ImGui.TextColored(0.72, 0.95, 1.00, 1.00, 'Status: ' .. (state.status or ''))
    end
    ImGui.End()
    themeBridge.pop(token)
end

local function help()
    print('[ExpressionEvaluator] Commands: /ee show | hide | toggle | clear | eval <expr> | quit')
end

local function handleCommand(arg)
    local raw = tostring(arg or '')
    local lower = raw:lower()
    if lower == '' or lower == 'toggle' then
        state.open = not state.open
    elseif lower == 'show' then
        state.open = true
    elseif lower == 'hide' then
        state.open = false
    elseif lower == 'clear' then
        state.expression = ''
        state.lastValue = ''
        state.lastLuaType = ''
        state.lastMqType = ''
        state.status = 'Cleared.'
    elseif lower:match('^eval%s+') then
        local expr = raw:match('^eval%s+(.+)$')
        state.expression = expr or ''
        evaluateExpression(state.expression)
    elseif lower == 'quit' or lower == 'stop' then
        state.running = false
    else
        help()
    end
end

mq.bind('/ee', handleCommand)
mq.imgui.init('ExpressionEvaluator', drawUI)
print('[ExpressionEvaluator] Loaded. Use /ee show to open.')

while state.running do
    mq.delay(50)
end

mq.unbind('/ee')
