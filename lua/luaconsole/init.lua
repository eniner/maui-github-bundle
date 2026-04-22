local mq                  = require('mq')
local ImGui               = require('ImGui')
local Icons               = require('mq.ICONS')
local Zep                 = require('Zep')
local themeBridge         = require('lib.maui_theme_bridge')

local luaConsole          = Zep.Console.new("##LuaConsole")
luaConsole.maxBufferLines = 1000
luaConsole.autoScroll     = true

local luaEditor           = Zep.Editor.new('##LuaEditor')
local luaBuffer           = luaEditor:CreateBuffer("[LuaConsole]")
luaBuffer.syntax          = 'lua'

local execRequested       = false
local showTimestamps      = true
local execCoroutine       = nil
local status              = "Idle..."

local openGUI             = true
local shouldDrawGUI       = true
local CHANNEL_COLOR       = IM_COL32(215, 154, 66)

local settings_path       = mq.configDir .. '/luaconsole_settings.lua'

local function LoadSettings()
    local settings, err = loadfile(settings_path)
    if not err and settings then
        luaBuffer:SetText(settings().editbox)
    end
end

local function SaveSettings()
    mq.pickle(settings_path, { editbox = luaBuffer:GetText(), })
end


local function LogTimestamp()
    if showTimestamps then
        local now = os.date('%H:%M:%S')
        luaConsole:AppendTextUnformatted(string.format('\aw[\at%s\aw] ', now))
    end
end

local function LogToConsole(...)
    LogTimestamp()
    luaConsole:AppendText(CHANNEL_COLOR, ...)
end

local function Exec(scriptText)
    local func, err = load(scriptText, "LuaConsoleScript", "t")
    if not func then
        return false, err
    end

    local locals = setmetatable({}, { __index = _G, })
    locals.mq = setmetatable({}, { __index = mq, })

    locals.print = function(...)
        LogTimestamp()
        luaConsole:PushStyleColor(Zep.ConsoleCol.Text, CHANNEL_COLOR)
        for _, arg in ipairs({ ..., }) do
            luaConsole:AppendTextUnformatted(tostring(arg))
        end
        luaConsole:AppendTextUnformatted('\n')
        luaConsole:PopStyleColor()
    end

    locals.printf = function(text, ...)
        LogTimestamp()
        luaConsole:AppendText(CHANNEL_COLOR, text, ...)
    end

    locals.mq.exit = function()
        execCoroutine = nil
    end

    locals.hi = 3

    setfenv(func, locals)

    local success, msg = pcall(func)
    return success, msg or ""
end

local function ExecCoroutine()
    local scriptText = luaBuffer:GetText()

    return coroutine.create(function()
        local success, msg = Exec(scriptText)
        if not success then
            LogToConsole("\ar" .. msg)
        end
    end)
end

local function RenderConsole()
    local contentSizeX, contentSizeY = ImGui.GetContentRegionAvail()
    luaConsole:Render(ImVec2(contentSizeX, math.max(200, (contentSizeY - 10))))
end

local function RenderEditor()
    local yPos = ImGui.GetCursorPosY()
    local footerHeight = 35
    local editHeight = (ImGui.GetWindowHeight() * .5) - yPos - footerHeight

    luaEditor:Render(ImVec2(ImGui.GetWindowWidth() * 0.98, editHeight))
end

local function RenderTooltip(text)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(text)
    end
end

local function CenteredButton(label)
    local style = ImGui.GetStyle()

    local framePaddingX = style.FramePadding.x * 2
    local framePaddingY = style.FramePadding.y * 2

    local availableWidth = ImGui.GetContentRegionAvailVec().x
    local availableHeight = 30

    local textSizeVec = ImGui.CalcTextSizeVec(label)
    local textWidth = textSizeVec.x
    local textHeight = textSizeVec.y

    local paddingX = (availableWidth - textWidth - framePaddingX) / 2
    local paddingY = (availableHeight - textHeight - framePaddingY) / 2

    if paddingX > 0 then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + paddingX)
    end
    if paddingY > 0 then
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() + paddingY)
    end
    return ImGui.SmallButton(string.format("%s", label))
end

local function RenderToolbar()
    if ImGui.BeginTable("##LuaConsoleToolbar", 5, ImGuiTableFlags.Borders) then
        ImGui.TableSetupColumn("##LuaConsoleToolbarCol1", ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn("##LuaConsoleToolbarCol2", ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn("##LuaConsoleToolbarCol3", ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn("##LuaConsoleToolbarCol4", ImGuiTableColumnFlags.WidthFixed, 180)
        ImGui.TableSetupColumn("##LuaConsoleToolbarCol5", ImGuiTableColumnFlags.WidthStretch, 200)
        ImGui.TableNextColumn()

        if execCoroutine and coroutine.status(execCoroutine) ~= 'dead' then
            if CenteredButton(Icons.MD_STOP) then
                execCoroutine = nil
            end
            RenderTooltip("Stop Script")
        else
            if CenteredButton(Icons.MD_PLAY_ARROW) then
                execRequested = true
            end
            RenderTooltip("Execute Script (Ctrl+Enter)")
        end

        ImGui.TableNextColumn()
        if CenteredButton(Icons.MD_CLEAR) then
            luaBuffer:Clear()
        end
        RenderTooltip("Clear Script")

        ImGui.TableNextColumn()
        if CenteredButton(Icons.MD_PHONELINK_ERASE) then
            luaConsole:Clear()
        end
        RenderTooltip("Clear Console")

        ImGui.TableNextColumn()
        showTimestamps = ImGui.Checkbox("Print Time Stamps", showTimestamps)
        ImGui.TableNextColumn()
        ImGui.Text("Status: " .. status)
        ImGui.EndTable()
    end
end

local function LuaConsoleGUI()
    local themeToken = themeBridge.push()
    ImGui.SetNextWindowSize(ImVec2(800, 600), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowPos(ImVec2(ImGui.GetIO().DisplaySize.x / 2 - 400, ImGui.GetIO().DisplaySize.y / 2 - 300), ImGuiCond.FirstUseEver)

    openGUI, shouldDrawGUI = ImGui.Begin("Lua Console - By: Derple", openGUI, ImGuiWindowFlags.None)
    if shouldDrawGUI then
        if (ImGui.IsWindowHovered(ImGuiHoveredFlags.ChildWindows) and (ImGui.IsKeyChordPressed(bit32.bor(ImGuiMod.Ctrl, ImGuiKey.Enter)))) then
            execRequested = true
        end

        RenderEditor()
        RenderToolbar()
        RenderConsole()
    end
    ImGui.End()
    themeBridge.pop(themeToken)
end

mq.imgui.init('LuaConsoleGUI', LuaConsoleGUI)
mq.bind('/lc', function()
    openGUI = not openGUI
end)

LogToConsole("\awLua Console by: \amDerple \awLoaded...")

LoadSettings()

while openGUI do
    if execRequested then
        execRequested = false
        execCoroutine = ExecCoroutine()
        coroutine.resume(execCoroutine)
        status = "Running..."
    end

    if execCoroutine and coroutine.status(execCoroutine) ~= 'dead' then
        coroutine.resume(execCoroutine)
    else
        execCoroutine = nil
        status = "Idle..."
    end

    if luaBuffer:HasFlag(Zep.BufferFlags.Dirty) then
        SaveSettings()
        luaBuffer:ClearFlags(Zep.BufferFlags.Dirty)
    end

    mq.delay(10)
end

SaveSettings()
