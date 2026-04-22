--[[ Grouper.lua
     Utility to provide a group-related functions. Mostly done as a Lua learning
     exercise, but has actually become useful.
     
     Thanks to several different RedGuides members for providing Lua code
     examples, and Sic for his Hot Keys.
  ]]
  
local LuaName = 'Grouper'
local LuaVersion = '1.2'
local mq = require 'mq'
local imgui = require 'ImGui'
local FIFO = require 'lib.FIFO'
local DANNET = require 'lib.DANNET'
local TABLE = require 'lib.TABLE'
local LIP = require 'lib.LIP'
local themeBridge = require 'lib.maui_theme_bridge'

local OpenUI,ShowUI = true,true
local camp_radius_assist = 55
local camp_radius_tank = 35
local pressing_down = 0
local following = false
local invis_update_time = 0
local invis_status = {}
local ivu_status = {}
local job_queue = FIFO.new()
local job_queue_delay = 0
local ui_elements = {}
local ui_layout = {}
local ui_hide_buttons = true
local element_being_edited = {}
local config_name = LuaName..'_'..mq.TLO.Me.CleanName()..'_'..mq.TLO.EverQuest.Server()..'.ini'
local observer_list = DANNET.newObserverList()
local invis_labels = { 'Dual', 'Invis', 'IVU' }
local invis_mode  = 0
local auto_attack_enabled = true
local grouper_running = true

local MT    = '(${Group.MainTank.ID}==${Me.ID})'
local MA    = '(${Group.MainAssist.ID}==${Me.ID})'
local KA    = '(${Macro.Name.Equal[kissassist.mac]} || ${Macro.Name.Equal[muleassist.mac]})'
local CWTN  = '(!${Macro.Name.Equal[kissassist.mac]} && !${Macro.Name.Equal[muleassist.mac]})'
local ONE_TENTH_SECOND = 100

local INVIS_QUERY = 'Me.Invis[1]'
local IVU_QUERY   = 'Me.Invis[2]'

local WHITE = '255,255,255,255'
local RED   = '255,0,0,255'

local DEFAULT_CUSTOM_COMMAND = '/noparse /dgga /multiline ; '

if DANNET.checkVersion(1,1) == false then OpenUI = false end
if FIFO.checkVersion(1,0) == false then OpenUI = false end
if TABLE.checkVersion(1,0) == false then OpenUI = false end

--[[ Basic command-line argument to disable invis display. Not sure
     is the extra Dannet traffic is an issue, so this allows turning
     it off.
  ]]
local args = {...}
local show_invis_status = true
if args[1] == 'nostatus' then show_invis_status = false end

--[[ Determine if a file can be opened in the specified mode.
  ]]
local function access(filename,mode)
  local f = io.open(filename, mode)
  if f ~= nil then io.close(f) return true else return false end
end

--[[ Separates string with color values (0..255) into component values (0..1).
  ]]
local function rgba(color)
  if color == nil or type(color) ~= 'string' then return 1,1,1,1 end
  local _,_,r,g,b,a = string.find(color,'(%d+),(%d+),(%d+),(%d+)')
  return tonumber(r)/255,tonumber(g)/255,tonumber(b)/255,tonumber(a)/255
end

--[[ Adds a job to the main loop job queue.
     Param..: action - table containing job parameters
                action[1] = function to be executed
                action[n] = function parameters
     Return.: none
  ]]
local function addJob(action)
  FIFO.push(job_queue,action)
end

--[[ Gets a job to the main loop job queue.
     Param..: none
     Return.: action - table containing job parameters
                action[1] = function to be executed
                action[n] = function parameters
  ]]
local function getJob()
  return FIFO.pop(job_queue)
end

--[[ Adds a delay to job processing.
     Param..: delay - the delay duration (0.1s)
     Return.: none
     Prevents the main loop from executing jobs until the
     specified time (minimum) has elapsed.
  ]]
local function mqDelay(delay)
  job_queue_delay = job_queue_delay + delay
end

--[[ Wrapper for 'mq.cmd()'. Just because I may want to add something.
     Param..: command - the command string (e.g., '/beep')
     Return.: none
  ]]
local function mqCommand(command)
  if command ~= nil then mq.cmd(command) end
end

--[[ Returns the number of members in the group (if any), not counting self.
  ]]
local function getMemberCount()
  return mq.TLO.Group.Members()
end

--[[ Gets the name of a group member.
     Param..: member_num - the group member number (0..5), 0 is self
     Return.: group member name (may be nil)
  ]]
local function getMemberName(member_num)
  local name = nil
  if member_num > 0 then name = mq.TLO.Group.Member(member_num).Name() end
  if name == nil then name = mq.TLO.Me.Name() end
  return name
end

--[[ Gets the class short name of a group member.
     Param..: member_num - the group member number (0..5), 0 is self
     Return.: group member class name (may be nil)
  ]]
local function getMemberClass(member_num)
  local class = nil
  if member_num > 0 then class = mq.TLO.Group.Member(member_num).Class.ShortName() end
  if class == nil then class = mq.TLO.Me.Class.ShortName() end
  return class
end

--[[ Gets the level of a group member.
     Param..: member_num - the group member number (0..5), 0 is self
     Return.: group member level
  ]]
local function getMemberLevel(member_num)
  local level = nil
  if member_num > 0 then level = mq.TLO.Group.Member(member_num).Level() end
  if level == nil then level = mq.TLO.Me.Level() end
  return level
end

--[[ Send a command to a single character.
     Param..: name - the character name
     Param..: command - the command
     Return.: none
  ]]
local function sendCommand(name,command)
  if name == nil or command == nil then return end
  if name == mq.TLO.Me.Name() then
    mqCommand(string.format('/docommand %s',command))
  else
    mqCommand(string.format('/dex %s %s',name,command))
  end
end

--[[ Gets invisibility information for a character.
     Param..: name  - the character name
     Return.: invisibility as a bit mask (bit 2=undead, bit 1=normal, bit 0=any)
  ]]
local function getInvisMask(name)
  if name == nil then return 0 end
  local invis_mask = 0
  if invis_status[name] then invis_mask = bit32.bor( invis_mask, 0x00000003 ) end
  if ivu_status[name]   then invis_mask = bit32.bor( invis_mask, 0x00000005 ) end
  return invis_mask
end

--[[ Show a tooltip.
  ]]
local function showTooltip(tooltip)
  if tooltip ~= nil and ImGui.IsItemHovered() then
    ImGui.BeginTooltip()
    ImGui.TextUnformatted(tooltip)
    ImGui.EndTooltip()
  end
