--Version 1.2.0
local mq = require 'mq'
require 'ImGui'
local themeBridge = require 'lib.maui_theme_bridge'
local Open,ShowUI = true,true

-- icons for the checkboxes
local done = mq.FindTextureAnimation('A_TransparentCheckBoxPressed')
local notDone = mq.FindTextureAnimation('A_TransparentCheckBoxNormal')

-- Some WindowFlags
local WindowFlags = bit32.bor(ImGuiWindowFlags.NoTitleBar,ImGuiWindowFlags.NoResize,ImGuiWindowFlags.AlwaysAutoResize)

-- print format function
local function printf(...)
    print(string.format(...))
end

local oldZone = 0
local myZone = mq.TLO.Zone.ID
local showOnlyMissing = false
local minimize = false
local showGrind = false
local onlySpawned = false
local spawnUp = 0
local totalDone = ''

-- shortening the mq bind for achievements 
local myAch = mq.TLO.Achievement

-- Table that will store the spawnnames of the Hunter achievement
local myHunterSpawn = {}

-- Current Achievemment information
local curAch = {}

-- nameMap that maps wrong achievement objective names to the ingame name.
local nameMap = {
    ["Pli Xin Liako"]           = "Pli Xin Laiko",
    ["Xetheg, Luclin's Warder"] = "Xetheg, Luclin`s Warder",
    ["Itzal, Luclin's Hunter"]  = "Itzal, Luclin`s Hunter",
    ["Ol' Grinnin' Finley"]     = "Ol` Grinnin` Finley"
}

-- Zonemap that maps zoneID's to Achievement Indexes, for zones that are speshul!
local zoneMap = {
    [58]  = 105880,  --Hunter of Crushbone                  Clan Crusbone=crushbone

    [66]  = 106680,  --Hunter of The Ruins of Old Guk       The Reinforced Ruins of Old Guk=gukbottom
    [73]  = 107380,  --Hunter of the Permafrost Caverns     Permafrost Keep=permafrost
    [81]  = 258180,  --Hunter of The Temple of Droga        The Temple of Droga=droga
    [87]  = 208780,  --Hunter of The Burning Wood           The Burning Woods=burningwood
    [89]  = 208980,  --Hunter of The Ruins of Old Sebilis   The Reinforced Ruins of Old Sebilis=sebilis
    [108] = 250880,  --Hunter of Veeshan's Peak             Veeshan's Peak=veeshan

    [207] = 520780,  --Hunter of Torment, the Plane of Pain Plane of Torment=potorment
    [455] = 1645560, --Hunter of Kurn's Tower               Kurn's Tower=oldkurn
    [318] = 908300,  --Hunter of Dranik's Hollows           Dranik's Hollows (A)=dranikhollowsa
    [319] = 908300,  --Hunter of Dranik's Hollows           Dranik's Hollows (B)=dranikhollowsb
    [320] = 908300,  --Hunter of Dranik's Hollows           Dranik's Hollows (C)=dranikhollowsc
    [328] = 908600,  --Hunter of Catacombs of Dranik        Catacombs of Dranik (A)=dranikcatacombsa
    [329] = 908600,  --Hunter of Catacombs of Dranik        Catacombs of Dranik (B)=dranikcatacombsb
    [330] = 908600,  --Hunter of Catacombs of Dranik        Catacombs of Dranik (C)=dranikcatacombsc
    [331] = 908700,  --Hunter of Sewers of Dranik           Sewers of Dranik (A)=draniksewersa
    [332] = 908700,  --Hunter of Sewers of Dranik           Sewers of Dranik (B)=draniksewersb
    [333] = 908700,  --Hunter of Sewers of Dranik           Sewers of Dranik (C)=draniksewersc
    
    [700] = 1870060, --Hunter of The Feerrott               The Feerrott=Feerrott2
    [772] = 2177270, --Hunter of West Karana (Ethernere)    Ethernere Tainted West Karana=ethernere
    [76]  = 2320180, --Hunter of the Plane of Hate: Broken Mirror  Plane of hate Revisited=hateplane
    [788] = 2478880, --Hunter of The Temple of Droga        Temple of Droga=drogab
    [791] = 2479180, --Hunter of Frontier Mountains         Frontier Mountains=frontiermtnsb
    [800] = 2480080, --Hunter of Chardok                    Chardok=chardoktwo

    [813] = 2581380, --Hunter of The Howling Stones         Howling Stones=charasistwo
    [814] = 2581480, --Hunter of The Skyfire Mountains      Skyfire Mountains=skyfiretwo
    [815] = 2581580, --Hunter of The Overthere              The Overthere=overtheretwo
    [816] = 2581680, --Hunter of Veeshan's Peak             Veeshan's Peak=veeshantwo

    [824] = 2782480, --Hunter of The Eastern Wastes         The Eastern Wastes=eastwastestwo
    [825] = 2782580, --Hunter of The Tower of Frozen Shadow The Tower of Frozen Shadow=frozenshadowtwo
    [826] = 2782680, --Hunter of The Ry`Gorr Mines          The Ry`Gorr Mines=crystaltwoa
    [827] = 2782780, --Hunter of The Great Divide           The Great Divide=greatdividetwo
    [828] = 2782880, --Hunter of Velketor's Labyrinth       Velketor's Labyrinth=velketortwo
    [829] = 2782980, --Hunter of Kael Drakkel               Kael Drakkel=kaeltwo
    [830] = 2783080, --Hunter of Crystal Caverns            Crystal Caverns=crystaltwob

    [831] = 2807601, --Hunter of The Sleeper's Tomb         The Sleeper's Tomb=sleepertwo
    [832] = 2807401, --Hunter of Dragon Necropolis          Dragon Necropolis=necropolistwo
    [833] = 2807101, --Hunter of Cobalt Scar                Cobalt Scar=cobaltscartwo
    [834] = 2807201, --Hunter of The Western Wastes         The Western Wastes=westwastestwo
    [835] = 2807501, --Hunter of Skyshrine                  Skyshrine=skyshrinetwo
    [836] = 2807301, --Hunter of The Temple of Veeshan      The Temple of Veeshan=templeveeshantwo

    [843] = 2908100, --Hunter of Maiden's Eye               Maiden's Eye=maidentwo
    [844] = 2908200, --Hunter of Umbral Plains              Umbral Plains=umbraltwo
    [846] = 2908400, --Hunter of Vex Thal                   Vex Thal=vexthaltwo
    [847] = 2908500, --Hunter of Shadow Valley              zone name has an extra space
}

