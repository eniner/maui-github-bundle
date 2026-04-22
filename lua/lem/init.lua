--[[
lua event manager -- aquietone
]]
local mq = require 'mq'
require 'ImGui'
local zep = require('Zep')
local events = require('events')
-- for scripts with a check on lem.events being required, since they won't find lem.events if the require used the name events
require('lem.events')
local templates = require('templates.index')
require('write')
local persistence = require('persistence')
local icons = require('mq.icons')
local themeBridge = require('lib.maui_theme_bridge')
local version = '0.10.2'
local safemode = false

---@type Zep.Editor
local editor = nil
---@type Zep.Buffer
local buffer = nil

-- application state
local state = {
    terminate = false,
    ui = {
        main = {
            title = 'Lua Event Manager (v%s)%s###lem',
            open_ui = true,
            draw_ui = true,
            menu_idx = 1,
            event_idx = nil,
            category_idx = 0,
            menu_width = 120,
            filter = '',
            dirty = false,
        },
        editor = {
            open_ui = false,
            draw_ui = false,
            action = nil,
            event_idx = nil,
            event_type = nil,
            template = '',
        },
    },
    inputs = {
        import = '',
        add_event = {name='', category='', enabled=false, pattern='', code='',load={always=false,zone='',class='',characters='',},},
        add_category = {name='',parent='',parent_idx=0},
        cond_lab = {
            expression = 'mq.TLO.Me.XTarget() > 0',
            action_cmd = '',
            last_validate_ok = nil,
            last_validate_msg = '',
            last_eval_ok = nil,
            last_eval_msg = '',
            snippet_idx = 1,
        },
    },
}

local function fileExists(path)
    local f = io.open(path, "r")
    if f ~= nil then io.close(f) return true else return false end
end
if fileExists(mq.luaDir..'/lem.lua') then
    os.remove(mq.luaDir..'/lem.lua')
end

local table_flags = bit32.bor(ImGuiTableFlags.Hideable, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.Resizable, ImGuiTableFlags.Sortable)
local actions = {add=1,edit=2,view=3,add_category=4,import=5}
local base_dir = mq.luaDir .. '/lem'
local menu_default_width = 120

local settings, text_events, condition_events, categories, char_settings, filtered_events
local show_code = false
local sortable_events = {}
local first_load = true

local function save_settings()
    persistence.store(('%s/settings.lua'):format(base_dir), settings)
    --mq.pickle(('%s/settings.lua'):format(base_dir), settings)
end

local function save_character_settings()
    persistence.store(('%s/characters/%s.lua'):format(base_dir, mq.TLO.Me.CleanName():lower():gsub('\'s corpse', '')), char_settings)
    --mq.pickle(('%s/characters/%s.lua'):format(base_dir, mq.TLO.Me.CleanName():lower():gsub('\'s corpse', '')), char_settings)
end

local function init_settings()
    local ok, module = pcall(require, 'settings')
    if not ok then
        if persistence.file_exists(base_dir..'/settings.lua') then
            print('\arLEM: Unable to load settings.lua, exiting!\ax')
            return
        end
        settings = {
            text_events = {},
            condition_events = {},
            categories = {},
            settings = {
                frequency = 250,
            },
        }
        save_settings()
    else
        settings = module
    end
    text_events = settings.text_events or {}
    condition_events = settings.condition_events or {}
    categories = settings.categories or {}
    for i,category in ipairs(categories) do
        if type(category) == 'string' then
            categories[i] = {name=category, children={}}
        end
    end
    if not settings.settings or not settings.settings.frequency then
        settings['settings'] = {frequency = 250, broadcast = 'DanNet'}
    end
    if not settings.settings.broadcast then settings.settings.broadcast = 'None' end
    events.setSettings(settings)
end

local function init_char_settings()
    local my_name = mq.TLO.Me.CleanName():lower():gsub('\'s corpse', '')
    local ok, module = pcall(require, 'characters.'..my_name)
    if not ok then
        char_settings = {events={}, conditions={}}
        save_character_settings()
    else
        char_settings = module
    end
end

local function reset_add_event_inputs(event_type)
    state.inputs.add_event = {name='', category='', enabled=false, pattern='', singlecommand=false, command='', load={always=false,zone='',class='',characters='',},}
    if event_type == events.types.text then
        buffer:SetText(templates.text_base)
    elseif event_type == events.types.cond then
        buffer:SetText(templates.condition_base)
    end
    show_code = false
end

local function set_add_event_inputs(event)
    state.inputs.add_event = {
        name=event.name,
        category=event.category,
        enabled=char_settings[state.ui.editor.event_type][event.name],
        pattern=event.pattern,
        singlecommand=event.singlecommand,
        command=event.command,
        code=event.code,
        load=event.load,
    }
    if event.load then
        state.inputs.add_event.load = {
            always=event.load.always,
            characters=event.load.characters,
            class=event.load.class,
            zone=event.load.zone,
        }
    else
        state.inputs.add_event.load = {
            always=false,
            characters='',
            class='',
            zone=''
        }
    end
    show_code = false
end

local function set_editor_state(open, action, event_type, event_idx)
    state.ui.editor.open_ui = open
    state.ui.editor.action = action
    state.ui.editor.event_idx = event_idx
    state.ui.editor.event_type = event_type
    show_code = false
end

local function get_event_list(event_type)
    if event_type == events.types.text then
        return text_events
    else
        return condition_events
    end
end

local function toggle_event(event, event_type)
    char_settings[event_type][event.name] = not char_settings[event_type][event.name]
    save_character_settings()
end

local function save_event()
    local event_type = state.ui.editor.event_type
    local add_event = state.inputs.add_event
    if event_type == events.types.text and add_event.pattern:len() == 0 then return end

    local event_list = get_event_list(event_type)
    local original_event = event_list[add_event.name]
    -- per character enabled flag currently in use instead of dynamic load options
    if original_event and not events.changed(original_event, add_event) and not buffer.dirty then
        -- code and pattern did not change
        if add_event.enabled ~= char_settings[event_type][add_event.name] then
            -- just enabling or disabling the event
            toggle_event(original_event, event_type)
        end
    else
    --if original_event and events.changed(original_event, add_event) then
        local new_event = {name=add_event.name,category=add_event.category,}
        new_event.load = {always=add_event.load.always, characters=add_event.load.characters, class=add_event.load.class, zone=add_event.load.zone,}
        if event_type == events.types.text then
            new_event.pattern = add_event.pattern
            new_event.singlecommand = add_event.singlecommand
            new_event.command = add_event.command
        end
        if state.ui.editor.action == actions.edit or (state.ui.editor.action == actions.import and event_list[add_event.name] ~= nil) then
            -- replacing event, disable then unload it first before it is saved
            char_settings[event_type][add_event.name] = nil
            if event_type == events.types.text then mq.unevent(add_event.name) end
            events.unload_package(add_event.name, event_type)
        end
        if not buffer.filePath:find(add_event.name) then
            local filename = events.filename(add_event.name, event_type)
            local tmpTxt = buffer:GetText()
            buffer:Load(filename)
            buffer:SetText(tmpTxt)
        end
        buffer:Save()
        event_list[add_event.name] = new_event
        save_settings()
        char_settings[event_type][add_event.name] = add_event.enabled
        save_character_settings()
        first_load = true -- so event list re-sorts with new event included
    end
    state.ui.editor.open_ui = false
end

local function drawEditor()
    local footerHeight = 0
    local contentSizeX, contentSizeY = ImGui.GetContentRegionAvail()
    contentSizeY = contentSizeY - footerHeight

    editor:Render(ImVec2(contentSizeX, contentSizeY))
end