end

--[[ Draws an indicator (arrow button) for flag value.
  ]]
local function drawIndicator(flag,button_num)
  if flag ~= nil and flag then
    ImGui.PushStyleColor(ImGuiCol.Button,0,1,0,1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,0,1,0,1)
    ImGui.ArrowButton('##'..button_num,ImGuiDir.Up)
    ImGui.PopStyleColor(2)
  else
    ImGui.PushStyleColor(ImGuiCol.Button,1,0,0,1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,1,0,0,1)
    ImGui.ArrowButton('##'..button_num,ImGuiDir.Down)
    ImGui.PopStyleColor(2)
  end
end

--[[ Stop frenzy (unroot) on Berzerkers.
  ]]
local function action_StopFrenzy()
  addJob({mqCommand,'/noparse /dgga /if (${Me.ActiveDisc.Name.Find[Frenzied Resolve Discipline]}) /stopdisc'})
end

--[[ Down button logic handler.
     The down button can be in one of 3 states
       0 = unknown status, will press END to ensure not held
       1 = not pressing END (down)
       2 = pressing END (down)
     The button shows its state with the arrow and color.
  ]]
local function action_Down()
  if pressing_down == 1 then
    addJob({mqCommand,'/dgga /multiline ; /keypress END ; /keypress END hold'})
    pressing_down = 2
  else
    addJob({mqCommand,'/dgga /keypress END'})
    pressing_down = 1
  end
end

--[[ Moves group member to a random position about self
     Param..: member_num - the group member number (1..5), 0 is self
     Param..: member_count - the number of members in the group
     Param..: distance   - the maximum distance from self
     Return.: none
  ]]
local function scatterPosition(member_num,member_count,distance)
  if member_count < 1 or member_num < 1 or member_num > member_count then return end
  local name = getMemberName(member_num)
  if name == nil or mq.TLO.Spawn(name)() == nil then return end
  local y = mq.TLO.Me.Y() - distance + math.random() * (2*distance)
  local x = mq.TLO.Me.X() - distance + math.random() * (2*distance)
  addJob({mqCommand,string.format('/dex %s /moveto loc %d %d',getMemberName(member_num),y,x)})
end

local function action_Scatter()
  local member_count = getMemberCount()
  for member_num = 1, member_count do
    scatterPosition(member_num,member_count,30)
  end
end

--[[ Moves group member to a position in a circle around self
     Param..: member_num - the group member number (1..5), 0 is self
     Param..: member_count - the number of members in the group
     Param..: distance   - the maximum distance from self
     Return.: none
  ]]
local function circlePosition(member_num,member_count,radius)
  if member_count < 1 or member_num < 1 or member_num > member_count then return end
  local name = getMemberName(member_num)
  if name == nil or mq.TLO.Spawn(name)() == nil then return end
  local angle = mq.TLO.Me.Heading.DegreesCCW() + 180
  if member_count > 1 then
    angle = mq.TLO.Me.Heading.DegreesCCW() + member_num * 360 / member_count
  end
  local y = mq.TLO.Me.Y() + math.cos(math.rad(mq.TLO.Me.Heading.DegreesCCW() + angle)) * radius
  local x = mq.TLO.Me.X() + math.sin(math.rad(mq.TLO.Me.Heading.DegreesCCW() + angle)) * radius
  addJob({mqCommand,string.format('/dex %s /moveto loc %d %d',name,y,x)})
end

local function action_Circle()
  local member_count = getMemberCount()
  for member_num = 1, member_count do
    circlePosition(member_num,member_count,30)
  end
end

--[[ Moves group member to a position in a half-circle around Me.
     Param..: member_num - the group member number (1..5), 0 is self
     Param..: member_count - the number of members in the group
     Param..: distance   - the maximum distance from self
     Return.: none
  ]]
local function halfmoonPosition(member_num,member_count,radius)
  if member_count < 1 or member_num < 1 or member_num > member_count then return end
  local name = getMemberName(member_num)
  if name == nil or mq.TLO.Spawn(name)() == nil then return end
  local angle = mq.TLO.Me.Heading.DegreesCCW() + 180
  if member_count > 1 then
    angle = mq.TLO.Me.Heading.DegreesCCW() + 90 + (member_num - 1) * 180 / (member_count - 1)
  end
  local y = mq.TLO.Me.Y() + math.cos(math.rad(angle)) * radius
  local x = mq.TLO.Me.X() + math.sin(math.rad(angle)) * radius
  addJob({mqCommand,string.format('/dex %s /moveto loc %d %d',name,y,x)})
end

local function action_HalfMoon()
  local member_count = getMemberCount()
  for member_num = 1, member_count do
    halfmoonPosition(member_num,member_count,30)
  end
end

--[[ Randomized group say. Will only say text if a target is selected and within 70 feet.
  ]]
local function action_GroupSay(say)
  if say == nil then return end
  if mq.TLO.Target.ID() == 0 then return end
  if mq.TLO.Target.Distance() > 70 then return end
  addJob({mqCommand,'/dgga /multiline ; /target id ${Target.ID}; /docommand /timed $\\{Math.Rand[1,100]} /say '..say})
end  

--[[ Random group say 'ready'
  ]]
local function action_Ready()
  action_GroupSay('ready')
end

--[[ Random group say 'leave'
  ]]
local function action_Leave()
  action_GroupSay('leave')
end

--[[ Everyone click on the nearest door.
  ]]
local function action_Door()
  addJob({mqCommand,'/dgga /multiline ; /doortarget; /timed 2 /click left door'})
  addJob({mqDelay,2})
end

--[[ Invis handler. Invis mode is toggled by middle mouse button.

     Invis or IVU only modes try to get a permanent invis, and fall back to bard (dual) otherwise.
     
     Dual invis mode:
     - if there is a Bard in the group will cast Selo's and Shauri's (level 110)
     - if are two casters in the group will cast group perfected invis (level 76) and perfected IVU (level 95)
     - if there is a non-insta-cast IVU caster and a caster in the group will cast group perfected IVU (level 75) and perfected group invis (level 76)
     - otherwise it will cast group IVU or invis as available
  ]]
  
local function invis_using_casters(caster_1,caster_2)
  sendCommand( caster_1, '/alt act 1210' )
  sendCommand( caster_2, '/timed 1 /alt act 280' )
end

local function invis_using_ivu_and_caster(ivu_caster,caster)
  sendCommand( caster, '/timed 1 /alt act 1210' )
  sendCommand( ivu_caster, '/alt act 1212' )
end