local function AchID()
    if zoneMap[mq.TLO.Zone.ID()] or myAch('Hunter of the '..mq.TLO.Zone.Name()).ID() then
        return zoneMap[mq.TLO.Zone.ID()] or myAch('Hunter of the '..mq.TLO.Zone.Name()).ID()
    else
        return myAch('Hunter of '..mq.TLO.Zone.Name()).ID()
    end
end

local function findspawn(spawn)
if nameMap[spawn] then spawn = nameMap[spawn] end
    local mySpawn = mq.TLO.Spawn(string.format('npc "%s"', spawn))
    if mySpawn.CleanName() == spawn then
        return mySpawn.ID()
    end
    return 0
end

local function getPctCompleted()
    local tmp = 0
    for index, hunterSpawn in ipairs(myHunterSpawn) do
        if myAch(curAch.ID).Objective(hunterSpawn).Completed() then
            tmp = tmp + 1
        end
    end
    totalDone = string.format('%d/%d',tmp, curAch.Count)
    if tmp == curAch.Count then totalDone = 'Completed!' end
    return tmp / curAch.Count
end

local function drawCheckBox(spawn)
    if myAch(curAch.ID).Objective(spawn).Completed() then
        ImGui.DrawTextureAnimation(done, 15, 15)
        ImGui.SameLine()
    else
        ImGui.DrawTextureAnimation(notDone, 15, 15)
        ImGui.SameLine()
    end
end

local function textEnabled(spawn)
    ImGui.PushStyleColor(ImGuiCol.Text, 0.690, 0.553, 0.259, 1)
    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0.33, 0.33, 0.33, 0.5)
    ImGui.PushStyleColor(ImGuiCol.HeaderActive, 0.0, 0.66, 0.33, 0.5)
    local selSpawn = ImGui.Selectable(spawn, false, ImGuiSelectableFlags.AllowDoubleClick)
    ImGui.PopStyleColor(3)
    if selSpawn and ImGui.IsMouseDoubleClicked(0) then
        mq.cmdf('/nav id %d log=error' , findspawn(spawn))
        printf('\ayMoving to \ag%s',spawn)
    end
end

local function hunterProgress()
    local x, y = ImGui.GetContentRegionAvail()
    ImGui.PushStyleColor(ImGuiCol.PlotHistogram, 0.690, 0.553, 0.259, 0.5)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, 0.33, 0.33, 0.33, 0.5)
    ImGui.SetWindowFontScale(0.85)
    ImGui.Indent(2)
    ImGui.ProgressBar(getPctCompleted(), x-4, 14, totalDone)
    ImGui.PopStyleColor(2)
    ImGui.SetWindowFontScale(1)

end

local function createLines(spawn)
    if findspawn(spawn) ~= 0 then
        drawCheckBox(spawn)
        textEnabled(spawn)
    elseif not onlySpawned then
        drawCheckBox(spawn)
        ImGui.TextDisabled(spawn)
    end
end

