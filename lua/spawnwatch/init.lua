local mq = require('mq')
local ImGui = require('ImGui') -- UPDATED: avoid leaking ImGui as an implicit global

local OpenEditor, OpenSpawnViewer = false, true
local npc_list = {}
local tracked_spawns = {}
local input_npc_name = ''
local file_path = mq.luaDir .. '/npc_watchlist_by_zone.json'
local lockWindow = false

mq.bind('/sm_edit', function()
    OpenEditor = true
end)

mq.bind('/sm_lock', function()
    lockWindow = not lockWindow
end)

mq.bind('/showspawns', function()
    OpenSpawnViewer = true
end)

local function escape_json_string(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    return s
end

local function table_to_json(tbl)
    local zones = {}
    for zone in pairs(tbl) do
        table.insert(zones, zone)
    end
    table.sort(zones)

    local lines = {'{'}
    for zi, zone in ipairs(zones) do
        local queries = tbl[zone] or {}
        local encoded = {}
        for i = 1, #queries do
            encoded[#encoded + 1] = '"' .. escape_json_string(queries[i]) .. '"'
        end
        local suffix = (zi < #zones) and ',' or ''
        lines[#lines + 1] = string.format('    "%s": [%s]%s', escape_json_string(zone), table.concat(encoded, ', '), suffix)
    end
    lines[#lines + 1] = '}'
    return table.concat(lines, '\n')
end

local function json_to_table(json)
    local tbl = {}
    for zone, query_list_str in json:gmatch('"([^"]+)":%s*%[(.-)%]') do
        local queries = {}
        for query in query_list_str:gmatch('"([^"]+)"') do
            table.insert(queries, query)
        end
        tbl[zone] = queries
    end
    return tbl
end

local function save_npc_list()
    local file = io.open(file_path, 'w')
    if file then
        file:write(table_to_json(npc_list))
        file:close()
    end
end

local function load_npc_list()
    local file = io.open(file_path, 'r')
    if file then
        local content = file:read('*a')
        file:close()
        npc_list = json_to_table(content) or {}
    end
end

local function update_tracked_spawns()
    tracked_spawns = {}
    local current_zone = mq.TLO.Zone.ShortName() or 'Unknown'

    if npc_list[current_zone] then
        tracked_spawns[current_zone] = {}
        for _, query in ipairs(npc_list[current_zone]) do
            local spawn_count = mq.TLO.SpawnCount(query)()
            if spawn_count and spawn_count > 0 then
                for i = 1, spawn_count do
                    local spawn = mq.TLO.NearestSpawn(i, query)
                    local spawn_name = spawn and spawn.Name() or 'Unknown'
                    local spawn_loc = string.format('(%d, %d, %d)',
                        spawn and (spawn.X() or 0) or 0,
                        spawn and (spawn.Y() or 0) or 0,
                        spawn and (spawn.Z() or 0) or 0)
                    table.insert(tracked_spawns[current_zone], {name = spawn_name, location = spawn_loc})
                end
            end
        end
        table.sort(tracked_spawns[current_zone], function(a, b)
            return (a.name or '') < (b.name or '')
        end)
    end
end

local function draw_editor()
    if not OpenEditor then
        return
    end

    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.6)
    OpenEditor = ImGui.Begin('Spawn Query Watchlist Editor', OpenEditor)

    local current_zone = mq.TLO.Zone.ShortName() or 'Unknown'
    ImGui.Text('Add spawn query in ' .. current_zone)
    ImGui.SetNextItemWidth(250)
    input_npc_name = ImGui.InputText('##spawnQuery', input_npc_name, 64)
    ImGui.SameLine()
    if ImGui.Button('Add') and input_npc_name ~= '' then
        if not npc_list[current_zone] then
            npc_list[current_zone] = {}
        end
        table.insert(npc_list[current_zone], input_npc_name)
        save_npc_list()
        input_npc_name = ''
    end

    for zone, queries in pairs(npc_list) do
        if ImGui.CollapsingHeader(zone) then
            if ImGui.BeginTable('WatchlistTable_' .. zone, 2, ImGuiTableFlags.Borders) then
                ImGui.TableSetupColumn('Spawn Query', ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn('Remove', ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()

                for i, query in ipairs(queries) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(query)
                    ImGui.TableSetColumnIndex(1)
                    if ImGui.Button('Remove##' .. zone .. i) then
                        table.remove(npc_list[zone], i)
                        if #npc_list[zone] == 0 then
                            npc_list[zone] = nil
                        end
                        save_npc_list()
                    end
                end
                ImGui.EndTable()
            end
        end
    end

    ImGui.End()
end

local function draw_spawn_viewer()
    if not OpenSpawnViewer then
        return
    end

    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.0)

    local window_flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.AlwaysAutoResize
    if lockWindow then
        window_flags = window_flags + ImGuiWindowFlags.NoMove
    end

    OpenSpawnViewer = ImGui.Begin('Active Spawn Viewer', OpenSpawnViewer, window_flags)

    if ImGui.Button('Open Spawn Query Editor') then
        OpenEditor = true
    end
    ImGui.SameLine()
    if ImGui.Button(lockWindow and 'Unlock Window' or 'Lock Window') then
        lockWindow = not lockWindow
    end

    local current_zone = mq.TLO.Zone.ShortName() or 'Unknown'
    if tracked_spawns[current_zone] and #tracked_spawns[current_zone] > 0 then
        for _, spawn in ipairs(tracked_spawns[current_zone]) do
            ImGui.TextColored(0, 1, 0, 1, (spawn.name or 'Unknown') .. ' ' .. (spawn.location or ''))
        end
    else
        ImGui.TextColored(1, 0, 0, 1, "Nothing's Up.")
    end

    ImGui.End()
end

mq.imgui.init('SpawnQueryEditor', draw_editor)
mq.imgui.init('SpawnViewer', draw_spawn_viewer)

local function main()
    load_npc_list()
    while true do
        mq.doevents()
        update_tracked_spawns()
        mq.delay(5000)
    end
end

main()