local function action_Invis()
  local bards = {}
  local fast_invis_casters = {}
  local fast_ivu_casters = {}
  local slow_ivu_casters = {}

  for member = 0,getMemberCount() do
    local class = getMemberClass(member)
    if class ~= nil then
      if class == 'BRD' and getMemberLevel(member) >= 110 then table.insert(bards,getMemberName(member)) end
      if class == 'WIZ' or class == 'MAG' or class == 'ENC' then
        if getMemberLevel(member) >= 76 then table.insert(fast_invis_casters,getMemberName(member)) end
        if getMemberLevel(member) >= 95 then table.insert(fast_ivu_casters,getMemberName(member)) end
      end
      if class == 'CLR' or class == 'PAL' or class == 'SHD' or class == 'NEC' then
        if getMemberLevel(member) >= 75 then table.insert(slow_ivu_casters,getMemberName(member)) end
      end
    end
  end

  if invis_mode == 1 then
    if table.getn(fast_invis_casters) > 0 then
      addJob({sendCommand,fast_invis_casters[1],'/alt act 1210'})
    elseif table.getn(bards) > 0 then
      addJob({sendCommand,bards[1],'/multiline ; /twist off; /stopcast; /alt act 3704; /alt act 231'})
    end
    return
  end
  
  if invis_mode == 2 then
    if table.getn(fast_ivu_casters) > 0 then
      addJob({sendCommand,fast_ivu_casters[1],'/alt act 280'})
    elseif table.getn(slow_ivu_casters) > 0 then
      addJob({sendCommand,slow_ivu_casters[1],'/alt act 1212'})
    elseif table.getn(bards) > 0 then
      addJob({sendCommand,bards[1],'/multiline ; /twist off; /stopcast; /alt act 3704; /alt act 231'})
    end
    return
  end
  
  if table.getn(bards) > 0 then
    addJob({sendCommand,bards[1],'/multiline ; /twist off; /stopcast; /alt act 3704; /alt act 231'})
    return
  end

  if table.getn(fast_invis_casters) > 1 and table.getn(fast_ivu_casters) > 0 then
    local invis_caster = fast_invis_casters[1]
    local ivu_caster = fast_ivu_casters[1]
    if invis_caster == ivu_caster then invis_caster = fast_invis_casters[2] end
    addJob({invis_using_casters,invis_caster,ivu_caster})
    return
  end

  if table.getn(slow_ivu_casters) > 0 and table.getn(fast_invis_casters) > 0 then
    addJob({invis_using_ivu_and_caster,slow_ivu_casters[1],fast_invis_casters[1]})
    return
  end

  if table.getn(fast_invis_casters) > 0 then
    addJob({sendCommand,fast_invis_casters[1],'/alt act 1210'})
    return
  end

  if table.getn(fast_ivu_casters) > 0 then
    addJob({sendCommand,fast_ivu_casters[1],'/alt act 280'})
    return
  end
    
  if table.getn(slow_ivu_casters) > 0 then
    addJob({sendCommand,slow_ivu_casters[1],'/alt act 1212'})
    return
  end
end

--[[ Makes everyone visible.
  ]]
local function action_MakeVis()
  addJob({mqCommand,'/dgga /makemevis'})
end

--[[ Pause everyone.
  ]]
local function action_Pause()
  addJob({mqCommand,'/dgga /boxr pause'})
end

--[[ Sets everyone to follow.
  ]]
local function action_FollowOn()
  addJob({mqCommand,'/dgge /multiline ; /afollow off; /nav stop; /timed 5 /afollow spawn ${Me.ID}'})
  addJob({mqDelay,5})
  following = true
end

--[[ Stops everyone following.
  ]]
local function action_FollowOff()
  addJob({mqCommand,'/dgge /multiline ; /afollow off; /nav stop'})
  following = false
end
  
--[[ Makes everyone come to me.
  ]]
local function action_ComeToMe()
  action_FollowOff()
  addJob({mqCommand,'/dgge /nav id ${Me.ID}'})
end

--[[ Unpause everyone.
  ]]
local function action_Resume()
  addJob({mqCommand,'/dgga /boxr unpause'})
end

--[[ Camp Off. Sets everyone to manual. This is a neutral mode
     intended either for travel or as an intermediate mode
     when transitioning between Camp and Chase.
  ]]
local function action_CampOff()
  action_Resume()
  action_FollowOff()
  action_StopFrenzy()
  addJob({mqCommand,'/dgga /multiline ; /boxr manual; /dismount'})
end

--[[ Sets camp radius on all members other than MT.
  ]]
local function action_SetCampRadiusAssist()
  local command = string.format('/noparse /dgga /multiline ; /if (!'..MT..' && '..CWTN..') /${Me.Class.ShortName} campradius %d nosave; /if (!'..MT..' && '..KA..') /campradius %d',camp_radius_assist,camp_radius_assist)
  addJob({mqCommand,command})
end

--[[ Sets camp radius on MT only.
  ]]
local function action_SetCampRadiusTank()
  local command = string.format('/noparse /dgga /multiline ; /if ('..MT..' && '..CWTN..') /${Me.Class.ShortName} campradius %d nosave; /if ('..MT..' && '..KA..') /campradius %d',camp_radius_tank,camp_radius_tank)
  addJob({mqCommand,command})
end

--[[ Sets camp radius on all.
  ]]
local function action_SetCampRadius()
  action_SetCampRadiusAssist()
  action_SetCampRadiusTank()
end

--[[ Sets up camp in the current location.
     To allow this to be performed by any toon we first set everyone to
     camp mode (puts CWTN toons into Assist mode), then send a command
     to the Main Assist to set to SicTank mode. If the main assist is not
     running CTWN then they will stay in whatever mode they were started
     in. Sorry.
     Camp radius is set based on role - everyone but the Main Tank
     will use the 'Assists' value.
  ]]
local function action_CampOn()
  action_Resume()
  action_FollowOff()
  addJob({mqCommand,'/noparse /dgga /multiline ; /boxr camp; /if ('..MA..' && '..CWTN..') /${Me.Class.ShortName} mode 7 nosave;  /if ('..MA..' && '..KA..') /returntocamp 0'})
  action_SetCampRadius()
end

--[[ Chase On. Everyone but the main assist is set to Chase. The
     main assist is currently assumed to be running CWTN and is set
     to Vorpal.
  ]]
local function action_ChaseOn()
  action_Resume()
  action_FollowOff()
  action_StopFrenzy()
  addJob({mqCommand,'/noparse /dgga /multiline ; /if (!'..MA..') /boxr chase; /if ('..MA..') /boxr manual'})
  addJob({mqCommand,string.format('/noparse /dgga /if ('..MA..' && '..CWTN..') /%s mode 3 nosave',mq.TLO.Group.MainAssist.Class.ShortName())})