local function popupmenu()
    ImGui.SetCursorPosX((ImGui.GetWindowWidth() - ImGui.CalcTextSize('HunterHUD')) * 0.5)
    ImGui.TextColored(0.973, 0.741, 0.129, 1, 'HunterHUD')
    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.690, 0.553, 0.259, 1)
    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0.33, 0.33, 0.33, 0.5)
    ImGui.PushStyleColor(ImGuiCol.HeaderActive, 0.0, 0.66, 0.33, 0.5)

    minimize = ImGui.MenuItem('Minimize', '', minimize)
    if ImGui.Selectable('Hide') then 
        printf('\a#f8bd21Hiding HunterHud(\a#b08d42\'/hh\' to show\ax)') 
        ShowUI = not ShowUI 
    end
    onlySpawned = ImGui.MenuItem('Toggle Spawned Only', '', onlySpawned)
    showOnlyMissing = ImGui.MenuItem('Toggle Missing Hunts', '', showOnlyMissing)
    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.973, 0.741, 0.129, 1)
    if ImGui.Selectable('Stop HunterHUD') then Open = false end
    ImGui.PopStyleColor(4)
    ImGui.EndPopup()
end

local function PCList()
    ImGui.SetCursorPosX((ImGui.GetWindowWidth() - ImGui.CalcTextSize('Players in Zone')) * 0.5)
    ImGui.TextColored(0.973, 0.741, 0.129, 1, 'Players in Zone')
    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.690, 0.553, 0.259, 1)
    --ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0.33, 0.33, 0.33, 0.5)
    --ImGui.PushStyleColor(ImGuiCol.HeaderActive, 0.0, 0.66, 0.33, 0.5)

    for i = 1, mq.TLO.SpawnCount('pc')() do
        local player = mq.TLO.NearestSpawn(i,'pc')
        ImGui.Text(string.format('%s [%d - %s] - %s', player.Name(), player.Level(), player.Class(), player.Guild() or 'No Guild'))
    end
    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.973, 0.741, 0.129, 1)
    --bottom line
    ImGui.PopStyleColor(2)
    ImGui.EndPopup()
end

local function RenderHunter()
    hunterProgress()
    if not minimize then ImGui.Separator() end
    for index, hunterSpawn in ipairs(myHunterSpawn) do

        if not minimize then
            if showOnlyMissing then
                if not myAch(curAch.ID).Objective(hunterSpawn).Completed() then
                    createLines(hunterSpawn)
                end
            else
                createLines(hunterSpawn)
            end
        end
    end
end 

local function InfoLine()
    ImGui.Separator()
    ImGui.TextColored(0.690, 0.553, 0.259, 1,'\xee\x9f\xbc')
    --[[if ImGui.BeginPopupContextItem('pcpopup') then
        PCList()
    end]]--
    ImGui.SameLine()
    local pcs = mq.TLO.SpawnCount('pc')() - mq.TLO.SpawnCount('group pc')()
    
    if pcs > 50 then 
        ImGui.TextColored(0.95, 0.05, 0.05, 1, tostring(pcs))
    elseif pcs > 25 then 
        ImGui.TextColored(0.95, 0.95, 0.05, 1, tostring(pcs))
    elseif pcs > 0 then 
        ImGui.TextColored(0.05, 0.95, 0.05, 1, tostring(pcs))
    else
        ImGui.TextDisabled(tostring(pcs))
    end

    ImGui.SameLine() ImGui.TextDisabled('|')
    if mq.TLO.Group() ~= nil then
        for i = 0, mq.TLO.Group.Members() do
            local member = mq.TLO.Group.Member(i)
            if member.Present() and not member.Mercenary() then
                ImGui.SameLine()
                if not member.Invis() then 
                    ImGui.TextColored(0.0, 0.95, 0.0, 1, 'F'..i+1)
                elseif member.Invis('NORMAL')() and not member.Invis('IVU')() then 
                    ImGui.TextDisabled('F'..i+1) 
                end
            end
        
        end
    else
        if not mq.TLO.Me.Invis() then 
            ImGui.SameLine()
            ImGui.TextColored(0.0, 0.95, 0.0, 1, 'F1')
        end
    end
    ImGui.SameLine() ImGui.TextDisabled('|')
    ImGui.SameLine()
    spawnUp = 0
    if spawnUp == 0 then ImGui.TextDisabled('\xee\x9f\xb5')  end
    if spawnUp == 1 then ImGui.TextColored(0.973, 0.741, 0.129, 1, '\xee\x9f\xb5') end
    if spawnUp == 2 then ImGui.TextColored(0.0129, 0.973, 0.129, 1, '\xee\x9f\xb5') end

end