local function draw_event_editor_general(add_event)
    add_event.name,_ = ImGui.InputText('Event Name', add_event.name)
    if ImGui.BeginCombo('Category', add_event.category or '') then
        for _,j in pairs(categories) do
            if ImGui.Selectable(j.name, j.name == add_event.category) then
                add_event.category = j.name
            end
            for _,k in pairs(j.children) do
                if ImGui.Selectable('- '..k.name, k.name == add_event.category) then
                    add_event.category = k.name
                end
            end
        end
        ImGui.EndCombo()
    end
    -- per character enabled flag currently in use instead of dynamic load options
    add_event.enabled,_ = ImGui.Checkbox('Event Enabled', add_event.enabled)
    if state.ui.editor.event_type == events.types.text then
        add_event.pattern,_ = ImGui.InputText('Event Pattern', add_event.pattern)
        add_event.singlecommand = ImGui.Checkbox('Single Command Action', add_event.singlecommand)
        if add_event.singlecommand then
            local changed = false
            add_event.command,changed = ImGui.InputText('Command', add_event.command)
            if changed then
                buffer:SetText(templates.command_base:format(add_event.command))
            end
        end
    end
    if ImGui.BeginCombo('Code Templates', state.ui.editor.template or '') then
        for _,template in ipairs(templates.files) do
            if ImGui.Selectable(template, state.ui.editor.template == template) then
                state.ui.editor.template = template
            end
        end
        ImGui.EndCombo()
    end
    local buttons_active = true
    if state.ui.editor.template == '' then
        ImGui.PushStyleColor(ImGuiCol.Button, .3, 0, 0,1)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, .3, 0, 0,1)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, .3, 0, 0,1)
        buttons_active = false
    end
    if ImGui.Button('Load Template') and state.ui.editor.template ~= '' then
        buffer:SetText(events.read_event_file(templates.filename(state.ui.editor.template)))
    end
    if not buttons_active then
        ImGui.PopStyleColor(3)
    end
    ImGui.SameLine()
    ImGui.TextColored(1, 0, 0, 1, 'This will OVERWRITE the existing event code')
    if not add_event.singlecommand then
        ImGui.NewLine()
        if show_code then
            ImGui.PushStyleColor(ImGuiCol.Text, ImVec4(0,1,0,1))
            ImGui.Text(icons.FA_TOGGLE_ON)
        else
            ImGui.PushStyleColor(ImGuiCol.Text, ImVec4(1,0,0,1))
            ImGui.Text(icons.FA_TOGGLE_OFF)
        end
        if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Left) then
            show_code = not show_code
        end
        ImGui.PopStyleColor()
        ImGui.SameLine()
        ImGui.Text('Show Code')
        if show_code then
            local x, y = ImGui.GetContentRegionAvail()
            drawEditor()
        end
    end
end

local function draw_event_editor_load(add_event)
    ImGui.TextColored(1, 1, 0, 1, '>>> UNDER CONSTRUCTION - NOT IN USE <<<')
    add_event.load.always = ImGui.Checkbox('Always', add_event.load.always)
    add_event.load.zone,_ = ImGui.InputText('Zone Shortname', add_event.load.zone)
    add_event.load.class,_ = ImGui.InputText('Classes', add_event.load.class)
    add_event.load.character,_ = ImGui.InputText('Characters', add_event.load.characters)
end

local CONDITION_SNIPPETS = {
    {label='Low HP Self', expr='mq.TLO.Me.PctHPs() < 40'},
    {label='Need Mana', expr='mq.TLO.Me.PctMana() < 25'},
    {label='Has XTarget Aggro', expr='mq.TLO.Me.XTarget() > 0'},
    {label='Target In Range', expr='mq.TLO.Target.ID() ~= nil and mq.TLO.Target.Distance3D() <= 25'},
    {label='Named Target', expr='mq.TLO.Target.ID() ~= nil and mq.TLO.Target.Named()'},
    {label='Out Of Combat', expr='not mq.TLO.Me.InCombat()'},
    {label='Can Cast', expr='not mq.TLO.Me.Casting() and not mq.TLO.Me.Moving()'},
    {label='Any Group Injured', expr='mq.TLO.Group.Injured(70)() > 0'},
}

local LAB_BASES = {
    {label='Me.PctHPs()', lhs='mq.TLO.Me.PctHPs()'},
    {label='Me.PctMana()', lhs='mq.TLO.Me.PctMana()'},
    {label='Me.PctEndurance()', lhs='mq.TLO.Me.PctEndurance()'},
    {label='Me.XTarget()', lhs='mq.TLO.Me.XTarget()'},
    {label='Me.InCombat()', lhs='mq.TLO.Me.InCombat()'},
    {label='Me.Buff("name")', lhs='mq.TLO.Me.Buff(%q)() ~= nil', needsText=true, textHint='Credence'},
    {label='Target.ID()', lhs='mq.TLO.Target.ID()'},
    {label='Target.PctHPs()', lhs='mq.TLO.Target.PctHPs()'},
    {label='Target.Distance3D()', lhs='mq.TLO.Target.Distance3D()'},
    {label='Target.Named()', lhs='mq.TLO.Target.Named()'},
    {label='SpawnCount("query")', lhs='mq.TLO.SpawnCount(%q)()', needsText=true, textHint='npc radius 80'},
    {label='Group.Injured(%%)', lhs='mq.TLO.Group.Injured(%s)()', needsText=true, textHint='70'},
    {label='Custom', lhs='', custom=true},
}

local LAB_OPS = {
    {label='==', kind='binary', symbol='=='},
    {label='~=', kind='binary', symbol='~='},
    {label='>', kind='binary', symbol='>'},
    {label='<', kind='binary', symbol='<'},
    {label='>=', kind='binary', symbol='>='},
    {label='<=', kind='binary', symbol='<='},
    {label='Truthy', kind='truthy'},
    {label='Falsy', kind='falsy'},
}

local LAB_VALUE_TYPES = {
    {label='Number', id='number'},
    {label='String', id='string'},
    {label='Boolean', id='bool'},
    {label='Raw', id='raw'},
    {label='nil', id='nil'},
}

local WATCH_DEFS = {
    {label='Me.PctHPs()', fn=function() return tostring(mq.TLO.Me.PctHPs()) end},
    {label='Me.PctMana()', fn=function() return tostring(mq.TLO.Me.PctMana()) end},
    {label='Me.InCombat()', fn=function() return tostring(mq.TLO.Me.InCombat()) end},
    {label='Me.Casting()', fn=function() return tostring(mq.TLO.Me.Casting()) end},
    {label='Target.ID()', fn=function() return tostring(mq.TLO.Target.ID()) end},
    {label='Target.Distance3D()', fn=function() return tostring(mq.TLO.Target.Distance3D()) end},
    {label='Target.Named()', fn=function() return tostring(mq.TLO.Target.Named()) end},
    {label='Group.Injured(70)()', fn=function() return tostring(mq.TLO.Group.Injured(70)()) end},
    {label='XTarget()', fn=function() return tostring(mq.TLO.Me.XTarget()) end},
}

local function trim(s)
    return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function labSavesTable()
    settings.settings = settings.settings or {}
    settings.settings.condition_lab_saves = settings.settings.condition_lab_saves or {}
    return settings.settings.condition_lab_saves
end

local function labHistoryPush(lab, expr)
    local e = trim(expr)
    if e == '' then return end
    lab.history = lab.history or {}
    for i, h in ipairs(lab.history) do
        if h == e then
            table.remove(lab.history, i)
            break
        end
    end
    table.insert(lab.history, 1, e)
    while #lab.history > 30 do
        table.remove(lab.history)
    end
end