end

local function action_BurnOn()
  addJob({mqCommand,'/noparse /dgga /multiline ; /if '..CWTN..' /${Me.Class.ShortName} burnallnamed on nosave; /if '..KA..' /varset BurnAllNamed 1'})
end

local function action_BurnOff()
  addJob({mqCommand,'/noparse /dgga /multiline ; /if '..CWTN..' /${Me.Class.ShortName} burnallnamed off nosave; /if '..KA..' /varset BurnAllNamed 0'})
end

local function action_BurnNow()
  addJob({mqCommand,'/dgga /boxr BurnNow'})
end

local function action_CampDesk()
  action_Pause()
  action_Invis()
  addJob({mqDelay,10})
  addJob({mqCommand,'/dgga /camp desktop'})
end

local function action_Inventory()
  if mq.TLO.Cursor.ID() then
   addJob({mqCommand,'/autoi'})
  end
end

local function action_Destroy()
  if mq.TLO.Cursor.ID() then
   addJob({mqCommand,'/destroy'})
  end
end

local function action_Ignore()
  if mq.TLO.Cursor.ID() then
   addJob({mqCommand,'/setitem ignore'})
  end
end

--[[ Does a basic first-time / one-time setup:
      - disables annoying Dannet stuff (may want to enable for debugging)
      - loads MQ2AutoAccept and auto-accepts all
      - loads MQ2Rez and auto-accepts with 0 delay
      - loads MQ2AASpend and enables brute mode
      - configures frame limiter
     Special thanks to Sic and his hot keys.
  ]]
local function action_Setup()
  addJob({mqCommand,'/dgga /dnet localecho off'})
  addJob({mqCommand,'/dgga /dnet commandecho off'})
  addJob({mqCommand,'/noparse /dgga /multiline ; /plugin mq2autoaccept load; /timed 10 /dgga /autoaccept add ${Me.Name}; /timed 15 /autoaccept save'})
  addJob({mqDelay,30})
  addJob({mqCommand,'/dgga /multiline ; /plugin mq2rez load; /timed 5 /rez accept on; /timed 10 /rez acceptpct 90; /timed 15 /rez delay 0'})
  addJob({mqDelay,30})
  addJob({mqCommand,'/dgga /multiline ; /plugin mq2aaspend load; /timed 5 /aaspend bank 200; /timed 10 /aaspend order 53214; /timed 15 /aaspend brute on; /timed 20 /aaspend save'})
  addJob({mqDelay,30})
  addJob({mqCommand,'/dgga /plugin mq2boxr load'})
  addJob({mqDelay,10})
  addJob({mqCommand,'/multiline ; /framelimiter enable; /framelimiter enablefg; /framelimiter savebychar off; /framelimiter bgrender on; /framelimiter clearscreen off; /framelimiter imguirender on; /framelimiter uirender off; /framelimiter bgfps 1.0; /framelimiter fgfps 45.000000; /framelimiter simfps 30.000000'})
  addJob({mqCommand,'/dgae /framelimiter reloadsettings'})
end

local function uiCustomUpDownArrow()
  if pressing_down == 2 then
    ImGui.PushStyleColor(ImGuiCol.Button,1,0,0,1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,1,0,0,1)
    if ImGui.ArrowButton('ArrowUp',ImGuiDir.Up ) then
      action_Down()
    end
    ImGui.PopStyleColor(2)
    showTooltip('Stop force down (/dgga /keypress END)')
  elseif pressing_down == 1 then
    if ImGui.ArrowButton('ArrowDown',ImGuiDir.Down) then
      action_Down()
    end
    showTooltip('Start force down (/dgga /keypress END hold)')
  else
    action_Down()
  end
end

--[[ Displays a list of group members with invisibility status.
     Clicking a name will target and face that member.
     Right-clicking a name will switch to that member.
  ]]
local function showGroupMembers()
  local width = 196
  local member_count = getMemberCount()

  for member_num=0, member_count do
    local member_name = getMemberName(member_num)
    local invis_mask = getInvisMask(member_name)

    local selected = false
    local switchto = false
    if member_name ~= nil then 
      if mq.TLO.Group.MainAssist.Name() == member_name then
        ImGui.PushStyleColor(ImGuiCol.Text,0,1,0,1)
        selected = ImGui.Selectable(member_name,false,ImGuiSelectableFlags.None,width,0)
        ImGui.PopStyleColor()
      else
        selected = ImGui.Selectable(member_name,false,ImGuiSelectableFlags.None,width,0)
      end
      switchto = ImGui.IsItemClicked(ImGuiMouseButton.Right)
    else
      ImGui.Selectable("---",false,ImGuiSelectableFlags.None,width,0)
    end
    if mq.TLO.Cursor.ID() and mq.TLO.Spawn(member_name)() ~= nil and mq.TLO.Spawn(member_name).Distance3D() < 20 then
      showTooltip(string.format('Left-click to trade %s to %s. Right-click to switch to %s.',mq.TLO.Cursor.Name(),member_name,member_name))
    else
      showTooltip(string.format('Left-click to target %s. Right-click to switch to %s.',member_name,member_name))
    end
    
    if show_invis_status then
      ImGui.SameLine()
      drawIndicator(invis_status[member_name],member_num*2)
      ImGui.SameLine()
      drawIndicator(ivu_status[member_name],member_num*2+1)
    end

    if selected then
      addJob({mqCommand,string.format('/multiline ; /tar PC %s; /face; /if (${Cursor.ID}) /click left target',member_name)})
    end

    if switchto then
      addJob({sendCommand,member_name,'/foreground'})
    end
    
  end
  
  ImGui.SameLine()
  if ui_hide_buttons then
    if ImGui.ArrowButton('hide',ImGuiDir.Up ) then
      ui_hide_buttons = false
    end
    showTooltip('Show buttons always (/grouper hide)')
  else
    if ImGui.ArrowButton('show',ImGuiDir.Down ) then
      ui_hide_buttons = true
    end
    showTooltip('Hide buttons when not in focus (/grouper hide)')
  end

end

--[[ Executes an action. If the action is a function then it is called. If the
     action is a string then it is added as a command to the job queue. Function
     actions should perform MQ commands via the job queue.
     
     This function can be called for buttons clicked on the UI, or when an
     element action is invoked from the /grouper bind.
  ]]