local function RenderTitle()
    ImGui.SetWindowFontScale(1.15)
    local title = 0
    if curAch.ID then 
        title = curAch.Name
    else
        title = mq.TLO.Zone.Name()
    end
    ImGui.SetCursorPosX((ImGui.GetWindowWidth() - ImGui.CalcTextSize(title)) * 0.5)
    ImGui.TextColored(0.973, 0.741, 0.129, 1, title)
    ImGui.SetWindowFontScale(1)
    if ImGui.BeginPopupContextItem('titlepopup') then
        popupmenu()
    end
end

local function HunterHUD()
    if ShowUI then
        local themeToken = themeBridge.push()
        Open, _ = ImGui.Begin('HunterHUD', Open, WindowFlags)
        RenderTitle()
        if curAch.ID then 
            RenderHunter() 
        end
        InfoLine()
        ImGui.End()
        themeBridge.pop(themeToken)
    end
end

local function updateTables()
    myHunterSpawn = {}
    curAch = {}

    if AchID() ~= nil then
        curAch = {
            ID = AchID(),
            Name = myAch(AchID()).Name(),
            Count = myAch(AchID()).ObjectiveCount()
        }
        printf('\a#f8bd21Updating HunterHUD(\a#b08d42%s\a#f8bd21)', curAch.Name)
        local i = 0
        repeat
            if myAch(AchID()).ObjectiveByIndex(i)() ~= nil then
                table.insert(myHunterSpawn,myAch(AchID()).ObjectiveByIndex(i)())
            end
            i = i + 1
        until #myHunterSpawn == curAch.Count 
        printf('\a#f8bd21Updating Done(\a#b08d42%s\a#f8bd21)', curAch.Name)
    else 
        print('\a#f8bd21No Hunts found in \a#b08d42'..mq.TLO.Zone())
    end
end

local function bind_hh(cmd)
    local VividOrange = '\a#f8bd21'
    local DarkOrange  = '\a#b08d42'

    if cmd == nil then 
        if ShowUI then 
            printf('%sHiding HunterHUD', VividOrange)
            ShowUI = false
        else
            printf('%sShowing HunterHUD', VividOrange)
            ShowUI = true
        end
    elseif cmd == 'stop' then
        printf('%sHunterHUD Ended', VividOrange)
        Open = false
    else
        printf('%sHunterHUD usage:', VividOrange)
        printf('%s/hh %sToggles showing and hiding HunterHud', VividOrange, DarkOrange)
        printf('%s/hh stop %sStop HunterHUD', VividOrange, DarkOrange)
    end

    return
end

mq.imgui.init('hunterhud', HunterHUD)
mq.bind('/hh', bind_hh)

while Open do
    if oldZone ~= myZone() then
        updateTables()
        oldZone = myZone()
    end
    mq.delay(250)
end



--[[

Version 1.2.1
* Progrssbar will now show Completed! if the achievement is done.
* Findspawn function was optimized, cause i done dumb the first time.
* Fixed achievements:
    - Hunter of The Ruins of Old Guk       The Reinforced Ruins of Old Guk=gukbottom
    - Hunter of the Permafrost Caverns     Permafrost Keep=permafrost
    - Hunter of The Temple of Droga        The Temple of Droga=droga
    - Hunter of The Burning Wood           The Burning Woods=burningwood
    - Hunter of The Ruins of Old Sebilis   The Reinforced Ruins of Old Sebilis=sebilis
* Some rogue integer vars fixed to proper string vars where used
* Fancy icon for people in zone, still need to fix it proper counting when you not in group.

**Version 1.2.0
* Fixed achievements:
    - Hunter of The Feerrott               The Feerrott=Feerrott2
    - Hunter of West Karana (Ethernere)    Ethernere Tainted West Karana=ethernere
    - Hunter of the Plane of Hate: Broken Mirror  Plane of hate Revisited=hateplane
    - Hunter of Frontier Mountains         Frontier Mountains=frontiermtnsb
    - Hunter of Kurn's Tower               Kurn's Tower=oldkurn

* In world mob name to achievement objective name mapping, as some names dont match properly, please report names if you find any, i need a screenshot of the mobs ingame name, and the achievement name

* Removed some commnad line options as i didnt like them, now that we got the right click menu.

* Removed the check that made the achievment name grey when you didnt have any spawns up

* Added infoline (its a work in progrss!)
    - shows numbers of players in zone
    - Working on an invis indicator for group
    - Working on indicator for showing if spawns are up
        - indicator will show if you need the spawn or if its just or if something is just up.

* cleaned up some code and restructured some code to make it more modular and fanzys.



local function findspawnold(spawn)
    if nameMap[spawn] then spawn = nameMap[spawn] end
    local spawnCount = mq.TLO.SpawnCount(string.format('npc "%s"', spawn))()
    for i = 1, spawnCount do
        local mySpawn = mq.TLO.NearestSpawn(string.format('%d,npc "%s"',i , spawn))
        if mySpawn.CleanName() == spawn then
            return mySpawn.ID()
        end
    end
    return 0
end

]]--