local function validate_condition_expression(expr)
    expr = trim(expr)
    if expr == '' then
        return false, {'Expression is empty.'}, {}
    end
    local errs, warns = {}, {}
    local depth = 0
    for c in expr:gmatch('.') do
        if c == '(' then depth = depth + 1 end
        if c == ')' then depth = depth - 1 end
        if depth < 0 then
            errs[#errs + 1] = 'Too many closing parentheses.'
            depth = 0
        end
    end
    if depth > 0 then errs[#errs + 1] = string.format('Missing %d closing parenthesis.', depth) end
    if expr:match('^%s*and%s') or expr:match('^%s*or%s') then
        errs[#errs + 1] = 'Expression starts with logical operator.'
    end
    if expr:match('%sand%s*$') or expr:match('%sor%s*$') then
        errs[#errs + 1] = 'Expression ends with logical operator.'
    end
    local chunk, err = load('return ('..expr..')', 'lem_cond_validate', 't', {mq=mq, math=math, string=string, tonumber=tonumber, tostring=tostring, pairs=pairs, ipairs=ipairs})
    if not chunk then errs[#errs + 1] = tostring(err) end
    if not expr:find('mq%.TLO%.', 1, false) and not expr:find('%$%{', 1, false) then
        warns[#warns + 1] = 'No mq.TLO or ${} token found.'
    end
    return #errs == 0, errs, warns
end

local function evaluate_condition_expression(expr)
    expr = trim(expr)
    if expr == '' then return false, 'empty expression' end
    if expr:find('%$%{', 1, false) then
        local probe = '${If['..expr..',TRUE,FALSE]}'
        local ok, out = pcall(mq.parse, probe)
        if not ok then return false, tostring(out) end
        return true, tostring(out)
    end
    local chunk, err = load('return ('..expr..')', 'lem_cond_eval', 't', {mq=mq, math=math, string=string, tonumber=tonumber, tostring=tostring, pairs=pairs, ipairs=ipairs})
    if not chunk then return false, tostring(err) end
    local ran, result = pcall(chunk)
    if not ran then return false, tostring(result) end
    return true, tostring(result)
end

local function normalize_piece_value(lab)
    local vt = (LAB_VALUE_TYPES[lab.value_type] and LAB_VALUE_TYPES[lab.value_type].id) or 'raw'
    local raw = tostring(lab.value_input or '')
    if vt == 'number' then return tostring(tonumber(raw) or 0) end
    if vt == 'string' then return string.format('%q', raw) end
    if vt == 'bool' then
        local l = raw:lower()
        if l == 'true' or l == '1' or l == 'on' then return 'true' end
        return 'false'
    end
    if vt == 'nil' then return 'nil' end
    return raw
end

local function current_piece_lhs(lab)
    local base = LAB_BASES[lab.base_idx]
    if not base then return '' end
    if base.custom then return tostring(lab.custom_lhs or '') end
    if base.needsText then
        local txt = tostring(lab.extra_text or '')
        if base.lhs:find('%%q', 1, true) then
            return string.format(base.lhs, txt)
        end
        return string.format(base.lhs, txt)
    end
    return base.lhs
end

local function build_piece(lab)
    local lhs = current_piece_lhs(lab)
    local op = LAB_OPS[lab.op_idx]
    if lhs == '' or not op then return '' end
    if op.kind == 'truthy' then return '('..lhs..')' end
    if op.kind == 'falsy' then return 'not ('..lhs..')' end
    return string.format('(%s %s %s)', lhs, op.symbol, normalize_piece_value(lab))
end

local function build_condition_event_code(expr, actionCmd)
    local actionBody
    if actionCmd and actionCmd ~= '' then
        actionBody = string.format("    mq.cmd(%q)", actionCmd)
    else
        actionBody = "    -- Implement the action to perform here."
    end
    return table.concat({
        "local mq = require('mq')",
        "-- Do not edit this if condition",
        "if not package.loaded['events'] then",
        "    print('This script is intended to be imported to Lua Event Manager (LEM). Try \"\\a-t/lua run lem\\a-x\"')",
        "end",
        "",
        "local function on_load()",
        "    -- Perform any initial setup here when the event is loaded.",
        "end",
        "",
        "---@return boolean @Returns true if the action should fire, otherwise false.",
        "local function condition()",
        "    return ("..expr..")",
        "end",
        "",
        "local function action()",
        actionBody,
        "end",
        "",
        "return {onload=on_load, condfunc=condition, actionfunc=action}",
    }, "\n")
end

local function ensure_lab_defaults()
    local lab = state.inputs.cond_lab
    lab.expression = lab.expression or 'mq.TLO.Me.XTarget() > 0'
    lab.action_cmd = lab.action_cmd or ''
    lab.last_validate_ok = lab.last_validate_ok
    lab.last_validate_msg = lab.last_validate_msg or ''
    lab.last_eval_ok = lab.last_eval_ok
    lab.last_eval_msg = lab.last_eval_msg or ''
    lab.snippet_idx = lab.snippet_idx or 1
    lab.base_idx = lab.base_idx or 1
    lab.op_idx = lab.op_idx or 1
    lab.value_type = lab.value_type or 1
    lab.value_input = lab.value_input or ''
    lab.custom_lhs = lab.custom_lhs or ''
    lab.extra_text = lab.extra_text or ''
    lab.preview = lab.preview or ''
    lab.history = lab.history or {}
    lab.save_name = lab.save_name or ''
    lab.save_tag = lab.save_tag or ''
    lab.timer_running = lab.timer_running or false
    lab.timer_ms = lab.timer_ms or 500
    lab.timer_last = lab.timer_last or 0
    lab.timer_ticks = lab.timer_ticks or 0
    lab.eval_log = lab.eval_log or {}
end

local function lab_log(lab, msg)
    table.insert(lab.eval_log, 1, msg)
    while #lab.eval_log > 50 do table.remove(lab.eval_log) end
end

local function run_lab_eval_once(lab)
    local ok, out = evaluate_condition_expression(lab.expression)
    lab.last_eval_ok = ok
    lab.last_eval_msg = out
    lab_log(lab, string.format('[%s] %s', os.date('%H:%M:%S'), tostring(out)))
    return ok, out
end

local function condition_lab_tick()
    local lab = state.inputs.cond_lab
    if not lab or not lab.timer_running then return end
    local now = mq.gettime()
    if (now - (lab.timer_last or 0)) >= (tonumber(lab.timer_ms) or 500) then
        lab.timer_last = now
        lab.timer_ticks = (lab.timer_ticks or 0) + 1
        run_lab_eval_once(lab)
    end
end

local function draw_condition_lab()
    ensure_lab_defaults()
    local lab = state.inputs.cond_lab
    ImGui.TextColored(0, 1, 1, 1, 'Condition Lab')
    ImGui.TextWrapped('ConditionBuilder-grade tools inside LEM: piece build, live test, watch panel, saves, and event code generation.')
    lab.expression,_ = ImGui.InputTextMultiline('Expression', lab.expression or '', 0, 88)
    lab.action_cmd,_ = ImGui.InputText('Action Command (optional)', lab.action_cmd or '')

    if ImGui.BeginCombo('Snippet', CONDITION_SNIPPETS[lab.snippet_idx].label) then
        for i, s in ipairs(CONDITION_SNIPPETS) do
            if ImGui.Selectable(s.label, i == lab.snippet_idx) then
                lab.snippet_idx = i
            end
        end
        ImGui.EndCombo()
    end
    if ImGui.Button('Use Snippet') then
        lab.expression = CONDITION_SNIPPETS[lab.snippet_idx].expr
    end
    ImGui.SameLine()
    if ImGui.Button('To Expression') then
        local s = CONDITION_SNIPPETS[lab.snippet_idx].expr
        lab.expression = (trim(lab.expression) == '' and s) or (lab.expression .. ' and ' .. s)
    end
    ImGui.SameLine()
    if ImGui.Button('Validate') then
        local ok, errs, warns = validate_condition_expression(lab.expression)
        lab.last_validate_ok = ok
        if ok then
            if #warns > 0 then
                lab.last_validate_msg = table.concat(warns, ' | ')
            else
                lab.last_validate_msg = 'Expression valid.'
            end
        else
            lab.last_validate_msg = table.concat(errs, ' | ')
        end
        labHistoryPush(lab, lab.expression)
    end
    ImGui.SameLine()
    if ImGui.Button('Evaluate Now') then
        run_lab_eval_once(lab)
        labHistoryPush(lab, lab.expression)
    end
    ImGui.SameLine()
    if ImGui.Button('Generate Event Code') then
        local ok, _, _ = validate_condition_expression(lab.expression)
        if ok then
            buffer:SetText(build_condition_event_code(lab.expression, lab.action_cmd))
            show_code = true
        else
            local ok2, errs2, warns2 = validate_condition_expression(lab.expression)
            lab.last_validate_ok = ok2
            lab.last_validate_msg = table.concat(ok2 and warns2 or errs2, ' | ')
        end
    end

    ImGui.Separator()
    ImGui.TextDisabled('Piece Builder')
    if ImGui.BeginCombo('Base', LAB_BASES[lab.base_idx].label) then
        for i, b in ipairs(LAB_BASES) do
            if ImGui.Selectable(b.label, i == lab.base_idx) then lab.base_idx = i end
        end
        ImGui.EndCombo()
    end
    local base = LAB_BASES[lab.base_idx]
    if base.custom then
        lab.custom_lhs,_ = ImGui.InputText('Custom LHS', lab.custom_lhs)
    elseif base.needsText then
        lab.extra_text,_ = ImGui.InputText('Text/Query', lab.extra_text)
        ImGui.SameLine()
        ImGui.TextDisabled(base.textHint or '')
    end
    if ImGui.BeginCombo('Operator', LAB_OPS[lab.op_idx].label) then
        for i, o in ipairs(LAB_OPS) do
            if ImGui.Selectable(o.label, i == lab.op_idx) then lab.op_idx = i end
        end
        ImGui.EndCombo()
    end
    local op = LAB_OPS[lab.op_idx]
    if op.kind == 'binary' then
        if ImGui.BeginCombo('Value Type', LAB_VALUE_TYPES[lab.value_type].label) then
            for i, vt in ipairs(LAB_VALUE_TYPES) do
                if ImGui.Selectable(vt.label, i == lab.value_type) then lab.value_type = i end
            end
            ImGui.EndCombo()
        end
        lab.value_input,_ = ImGui.InputText('Value', lab.value_input)
    end
    lab.preview = build_piece(lab)
    ImGui.TextColored(0.72, 0.95, 1.00, 1.0, 'Preview: %s', lab.preview ~= '' and lab.preview or '<empty>')
    if ImGui.Button('Add Piece') then
        if lab.preview ~= '' then
            lab.expression = (trim(lab.expression) == '' and lab.preview) or (lab.expression .. ' and ' .. lab.preview)
        end
    end
    ImGui.SameLine()
    if ImGui.Button('(') then lab.expression = lab.expression .. '(' end
    ImGui.SameLine()
    if ImGui.Button(')') then lab.expression = lab.expression .. ')' end
    ImGui.SameLine()
    if ImGui.Button('AND') then lab.expression = lab.expression .. ' and ' end
    ImGui.SameLine()
    if ImGui.Button('OR') then lab.expression = lab.expression .. ' or ' end
    ImGui.SameLine()
    if ImGui.Button('NOT') then lab.expression = lab.expression .. ' not ' end

    if lab.last_validate_ok ~= nil then
        if lab.last_validate_ok then
            ImGui.TextColored(0.25, 1.0, 0.35, 1.0, 'Validate: %s', tostring(lab.last_validate_msg))
        else
            ImGui.TextColored(1.0, 0.35, 0.35, 1.0, 'Validate: %s', tostring(lab.last_validate_msg))
        end
    end
    if lab.last_eval_ok ~= nil then
        if lab.last_eval_ok then
            ImGui.TextColored(0.35, 0.9, 1.0, 1.0, 'Eval Result: %s', tostring(lab.last_eval_msg))
        else
            ImGui.TextColored(1.0, 0.35, 0.35, 1.0, 'Eval Error: %s', tostring(lab.last_eval_msg))
        end
    end

    ImGui.Separator()
    ImGui.TextDisabled('Live Tester')
    if lab.timer_running then
        if ImGui.Button('Stop Timer') then lab.timer_running = false end
    else
        if ImGui.Button('Start Timer') then
            lab.timer_running = true
            lab.timer_last = mq.gettime()
            lab.timer_ticks = 0
        end
    end
    ImGui.SameLine()
    local tms, tc = ImGui.InputInt('Interval ms', tonumber(lab.timer_ms) or 500)
    if tc then lab.timer_ms = math.max(100, tms) end
    ImGui.SameLine()
    if ImGui.Button('Clear Log') then lab.eval_log = {} end
    if lab.timer_running then
        ImGui.SameLine()
        ImGui.TextColored(0.25, 1.0, 0.35, 1.0, 'RUNNING #%d', tonumber(lab.timer_ticks) or 0)
    end

    if #lab.eval_log > 0 then
        ImGui.InputTextMultiline('##eval_log', table.concat(lab.eval_log, '\n'), -1, 70, ImGuiInputTextFlags.ReadOnly)
    end

    ImGui.TextDisabled('Watch')
    for _, w in ipairs(WATCH_DEFS) do
        local ok, val = pcall(w.fn)
        ImGui.Text(w.label)
        ImGui.SameLine(220)
        if ok then
            ImGui.TextColored(0.94, 0.53, 0.24, 1.0, tostring(val))
        else
            ImGui.TextColored(1.0, 0.35, 0.35, 1.0, 'ERR')
        end
    end

    ImGui.Separator()
    ImGui.TextDisabled('Saved Conditions')
    local saveNameChanged
    lab.save_name, saveNameChanged = ImGui.InputText('Name', lab.save_name)
    if saveNameChanged then lab.save_name = trim(lab.save_name) end
    lab.save_tag,_ = ImGui.InputText('Tag', lab.save_tag)
    if ImGui.Button('Save Condition') then
        local name = trim(lab.save_name)
        local expr = trim(lab.expression)
        if name ~= '' and expr ~= '' then
            local saves = labSavesTable()
            saves[name] = {expr = expr, tag = tostring(lab.save_tag or '')}
            save_settings()
            lab.last_validate_ok = true
            lab.last_validate_msg = string.format('Saved condition "%s".', name)
        end
    end
    local saves = labSavesTable()
    for name, entry in pairs(saves) do
        ImGui.TextColored(0.72, 0.95, 1.00, 1.0, name)
        if entry.tag and entry.tag ~= '' then
            ImGui.SameLine()
            ImGui.TextDisabled('['..entry.tag..']')
        end
        ImGui.SameLine(280)
        if ImGui.SmallButton('Load##'..name) then
            lab.expression = tostring(entry.expr or '')
            lab.save_name = name
            lab.save_tag = tostring(entry.tag or '')
        end
        ImGui.SameLine()
        if ImGui.SmallButton('Del##'..name) then
            saves[name] = nil
            save_settings()
        end
        ImGui.TextDisabled(tostring(entry.expr or ''):sub(1, 96))
    end

    if lab.history and #lab.history > 0 then
        ImGui.Separator()
        ImGui.TextDisabled('History')
        for i, h in ipairs(lab.history) do
            local short = (#h > 100) and (h:sub(1, 97) .. '...') or h
            if ImGui.Selectable(string.format('[%d] %s', i, short), false) then
                lab.expression = h
            end
        end
    end
end

local function draw_event_editor()
    if not state.ui.editor.open_ui then return end
    local title = 'Event Editor###lemeditor'
    if state.ui.editor.action == actions.add then
        title = 'Add Event###lemeditor'
    elseif state.ui.editor.action == actions.import then
        title = 'Import Event###lemeditor'
    end
    state.ui.editor.open_ui, state.ui.editor.draw_ui = ImGui.Begin(title, state.ui.editor.open_ui)
    if state.ui.editor.draw_ui then
        if ImGui.Button('Save') then
            save_event()
        end
        local add_event = state.inputs.add_event
        local event_type = state.ui.editor.event_type
        local event_list = get_event_list(event_type)
        if state.ui.editor.action == actions.import and event_list[add_event.name] ~= nil then
            ImGui.SameLine()
            ImGui.TextColored(1, 0, 0, 1, '(Overwrite existing)')
        end
        if ImGui.BeginTabBar('EventTabs') then
            if ImGui.BeginTabItem('General') then
                draw_event_editor_general(add_event)
                ImGui.EndTabItem()
            end
            if state.ui.editor.event_type == events.types.cond and ImGui.BeginTabItem('Condition Lab') then
                draw_condition_lab()
                ImGui.EndTabItem()
            end
            --[[if ImGui.BeginTabItem('Load') then
                draw_event_editor_load(add_event)
                ImGui.EndTabItem()
            end]]
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
end

local function draw_import_window()
    if ImGui.Button('Import Event') then
        local imported_event = events.import(state.inputs.import, categories)
        if imported_event then
            set_editor_state(true, actions.import, imported_event.type, nil)
            set_add_event_inputs(imported_event)
            buffer:Load(events.filename(imported_event.name, imported_event.type))
            buffer:SetText(imported_event.code)
            state.inputs.import = ''
        end
    end
    ImGui.SameLine()
    if ImGui.Button('Paste from clipboard') then
        state.inputs.import = ImGui.GetClipboardText()
    end
    state.inputs.import = ImGui.InputText('##importeventtext', state.inputs.import)
    local width = ImGui.GetContentRegionAvail()
    ImGui.PushTextWrapPos(width-15)
    ImGui.Text('Paste base64 encoded string data (it will look like a very long, random string of letters and numbers)')
    ImGui.PopTextWrapPos()
end

local function draw_event_viewer_general(event)
    local width = ImGui.GetContentRegionAvail()
    ImGui.PushTextWrapPos(width-15)
    if ImGui.Button('Edit Event') then
        buffer:Load(events.filename(event.name, state.ui.editor.event_type))
        state.ui.editor.action = actions.edit
        buffer.readonly = false
        set_add_event_inputs(event)
    end
    ImGui.SameLine()
    if ImGui.Button('Edit In VS Code') then
        os.execute('start "" "'..events.filename(event.name, state.ui.editor.event_type)..'"')
    end
    ImGui.SameLine()
    if ImGui.Button('Export Event') then
        ImGui.SetClipboardText(events.export(event, state.ui.editor.event_type))
    end
    ImGui.SameLine()
    if ImGui.Button('Reload Source') then
        buffer:Load(events.filename(event.name, state.ui.editor.event_type))
        events.reload(event, state.ui.editor.event_type)
    end
    if event.failed then
        ImGui.TextColored(1, 0, 0, 1, 'ERROR: Event failed to load!')
    end
    ImGui.TextColored(1, 1, 0, 1, 'Name: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(100)
    -- per character enabled flag currently in use instead of dynamic load options
    if char_settings[state.ui.editor.event_type][event.name] then
    --if event.loaded then
        ImGui.TextColored(0, 1, 0, 1, event.name)
    else
        ImGui.TextColored(1, 0, 0, 1, event.name .. ' (Disabled)')
    end
    ImGui.TextColored(1, 1, 0, 1, 'Category: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(100)
    ImGui.Text(event.category or '')
    if state.ui.editor.event_type == events.types.text then
        ImGui.TextColored(1, 1, 0, 1, 'Pattern: ')
        ImGui.SameLine()
        ImGui.SetCursorPosX(100)
        ImGui.TextColored(1, 0, 1, 1, '%s', event.pattern)
        if event.singlecommand then
            ImGui.TextColored(1, 1, 0, 1, 'Command: ')
            ImGui.SameLine()
            ImGui.SetCursorPosX(100)
            ImGui.TextColored(1, 0, 1, 1, '%s', event.command or '')
        end
    end
    if show_code then
        ImGui.PushStyleColor(ImGuiCol.Text, ImVec4(0,1,0,1))
        ImGui.Text(icons.FA_TOGGLE_ON)
    else
        ImGui.PushStyleColor(ImGuiCol.Text, ImVec4(1,0,0,1))
        ImGui.Text(icons.FA_TOGGLE_OFF)
    end
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Left) then
        show_code = not show_code
    end
    ImGui.PopStyleColor()
    ImGui.SameLine()
    ImGui.Text('Show Code')
    if show_code then
        drawEditor()
    end
end

local function draw_event_viewer_load(event)
    ImGui.TextColored(1, 1, 0, 1, '>>> UNDER CONSTRUCTION - NOT IN USE <<<')
    ImGui.TextColored(1, 1, 0, 1, 'Always: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(125)
    ImGui.Text(('%s'):format(event.load.always))
    ImGui.TextColored(1, 1, 0, 1, 'Zone Shortname: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(125)
    ImGui.Text(event.load.zone)
    ImGui.TextColored(1, 1, 0, 1, 'Classes: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(125)
    ImGui.Text(event.load.class)
    ImGui.TextColored(1, 1, 0, 1, 'Characters: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(125)
    ImGui.Text(event.load.characters)
end

local function draw_event_viewer()
    if not state.ui.editor.open_ui then return end
    state.ui.editor.open_ui, state.ui.editor.draw_ui = ImGui.Begin('Event Viewer###lemeditor', state.ui.editor.open_ui)
    local event_list = get_event_list(state.ui.editor.event_type)
    local event = event_list[state.ui.editor.event_idx]
    if state.ui.editor.draw_ui and event then
        if ImGui.BeginTabBar('EventViewer') then
            if ImGui.BeginTabItem('General') then
                draw_event_viewer_general(event)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Load') then
                draw_event_viewer_load(event)
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
end

local function draw_event_control_buttons(event_type)
    local event_list = get_event_list(event_type)
    if ImGui.Button('Add Event...') then
        set_editor_state(true, actions.add, event_type, nil)
        reset_add_event_inputs(event_type)
        buffer.readonly = false
        buffer.syntax = 'lua'
    end
    local buttons_active = true
    if not state.ui.main.event_idx then
        ImGui.PushStyleColor(ImGuiCol.Button, .3, 0, 0,1)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, .3, 0, 0,1)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, .3, 0, 0,1)
        buttons_active = false
    end
    local event = event_list[state.ui.main.event_idx]
    ImGui.SameLine()
    if ImGui.Button('View Event') and state.ui.main.event_idx and event then
        set_editor_state(true, actions.view, event_type, state.ui.main.event_idx)
        buffer.readonly = true
        buffer:Load(events.filename(event.name, state.ui.editor.event_type))
    end
    ImGui.SameLine()
    if ImGui.Button('Edit Event') and state.ui.main.event_idx and event then
        set_editor_state(true, actions.edit, event_type, state.ui.main.event_idx)
        buffer.readonly = false
        buffer:Load(events.filename(event.name, event_type))
        set_add_event_inputs(event)
    end
    ImGui.SameLine()
    if ImGui.Button('Remove Event') and state.ui.main.event_idx and event then
        event_list[event.name] = nil
        if event_type == events.types.text and char_settings[event_type][event.name] then
            mq.unevent(event.name)
        end
        char_settings[event_type][event.name] = nil
        events.unload_package(event.name, event_type)
        state.ui.main.event_idx = nil
        events.delete_event_file(events.filename(event.name, event_type))
        save_settings()
        save_character_settings()
        set_editor_state(false, nil, nil, nil)
        state.ui.main.dirty = true
    end
    if not buttons_active then
        ImGui.PopStyleColor(3)
    end
end

local function draw_event_table_context_menu(event, event_type)
    if ImGui.BeginPopupContextItem() then
        if ImGui.MenuItem('Export') then
            ImGui.SetClipboardText(events.export(event, event_type))
        end
        if ImGui.MenuItem('Edit in VS Code') then
            os.execute('start "" "'..events.filename(event.name, event_type)..'"')
        end
        if ImGui.MenuItem('Reload Source') then
            buffer:Load(events.filename(event.name, event_type))
            events.reload(event, event_type)
        end
        local event_enabled = char_settings[event_type][event.name] or false
        local enable_prefix = event_enabled and 'Disable' or 'Enable'
        local action = event_enabled and '0' or '1'
        local type_singular = event_type == 'events' and 'event' or 'cond'
        if ImGui.MenuItem(enable_prefix..' For All') then
            mq.cmdf('/dga /lem %s "%s" %s', type_singular, event.name, action)
        end
        if ImGui.MenuItem(enable_prefix..' For Raid') then
            mq.cmdf('/dgra /lem %s "%s" %s', type_singular, event.name, action)
        end
        if ImGui.MenuItem(enable_prefix..' For Group') then
            mq.cmdf('/dgga /lem %s "%s" %s', type_singular, event.name, action)
        end
        if ImGui.MenuItem('DEBUG: Run event script') then
            mq.cmdf('/lua run "lem/%s/%s"', event_type, event.name)
        end
        ImGui.EndPopup()
    end
end

local function draw_event_table_row(event, event_type)
    -- per character enabled flag currently in use instead of dynamic load options
    local enabled = ImGui.Checkbox('##'..event.name, char_settings[event_type][event.name] or false)
    if enabled ~= (char_settings[event_type][event.name] or false) then
        toggle_event(event, event_type)
    end
    ImGui.TableNextColumn()
    local row_label = event.name
    -- per character enabled flag currently in use instead of dynamic load options
    if char_settings[event_type][event.name] and not event.failed then
    --if event.loaded then
        ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
    else
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
        if event.failed then
            row_label = row_label .. ' (Failed to load)'
        end
    end
    if ImGui.Selectable(row_label, state.ui.main.event_idx == event.name, ImGuiSelectableFlags.SpanAllColumns) then
        if state.ui.main.event_idx ~= event.name then
            state.ui.main.event_idx = event.name
        end
    end
    if ImGui.IsItemHovered() and ImGui.IsMouseDoubleClicked(0) then
        set_editor_state(true, actions.view, event_type, event.name)
        buffer.readonly = true
        buffer:Load(events.filename(event.name, state.ui.editor.event_type))
    end
    ImGui.PopStyleColor()
    draw_event_table_context_menu(event, event_type)
end

local ColumnID_OnOff = 1
local ColumnID_Name = 2
local current_sort_specs = nil
local sort_event_type = nil
local function CompareWithSortSpecs(a, b)
    for n = 1, current_sort_specs.SpecsCount, 1 do
        -- Here we identify columns using the ColumnUserID value that we ourselves passed to TableSetupColumn()
        -- We could also choose to identify columns based on their index (sort_spec.ColumnIndex), which is simpler!
        local sort_spec = current_sort_specs:Specs(n)
        local delta = 0

        local sortA = a
        local sortB = b
        if sort_spec.ColumnUserID == ColumnID_OnOff then
            sortA = char_settings[sort_event_type][a.name] or false
            sortB = char_settings[sort_event_type][b.name] or false
            if sort_spec.SortDirection == ImGuiSortDirection.Ascending then
                --return sortA == true and sortB == false or a.name < b.name
                return sortA and a.name < b.name
            else
                --return sortB == true and sortA == false or b.name < a.name
                return sortB and b.name < a.name
            end
        elseif sort_spec.ColumnUserID == ColumnID_Name then
            sortA = a.name
            sortB = b.name
        end
        if sortA < sortB then
            delta = -1
        elseif sortB < sortA then
            delta = 1
        else
            delta = 0
        end

        if delta ~= 0 then
            if sort_spec.SortDirection == ImGuiSortDirection.Ascending then
                return delta < 0
            end
            return delta > 0
        end
    end

    -- Always return a way to differentiate items.
    -- Your own compare function may want to avoid fallback on implicit sort specs e.g. a Name compare if it wasn't already part of the sort specs.
    return a.name < b.name
end

local function draw_events_table(event_type)
    local event_list = get_event_list(event_type)
    local new_filter,_ = ImGui.InputTextWithHint('##tablefilter', 'Filter...', state.ui.main.filter, 0)
    if new_filter ~= state.ui.main.filter or state.ui.main.dirty then
        state.ui.main.filter = new_filter:lower()
        filtered_events = {}
        sortable_events = {}
        first_load = true
        for event_name,event in pairs(event_list) do
            if event_name:lower():find(state.ui.main.filter) then
                filtered_events[event_name] = event
            end
        end
    end
    if ImGui.BeginTable('EventTable', 2, table_flags, 0, 0, 0.0) then
        local column_label = 'Event Name'
        ImGui.TableSetupColumn('On/Off', ImGuiTableColumnFlags.DefaultSort, 1, ColumnID_OnOff)
        ImGui.TableSetupColumn(column_label,     ImGuiTableColumnFlags.DefaultSort,   3, ColumnID_Name)
        ImGui.TableSetupScrollFreeze(0, 1) -- Make row always visible
        ImGui.TableHeadersRow()

        local sort_specs = ImGui.TableGetSortSpecs()
        if sort_specs then
            if sort_specs.SpecsDirty or first_load then
                first_load = false
                sortable_events = {}
                if state.ui.main.filter ~= '' then
                    for _,event in pairs(filtered_events) do
                        table.insert(sortable_events, event)
                    end
                else
                    for _,event in pairs(event_list) do
                        table.insert(sortable_events, event)
                    end
                end
                current_sort_specs = sort_specs
                sort_event_type = event_type
                table.sort(sortable_events, CompareWithSortSpecs)
                sort_event_type = nil
                current_sort_specs = nil
                sort_specs.SpecsDirty = false
            end
        end

        if state.ui.main.filter ~= '' then
            for _,event in pairs(sortable_events) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                draw_event_table_row(event, event_type)
            end
        else
            for _,category in ipairs(categories) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local open = ImGui.TreeNodeEx(category.name, ImGuiTreeNodeFlags.SpanFullWidth)
                ImGui.TableNextColumn()
                if open then
                    for _,subcategory in ipairs(category.children) do
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        local subopen = ImGui.TreeNodeEx(subcategory.name, ImGuiTreeNodeFlags.SpanFullWidth)
                        ImGui.TableNextColumn()
                        if subopen then
                            for _,event in pairs(sortable_events) do
                                if event.category == subcategory.name then
                                    ImGui.TableNextRow()
                                    ImGui.TableNextColumn()
                                    draw_event_table_row(event, event_type)
                                end
                            end
                            ImGui.TreePop()
                        end
                    end
                    for _,event in pairs(sortable_events) do
                        if event.category == category.name then
                            ImGui.TableNextRow()
                            ImGui.TableNextColumn()
                            draw_event_table_row(event, event_type)
                        end
                    end
                    ImGui.TreePop()
                end
            end
            for _,event in pairs(sortable_events) do
                if not event.category or event.category == '' then
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    draw_event_table_row(event, event_type)
                end
            end
        end
        ImGui.EndTable()
    end
end

local function draw_events_section(event_type)
    draw_event_control_buttons(event_type)
    draw_events_table(event_type)
end

local function draw_settings_section()
    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
    ImGui.SetNextItemWidth(100)
    settings.settings.frequency = ImGui.InputInt('Frequency', settings.settings.frequency)
    ImGui.SetNextItemWidth(100)
    if ImGui.BeginCombo('Broadcast Event Enable/Disable', settings.settings.broadcast or 'None') then
        for _,channel in ipairs({'None', 'DanNet', 'EQBC'}) do
            if ImGui.Selectable(channel, settings.settings.broadcast == channel) then
                settings.settings.broadcast = channel
            end
        end
        ImGui.EndCombo()
    end
    ImGui.PopStyleColor()
    if ImGui.Button('Save') then
        save_settings()
    end
    ImGui.SetNextItemWidth(100)
    if ImGui.BeginCombo('Log Level (Not Saved)', Write.loglevel) then
        for _,loglevel in ipairs({'help', 'fatal', 'error', 'warn', 'info', 'debug', 'trace'}) do
            if ImGui.Selectable(loglevel, Write.loglevel == loglevel) then
                Write.loglevel = loglevel
            end
        end
        ImGui.EndCombo()
    end
end

local function draw_reload_section()
    if ImGui.Button('Reload Settings') then
        mq.cmd('/timed 10 /lua run lem')
        state.terminate = true
    end
    ImGui.Text('Reload currently just restarts the script.')
end

local function save_category()
    if state.inputs.add_category.name:len() > 0 then
        if state.inputs.add_category.parent:len() > 0 then
            table.insert(settings.categories[state.inputs.add_category.parent_idx].children, {name=state.inputs.add_category.name, children={}})
        else
            table.insert(settings.categories, {name=state.inputs.add_category.name, children={}})
        end
        save_settings()
        state.ui.editor.open_ui = false
        state.inputs.add_category.name = ''
        state.inputs.add_category.parent = ''
        state.inputs.add_category.parent_idx = 0
    end
end

local function draw_category_editor()
    state.ui.editor.open_ui, state.ui.editor.draw_ui = ImGui.Begin('Add Category###lemeditor', state.ui.editor.open_ui)
    if state.ui.editor.draw_ui then
        if ImGui.Button('Save') then
            save_category()
        end
        state.inputs.add_category.name,_ = ImGui.InputText('Category Name', state.inputs.add_category.name)
        if ImGui.BeginCombo('Parent Category', state.inputs.add_category.parent or '') then
            if ImGui.Selectable('None', state.inputs.add_category.parent == '') then
                state.inputs.add_category.parent = ''
                state.inputs.add_category.parent_idx = 0
            end
            for parentIdx,category in ipairs(categories) do
                if ImGui.Selectable(category.name, state.inputs.add_category.parent == category.name) then
                    state.inputs.add_category.parent = category.name
                    state.inputs.add_category.parent_idx = parentIdx
                end
            end
            ImGui.EndCombo()
        end
    end
    ImGui.End()
end

local function draw_categories_control_buttons()
    if ImGui.Button('Add Category...') then
        state.ui.editor.open_ui = true
        state.ui.editor.action = actions.add_catogory
    end
    if state.ui.main.category_name or state.ui.main.subcategory_name then
        ImGui.SameLine()
        if ImGui.Button('Remove Category') then
            local categoryName = state.ui.main.subcategory_name or state.ui.main.category_name
            for _,event in pairs(text_events) do
                if event.category == categoryName then
                    printf('\arCannot delete category \ay%s\ax, text event \ay%s\ax belongs to it.\ax', categoryName, event.name)
                    return
                end
            end
            for _,event in pairs(condition_events) do
                if event.category == categoryName then
                    printf('\arCannot delete category \ay%s\ax, condition event \ay%s\ax belongs to it.\ax', categoryName, event.name)
                    return
                end
            end
            if not state.ui.main.subcategory_name and #categories[state.ui.main.category_idx].children > 0 then
                printf('\arCannot delete category \ay%s\ax as it has sub-categories.\ax', categoryName)
                return
            end
            if state.ui.main.subcategory_name then
                table.remove(categories[state.ui.main.category_idx].children, state.ui.main.category_subidx)
            else
                table.remove(categories, state.ui.main.category_idx)
            end
            state.ui.main.category_idx = 0
            state.ui.main.category_subidx = 0
            state.ui.main.category_name = nil
            state.ui.main.subcategory_name = nil
            save_settings()
        end
    end
end

local function draw_categories_table()
    if ImGui.BeginTable('CategoryTable', 1, table_flags, 0, 0, 0.0) then
        ImGui.TableSetupColumn('Category',     ImGuiTableColumnFlags.NoSort,   -1, 1)
        ImGui.TableSetupScrollFreeze(0, 1) -- Make row always visible
        ImGui.TableHeadersRow()

        local clipper = ImGuiListClipper.new()
        clipper:Begin(#categories)
        while clipper:Step() do
            for row_n = clipper.DisplayStart, clipper.DisplayEnd - 1, 1 do
                local category = categories[row_n + 1]
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                if #category.children > 0 then
                    local open = ImGui.TreeNode(category.name)
                    if open then
                        for subindex,subcategory in ipairs(category.children) do
                            ImGui.TableNextRow()
                            ImGui.TableNextColumn()
                            if ImGui.Selectable(subcategory.name, state.ui.main.category_subidx == subindex and state.ui.main.category_idx == row_n + 1) then
                                if state.ui.main.category_subidx ~= subindex or state.ui.main.category_idx ~= row_n + 1 then
                                    state.ui.main.category_idx = row_n + 1
                                    state.ui.main.category_subidx = subindex
                                    state.ui.main.category_name = category.name
                                    state.ui.main.subcategory_name = subcategory.name
                                end
                            end
                        end
                        ImGui.TreePop()
                    end
                else
                    if ImGui.Selectable(category.name, state.ui.main.category_idx == row_n + 1) then
                        if state.ui.main.category_idx ~= row_n + 1 then
                            state.ui.main.category_idx = row_n + 1
                            state.ui.main.category_subidx = 0
                            state.ui.main.category_name = category.name
                            state.ui.main.subcategory_name = nil
                        end
                    end
                end
            end
        end
        ImGui.EndTable()
    end
end

local function draw_categories_section()
    draw_categories_control_buttons()
    draw_categories_table()
end

local sections = {
    {
        name='Text Events', 
        handler=draw_events_section,
        arg=events.types.text,
    },
    {
        name='Condition Events',
        handler=draw_events_section,
        arg=events.types.cond,
    },
    {
        name='Categories',
        handler=draw_categories_section,
    },
    {
        name='Settings',
        handler=draw_settings_section,
    },
    {
        name='Reload',
        handler=draw_reload_section,
    },
    {
        name='Import',
        handler=draw_import_window,
    }
}

local function draw_selected_section()
    local x,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("right", x, y-1, ImGuiChildFlags.Border) then
        if state.ui.main.menu_idx > 0 then
            sections[state.ui.main.menu_idx].handler(sections[state.ui.main.menu_idx].arg)
        end
    end
    ImGui.EndChild()
end

local function draw_menu()
    local _,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("left", state.ui.main.menu_width, y-1, ImGuiChildFlags.Border) then
        if ImGui.BeginTable('MenuTable', 1, table_flags, 0, 0, 0.0) then
            for idx,section in ipairs(sections) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                if ImGui.Selectable(section.name, state.ui.main.menu_idx == idx) then
                    if state.ui.main.menu_idx ~= idx then
                        state.ui.main.menu_idx = idx
                        state.ui.main.event_idx = nil
                        state.ui.main.filter = ''
                        first_load = true
                    end
                end
            end
            ImGui.EndTable()
        end
    end
    ImGui.EndChild()
end

local function draw_splitter(thickness, size0, min_size0)
    local x,y = ImGui.GetCursorPos()
    local delta = 0
    ImGui.SetCursorPosX(x + size0)

    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.6, 0.6, 0.1)
    ImGui.Button('##splitter', thickness, -1)
    ImGui.PopStyleColor(3)

    ImGui.SetNextItemAllowOverlap()

    if ImGui.IsItemActive() then
        delta,_ = ImGui.GetMouseDragDelta()

        if delta < min_size0 - size0 then
            delta = min_size0 - size0
        end
        if delta > 200 - size0 then
            delta = 200 - size0
        end

        size0 = size0 + delta
        state.ui.main.menu_width = size0
    else
        menu_default_width = state.ui.main.menu_width
    end
    ImGui.SetCursorPosX(x)
    ImGui.SetCursorPosY(y)
end

local function push_style()
    return themeBridge.push()
end

local function pop_style(token)
    themeBridge.pop(token)
end

-- ImGui main function for rendering the UI window
local lem_ui = function()
    if not state.ui.main.open_ui then return end

    if editor == nil then
        editor = zep.Editor.new('##Editor')
        buffer = editor.activeBuffer
    end

    local styleToken = push_style()
    state.ui.main.open_ui, state.ui.main.draw_ui = ImGui.Begin(state.ui.main.title:format(version, safemode and ' - SAFEMODE ENABLED' or ''), state.ui.main.open_ui)
    if state.ui.main.draw_ui then
        local x, y = ImGui.GetWindowSize() -- 148 42
        if x == 148 and y == 42 then
            ImGui.SetWindowSize(510, 200)
        end
        draw_splitter(8, menu_default_width, 75)
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)
        draw_menu()
        ImGui.SameLine()
        draw_selected_section()
        ImGui.PopStyleVar()
    end
    ImGui.End()

    if state.ui.editor.open_ui then
        if state.ui.editor.action == actions.add or state.ui.editor.action == actions.edit or state.ui.editor.action == actions.import then
            draw_event_editor()
        elseif state.ui.editor.action == actions.view then
            draw_event_viewer()
        elseif state.ui.editor.action == actions.add_catogory then
            draw_category_editor()
        end
    end

    --events.draw(text_events)
    --events.draw(condition_events)

    pop_style(styleToken)
end

local function print_help()
    print(('\a-t[\ax\ayLua Event Manager v%s\ax\a-t]\ax'):format(version))
    print('\axAvailable Commands:')
    print('\t- \ay/lem help\ax -- Display this help output.')
    print('\t- \ay/lem event <event_name> [on|1|true|off|0|false]\ax -- Toggle the named text event on/off.')
    print('\t- \ay/lem cond <event_name> [on|1|true|off|0|false]\ax -- Toggle the named condition event on/off.')
    print('\t- \ay/lem show\ax -- Show the UI.')
    print('\t- \ay/lem hide\ax -- Hide the UI.')
    print('\t- \ay/lem reload\ax -- Reload settings (Currently just restarts the script).')
    print('\t- \ay/lua run lem safemode\ax -- Start LEM without enabling any events.')
end

local ON_VALUES = {['on']=1,['1']=1,['true']=1}
local OFF_VALUES = {['off']=1,['0']=1,['false']=1}
local function cmd_handler(...)
    local args = {...}
    if #args < 1 then
        print_help()
        return
    end
    local command = args[1]
    if command == 'help' then
        print_help()
    elseif command == 'event' then
        if #args < 2 then return end
        local enable
        if #args > 2 then enable = args[3] end
        local event_name = args[2]
        local event = text_events[event_name]
        if event then
            if enable and ON_VALUES[enable] and char_settings.events[event_name] then
                return -- event is already on, do nothing
            elseif enable and OFF_VALUES[enable] and not char_settings.events[event_name] then
                return -- event is already off, do nothing
            end
            toggle_event(event, events.types.text)
        end
    elseif command == 'cond' then
        if #args < 2 then return end
        local event_name = args[2]
        local enable
        if #args > 2 then enable = args[3] end
        local event = condition_events[event_name]
        if event then
            if enable and ON_VALUES[enable] and char_settings.conditions[event_name] then
                return -- event is already on, do nothing
            elseif enable and OFF_VALUES[enable] and not char_settings.conditions[event_name] then
                return -- event is already off, do nothing
            end
            toggle_event(event, events.types.cond)
        end
    elseif command == 'show' then
        state.ui.main.open_ui = true
    elseif command == 'hide' then
        state.ui.main.open_ui = false
    elseif command == 'reload' then
        mq.cmd('/timed 10 /lua run lem')
        state.terminate = true
    end
end

local function validate_events()
    for _,event in pairs(text_events) do
        if not event.load then
            event.load = {always=false,zone='',class='',characters='',}
        end
    end
    for _,event in pairs(condition_events) do
        if not event.load then
            event.load = {always=false,zone='',class='',characters='',}
        end
    end
end

local args = {...}
if #args == 1 then
    if args[1] == 'bg' then state.ui.main.open_ui = false printf('\ayLua Event Manager (%s)\ax running in \aybackground\ax.', version) end
    if args[1] == 'safemode' then safemode = true printf('\ayLua Event Manager (v%s)\ax running in \arSAFEMODE\ax, no events will be enabled.', version) end
else
    printf('\ayLua Event Manager (%s)\ax running. Restart with \ay/lua run lem safemode\ax if any event prevents the script from starting', version)
end

init_settings()
if not settings then return end
init_char_settings()
validate_events()
mq.imgui.init('Lua Event Manager', lem_ui)
mq.bind('/lem', cmd_handler)
mq.bind('/mlem', cmd_handler)

local EventDT, reactDT
local function init_tlo()
    EventDT = mq.DataType.new('LEMEventType', {
        Members = {
            Enabled = function(_, event)
                return 'bool', char_settings.events[event.name]
            end,
            Category = function(_, event) return 'string', event.category end,
            Pattern = function(_, event) return 'string', event.pattern end,
            Command = function(_, event) return 'string', event.command end,
        },
        ToString = function(event)
            return ('%s \ay[\ax%s\ay]\ax'):format(event.name, char_settings.events[event.name] and '\agENABLED\ax' or '\arDISABLED\ax')
        end
    })
    reactDT = mq.DataType.new('LEMReactType', {
        Members = {
            Enabled = function(_, react)
                return 'bool', char_settings.conditions[react.name]
            end,
            Category = function(_, react) return 'string', react.category end,
        },
        ToString = function(react)
            return ('%s \ay[\ax%s\ay]\ax'):format(react.name, char_settings.conditions[react.name] and '\agENABLED\ax' or '\arDISABLED\ax')
        end
    })

    local LEMType = mq.DataType.new('LEMType', {
        Members = {
            Event = function(index)
                return EventDT, text_events[index]
            end,
            React = function(index)
                return reactDT, condition_events[index]
            end,
            Frequency = function() return 'int', settings.settings.frequency end,
            Broadcast = function() return 'string', settings.settings.broadcast end,
            LogLevel = function() return 'string', Write.loglevel end,
        },
        ToString = function()
            return ('Lua Event Manager v%s'):format(version)
        end
    })

    local function LEMTLO(_)
        return LEMType, {}
    end

    mq.AddTopLevelObject('LEM', LEMTLO)
end
init_tlo()

while not state.terminate do
    if not safemode then
        events.manage(text_events, events.types.text, char_settings)
        events.manage(condition_events, events.types.cond, char_settings)
        mq.doevents()
        condition_lab_tick()
    end
    mq.delay(settings.settings.frequency)
end