local function do_action(action)
  if type(action) == 'function' then action() end
  if type(action) == 'string' then addJob({mqCommand,action}) end
end

--[[ Displays and handles a UI element. Supports two basic element types
      1) An custom UI element using a custom function (uiFunction).
      2) A button element.
     For custom UI elements we just call the custom function. Button elements
     support the following attributes:
      - 'enabled' to determine if the button is enabled
      - 'text_color_ena'* to set color (RGBA) for the button text when enabled
      - 'text_color_dis'* to set color (RGBA) for the button text when disabled
      - 'label'* to set the button text
      - 'tooltip' to set the tool tip
      - 'action'* the action to be performed when clicked
     
     *Note: These attributes can be modified and will be saved to the config file.
  ]]
local function do_ui_element(element)
  if element == nil then return end
  
  if element.uiFunction ~= nil then
    if type(element.uiFunction) == 'function' then element.uiFunction() end
    return
  end
  
  local enabled = true
  if element.enabled ~= nil then
    if type(element.enabled) == 'function' then enabled = element.enabled() end
    if type(element.enabled) == 'boolean'  then enabled = element.enabled end
  end
  
  if enabled then
    local color = WHITE
    if element.text_color_ena ~= nil then color = element.text_color_ena end
    local r,g,b,a = rgba(color)
    ImGui.PushStyleColor(ImGuiCol.Text,r,g,b,a)
  else
    local color = RED
    if element.text_color_dis ~= nil then color = element.text_color_dis end
    local r,g,b,a = rgba(color)
    ImGui.PushStyleColor(ImGuiCol.Text,r,g,b,a)
  end
  
  pressed = ImGui.Button(element.label,100,0)

  ImGui.PopStyleColor()

  if element.tooltip ~= nil then
    local tooltip = ''
    if type(element.tooltip) == 'function' then tooltip = element.tooltip() end
    if type(element.tooltip) == 'string' then tooltip = element.tooltip end
    showTooltip(tooltip)
  end
  
  if pressed and enabled and element.action ~= nil then
    do_action(element.action)
  end

  if ImGui.IsItemClicked(ImGuiMouseButton.Right) then
    if ImGui.IsPopupOpen('element_edit_popup') == false then
      element_being_edited = element
      ImGui.OpenPopup('element_edit_popup')
    end
  end
  
end

local function uiCustomInvisButton()
  if invis_mode == 0 then
    do_ui_element(ui_elements['InvisDual'])
  elseif invis_mode == 1 then
    do_ui_element(ui_elements['InvisNormal'])
  else
    do_ui_element(ui_elements['InvisIVU'])
  end
  if ImGui.IsItemClicked(ImGuiMouseButton.Middle) then
    invis_mode = invis_mode + 1
    if invis_mode == 3 then
      invis_mode = 0
    end
  end
end

--[[ Displays the Follow Me or Stop buttons depending on state.
     The program tries to keep track of whether or not follow
     is on. This will fail if something else toggles follow, or
     follow is used on another character.
  ]]
local function uiCustomFollowButton()
  if not following then
    do_ui_element(ui_elements['FollowOn'])
  else
    do_ui_element(ui_elements['FollowOff'])
  end
end

local function uiCustomAssistRadius()
  local changed = false
  ImGui.PushItemWidth(87)
  camp_radius_assist, changed = ImGui.InputInt("A", camp_radius_assist)
  if changed then action_SetCampRadiusAssist() end
  ImGui.PopItemWidth()
end

local function uiCustomTankRadius()
  local changed = false
  ImGui.PushItemWidth(87)
  camp_radius_tank, changed = ImGui.InputInt("T", camp_radius_tank)
  if changed then action_SetCampRadiusTank() end
  ImGui.PopItemWidth()
end

local function uiCustomAutoAttack()
  if mq.TLO.CWTN == nil then
    auto_attack_enabled = false
    return
  end
  
  auto_attack_enabled, _ = ImGui.Checkbox( 'Auto-Attack', auto_attack_enabled )
  showTooltip( 'Auto-attack aggro mobs within range when in VorpalAssist mode.\nUses camp radius.' )
end

local function loadConfig()

  config_file = string.format("%s%s%s",mq.TLO.MacroQuest.Path():gsub('\\', '/'),'/config/',config_name)

  if not access(config_file,'r') then return end

  local settings = LIP.load(config_file)
  
  for i,v in pairs(ui_elements) do
    if settings[i] ~= nil then
      if settings[i]['label']  ~= nil then ui_elements[i]['label']  = tostring(settings[i]['label'])  end
      if settings[i]['text_color_ena'] ~= nil then ui_elements[i]['text_color_ena'] = tostring(settings[i]['text_color_ena']) end
      if settings[i]['text_color_dis'] ~= nil then ui_elements[i]['text_color_dis'] = tostring(settings[i]['text_color_dis']) end
      if settings[i]['action'] ~= nil then
        ui_elements[i]['action'] = tostring(settings[i]['action']):gsub('\\n','\n')
      end
    end
  end
  if settings['CampRadius'] ~= nil then
    if settings['CampRadius']['assist'] ~= nil then camp_radius_assist = tonumber(settings['CampRadius']['assist']) end
    if settings['CampRadius']['tank'] ~= nil then camp_radius_tank = tonumber(settings['CampRadius']['tank']) end
  end
 
  if settings['Window'] ~= nil then
    if settings['Window']['autohidebuttons'] ~= nil then ui_hide_buttons = settings['Window']['autohidebuttons'] == true end
  end
  
end

local function saveConfig()

  config_file = string.format("%s%s%s",mq.TLO.MacroQuest.Path():gsub('\\', '/'),'/config/',config_name)

  if not access(config_file,'w') then return end
  
  local settings = {}

  for i,v in pairs(ui_elements) do
    if ui_elements[i] ~= nil and ui_elements[i]['label'] ~= nil then
      settings[i] = {}
      local data_to_write = false
      if ui_elements[i]['text_color_ena'] ~= nil then settings[i]['text_color_ena'] = ui_elements[i]['text_color_ena'] data_to_write = true end
      if ui_elements[i]['text_color_dis'] ~= nil then settings[i]['text_color_dis'] = ui_elements[i]['text_color_dis'] data_to_write = true end
      if ui_elements[i]['custom'] ~= nil then
        if ui_elements[i]['label']  ~= nil then settings[i]['label']  = ui_elements[i]['label']:gsub('\n', '\\n')  data_to_write = true end
        if ui_elements[i]['action'] ~= nil then settings[i]['action'] = ui_elements[i]['action']:gsub('\n', '\\n') data_to_write = true end
      end
      if data_to_write == false then settings[i] = nil end
    end
  end
  
  settings['CampRadius'] = {}
  settings['CampRadius']['assist'] = tostring(camp_radius_assist)
  settings['CampRadius']['tank'] = tostring(camp_radius_tank)
  
  settings['Window'] = {}
  settings['Window']['autohidebuttons'] = tostring(ui_hide_buttons)
  
  LIP.save(config_file,settings)
  
end

ui_elements = {
  Scatter=      { label='Scatter',      action=action_Scatter,              tooltip='/grouper scatter' },
  Circle=       { label='Circle',       action=action_Circle,               tooltip='/grouper circle' },
  Moon=         { label='Moon',         action=action_HalfMoon,             tooltip='/grouper moon' },
  Ready=        { label='Ready',        action=action_Ready             },
  Leave=        { label='Leave',        action=action_Leave             },
  Door=         { label='Door',         action=action_Door,                 tooltip='/grouper door'},
  Invis=        { uiFunction=uiCustomInvisButton }, 
  Vis=          { label='Vis',          action=action_MakeVis,              tooltip='/grouper vis'},
  Come=         { label='Come to Me',   action=action_ComeToMe,             tooltip='/grouper come'},
  CampOff=      { label='Camp Off',     action=action_CampOff,              tooltip='/grouper campoff'},
  CampOn=       { label='Camp On',      action=action_CampOn,               tooltip='/grouper campon'},
  ChaseOn=      { label='Chase',        action=action_ChaseOn,              tooltip='/grouper chaseon',   text_color_dis=RED,
                  enabled=function() return mq.TLO.Group.MainAssist.Name() ~= nil end },
  Pause=        { label='Pause',        action=action_Pause,                tooltip='/grouper pause'},
  Resume=       { label='Resume',       action=action_Resume,               tooltip='/grouper resume'},
  TaskQuit=     { label='Task Quit',    action='/dgga /taskquit'        },
  Yes=          { label='Yes',          action='/dgga /yes'             },
  No=           { label='No',           action='/dgga /no'              },
  BurnOn=       { label='Burn On',      action=action_BurnOn            },
  BurnOff=      { label='Burn Off',     action=action_BurnOff           },
  BurnNow=      { label='Burn Now',     action=action_BurnNow           },
  CampDesk=     { label='Camp Desktop', action=action_CampDesk,             tooltip='Camp to desktop'},
  Disband=      { label='Disband',      action='/dgge /disband'         },
  Setup=        { label='Setup',        action=action_Setup,                tooltip='!!!CAUTION!!! Will change your settings!! Use at your own risk!! See Overview for info.', text_color_ena=RED },
  DMMSI=        { label='DMMSI',        action='/lua run dontmakemesayit',  tooltip='/lua run dontmakemesayit'},
  Switcher=     { label='Switcher',     action='/lua run switcher',         tooltip='/lua run switcher'},
  Inventory=    { label='Inventory',    action=action_Inventory,  text_color_dis=RED,
                  enabled=function() return mq.TLO.Cursor.Name() ~= nil end,
                  tooltip=function() if mq.TLO.Cursor.Name() ~= nil then return 'Inventory '..mq.TLO.Cursor.Name() else return 'No item on cursor' end end },
  Destroy=      { label='Destroy',      action=action_Destroy,  text_color_dis=RED,
                  enabled=function() return mq.TLO.Cursor.Name() ~= nil end,
                  tooltip=function() if mq.TLO.Cursor.Name() ~= nil then return 'Destroy '..mq.TLO.Cursor.Name() else return 'No item on cursor' end end },
  Ignore=       { label='Ignore',       action=action_Ignore,  text_color_dis=RED,
                  enabled=function() return mq.TLO.Cursor.Name() ~= nil end,
                  tooltip=function() if mq.TLO.Cursor.Name() ~= nil then return 'Set '..mq.TLO.Cursor.Name()..'to ignore' else return 'No item on cursor' end end },
  UpDown=       { uiFunction=uiCustomUpDownArrow },
  AssistRadius= { uiFunction=uiCustomAssistRadius },
  TankRadius=   { uiFunction=uiCustomTankRadius },
  AutoAttack=   { uiFunction=uiCustomAutoAttack },
  ShowGroup=    { uiFunction=showGroupMembers },
  FollowMe=     { uiFunction=uiCustomFollowButton },
  Separator=    { uiFunction=ImGui.Separator },
  SameLine=     { uiFunction=ImGui.SameLine },
  Custom1=      { label='Custom1', custom=true },
  Custom2=      { label='Custom2', custom=true },
  Custom3=      { label='Custom3', custom=true },
  Custom4=      { label='Custom4', custom=true },
  Custom5=      { label='Custom5', custom=true },
  Custom6=      { label='Custom6', custom=true },
  Invite=       { label='Invite',  custom=true, action='/multiline ; \n/invite member1;\n/invite member2;\n/invite member3;\n/invite member4;\n/invite member5;\n/timed 20 /grouproles set ${Me.Name} 1;\n/timed 20 /grouproles set ${Me.Name} 2' },
  FollowOn=     { label='Follow On',    action=action_FollowOn,         tooltip='/grouper followon'    },
  FollowOff=    { label='Follow Off',   action=action_FollowOff,        tooltip='/grouper followoff', text_color_ena=RED   },
  InvisDual=    { label='Dual',         action=action_Invis,            tooltip='/grouper invis'},
  InvisNormal=  { label='Invis',        action=action_Invis,            tooltip='/grouper invis'},
  InvisIVU=     { label='IVU',          action=action_Invis,            tooltip='/grouper invis'},
}

local ui_layout = {
  'ShowGroup',    'SameLine',      'UpDown',
  'Separator',
  'Scatter',      'SameLine',      'Circle',      'SameLine',      'Moon',
  'Ready',        'SameLine',      'Leave',       'SameLine',      'Door',
  'Invis',        'SameLine',      'Vis',         'SameLine',      'Pause',
  'Come',         'SameLine',      'FollowMe',    'SameLine',      'Resume',
  'CampOff',      'SameLine',      'CampOn',      'SameLine',      'ChaseOn',
  'AssistRadius', 'SameLine',      'TankRadius',  'SameLine',      'AutoAttack',
  'Separator',
  'Custom1',      'SameLine',      'Custom2',     'SameLine',      'Custom3',
  'Custom4',      'SameLine',      'Custom5',     'SameLine',      'Custom6',
  'Separator',
  'BurnOn',       'SameLine',      'BurnOff',     'SameLine',      'BurnNow',
  'TaskQuit',     'SameLine',      'Yes',         'SameLine',      'No',
  'Separator',
  'CampDesk',     'SameLine',      'Disband',     'SameLine',      'Invite',
  'DMMSI',        'SameLine',      'Switcher',    'SameLine',      'Setup',
  'Separator',
  'Inventory',    'SameLine',      'Destroy',     'SameLine',      'Ignore'
}

local function uiColorPicker(title,original_color,default_color)
  
  local color = default_color
  if original_color ~= nil then color = original_color end
    
  local colors = {}
  colors[1],colors[2],colors[3],colors[4] = rgba(color)
    
  local new_colors, changed = ImGui.ColorEdit4(title, colors, ImGuiColorEditFlags.NoInputs)
  if changed then
    return true, string.format("%d,%d,%d,%d", math.floor(new_colors[1]*255), math.floor(new_colors[2]*255), math.floor(new_colors[3]*255), math.floor(new_colors[4]*255))
  else
    return false, original_color
  end

end

local function ElementEditPopupUI()
  local changed = false
  local data = ''

  ImGui.SetNextWindowSize(0,0)
  if ImGui.BeginPopup('element_edit_popup') then
  
    changed, data = uiColorPicker('Enabled Text',element_being_edited.text_color_ena,WHITE)
    if changed and data ~= element_being_edited.text_color_ena then
      element_being_edited.text_color_ena = data
    end
    if element_being_edited.text_color_dis ~= nil then
      changed, data = uiColorPicker('Disabled Text',element_being_edited.text_color_dis,RED)
      if changed and data ~= element_being_edited.text_color_dis then
        element_being_edited.text_color_dis = data
      end
    end
    
    if element_being_edited.custom ~= nil then
    
      data, changed = ImGui.InputText('Label',element_being_edited.label)
      if changed and data ~= element_being_edited.label then
        element_being_edited.label = data
      end

      if element_being_edited.action == nil or string.len(element_being_edited.action) == 0 then element_being_edited.action = DEFAULT_CUSTOM_COMMAND end
      data, changed = ImGui.InputTextMultiline('Command', element_being_edited.action)
      if changed and data ~= element_being_edited.action then
        element_being_edited.action = data
      end
    end

    if ImGui.Button("Done") then
      ImGui.CloseCurrentPopup()
    end
    
    ImGui.EndPopup()
  end
end

function GrouperUI()

  if OpenUI then
    local themeToken = themeBridge.push()
  
    ImGui.SetNextWindowSize(0, 0)
    ImGui.SetNextWindowBgAlpha(0.7)
    local WindowFlags = bit32.bor(ImGuiWindowFlags.NoResize,ImGuiWindowFlags.AlwaysAutoResize)
    OpenUI, ShowUI = ImGui.Begin(LuaName, OpenUI, WindowFlags)
    showTooltip( string.format( '%s Version %s', LuaName, LuaVersion ) )

    if ShowUI then
    
      if not ui_hide_buttons or ImGui.IsWindowHovered(ImGuiHoveredFlags.AllowWhenBlockedByActiveItem) then
        for i, element in pairs(ui_layout) do
          do_ui_element(ui_elements[element])
        end
      else
        do_ui_element(ui_elements['ShowGroup'])
        do_ui_element(ui_elements['SameLine'])
        do_ui_element(ui_elements['UpDown'])
      end

      ElementEditPopupUI()
    end

    ImGui.End()
    themeBridge.pop(themeToken)
  end
end

local function action_Beep()
  addJob({mqCommand,'/beep'})
end

--[[ Queries the invisibility status of a peer.
      @param peer     - the peer name
      @param query    - the query, e.g., 'Me.Invis[1]'
      @param timeout  - timeout in milliseconds
  ]]
local function invis_query(names,query)
  local invis_status = {}
  for i,name in pairs(names) do
    invis_status[name] = DANNET.observe(name,query)
  end
  return invis_status
end

--[[ Updates invisibility status tables.
  ]]
local function invis_update()
  local names = {}
  for member= 0, getMemberCount() do
    local name = getMemberName(member)
    if name ~= nil then
      names[member] = name
      DANNET.addPeer(observer_list,name)
    end
  end
  invis_status = invis_query(names,INVIS_QUERY)
  ivu_status   = invis_query(names,IVU_QUERY)
  invis_update_time = os.time()
end

--[[ Ensures someone is set to the MA and MT role. Grouper assumes
     the same person is assigned to both roles. You should really
     set your Main Assist before starting but yeah, if you auto-started
     Grouper then this can kick in.
  ]]
local function set_Roles()

  -- Can only change roles from Leader. Let them handle it.
  currentLeader = mq.TLO.Group.Leader()
  if currentLeader == nil then return end

  -- Get assignments.
  currentMA = mq.TLO.Group.MainAssist()
  currentMT = mq.TLO.Group.MainTank()
  
  -- Nobody set as either MT or MA. Find the first tank class and assign both.
  if currentMA == nil and currentMT == nil then
    local primary_tanks = {}
    local secondary_tanks = {}
    local tank_name = currentLeader
    
    for member = 0, getMemberCount() do
      local class = getMemberClass(member)
      if class ~= nil then
        if class == 'WAR' or class == 'SHD' or class == 'PAL' then table.insert(primary_tanks,getMemberName(member)) end
        if class == 'RNG' or class == 'BRD' then table.insert(secondary_tanks,getMemberName(member)) end
      end
    end
    
    if table.getn(primary_tanks) > 0 then
      tank_name = primary_tanks[1]
    elseif table.getn(secondary_tanks) > 0 then
      tank_name = secondary_tanks[1]
    end
    
    sendCommand(currentLeader,string.format('/grouproles set %s 1',tank_name))
    sendCommand(currentLeader,string.format('/grouproles set %s 2',tank_name))
  
  -- MA is set, MT is not. Set MT.
  elseif currentMA ~= nil and currentMT == nil then
    sendCommand(currentLeader,string.format('/grouproles set %s 1',currentMA))

  -- MT is set, MA is not. Set MA.
  elseif currentMT ~= nil and currentMA == nil then
    sendCommand(currentLeader,string.format('/grouproles set %s 2',currentMT))
    
  -- Both MT and MA are set, but not the same. Set MT to MA.
  elseif currentMT ~= currentMA then
    sendCommand(currentLeader,string.format('/grouproles set %s 1',currentMA))
  end

end

--[[ If enabled, targets and attacks any mob within radius. This function is meant for
     use with Vorpal mode (i.e., Chase) to allow something akin to SicTank mode with a camp
     that moves with you. Only works with characters run by CWTN plugins.
  ]]
local function auto_Attack()

  if not auto_attack_enabled or mq.TLO.Me.Combat() then
    return
  end
  
  local cwtn = mq.TLO.CWTN
  if cwtn == nil or cwtn.ModeID() ~= 3 then
    return
  end
  
  local min_distance = cwtn.CampRadius()
  local auto_target = nil
  
  local num_slots = mq.TLO.Me.XTargetSlots()
  for slot=1,num_slots do
    local xtarget = mq.TLO.Me.XTarget(slot)
    if xtarget ~= nil and xtarget.ID() ~= 0 and xtarget.TargetType() == 'Auto Hater' then
      local distance = xtarget.Distance()
      if distance ~= nil and distance < min_distance then
        min_distance = distance
        auto_target = xtarget
      end
    end
  end

  if auto_target == nil then
    return
  end
  
  if auto_target.ID() ~= mq.TLO.Target.ID() then
    mq.cmdf( '/tar ID %d', auto_target.ID() )
    mq.delay( 200, function() return mq.TLO.Target.ID() == auto_target.ID() end )
  end

  if auto_target.ID() ~= mq.TLO.Target.ID() then
    return
  end

  mq.cmd( '/attack on' )

end

--[[ Update the assist and tank camp radius.
  ]]
local function grouper_Radius(assist_radius,tank_radius)
  if assist_radius ~= nil and type(assist_radius) == 'string' then
    radius = tonumber(assist_radius)
    if radius ~= nil then
      camp_radius_assist = radius
      action_SetCampRadiusAssist()
    end
  end
  if tank_radius ~= nil and type(tank_radius) == 'string' then
    radius = tonumber(tank_radius)
    if radius ~= nil then
      camp_radius_tank = radius
      action_SetCampRadiusTank()
    end
  end
end

--[[ Utility function used for all binds that mimic a button click. Performs
     the action associated with the button in the same way as when the
     button is clicked.
  ]]
local function bind_action(element)
  do_action(ui_elements[element].action)
end

--[[ Set up a bind to allow command line or hotkey access
     to Grouper functionality. Pretty much everything that
     Grouper does can be accessed via "/grouper xxxx". Multiple
     functions can be run at once, e.g.,
       /grouper pause invis follow
  ]]
local binds = {}
binds["down"]     = { action_Down                 }
binds["scatter"]  = { bind_action, 'Scatter'      }
binds["circle"]   = { bind_action, 'Circle'       }
binds["moon"]     = { bind_action, 'Moon'         }
binds["ready"]    = { bind_action, 'Ready'        }
binds["leave"]    = { bind_action, 'Leave'        }
binds["door"]     = { bind_action, 'Door'         }
binds["invis"]    = { action_Invis                }
binds["vis"]      = { bind_action, 'Vis'          }
binds["pause"]    = { bind_action, 'Pause'        }
binds["come"]     = { bind_action, 'Come'         }
binds["followon"] = { bind_action, 'FollowOn'     }
binds["followoff"]= { bind_action, 'FollowOff'    }
binds["resume"]   = { bind_action, 'Resume'       }
binds["campoff"]  = { bind_action, 'CampOff'      }
binds["campon"]   = { bind_action, 'CampOn'       }
binds["chaseon"]  = { bind_action, 'ChaseOn'      }
binds["custom1"]  = { bind_action, 'Custom1'      }
binds["custom2"]  = { bind_action, 'Custom2'      }
binds["custom3"]  = { bind_action, 'Custom3'      }
binds["custom4"]  = { bind_action, 'Custom4'      }
binds["custom5"]  = { bind_action, 'Custom5'      }
binds["custom6"]  = { bind_action, 'Custom6'      }
binds["burnon"]   = { bind_action, 'BurnOn'       }
binds["burnoff"]  = { bind_action, 'BurnOff'      }
binds["burn"]     = { bind_action, 'BurnNow'      }
binds["taskquit"] = { bind_action, 'TaskQuit'     }
binds["yes"]      = { bind_action, 'Yes'          }
binds["no"]       = { bind_action, 'No'           }
binds["desktop"]  = { bind_action, 'CampDesk'     }
binds["disband"]  = { bind_action, 'Disband'      }
binds["invite"]   = { bind_action, 'Invite'       }
binds["inventory"]= { bind_action, 'Inventory'    }
binds["destroy"]  = { bind_action, 'Destroy'      }
binds["ignore"]   = { bind_action, 'Ignore'       }
binds["hide"]     = { function() ui_hide_buttons = not ui_hide_buttons end }
binds["show"]     = { function() ui_hide_buttons = not ui_hide_buttons end }
binds["beep"]     = { action_Beep                 }
binds["radius"]   = { grouper_Radius              }
binds["quit"]     = { function() grouper_running = false end }

--[[ Bind handler. Will execute a bind from the table for
     each argument that matches. The next two arguments are
     added to the bind table (copy) to be passed to the
     bind function in addition to any argumens in the table.
     This is a bit ugly but works for now (only the radius bind
     requires arguments for now).
  ]]
local function bind_Grouper(...)
  local args = {...}
  for i=1,#args do
    if args[i] ~= nil and binds[string.lower(args[i])] ~= nil then
      local bind = TABLE.copy(binds[string.lower(args[i])])
      table.insert(bind,args[i+1])
      table.insert(bind,args[i+2])
      if bind ~= nil then addJob(bind) end
    end
  end
end

local function init()

  math.randomseed(os.time())

  set_Roles()

  loadConfig()

  mq.bind('/grouper',bind_Grouper)

  mq.imgui.init(LuaName, GrouperUI)

  action_SetCampRadius()
  
  DANNET.addQuery(observer_list,INVIS_QUERY)
  DANNET.addQuery(observer_list,IVU_QUERY)

end

local function loop()

  while OpenUI and grouper_running do

    if show_invis_status and os.difftime( os.time(), invis_update_time) > 0 then
      invis_update()
    else
      mq.delay(ONE_TENTH_SECOND)
    end
    
    set_Roles()
    
    auto_Attack()
    
    if job_queue_delay > 0 then
      job_queue_delay = job_queue_delay - 1
    else
      local action = getJob(job_queue)
      if action ~= nil then action[1]( action[2], action[3], action[4], action[5] ) end
    end
    
  end
  
end

local function leave()

  DANNET.removeAll(observer_list)

  saveConfig()

  if pressing_down == 2 then
    mqCommand('/dgga /keypress END')
  end

end

init()
loop()
leave()
