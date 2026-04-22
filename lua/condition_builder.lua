-----------------------------------------------------------
-- ConditionBuilder.lua  v4  (MuleAssist Edition)
-- MQNext In-Game Lua Condition Builder — Complete Edition
--
-- Place in:  <MQ2Dir>/lua/ConditionBuilder.lua
-- Run:       /lua run ConditionBuilder
-- Commands:  /cb [show|hide|toggle|clear|quit]
-----------------------------------------------------------

local mq    = require('mq')
local ImGui = require('ImGui')

-- Optional MAUI theme bridge (graceful fallback if not present)
local okTheme, themeBridge = pcall(require, 'lib.maui_theme_bridge')
if not okTheme then
    themeBridge = { push = function() return nil end, pop = function() end }
end

-- ImGui integer constants (avoids ImGui.Xxx.Yyy nil-crashes in MQNext)
local COND_FIRST = 2   -- ImGuiCond_FirstUseEver
local FLAG_RO    = 1   -- ImGuiInputTextFlags_ReadOnly

-- ──────────────────────────────────────────────────────
-- COLOR PALETTE  (your cyan/teal MuleAssist theme)
-- ──────────────────────────────────────────────────────
local C = {
    HEADER   = {0.45, 0.90, 0.98, 1.0},   -- bright cyan title
    PREVIEW  = {0.72, 0.95, 1.00, 1.0},   -- light cyan preview text
    OK       = {0.22, 0.83, 0.33, 1.0},   -- green  (valid / true)
    WARN     = {0.89, 0.70, 0.25, 1.0},   -- yellow (warning)
    ERR      = {0.97, 0.32, 0.29, 1.0},   -- red    (error / false)
    MUTED    = {0.54, 0.58, 0.62, 1.0},   -- gray   (disabled text)
    ORANGE   = {0.94, 0.53, 0.24, 1.0},   -- orange (TLO names)
    PURPLE   = {0.74, 0.55, 1.00, 1.0},   -- purple (return types)
    FALSE_C  = {0.54, 0.58, 0.62, 1.0},   -- gray   (false result)
}

-- ──────────────────────────────────────────────────────
-- HELPERS
-- ──────────────────────────────────────────────────────
local function trim(s) return (s or ''):match('^%s*(.-)%s*$') end
local function split(s, sep)
    local t = {}
    for p in ((s or '')..sep):gmatch('(.-)'..sep) do table.insert(t,p) end
    return t
end
local function ts() return os.date('%H:%M:%S') end
local function logMsg(buf, msg, max)
    table.insert(buf, 1, '['..ts()..'] '..msg)
    if #buf > (max or 200) then table.remove(buf) end
end
local function escapeIni(v) return tostring(v or ''):gsub('"','\\"') end

-- ──────────────────────────────────────────────────────
-- PLUGIN DETECTION
-- ──────────────────────────────────────────────────────
local PLUGINS = {}
local function detectPlugins()
    PLUGINS = {}
    local known = {
        { name='MQ2DanNet', tlos={ {tlo='mq.TLO.DanNet.Peers()',ret='string',cat='DanNet',notes='Connected peer list'} } },
        { name='MQ2Nav',    tlos={ {tlo='mq.TLO.Navigation.Active()',ret='bool',cat='Nav',notes='Nav in progress'},
                                    {tlo='mq.TLO.Navigation.Paused()',ret='bool',cat='Nav',notes='Nav paused'} } },
        { name='MQ2Twist',  tlos={ {tlo='mq.TLO.Twist.Active()',ret='bool',cat='Twist',notes='Twist active'} } },
        { name='MQ2CWTN',   tlos={ {tlo='mq.TLO.CWTN.BurnNow()',ret='bool',cat='CWTN',notes='Burn active'},
                                    {tlo='mq.TLO.CWTN.Mode()',ret='string',cat='CWTN',notes='Current mode'} } },
        { name='MQ2Kiss',   tlos={ {tlo='mq.TLO.Kiss.BurnNow()',ret='bool',cat='Kiss',notes='KA burn'} } },
    }
    for _,p in ipairs(known) do
        local ok = pcall(function() return mq.TLO.Plugin(p.name) and mq.TLO.Plugin(p.name).IsLoaded() end)
        if ok and mq.TLO.Plugin(p.name) and mq.TLO.Plugin(p.name).IsLoaded() then
            table.insert(PLUGINS, p)
        end
    end
end
detectPlugins()

-- ──────────────────────────────────────────────────────
-- CONDITION GROUPS
-- ──────────────────────────────────────────────────────
local condGroups = {}
local function resolveGroups(code)
    local r = code
    for _,g in ipairs(condGroups) do
        r = r:gsub('@'..g.name:gsub('%s','_'), '('..g.code..')')
    end
    return r
end

-- ──────────────────────────────────────────────────────
-- PIECE BUILDER DATA  (from your version, expanded)
-- ──────────────────────────────────────────────────────
local BASES = {
    { label='Me.PctHPs',              lhs='Me.PctHPs' },
    { label='Me.PctMana',             lhs='Me.PctMana' },
    { label='Me.PctEndurance',        lhs='Me.PctEndurance' },
    { label='Me.Casting.ID',          lhs='Me.Casting.ID' },
    { label='Me.InCombat',            lhs='Me.Combat' },
    { label='Me.Sitting',             lhs='Me.Sitting' },
    { label='Me.Standing',            lhs='Me.Standing' },
    { label='Me.Invis',               lhs='Me.Invis' },
    { label='Me.Speed',               lhs='Me.Speed' },
    { label='Me.Level',               lhs='Me.Level' },
    { label='Me.XTarget',             lhs='Me.XTarget' },
    { label='Target.PctHPs',          lhs='Target.PctHPs' },
    { label='Target.Distance',        lhs='Target.Distance' },
    { label='Target.Named',           lhs='Target.Named' },
    { label='Target.CleanName',       lhs='Target.CleanName' },
    { label='Target.ID',              lhs='Target.ID' },
    { label='Target.Aggressive',      lhs='Target.Aggressive' },
    { label='Target.Type',            lhs='Target.Type' },
    { label='Target.Level',           lhs='Target.Level' },
    { label='Group.Member[#].PctHPs', lhs='Group.Member[%d].PctHPs', needsIndex=true },
    { label='Group.Injured[percent]', lhs='Group.Injured[%s]', needsText=true, textHint='60' },
    { label='Me.Buff[buffname].ID',   lhs='Me.Buff[%s].ID', needsText=true, textHint='Credence' },
    { label='Me.Song[songname].ID',   lhs='Me.Song[%s].ID', needsText=true, textHint='Warsong' },
    { label='Me.SpellReady[spell]',   lhs='Me.SpellReady[%s]', needsText=true, textHint='Complete Heal' },
    { label='SpawnCount[query]',      lhs='SpawnCount[%s]', needsText=true, textHint='npc radius 80 named' },
    { label='Spawn[query].ID',        lhs='Spawn[%s].ID', needsText=true, textHint='npc radius 100 named' },
    { label='Navigation.Active',      lhs='Navigation.Active' },
    { label='Zone.Safe',              lhs='Zone.Safe' },
    { label='Zone.ShortName',         lhs='Zone.ShortName' },
    { label='Pet.PctHPs',             lhs='Pet.PctHPs' },
    { label='Custom (manual)',        lhs='', custom=true },
}

local OPS = {
    { label='==',              kind='binary',  symbol='==' },
    { label='!=',              kind='binary',  symbol='!=' },
    { label='>',               kind='binary',  symbol='>' },
    { label='<',               kind='binary',  symbol='<' },
    { label='>=',              kind='binary',  symbol='>=' },
    { label='<=',              kind='binary',  symbol='<=' },
    { label='.Equal[value]',   kind='method',  method='Equal' },
    { label='.NotEqual[value]',kind='method',  method='NotEqual' },
    { label='.Find[value]',    kind='method',  method='Find' },
    { label='Exists / truthy', kind='truthy',  needsValue=false },
    { label='Not Exists/falsy',kind='falsy',   needsValue=false },
}

local VALUE_TYPES = {
    { label='Number',              id='number' },
    { label='String',              id='string' },
    { label='Raw Macro (no quotes)',id='raw' },
    { label='TRUE / FALSE',        id='bool' },
    { label='NULL',                id='null' },
}

-- MAUI INI section → condition key prefix  (from your version)
local SECTION_PREFIX = {
    DPS='DPSCond', Buffs='BuffsCond', Heals='HealsCond',
    Cures='CuresCond', Mez='MezCond', OhShit='OhShitCond',
    Burn='BurnCond', AE='AECond', Pet='PetCond',
}
local INI_SECTIONS = {'DPS','Buffs','Heals','Cures','Mez','OhShit','Burn','AE','Pet'}

-- ──────────────────────────────────────────────────────
-- INI SAVE / LOAD  (ConditionBuilder's own named saves)
-- ──────────────────────────────────────────────────────
local CB_INI = 'ConditionBuilder'

local function cbIniSave(name, code, tag)
    if trim(name)=='' then return false end
    local k = name:gsub('%s','_')
    mq.cmdf('/ini "%s" "Conditions" "%s" "%s"', CB_INI, k, escapeIni(code))
    mq.cmdf('/ini "%s" "Tags"       "%s" "%s"', CB_INI, k, escapeIni(tag or ''))
    return true
end
local function cbIniLoad(name)
    local k = name:gsub('%s','_')
    local code = mq.TLO.Ini(CB_INI,'Conditions',k,'')()
    local tag  = mq.TLO.Ini(CB_INI,'Tags',k,'')()
    return code, tag
end
local function cbIniList()
    local raw = mq.TLO.Ini(CB_INI,'Index','keys','')()
    if not raw or raw=='' then return {} end
    return split(raw,'|')
end
local function cbIniAddIndex(name)
    local k = name:gsub('%s','_')
    local ex = mq.TLO.Ini(CB_INI,'Index','keys','')()
    local keys = (ex and ex~='') and split(ex,'|') or {}
    for _,v in ipairs(keys) do if v==k then return end end
    table.insert(keys,k)
    mq.cmdf('/ini "%s" "Index" "keys" "%s"', CB_INI, table.concat(keys,'|'))
end
local function cbIniDelete(name)
    local k = name:gsub('%s','_')
    mq.cmdf('/ini "%s" "Conditions" "%s" ""', CB_INI, k)
    mq.cmdf('/ini "%s" "Tags"       "%s" ""', CB_INI, k)
    local keys = cbIniList()
    local nk = {}
    for _,v in ipairs(keys) do if v~=k then table.insert(nk,v) end end
    mq.cmdf('/ini "%s" "Index" "keys" "%s"', CB_INI, table.concat(nk,'|'))
end

-- ──────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────
local function validateLua(code)
    local errs, warns = {}, {}
    if trim(code)=='' then return true, errs, warns end
    local r = resolveGroups(code)
    local depth, hadNeg = 0, false
    for c in r:gmatch('.') do
        if c=='(' then depth=depth+1 elseif c==')' then depth=depth-1 end
        if depth<0 and not hadNeg then table.insert(errs,'Extra closing )') hadNeg,depth=true,0 end
    end
    if depth>0 then table.insert(errs,'Missing '..depth..' closing )') end
    if not r:find('mq%.TLO%.') and not r:find('%$%{') then
        table.insert(warns,'No TLO reference found') end
    if r:match('%sand%s*$') or r:match('%sor%s*$') then
        table.insert(errs,'Ends with and/or') end
    if r:match('^%s*and%s') or r:match('^%s*or%s') then
        table.insert(errs,'Starts with and/or') end
    local s=r:gsub('"[^"]*"',''):gsub("'[^']*'",'')
    if s:match('[^~<>=!]=[^=>]') then table.insert(warns,'Possible = instead of == or ~=') end
    if r:find('not%s+not%s') then table.insert(warns,'Double not not is redundant') end
    return (#errs==0), errs, warns
end

local function buildLuaBlock(code, mode)
    local r = resolveGroups(code)
    if trim(r)=='' then return '-- enter a condition above' end
    if mode=='if' then return 'if '..r..' then\n    -- action here\nend' end
    if mode=='macro' then
        local m = r
        m=m:gsub('mq%.TLO%.Me%.PctHPs%(%)','${Me.PctHPs}')
        m=m:gsub('mq%.TLO%.Me%.PctMana%(%)','${Me.PctMana}')
        m=m:gsub('mq%.TLO%.Me%.PctEndurance%(%)','${Me.PctEndurance}')
        m=m:gsub('mq%.TLO%.Me%.Combat%(%)','${Me.Combat}')
        m=m:gsub('mq%.TLO%.Me%.Sitting%(%)','${Me.Sitting}')
        m=m:gsub('mq%.TLO%.Me%.Standing%(%)','${Me.Standing}')
        m=m:gsub('mq%.TLO%.Me%.Casting%.ID%(%)','${Me.Casting.ID}')
        m=m:gsub('mq%.TLO%.Me%.Invis%(%)','${Me.Invis}')
        m=m:gsub("mq%.TLO%.Me%.Buff%('([^']+)'%)%.ID%(%)","${Me.Buff[%1].ID}")
        m=m:gsub("mq%.TLO%.Me%.Song%('([^']+)'%)%.ID%(%)","${Me.Song[%1].ID}")
        m=m:gsub("mq%.TLO%.Me%.SpellReady%('([^']+)'%)","${Me.SpellReady[%1]}")
        m=m:gsub('mq%.TLO%.Target%.ID%(%)','${Target.ID}')
        m=m:gsub('mq%.TLO%.Target%.PctHPs%(%)','${Target.PctHPs}')
        m=m:gsub('mq%.TLO%.Target%.Distance%(%)','${Target.Distance}')
        m=m:gsub('mq%.TLO%.Target%.Type%(%)','${Target.Type}')
        m=m:gsub('mq%.TLO%.Target%.Aggressive%(%)','${Target.Aggressive}')
        m=m:gsub('mq%.TLO%.Zone%.Safe%(%)','${Zone.Safe}')
        m=m:gsub('mq%.TLO%.Navigation%.Active%(%)','${Navigation.Active}')
        m=m:gsub('mq%.TLO%.Group%.Members%(%)','${Group.Members}')
        m=m:gsub(' and ',' && '):gsub(' or ',' || '):gsub('not ','!')
        return '/if ('..m..') {\n  /docommand\n}'
    end
    return 'local function checkCondition()\n    return (\n        '..r..'\n    )\nend'
end

-- ──────────────────────────────────────────────────────
-- PIECE BUILDER LOGIC  (your version's approach)
-- ──────────────────────────────────────────────────────
local pb = {
    selectedBase=1, selectedOp=1, valueType=1,
    valueInput='', customLhs='', extraText='', groupIndex=1,
    preview='',
}

local function pbNormalizeValue(op)
    if op and op.needsValue==false then return '' end
    local vt = VALUE_TYPES[pb.valueType] and VALUE_TYPES[pb.valueType].id or 'raw'
    local raw = tostring(pb.valueInput or '')
    if vt=='number' then return tostring(tonumber(raw) or 0)
    elseif vt=='string' then
        if raw:match('^".*"$') then return raw end
        return '"'..raw..'"'
    elseif vt=='bool' then
        local u=raw:upper() return (u=='TRUE' or u=='FALSE') and u or 'TRUE'
    elseif vt=='null' then return 'NULL' end
    return raw
end

local function pbCurrentLhs()
    local base = BASES[pb.selectedBase]
    if not base then return '' end
    if base.custom then return tostring(pb.customLhs or '') end
    if base.needsIndex then return string.format(base.lhs, tonumber(pb.groupIndex) or 1) end
    if base.needsText  then return string.format(base.lhs, tostring(pb.extraText or '')) end
    return base.lhs
end

local function pbBuildPiece()
    local lhs = pbCurrentLhs()
    local op  = OPS[pb.selectedOp]
    if lhs=='' or not op then return '' end
    -- Determine if this is Lua mq.TLO style or MQ2 ${} style
    -- We'll output MQ2 ${} style in the piece builder to match your original
    if op.kind=='truthy'  then return '${' ..lhs..'}' end
    if op.kind=='falsy'   then return '!${'..lhs..'}' end
    if op.kind=='method'  then return string.format('${%s.%s[%s]}',lhs,op.method,pbNormalizeValue(op)) end
    return string.format('${%s} %s %s', lhs, op.symbol, pbNormalizeValue(op))
end

-- ──────────────────────────────────────────────────────
-- GLOBAL RUNNING STATE
-- ──────────────────────────────────────────────────────
local running = true
local open    = true

-- ══════════════════════════════════════════════════════
--  TAB 1 — BUILDER
-- ══════════════════════════════════════════════════════
local bld = {
    input='', block='-- enter a condition above',
    msg='', ok=true, errors={}, warnings={},
    flash=0, history={}, HMAX=50,
    saveName='', saveTag='', saveMsg='',
    showSaves=false,
    -- MAUI INI export (your version)
    mauiFile='', mauiSection='DPS', mauiIndex=1,
}

local QUICK = {
    {l='PctHPs()',      v='mq.TLO.Me.PctHPs()'},{l='PctMana()',     v='mq.TLO.Me.PctMana()'},
    {l='PctEnd()',      v='mq.TLO.Me.PctEndurance()'},{l='Combat()',v='mq.TLO.Me.Combat()'},
    {l="Buff('?')",     v="mq.TLO.Me.Buff('')"},{l="Song('?')",     v="mq.TLO.Me.Song('')"},
    {l="SpellRdy('?')", v="mq.TLO.Me.SpellReady('')"},{l='Casting.ID()',v='mq.TLO.Me.Casting.ID()'},
    {l='Sitting()',     v='mq.TLO.Me.Sitting()'},{l='Standing()',   v='mq.TLO.Me.Standing()'},
    {l='Tgt.ID()',      v='mq.TLO.Target.ID()'},{l='Tgt.HP()',      v='mq.TLO.Target.PctHPs()'},
    {l='Tgt.Dist()',    v='mq.TLO.Target.Distance()'},{l='Tgt.Type()',v='mq.TLO.Target.Type()'},
    {l='Nav.Active()',  v='mq.TLO.Navigation.Active()'},{l='Zone.Safe()',v='mq.TLO.Zone.Safe()'},
    {l='SpawnCnt()',    v="mq.TLO.SpawnCount('npc radius 30')()"},
    {l=' and ',v=' and '},{l=' or ',v=' or '},{l='not ',v='not '},
    {l=' ~= ',v=' ~= '},{l=' == ',v=' == '},{l=' < ',v=' < '},{l=' > ',v=' > '},
    {l='nil',v='nil'},{l='( )',v='()'},
}

local function bldPushHistory(code)
    if trim(code)=='' then return end
    for i,h in ipairs(bld.history) do if h==code then table.remove(bld.history,i) break end end
    table.insert(bld.history,1,code)
    if #bld.history>bld.HMAX then table.remove(bld.history) end
end

local function bldRunValidate()
    local ok,errs,warns = validateLua(bld.input)
    bld.errors,bld.warnings=errs,warns
    bld.block = buildLuaBlock(bld.input,'function')
    if #errs>0 then bld.msg,bld.ok='[X] '..#errs..' error(s)',false
    elseif #warns>0 then bld.msg,bld.ok='[!] Valid — '..#warns..' warning(s)',nil
    else bld.msg,bld.ok='[OK] Condition looks valid',true end
    bldPushHistory(bld.input)
end

local function bldLoad(code)
    bld.input=code bld.block=buildLuaBlock(code,'function')
    bld.msg='' bld.errors={} bld.warnings={}
end

local function drawBuilder()
    -- ── Condition input ──
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4], 'MuleAssist Condition Builder')
    ImGui.Separator()
    local nv,ch = ImGui.InputTextMultiline('##cond',bld.input,-1,74)
    if ch then bld.input=nv end
    ImGui.TextWrapped('Build pieces below then append. Use AND/OR/NOT/grouping buttons for logic.')
    ImGui.Separator()

    -- ── Piece Builder (your dropdown approach) ──
    ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4], 'Piece Builder  (builds ${TLO} op value pieces)')
    if ImGui.BeginCombo('Base TLO / Left Side', BASES[pb.selectedBase].label) then
        for i,b in ipairs(BASES) do
            if ImGui.Selectable(b.label, i==pb.selectedBase) then pb.selectedBase=i end
        end
        ImGui.EndCombo()
    end
    local b = BASES[pb.selectedBase]
    if b.custom then
        local cv,cc=ImGui.InputText('Custom Left Side',pb.customLhs) if cc then pb.customLhs=cv end
    elseif b.needsIndex then
        local iv,ic=ImGui.InputInt('Group Member Index',pb.groupIndex)
        if ic then pb.groupIndex=math.max(1,iv) end
    elseif b.needsText then
        local tv,tc=ImGui.InputText('Query / Name',pb.extraText) if tc then pb.extraText=tv end
        ImGui.SameLine() ImGui.TextDisabled(b.textHint or '')
    end
    if ImGui.BeginCombo('Operator', OPS[pb.selectedOp].label) then
        for i,op in ipairs(OPS) do
            if ImGui.Selectable(op.label, i==pb.selectedOp) then pb.selectedOp=i end
        end
        ImGui.EndCombo()
    end
    local op = OPS[pb.selectedOp]
    if op.needsValue ~= false then
        if ImGui.BeginCombo('Value Type', VALUE_TYPES[pb.valueType].label) then
            for i,vt in ipairs(VALUE_TYPES) do
                if ImGui.Selectable(vt.label, i==pb.valueType) then pb.valueType=i end
            end
            ImGui.EndCombo()
        end
        local vv,vc=ImGui.InputText('Value',pb.valueInput) if vc then pb.valueInput=vv end
    end
    pb.preview = pbBuildPiece()
    ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],
        'Piece Preview: '..(pb.preview~='' and pb.preview or '<empty>'))

    if ImGui.Button('Add to Condition',140,0) then
        if pb.preview~='' then
            bld.input = bld.input~='' and bld.input..' '..pb.preview or pb.preview
        end
    end
    ImGui.SameLine()
    if ImGui.Button('(',30,0)        then bld.input=bld.input..'(' end ImGui.SameLine()
    if ImGui.Button(')',30,0)        then bld.input=bld.input..')' end ImGui.SameLine()
    if ImGui.Button('AND (&&)',90,0) then bld.input=bld.input..' && ' end ImGui.SameLine()
    if ImGui.Button('OR (||)',80,0)  then bld.input=bld.input..' || ' end ImGui.SameLine()
    if ImGui.Button('NOT (!)',70,0)  then bld.input=bld.input..'!' end

    ImGui.Separator()

    -- ── Action buttons ──
    if ImGui.Button('Validate',    100,0) then bldRunValidate() end ImGui.SameLine()
    if ImGui.Button('Wrap fn',      72,0) then bld.block=buildLuaBlock(bld.input,'function') end ImGui.SameLine()
    if ImGui.Button('Wrap if',      64,0) then bld.block=buildLuaBlock(bld.input,'if') end ImGui.SameLine()
    if ImGui.Button('MQ2 Macro',    84,0) then bld.block=buildLuaBlock(bld.input,'macro') end ImGui.SameLine()
    if ImGui.Button('Copy Cond',    80,0) then ImGui.SetClipboardText(bld.input) bld.flash=90 end ImGui.SameLine()
    if ImGui.Button('Copy Block',   84,0) then ImGui.SetClipboardText(bld.block) bld.flash=90 end ImGui.SameLine()
    if ImGui.Button('Clear',        56,0) then
        bld.input='' bld.block='-- enter a condition above'
        bld.msg='' bld.errors={} bld.warnings={}
    end
    if bld.flash>0 then
        bld.flash=bld.flash-1 ImGui.SameLine()
        ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],'Copied!')
    end
    ImGui.Spacing()

    -- ── Validation output ──
    if bld.msg~='' then
        if bld.ok==true then ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],bld.msg)
        elseif bld.ok==false then ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],bld.msg)
        else ImGui.TextColored(C.WARN[1],C.WARN[2],C.WARN[3],C.WARN[4],bld.msg) end
        for _,e in ipairs(bld.errors)   do ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],'  [x] '..e) end
        for _,w in ipairs(bld.warnings) do ImGui.TextColored(C.WARN[1],C.WARN[2],C.WARN[3],C.WARN[4],'  [!] '..w) end
        -- Auto-fix
        for _,e in ipairs(bld.errors) do
            if e:find('closing') then
                if ImGui.SmallButton('Fix: add )##fx1') then bld.input=bld.input..')' bldRunValidate() end
            end
            if e:find('right side') or e:find('Ends with') then
                if ImGui.SmallButton('Fix: trim trailing op##fx2') then
                    bld.input=trim(bld.input):gsub('%s+and$',''):gsub('%s+or$','') bldRunValidate()
                end
            end
        end
        ImGui.Spacing()
    end

    -- ── DanNet + Save ──
    if ImGui.Button('DanNet: broadcast##dn',150,0) then
        if bld.input~='' then mq.cmdf('/dnet tell all /echo [CB] %s', bld.input) bld.saveMsg='Broadcast sent!' end
    end ImGui.SameLine()
    ImGui.SetNextItemWidth(150)
    local sn,snc=ImGui.InputText('##savename',bld.saveName) if snc then bld.saveName=sn end
    ImGui.SameLine() ImGui.SetNextItemWidth(70)
    local st,stc=ImGui.InputText('tag##st',bld.saveTag) if stc then bld.saveTag=st end
    ImGui.SameLine()
    if ImGui.Button('Save##savebtn',50,0) then
        if trim(bld.saveName)~='' and trim(bld.input)~='' then
            cbIniSave(bld.saveName,bld.input,bld.saveTag)
            cbIniAddIndex(bld.saveName)
            bld.saveMsg='Saved: '..bld.saveName
        else bld.saveMsg='Enter name + condition' end
    end ImGui.SameLine()
    if ImGui.Button('Saves##showsv',52,0) then bld.showSaves=not bld.showSaves end
    if bld.saveMsg~='' then ImGui.SameLine() ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],bld.saveMsg) end

    if bld.showSaves then
        ImGui.Spacing() ImGui.TextDisabled('Saved Conditions') ImGui.Separator()
        local keys=cbIniList()
        if #keys==0 then ImGui.TextDisabled('  None saved yet.') end
        for _,k in ipairs(keys) do
            local code,tag=cbIniLoad(k)
            if code and code~='' then
                ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],k)
                if tag~='' then ImGui.SameLine() ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'['..tag..']') end
                ImGui.SameLine(400)
                if ImGui.SmallButton('Load##sl'..k) then bldLoad(code) bld.showSaves=false end ImGui.SameLine()
                if ImGui.SmallButton('Del##sd'..k)  then cbIniDelete(k) end
                ImGui.TextDisabled('  '..code:sub(1,72))
            end
        end
        ImGui.Spacing()
    end

    -- ── Quick Insert (Lua style) ──
    ImGui.TextDisabled('Quick Insert  (Lua mq.TLO style)')
    ImGui.Separator()
    for i,q in ipairs(QUICK) do
        if ImGui.Button(q.l..'##qi'..i,0,0) then bld.input=bld.input..q.v end
        if i%7~=0 then ImGui.SameLine() end
    end
    if #PLUGINS>0 then
        ImGui.Spacing() ImGui.TextDisabled('Detected Plugin TLOs')
        for _,p in ipairs(PLUGINS) do
            for _,t in ipairs(p.tlos) do
                local s=t.tlo:gsub('mq%.TLO%.','')
                if ImGui.Button(s..'##pq'..s,0,0) then bld.input=bld.input..t.tlo end
                ImGui.SameLine()
            end
        end
        ImGui.NewLine()
    end
    if #condGroups>0 then
        ImGui.Spacing() ImGui.TextDisabled('Condition Groups')
        for i,g in ipairs(condGroups) do
            if ImGui.Button('@'..g.name:gsub('%s','_')..'##cgi'..i,0,0) then
                bld.input=bld.input..'@'..g.name:gsub('%s','_')
            end ImGui.SameLine()
        end ImGui.NewLine()
    end

    -- ── Generated Block ──
    ImGui.Spacing() ImGui.TextDisabled('Generated Lua Block') ImGui.Separator()
    ImGui.InputTextMultiline('##blk',bld.block,-1,74,FLAG_RO)

    -- ── MAUI INI Export (your version) ──
    ImGui.Spacing()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Apply to MAUI INI  (optional)')
    ImGui.Separator()
    local mf,mfc=ImGui.InputText('INI File Path##maui',bld.mauiFile) if mfc then bld.mauiFile=mf end
    if ImGui.BeginCombo('INI Section##mauisec', bld.mauiSection) then
        for _,sec in ipairs(INI_SECTIONS) do
            if ImGui.Selectable(sec, bld.mauiSection==sec) then bld.mauiSection=sec end
        end
        ImGui.EndCombo()
    end
    local mi,mic=ImGui.InputInt('Condition Slot Index##mauiidx',bld.mauiIndex)
    if mic then bld.mauiIndex=math.max(1,mi) end
    local condKey = (SECTION_PREFIX[bld.mauiSection] or 'DPSCond')..tostring(bld.mauiIndex)
    ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],'Target Key: '..condKey)
    if ImGui.Button('Apply to MAUI INI',135,0) then
        if trim(bld.input)~='' and trim(bld.mauiFile)~='' then
            mq.cmdf('/ini "%s" "%s" "%s" "%s"', bld.mauiFile, bld.mauiSection, condKey, escapeIni(bld.input))
            bld.saveMsg='Applied to ['..bld.mauiSection..'] '..condKey
        else bld.saveMsg='Need condition + INI path' end
    end

    -- ── History ──
    if #bld.history>0 then
        ImGui.Spacing() ImGui.TextDisabled('History') ImGui.Separator()
        for i,h in ipairs(bld.history) do
            local s=(#h>62) and h:sub(1,59)..'...' or h
            if ImGui.Selectable('['..i..'] '..s..'##hist'..i) then bldLoad(h) end
        end
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 2 — LIVE TESTER  (uses mq.parse like your version)
-- ══════════════════════════════════════════════════════
local tst = {
    input='', result='', lastResult='',
    running=false, intervalMs=500, tickCount=0, lastTick=0,
    log={},
}

local WATCH_DEFS = {
    {label='Me.PctHPs()',       fn=function() return tostring(mq.TLO.Me.PctHPs()) end},
    {label='Me.PctMana()',      fn=function() return tostring(mq.TLO.Me.PctMana()) end},
    {label='Me.PctEndurance()', fn=function() return tostring(mq.TLO.Me.PctEndurance()) end},
    {label='Me.Combat()',       fn=function() return tostring(mq.TLO.Me.Combat()) end},
    {label='Me.Sitting()',      fn=function() return tostring(mq.TLO.Me.Sitting()) end},
    {label='Me.Casting.ID()',   fn=function() local v=mq.TLO.Me.Casting.ID() return v and tostring(v) or 'nil' end},
    {label='Target.ID()',       fn=function() local v=mq.TLO.Target.ID() return v and tostring(v) or 'nil' end},
    {label='Target.PctHPs()',   fn=function()
        if not mq.TLO.Target.ID() then return 'no target' end
        return tostring(mq.TLO.Target.PctHPs()) end},
    {label='Target.Distance()', fn=function()
        if not mq.TLO.Target.ID() then return 'no target' end
        return tostring(mq.TLO.Target.Distance()) end},
    {label='Nav.Active()',      fn=function() return tostring(mq.TLO.Navigation.Active()) end},
    {label='Zone.Safe()',       fn=function() return tostring(mq.TLO.Zone.Safe()) end},
    {label='Zone.Name()',       fn=function() return tostring(mq.TLO.Zone.Name()) end},
    {label='SpawnCnt npc r30',  fn=function() return tostring(mq.TLO.SpawnCount('npc radius 30')()) end},
}

-- Test using mq.parse (your approach) for ${} style, pcall load() for Lua style
local function tstEval(code)
    if trim(code)=='' then return nil,'empty' end
    -- Detect if it's MQ2 ${} syntax or Lua mq.TLO syntax
    if code:find('%$%{') then
        -- MQ2 macro style — use mq.parse
        local probe = '${If['..code..',TRUE,FALSE]}'
        local ok,result = pcall(mq.parse, probe)
        if ok then
            return (result=='TRUE'), nil
        else
            return nil, 'PARSE ERROR: '..tostring(result)
        end
    else
        -- Lua style — use load/pcall
        local resolved = resolveGroups(code)
        local fn,err = load('local mq=require("mq") return ('..resolved..')')
        if not fn then return nil,'SYNTAX: '..(err or '?') end
        local ok2,val = pcall(fn)
        if not ok2 then return nil,'RUNTIME: '..(val or '?') end
        return val, nil
    end
end

local function tstRunOnce()
    local val,err = tstEval(tst.input)
    if err then
        tst.result=err tst.lastResult='err'
        logMsg(tst.log,'ERROR: '..err)
        mq.cmdf('/echo [CB Tester] ERROR: %s', err)
    else
        tst.result='Result: '..tostring(val)
        tst.lastResult=tostring(val)
        logMsg(tst.log,tostring(val):upper())
        mq.cmdf('/echo [CB Tester] %s = %s', tst.input:sub(1,60), tostring(val))
    end
end

local function tstTick()
    if not tst.running then return end
    local now = mq.gettime()
    if (now - tst.lastTick) >= tst.intervalMs then
        tst.lastTick=now tst.tickCount=tst.tickCount+1
        tstRunOnce()
    end
end

local function drawTester()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Live Condition Tester')
    ImGui.TextDisabled('Supports both Lua mq.TLO.* and MQ2 ${} macro syntax')
    ImGui.Separator()
    local nv,ch=ImGui.InputTextMultiline('##tstcond',tst.input,-1,60)
    if ch then tst.input=nv end
    ImGui.Spacing()
    if ImGui.Button('Test Once',90,0) then tstRunOnce() end ImGui.SameLine()
    if ImGui.Button('<Builder',78,0)  then tst.input=bld.input end ImGui.SameLine()
    if ImGui.Button('>Builder',78,0)  then bldLoad(tst.input) end ImGui.SameLine()
    if tst.running then
        if ImGui.Button('Stop Timer',84,0) then tst.running=false end
    else
        if ImGui.Button('Start Timer',90,0) then
            tst.running=true tst.lastTick=mq.gettime() tst.tickCount=0
        end
    end
    ImGui.SameLine() ImGui.SetNextItemWidth(64)
    local iv,ic=ImGui.InputInt('ms##tiv',tst.intervalMs) if ic then tst.intervalMs=math.max(100,iv) end
    ImGui.SameLine()
    if ImGui.Button('Clear Log',80,0) then tst.log={} end
    if tst.running then
        ImGui.SameLine()
        ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],'RUNNING  tick #'..tst.tickCount)
    end
    ImGui.Spacing()
    if tst.result~='' then
        if     tst.lastResult=='true'  then ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],tst.result)
        elseif tst.lastResult=='false' then ImGui.TextColored(C.FALSE_C[1],C.FALSE_C[2],C.FALSE_C[3],C.FALSE_C[4],tst.result)
        elseif tst.lastResult=='err'   then ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],tst.result)
        else                                ImGui.TextColored(C.WARN[1],C.WARN[2],C.WARN[3],C.WARN[4],tst.result)
        end
    end
    if #tst.log>0 then
        ImGui.Spacing() ImGui.TextDisabled('Fire Log  (newest first)')
        ImGui.Separator()
        ImGui.InputTextMultiline('##tstlog',table.concat(tst.log,'\n'),-1,80,FLAG_RO)
    end
    ImGui.Spacing() ImGui.TextDisabled('Live TLO Watch Window') ImGui.Separator()
    for _,w in ipairs(WATCH_DEFS) do
        local val='ERR'
        local ok2,v2=pcall(w.fn) if ok2 then val=v2 end
        ImGui.Text(w.label) ImGui.SameLine(210)
        if     val=='true'      then ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],val)
        elseif val=='false'     then ImGui.TextColored(C.FALSE_C[1],C.FALSE_C[2],C.FALSE_C[3],C.FALSE_C[4],val)
        elseif val=='nil' or val=='no target' then ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],val)
        elseif val=='ERR'       then ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],val)
        else                         ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],val) end
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 3 — TEMPLATES
-- ══════════════════════════════════════════════════════
local tmpl = { selected=1, output='' }
local TEMPLATES = {
    { name='Heal when HP low', fields={
        {id='hp',label='HP threshold %',kind='int',val=50,min=1,max=99},
        {id='nc',label='Not casting',kind='bool',val=true},
        {id='nz',label='Not safe zone',kind='bool',val=false},
    }, build=function(f)
        local s='mq.TLO.Me.PctHPs() < '..f.hp
        if f.nc then s=s..' and not mq.TLO.Me.Casting.ID()' end
        if f.nz then s=s..' and not mq.TLO.Zone.Safe()' end
        return s end},
    { name='Mana conservation', fields={
        {id='mp',label='Mana threshold %',kind='int',val=20,min=1,max=99},
        {id='sit',label='Not sitting',kind='bool',val=true},
        {id='cb',label='In combat',kind='bool',val=false},
    }, build=function(f)
        local s='mq.TLO.Me.PctMana() < '..f.mp
        if f.sit then s=s..' and not mq.TLO.Me.Sitting()' end
        if f.cb  then s=s..' and mq.TLO.Me.Combat()' end
        return s end},
    { name='Buff missing', fields={
        {id='bn',label='Buff name',kind='str',val='Haste'},
        {id='cb',label='And in combat',kind='bool',val=false},
    }, build=function(f)
        local s="not mq.TLO.Me.Buff('"..f.bn.."').ID()"
        if f.cb then s=s..' and mq.TLO.Me.Combat()' end
        return s end},
    { name='Target HP trigger', fields={
        {id='th',label='Target HP % below',kind='int',val=20,min=1,max=99},
        {id='nt',label='Target must exist',kind='bool',val=true},
        {id='npc',label='Target is NPC',kind='bool',val=true},
    }, build=function(f)
        local s='mq.TLO.Target.PctHPs() < '..f.th
        if f.nt  then s='mq.TLO.Target.ID() ~= nil and '..s end
        if f.npc then s=s.." and mq.TLO.Target.Type() == 'NPC'" end
        return s end},
    { name='Enemy count (AoE)', fields={
        {id='cnt',label='Min enemies',kind='int',val=3,min=1,max=20},
        {id='range',label='Range (units)',kind='int',val=30,min=5,max=200},
    }, build=function(f)
        return "mq.TLO.SpawnCount('npc radius "..f.range.."')() >= "..f.cnt end},
    { name='Spell ready', fields={
        {id='spell',label='Spell name',kind='str',val='Complete Heal'},
        {id='mp',label='Min mana %',kind='int',val=10,min=1,max=99},
    }, build=function(f)
        return "mq.TLO.Me.SpellReady('"..f.spell.."') and mq.TLO.Me.PctMana() >= "..f.mp end},
    { name='HP + Mana both low', fields={
        {id='hp',label='HP threshold %',kind='int',val=50,min=1,max=99},
        {id='mp',label='Mana threshold %',kind='int',val=30,min=1,max=99},
    }, build=function(f)
        return 'mq.TLO.Me.PctHPs() < '..f.hp..' and mq.TLO.Me.PctMana() < '..f.mp end},
    { name='Group member needs heal', fields={
        {id='pct',label='HP threshold %',kind='int',val=50,min=1,max=99},
    }, build=function(f)
        return 'mq.TLO.Group.LowHP('..f.pct..') ~= nil' end},
}

local function drawTemplates()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Condition Templates')
    ImGui.TextDisabled('Fill in the blanks — no syntax required')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Template:') ImGui.SameLine()
    ImGui.SetNextItemWidth(300)
    local names={} for _,t in ipairs(TEMPLATES) do table.insert(names,t.name) end
    local idx=tmpl.selected-1
    local ni,cc=ImGui.Combo('##tmplsel',idx,names,#names)
    if cc then tmpl.selected=ni+1 tmpl.output='' end
    ImGui.Spacing() ImGui.Separator()
    local t=TEMPLATES[tmpl.selected]
    for _,f in ipairs(t.fields) do
        if f.kind=='int' then
            ImGui.Text(f.label) ImGui.SameLine(220)
            ImGui.SetNextItemWidth(110)
            local v,c=ImGui.SliderInt('##'..f.id,f.val,f.min,f.max) if c then f.val=v end
            ImGui.SameLine() ImGui.SetNextItemWidth(50)
            local v2,c2=ImGui.InputInt('##'..f.id..'n',f.val)
            if c2 then f.val=math.max(f.min,math.min(f.max,v2)) end
        elseif f.kind=='str' then
            ImGui.Text(f.label) ImGui.SameLine(220)
            ImGui.SetNextItemWidth(220)
            local v,c=ImGui.InputText('##'..f.id,f.val) if c then f.val=v end
        elseif f.kind=='bool' then
            local v,c=ImGui.Checkbox(f.label..'##'..f.id,f.val) if c then f.val=v end
        end
    end
    ImGui.Spacing()
    if ImGui.Button('Build',64,0) then
        local fields={} for _,f in ipairs(t.fields) do fields[f.id]=f.val end
        local ok,r=pcall(t.build,fields) tmpl.output=ok and r or 'ERROR: '..tostring(r)
    end ImGui.SameLine()
    if ImGui.Button('To Builder',84,0) and tmpl.output~='' then bldLoad(tmpl.output) end ImGui.SameLine()
    if ImGui.Button('To Tester',80,0)  and tmpl.output~='' then tst.input=tmpl.output end
    if tmpl.output~='' then
        ImGui.Spacing() ImGui.TextDisabled('Generated:')
        ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],tmpl.output)
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 4 — CLASS PRESETS
-- ══════════════════════════════════════════════════════
local CLASS_PRESETS = {
    WAR={ name='Warrior', presets={
        {name='Taunt ready',       code="mq.TLO.Me.AbilityReady('Taunt')"},
        {name='Defensive disc',    code="mq.TLO.Me.AbilityReady('Defensive') and mq.TLO.Me.PctHPs() < 30"},
        {name='HP critical',       code='mq.TLO.Me.PctHPs() < 20 and mq.TLO.Me.Combat()'},
    }},
    CLR={ name='Cleric', presets={
        {name='Complete Heal',     code="mq.TLO.Me.SpellReady('Complete Heal') and mq.TLO.Me.PctMana() >= 30"},
        {name='Group heal needed', code='mq.TLO.Group.LowHP(60) ~= nil'},
        {name='Rez needed',        code='mq.TLO.Group.LowHP(1) ~= nil and not mq.TLO.Me.Combat()'},
        {name='Divine Aura',       code="mq.TLO.Me.PctHPs() < 10 and mq.TLO.Me.AbilityReady('Divine Aura')"},
    }},
    DRU={ name='Druid', presets={
        {name='Regen missing',     code="not mq.TLO.Me.Buff('Regen').ID()"},
        {name='HP low outdoor',    code='mq.TLO.Me.PctHPs() < 50 and not mq.TLO.Zone.Safe()'},
    }},
    WIZ={ name='Wizard', presets={
        {name='Harvest ready',     code="mq.TLO.Me.AbilityReady('Harvest')"},
        {name='Nuke ready',        code="mq.TLO.Me.SpellReady('Bolt of Jikai') and mq.TLO.Me.PctMana() >= 15"},
    }},
    NEC={ name='Necromancer', presets={
        {name='Feign ready',       code="mq.TLO.Me.AbilityReady('Feign Death') and mq.TLO.Me.PctHPs() < 20"},
        {name='Pet low HP',        code='mq.TLO.Pet.PctHPs() ~= nil and mq.TLO.Pet.PctHPs() < 40'},
    }},
    BRD={ name='Bard', presets={
        {name='Haste song missing',code="not mq.TLO.Me.Song('Warsong').ID()"},
        {name='Regen song missing',code="not mq.TLO.Me.Song('Cassindra').ID()"},
    }},
    SHM={ name='Shaman', presets={
        {name='Canni ready',       code="mq.TLO.Me.AbilityReady('Cannibalize') and mq.TLO.Me.PctMana() < 30"},
        {name='Haste buff missing',code="not mq.TLO.Me.Buff('Alacrity').ID() and mq.TLO.Me.Combat()"},
    }},
    MNK={ name='Monk', presets={
        {name='Mend ready',        code="mq.TLO.Me.AbilityReady('Mend') and mq.TLO.Me.PctHPs() < 60"},
        {name='Feign ready',       code="mq.TLO.Me.AbilityReady('Feign Death') and mq.TLO.Me.PctHPs() < 20"},
    }},
    PAL={ name='Paladin', presets={
        {name='Lay on hands',      code="mq.TLO.Me.AbilityReady('Lay on Hands') and mq.TLO.Me.PctHPs() < 15"},
        {name='Group low + heal',  code='mq.TLO.Group.LowHP(50) ~= nil and mq.TLO.Me.PctMana() >= 20'},
    }},
    RNG={ name='Ranger', presets={
        {name='Trueshot disc',     code="mq.TLO.Me.AbilityReady('Trueshot') and mq.TLO.Me.Combat()"},
        {name='Low HP',            code='mq.TLO.Me.PctHPs() < 25 and mq.TLO.Me.Combat()'},
    }},
}
local clsKeys={'WAR','CLR','DRU','WIZ','NEC','BRD','SHM','MNK','PAL','RNG'}
local clsSelected='WAR'

local function drawClassPresets()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Class Presets')
    ImGui.Separator() ImGui.Spacing()
    for _,k in ipairs(clsKeys) do
        if clsSelected==k then
            ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],'['..k..']')
        else
            if ImGui.SmallButton(k..'##cls') then clsSelected=k end
        end
        ImGui.SameLine()
    end
    ImGui.NewLine() ImGui.Spacing() ImGui.Separator()
    local cls=CLASS_PRESETS[clsSelected]
    if not cls then ImGui.TextDisabled('No presets.') return end
    ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],cls.name..' Presets')
    ImGui.Spacing()
    for i,p in ipairs(cls.presets) do
        ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],p.name)
        local s=(#p.code>68) and p.code:sub(1,65)..'...' or p.code
        ImGui.TextDisabled('  '..s) ImGui.SameLine()
        if ImGui.SmallButton('Use##cls'..i)  then bldLoad(p.code) end ImGui.SameLine()
        if ImGui.SmallButton('Test##clst'..i) then tst.input=p.code end
        ImGui.Separator()
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 5 — ROTATION BUILDER
-- ══════════════════════════════════════════════════════
local rot={steps={},newCond='',newAct='',newLbl='',loop=true,delay=100,output=''}

local function rotBuild()
    local lines={'-- Rotation by ConditionBuilder v4 (MuleAssist)','local mq=require("mq")','','local function rotation()'}
    for i,s in ipairs(rot.steps) do
        if s.enabled then
            table.insert(lines,'    -- '..s.label)
            table.insert(lines,'    if '..resolveGroups(s.cond)..' then')
            table.insert(lines,'        '..s.action)
            table.insert(lines,'    end')
        end
    end
    table.insert(lines,'end') table.insert(lines,'')
    if rot.loop then
        table.insert(lines,'while true do') table.insert(lines,'    rotation()')
        table.insert(lines,'    mq.delay('..rot.delay..')') table.insert(lines,'end')
    else table.insert(lines,'rotation()') end
    rot.output=table.concat(lines,'\n')
end

local function drawRotation()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Rotation Builder')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Label:') ImGui.SameLine(70) ImGui.SetNextItemWidth(200)
    local v,c=ImGui.InputText('##rlbl',rot.newLbl) if c then rot.newLbl=v end
    ImGui.Text('Condition:') ImGui.SameLine(70) ImGui.SetNextItemWidth(380)
    local v2,c2=ImGui.InputText('##rcnd',rot.newCond) if c2 then rot.newCond=v2 end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##rb') then rot.newCond=bld.input end
    ImGui.Text('Action:') ImGui.SameLine(70) ImGui.SetNextItemWidth(380)
    local v3,c3=ImGui.InputText('##ract',rot.newAct) if c3 then rot.newAct=v3 end
    if ImGui.Button('Add Step',80,0) then
        if trim(rot.newCond)~='' and trim(rot.newAct)~='' then
            table.insert(rot.steps,{cond=rot.newCond,action=rot.newAct,
                label=rot.newLbl~='' and rot.newLbl or 'Step '..#rot.steps+1,enabled=true})
            rot.newCond='' rot.newAct='' rot.newLbl=''
        end
    end
    ImGui.Spacing() ImGui.Separator()
    ImGui.TextDisabled('Steps  (top = highest priority)') ImGui.Separator()
    local removeIdx,moveUp,moveDown=nil,nil,nil
    for i,s in ipairs(rot.steps) do
        local ev,ec=ImGui.Checkbox('##en'..i,s.enabled) if ec then s.enabled=ev end
        ImGui.SameLine()
        if s.enabled then ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],'['..i..'] '..s.label)
        else ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'['..i..'] '..s.label..' (off)') end
        ImGui.SameLine(440)
        if ImGui.SmallButton('Up##u'..i)  and i>1          then moveUp=i   end ImGui.SameLine()
        if ImGui.SmallButton('Dn##d'..i)  and i<#rot.steps then moveDown=i end ImGui.SameLine()
        if ImGui.SmallButton('Del##x'..i) then removeIdx=i end
        ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'  IF: '..s.cond)
        ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],'  DO: '..s.action)
        ImGui.Spacing()
    end
    if removeIdx then table.remove(rot.steps,removeIdx) end
    if moveUp    then rot.steps[moveUp],rot.steps[moveUp-1]=rot.steps[moveUp-1],rot.steps[moveUp] end
    if moveDown  then rot.steps[moveDown],rot.steps[moveDown+1]=rot.steps[moveDown+1],rot.steps[moveDown] end
    ImGui.Separator()
    local lv,lc=ImGui.Checkbox('Loop##lp',rot.loop) if lc then rot.loop=lv end
    ImGui.SameLine(100) ImGui.Text('Delay ms:') ImGui.SameLine(170) ImGui.SetNextItemWidth(70)
    local dv,dc=ImGui.InputInt('##rdel',rot.delay) if dc then rot.delay=math.max(50,dv) end
    ImGui.Spacing()
    if ImGui.Button('Build Rotation',110,0) then rotBuild() end
    if rot.output~='' then
        ImGui.SameLine() if ImGui.Button('Copy',52,0) then ImGui.SetClipboardText(rot.output) end
        ImGui.Spacing() ImGui.InputTextMultiline('##rotout',rot.output,-1,100,FLAG_RO)
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 6 — COMBINER
-- ══════════════════════════════════════════════════════
local comb={condA='',condB='',op='and',negate=false,result='',saveAs=''}

local function drawCombiner()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Condition Combiner')
    ImGui.TextDisabled('Combines two conditions with correct parentheses')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Condition A:') ImGui.SameLine(110) ImGui.SetNextItemWidth(400)
    local va,ca=ImGui.InputText('##combA',comb.condA) if ca then comb.condA=va end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##cab') then comb.condA=bld.input end
    ImGui.Text('Operator:') ImGui.SameLine(110) ImGui.SetNextItemWidth(120)
    local ops={'and','or','and not','or not'}
    local opi=1 for i,o in ipairs(ops) do if o==comb.op then opi=i end end
    local ni,cc2=ImGui.Combo('##combop',opi-1,ops,#ops) if cc2 then comb.op=ops[ni+1] end
    ImGui.Text('Condition B:') ImGui.SameLine(110) ImGui.SetNextItemWidth(400)
    local vb,cb=ImGui.InputText('##combB',comb.condB) if cb then comb.condB=vb end
    local nv,nc=ImGui.Checkbox('Negate entire result##combN',comb.negate) if nc then comb.negate=nv end
    ImGui.Spacing()
    if ImGui.Button('Combine',72,0) then
        if trim(comb.condA)~='' and trim(comb.condB)~='' then
            local r='('..comb.condA..') '..comb.op..' ('..comb.condB..')'
            if comb.negate then r='not ('..r..')' end
            comb.result=r
        end
    end
    if comb.result~='' then
        ImGui.Spacing() ImGui.TextDisabled('Result:')
        ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],comb.result)
        ImGui.Spacing()
        if ImGui.Button('To Builder',84,0) then bldLoad(comb.result) end ImGui.SameLine()
        if ImGui.Button('To Tester',80,0)  then tst.input=comb.result end ImGui.SameLine()
        if ImGui.Button('Copy',50,0) then ImGui.SetClipboardText(comb.result) end ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        local sv,sc=ImGui.InputText('Save as##csn',comb.saveAs) if sc then comb.saveAs=sv end
        ImGui.SameLine()
        if ImGui.Button('Save',50,0) and trim(comb.saveAs)~='' then
            cbIniSave(comb.saveAs,comb.result,'combined')
            cbIniAddIndex(comb.saveAs)
        end
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 7 — DIFF
-- ══════════════════════════════════════════════════════
local diff={condA='',condB='',nameA='',nameB=''}

local function drawDiff()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Condition Diff')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Condition A:') ImGui.SameLine(110) ImGui.SetNextItemWidth(360)
    local va,ca=ImGui.InputText('##diffA',diff.condA) if ca then diff.condA=va end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##dab') then diff.condA=bld.input end
    ImGui.SameLine() ImGui.SetNextItemWidth(90)
    local na,nca=ImGui.InputText('lbl A##dna',diff.nameA) if nca then diff.nameA=na end
    ImGui.Text('Condition B:') ImGui.SameLine(110) ImGui.SetNextItemWidth(360)
    local vb,cb=ImGui.InputText('##diffB',diff.condB) if cb then diff.condB=vb end
    ImGui.SameLine() ImGui.SetNextItemWidth(90)
    local nb,ncb=ImGui.InputText('lbl B##dnb',diff.nameB) if ncb then diff.nameB=nb end
    ImGui.Spacing()
    local lblA=diff.nameA~='' and diff.nameA or 'A'
    local lblB=diff.nameB~='' and diff.nameB or 'B'
    ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],lblA)
    ImGui.SameLine(370)
    ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],lblB)
    ImGui.Separator()
    ImGui.InputTextMultiline('##diffAout',diff.condA,350,70,FLAG_RO)
    ImGui.SameLine()
    ImGui.InputTextMultiline('##diffBout',diff.condB,350,70,FLAG_RO)
    -- Word diff
    if diff.condA~='' and diff.condB~='' then
        ImGui.Spacing() ImGui.TextDisabled('Token diff   green=added   red=removed   yellow=changed')
        ImGui.Separator()
        local function tok(s) local t={} for w in s:gmatch('%S+') do table.insert(t,w) end return t end
        local ta,tb=tok(diff.condA),tok(diff.condB)
        local ml=math.max(#ta,#tb)
        for i=1,ml do
            local A,B=ta[i] or '',tb[i] or ''
            if A==B then ImGui.Text(A..' ')
            elseif A~='' and B~='' then
                ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],'[-'..A..']') ImGui.SameLine()
                ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],'[+'..B..'] ')
            elseif A~='' then ImGui.TextColored(C.ERR[1],C.ERR[2],C.ERR[3],C.ERR[4],'[-'..A..'] ')
            else ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],'[+'..B..'] ') end
            ImGui.SameLine()
        end
        ImGui.NewLine()
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 8 — SPAWN INSPECTOR
-- ══════════════════════════════════════════════════════
local spwn={range=50,filter='npc',list={},selected=0,fields={}}

local function spwnRefresh()
    spwn.list={}
    local count=mq.TLO.SpawnCount(spwn.filter..' radius '..spwn.range)()
    if not count then return end
    for i=1,math.min(count,40) do
        local sp=mq.TLO.NearestSpawn(i,spwn.filter..' radius '..spwn.range)
        if sp and sp.ID() then
            table.insert(spwn.list,{id=sp.ID(),name=sp.CleanName() or '?',
                dist=math.floor((sp.Distance() or 0)+0.5),type=sp.Type() or '?',
                hp=sp.PctHPs() or 0,level=sp.Level() or 0})
        end
    end
end

local function drawSpawnInspector()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Spawn Inspector')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Range:') ImGui.SameLine(60) ImGui.SetNextItemWidth(80)
    local rv,rc=ImGui.InputInt('##sprange',spwn.range) if rc then spwn.range=math.max(10,rv) end
    ImGui.SameLine() ImGui.Text('Filter:') ImGui.SameLine(200) ImGui.SetNextItemWidth(100)
    local fv,fc=ImGui.InputText('##spfilter',spwn.filter) if fc then spwn.filter=fv end
    ImGui.SameLine() if ImGui.Button('Refresh',72,0) then spwnRefresh() end
    ImGui.Spacing() ImGui.Separator()
    ImGui.TextDisabled('Click to inspect — Use button to send to Builder')
    ImGui.Separator()
    if #spwn.list==0 then ImGui.TextDisabled('  No spawns — press Refresh') end
    for i,s in ipairs(spwn.list) do
        local line=string.format('[%d] %-22s  Lv%-3d  %3d%%HP  %3dyd  %s',
            s.id,s.name:sub(1,22),s.level,s.hp,s.dist,s.type)
        if ImGui.Selectable(line..'##sp'..i,spwn.selected==i) then
            spwn.selected=i
            spwn.fields={
                {k='Target.ID() ==',          v=tostring(s.id)},
                {k="Target.Type() ==",         v="'"..s.type.."'"},
                {k='Target.Distance() <',      v=tostring(s.dist+5)},
                {k='Target.PctHPs() <',        v=tostring(s.hp)},
                {k='Target.Level() ==',        v=tostring(s.level)},
                {k='Target.CleanName() ==',    v="'"..s.name.."'"},
            }
        end
    end
    if spwn.selected>0 and #spwn.fields>0 then
        ImGui.Spacing() ImGui.TextDisabled('Build condition from this spawn:') ImGui.Separator()
        for _,f in ipairs(spwn.fields) do
            ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],'mq.TLO.'..f.k..' '..f.v)
            ImGui.SameLine()
            if ImGui.SmallButton('Use##spf'..f.k) then bldLoad('mq.TLO.'..f.k..' '..f.v) end
        end
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 9 — CONDITION GROUPS
-- ══════════════════════════════════════════════════════
local grp={newName='',newCode='',msg=''}

local function drawCondGroups()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Condition Groups')
    ImGui.TextDisabled('Named sub-conditions referenced as @Name in any condition')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Name:') ImGui.SameLine(70) ImGui.SetNextItemWidth(180)
    local nv,nc=ImGui.InputText('##grpname',grp.newName) if nc then grp.newName=nv end
    ImGui.Text('Condition:') ImGui.SameLine(70) ImGui.SetNextItemWidth(420)
    local cv,cc=ImGui.InputText('##grpcode',grp.newCode) if cc then grp.newCode=cv end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##grpb') then grp.newCode=bld.input end
    if ImGui.Button('Add Group',88,0) then
        if trim(grp.newName)~='' and trim(grp.newCode)~='' then
            local k=grp.newName:gsub('%s','_')
            local dup=false for _,g in ipairs(condGroups) do if g.name==k then dup=true break end end
            if not dup then
                table.insert(condGroups,{name=k,code=grp.newCode})
                grp.msg='Added: @'..k grp.newName='' grp.newCode=''
            else grp.msg='Name already exists' end
        else grp.msg='Enter name + condition' end
    end
    if grp.msg~='' then ImGui.SameLine() ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],grp.msg) end
    ImGui.Spacing() ImGui.Separator()
    ImGui.TextDisabled('Defined Groups') ImGui.Separator()
    if #condGroups==0 then ImGui.TextDisabled('  None defined yet.') end
    local removeIdx=nil
    for i,g in ipairs(condGroups) do
        ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],'@'..g.name)
        ImGui.SameLine(160) ImGui.TextDisabled('= '..g.code:sub(1,58))
        ImGui.SameLine()
        if ImGui.SmallButton('Del##gd'..i) then removeIdx=i end
    end
    if removeIdx then table.remove(condGroups,removeIdx) end
end

-- ══════════════════════════════════════════════════════
--  TAB 10 — EVENT HOOKS
-- ══════════════════════════════════════════════════════
local evts={hooks={},newName='',newPat='',newCond='',newAct='',log={},active=false}
local registeredEvents={}

local function evtRegisterAll()
    for _,name in ipairs(registeredEvents) do pcall(function() mq.unevent(name) end) end
    registeredEvents={}
    for _,h in ipairs(evts.hooks) do
        if h.enabled and h.pattern~='' then
            local ref=h
            local ok=pcall(function()
                mq.event(h.name,h.pattern,function()
                    ref.count=(ref.count or 0)+1
                    local fire=true
                    if ref.cond~='' then
                        local val,err=tstEval(ref.cond)
                        fire=(err==nil and val==true)
                    end
                    if fire and ref.action~='' then
                        mq.cmd(ref.action)
                        logMsg(evts.log,'FIRED ['..ref.name..']: '..ref.action)
                    else
                        logMsg(evts.log,'heard ['..ref.name..'] cond='..tostring(fire))
                    end
                end)
            end)
            if ok then table.insert(registeredEvents,h.name) end
        end
    end
end

local function drawEventHooks()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Event Hooks')
    ImGui.TextDisabled('Fire commands when chat patterns match + condition is true')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Name:') ImGui.SameLine(80) ImGui.SetNextItemWidth(160)
    local nv,nc=ImGui.InputText('##evtname',evts.newName) if nc then evts.newName=nv end
    ImGui.Text('Pattern:') ImGui.SameLine(80) ImGui.SetNextItemWidth(360)
    local pv,pc=ImGui.InputText('##evtpat',evts.newPat) if pc then evts.newPat=pv end
    ImGui.TextDisabled('  e.g.  #*# tells you, #*#   or   You have been slain')
    ImGui.Text('Condition:') ImGui.SameLine(80) ImGui.SetNextItemWidth(360)
    local cv,cc=ImGui.InputText('##evtcond',evts.newCond) if cc then evts.newCond=cv end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##evtb') then evts.newCond=bld.input end
    ImGui.Text('Action:') ImGui.SameLine(80) ImGui.SetNextItemWidth(360)
    local av,ac=ImGui.InputText('##evtact',evts.newAct) if ac then evts.newAct=av end
    ImGui.TextDisabled('  e.g.  /cast "Complete Heal"  or  /echo reacting!')
    ImGui.Spacing()
    if ImGui.Button('Add Hook',80,0) then
        if trim(evts.newName)~='' and trim(evts.newPat)~='' and trim(evts.newAct)~='' then
            table.insert(evts.hooks,{name=evts.newName,pattern=evts.newPat,
                cond=evts.newCond,action=evts.newAct,enabled=true,count=0})
            evts.newName='' evts.newPat='' evts.newCond='' evts.newAct=''
        end
    end ImGui.SameLine()
    if evts.active then
        if ImGui.Button('Stop Hooks',88,0) then evts.active=false end
    else
        if ImGui.Button('Activate Hooks',112,0) then evts.active=true evtRegisterAll() end
    end
    if evts.active then ImGui.SameLine() ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],'ACTIVE') end
    ImGui.Spacing() ImGui.Separator()
    local removeIdx=nil
    for i,h in ipairs(evts.hooks) do
        local ev2,ec2=ImGui.Checkbox('##even'..i,h.enabled) if ec2 then h.enabled=ev2 end
        ImGui.SameLine()
        ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],h.name)
        ImGui.SameLine() ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'(fired: '..tostring(h.count)..')')
        ImGui.SameLine(460) if ImGui.SmallButton('Del##evd'..i) then removeIdx=i end
        ImGui.TextDisabled('  Pattern: '..h.pattern)
        if h.cond~='' then ImGui.TextDisabled('  When: '..h.cond:sub(1,58)) end
        ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],'  Do: '..h.action)
        ImGui.Spacing()
    end
    if removeIdx then table.remove(evts.hooks,removeIdx) end
    if #evts.log>0 then
        ImGui.Separator() ImGui.TextDisabled('Event Log')
        ImGui.InputTextMultiline('##evtlog',table.concat(evts.log,'\n'),-1,70,FLAG_RO)
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 11 — STATE MACHINE
-- ══════════════════════════════════════════════════════
local sm={states={},transitions={},newSName='',newSEnter='',newSExit='',
          newTFrom='',newTTo='',newTCond='',newTLabel='',output=''}

local function smBuild()
    local lines={'-- State Machine by ConditionBuilder v4','local mq=require("mq")','',
        'local currentState = "'..(sm.states[1] and sm.states[1].name or 'idle')..'"',''}
    for _,s in ipairs(sm.states) do
        if s.enterAction~='' then
            table.insert(lines,'local function onEnter_'..s.name..'()')
            table.insert(lines,'    '..s.enterAction) table.insert(lines,'end')
        end
    end
    table.insert(lines,'') table.insert(lines,'local function tick()')
    for _,t in ipairs(sm.transitions) do
        table.insert(lines,'    if currentState=="'..t.from..'" and ('..resolveGroups(t.cond)..') then')
        table.insert(lines,'        currentState="'..t.to..'"')
        table.insert(lines,'        mq.cmd("/echo [SM] -> '..t.to..'")')
        if t.enterFn then table.insert(lines,'        onEnter_'..t.to..'()') end
        table.insert(lines,'    end')
    end
    table.insert(lines,'end') table.insert(lines,'')
    table.insert(lines,'while true do') table.insert(lines,'    tick()') table.insert(lines,'    mq.delay(200)') table.insert(lines,'end')
    sm.output=table.concat(lines,'\n')
end

local function drawStateMachine()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'State Machine Builder')
    ImGui.Separator() ImGui.Spacing()
    ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],'Add State')
    ImGui.Text('Name:') ImGui.SameLine(80) ImGui.SetNextItemWidth(140)
    local nv,nc=ImGui.InputText('##smsn',sm.newSName) if nc then sm.newSName=nv end
    ImGui.Text('On Enter:') ImGui.SameLine(80) ImGui.SetNextItemWidth(280)
    local ev,ec=ImGui.InputText('##smsen',sm.newSEnter) if ec then sm.newSEnter=ev end
    if ImGui.Button('Add State',84,0) and trim(sm.newSName)~='' then
        table.insert(sm.states,{name=sm.newSName,enterAction=sm.newSEnter,exitAction=sm.newSExit})
        sm.newSName='' sm.newSEnter=''
    end
    if #sm.states>0 then
        ImGui.TextDisabled('States:') local rs=nil
        for i,s in ipairs(sm.states) do
            ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],'['..s.name..']') ImGui.SameLine()
            if ImGui.SmallButton('Del##ssd'..i) then rs=i end
        end
        if rs then table.remove(sm.states,rs) end
    end
    ImGui.Separator()
    ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],'Add Transition')
    ImGui.Text('From:') ImGui.SameLine(80) ImGui.SetNextItemWidth(120)
    local fv,fc=ImGui.InputText('##smtf',sm.newTFrom) if fc then sm.newTFrom=fv end
    ImGui.SameLine() ImGui.Text('-> To:') ImGui.SameLine(250) ImGui.SetNextItemWidth(120)
    local tv,tc=ImGui.InputText('##smtt',sm.newTTo) if tc then sm.newTTo=tv end
    ImGui.Text('When:') ImGui.SameLine(80) ImGui.SetNextItemWidth(380)
    local cv,cc2=ImGui.InputText('##smtc',sm.newTCond) if cc2 then sm.newTCond=cv end
    ImGui.SameLine() if ImGui.SmallButton('<Builder##smtb') then sm.newTCond=bld.input end
    if ImGui.Button('Add Transition',120,0) then
        if trim(sm.newTFrom)~='' and trim(sm.newTTo)~='' and trim(sm.newTCond)~='' then
            table.insert(sm.transitions,{from=sm.newTFrom,to=sm.newTTo,cond=sm.newTCond,
                label=sm.newTLabel~='' and sm.newTLabel or sm.newTFrom..'->'..sm.newTTo})
            sm.newTFrom='' sm.newTTo='' sm.newTCond=''
        end
    end
    if #sm.transitions>0 then
        ImGui.TextDisabled('Transitions:') local rt=nil
        for i,t in ipairs(sm.transitions) do
            ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],t.from..' -> '..t.to) ImGui.SameLine()
            ImGui.TextDisabled('when: '..t.cond:sub(1,48)) ImGui.SameLine()
            if ImGui.SmallButton('Del##std'..i) then rt=i end
        end
        if rt then table.remove(sm.transitions,rt) end
    end
    ImGui.Spacing()
    if ImGui.Button('Build State Machine',148,0) then smBuild() end
    if sm.output~='' then
        ImGui.SameLine() if ImGui.Button('Copy##smcp',52,0) then ImGui.SetClipboardText(sm.output) end
        ImGui.Spacing() ImGui.InputTextMultiline('##smout',sm.output,-1,100,FLAG_RO)
    end
end

-- ══════════════════════════════════════════════════════
--  TAB 12 — SNIPPETS
-- ══════════════════════════════════════════════════════
local SNIPPETS={
    {name='HP Heal Trigger',   cat='Healing', code="mq.TLO.Me.PctHPs() < 50 and not mq.TLO.Me.Casting.ID()"},
    {name='Mana Check',        cat='Mana',    code="mq.TLO.Me.PctMana() < 20 and not mq.TLO.Me.Sitting()"},
    {name='Buff Missing',      cat='Buffs',   code="not mq.TLO.Me.Buff('Haste').ID()"},
    {name='Song Missing',      cat='Buffs',   code="not mq.TLO.Me.Song('Warsong').ID()"},
    {name='In Combat',         cat='Combat',  code="mq.TLO.Me.Combat()"},
    {name='Not Casting',       cat='Casting', code="not mq.TLO.Me.Casting.ID()"},
    {name='Spell Ready',       cat='Casting', code="mq.TLO.Me.SpellReady('Complete Heal')"},
    {name='Target In Range',   cat='Target',  code="mq.TLO.Target.ID() ~= nil and mq.TLO.Target.Distance() < 30"},
    {name='Target HP Low',     cat='Target',  code="mq.TLO.Target.ID() ~= nil and mq.TLO.Target.PctHPs() < 20"},
    {name='Target Hostile',    cat='Target',  code="mq.TLO.Target.ID() ~= nil and mq.TLO.Target.Aggressive()"},
    {name='Target is NPC',     cat='Target',  code="mq.TLO.Target.ID() ~= nil and mq.TLO.Target.Type() == 'NPC'"},
    {name='Safe Zone',         cat='Zone',    code="mq.TLO.Zone.Safe()"},
    {name='Nav Not Active',    cat='Movement',code="not mq.TLO.Navigation.Active()"},
    {name='Multiple Mobs',     cat='Combat',  code="mq.TLO.SpawnCount('npc radius 30')() > 3"},
    {name='Group HP Low',      cat='Group',   code="mq.TLO.Group.LowHP(50) ~= nil"},
    {name='HP+Mana Combo',     cat='Healing', code="mq.TLO.Me.PctHPs() < 70 and mq.TLO.Me.PctMana() < 30"},
    -- MQ2 ${} style presets (from your version)
    {name='Low HP (MQ2)',      cat='MQ2',     code="${Me.PctHPs} < 50"},
    {name='Low Mana (MQ2)',    cat='MQ2',     code="${Me.PctMana} < 30"},
    {name='Combat Ready (MQ2)',cat='MQ2',     code="${Me.Combat} && ${Target.ID}"},
    {name='Named Target (MQ2)',cat='MQ2',     code="${Target.Named}"},
    {name='Named Nearby (MQ2)',cat='MQ2',     code="${SpawnCount[npc radius 120 named]} > 0"},
    {name='No Buff Active (MQ2)',cat='MQ2',   code="!${Me.Buff[Credence].ID}"},
}
local snipFilter,snipCat='','All'
local snipCats={'All','Healing','Mana','Buffs','Combat','Casting','Target','Zone','Movement','Group','MQ2'}
local snipCatIdx=0

local function drawSnippets()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'Snippet Library')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Search:') ImGui.SameLine(60) ImGui.SetNextItemWidth(200)
    local fv,fc=ImGui.InputText('##snipf',snipFilter) if fc then snipFilter=fv end
    ImGui.SameLine() ImGui.SetNextItemWidth(120)
    local ni,cc=ImGui.Combo('##snipc',snipCatIdx,snipCats,#snipCats)
    if cc then snipCatIdx=ni snipCat=snipCats[ni+1] end
    ImGui.Spacing() ImGui.Separator()
    local shown=0
    for i,s in ipairs(SNIPPETS) do
        local mc=(snipCat=='All' or s.cat==snipCat)
        local mt=(snipFilter=='' or s.name:lower():find(snipFilter:lower(),1,true) or s.code:lower():find(snipFilter:lower(),1,true))
        if mc and mt then
            shown=shown+1
            ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],s.name)
            ImGui.SameLine(200) ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'['..s.cat..']')
            local sh=(#s.code>58) and s.code:sub(1,55)..'...' or s.code
            ImGui.TextDisabled('  '..sh) ImGui.SameLine()
            if ImGui.SmallButton('Use##su'..i)  then bldLoad(s.code) end ImGui.SameLine()
            if ImGui.SmallButton('Test##st'..i) then tst.input=s.code end ImGui.SameLine()
            if ImGui.SmallButton('Save##ss'..i) then
                cbIniSave(s.name:gsub('%s','_'),s.code,s.cat)
                cbIniAddIndex(s.name:gsub('%s','_'))
            end
            ImGui.Separator()
        end
    end
    if shown==0 then ImGui.TextDisabled('No snippets match.') end
end

-- ══════════════════════════════════════════════════════
--  TAB 13 — GLOSSARY
-- ══════════════════════════════════════════════════════
local GLOSSARY={
    {tlo='mq.TLO.Me.PctHPs()',             ret='number', cat='Me',      notes='HP percent 0-100'},
    {tlo='mq.TLO.Me.PctMana()',            ret='number', cat='Me',      notes='Mana percent 0-100'},
    {tlo='mq.TLO.Me.PctEndurance()',       ret='number', cat='Me',      notes='Endurance percent 0-100'},
    {tlo='mq.TLO.Me.Combat()',             ret='bool',   cat='Me',      notes='In combat'},
    {tlo='mq.TLO.Me.Sitting()',            ret='bool',   cat='Me',      notes='Sitting or resting'},
    {tlo='mq.TLO.Me.Standing()',           ret='bool',   cat='Me',      notes='Standing upright'},
    {tlo='mq.TLO.Me.Invis()',              ret='bool',   cat='Me',      notes='Is invisible'},
    {tlo='mq.TLO.Me.Casting.ID()',         ret='number?',cat='Casting', notes='Spell ID being cast, nil if none'},
    {tlo="mq.TLO.Me.Buff('name').ID()",    ret='number?',cat='Buffs',   notes='Buff ID if present, nil if missing'},
    {tlo="mq.TLO.Me.Song('name').ID()",    ret='number?',cat='Buffs',   notes='Song ID if active, nil if not'},
    {tlo="mq.TLO.Me.SpellReady('name')",   ret='bool',   cat='Casting', notes='Spell gem ready to cast'},
    {tlo="mq.TLO.Me.AbilityReady('name')", ret='bool',   cat='Combat',  notes='Ability off cooldown'},
    {tlo='mq.TLO.Target.ID()',             ret='number?',cat='Target',  notes='Target ID, nil if no target'},
    {tlo='mq.TLO.Target.PctHPs()',         ret='number', cat='Target',  notes='Target HP percent'},
    {tlo='mq.TLO.Target.Distance()',       ret='number', cat='Target',  notes='Distance to target'},
    {tlo='mq.TLO.Target.Aggressive()',     ret='bool',   cat='Target',  notes='Aggressive toward you'},
    {tlo="mq.TLO.Target.Type()",           ret='string', cat='Target',  notes="'NPC' 'PC' 'CORPSE' ..."},
    {tlo='mq.TLO.Target.Named()',          ret='bool',   cat='Target',  notes='Is a named mob'},
    {tlo='mq.TLO.Group.Members()',         ret='number', cat='Group',   notes='Members not including self'},
    {tlo='mq.TLO.Group.LowHP(pct)()',      ret='spawn?', cat='Group',   notes='First member below pct HP'},
    {tlo='mq.TLO.Zone.Safe()',             ret='bool',   cat='Zone',    notes='Zone is safe'},
    {tlo='mq.TLO.Zone.Name()',             ret='string', cat='Zone',    notes='Short zone name'},
    {tlo='mq.TLO.Navigation.Active()',     ret='bool',   cat='Nav',     notes='MQ2Nav navigating'},
    {tlo="mq.TLO.SpawnCount('filter')()",  ret='number', cat='Spawns',  notes="Count spawns by filter"},
    {tlo='mq.TLO.Pet.PctHPs()',            ret='number?',cat='Pet',     notes='Pet HP percent, nil if no pet'},
    -- MQ2 macro syntax reference
    {tlo='${Me.PctHPs}',                   ret='number', cat='MQ2',     notes='HP percent in macro syntax'},
    {tlo='${Me.PctMana}',                  ret='number', cat='MQ2',     notes='Mana percent in macro syntax'},
    {tlo='${Me.Combat}',                   ret='bool',   cat='MQ2',     notes='In combat (macro)'},
    {tlo='${Target.Named}',                ret='bool',   cat='MQ2',     notes='Target is named (macro)'},
    {tlo='${SpawnCount[filter]}',          ret='number', cat='MQ2',     notes='Spawn count (macro)'},
    {tlo='${Me.Buff[name].ID}',            ret='number?',cat='MQ2',     notes='Buff ID (macro syntax)'},
}
local glosFilter,glosCat,glosCatIdx='','All',0
local glosCats={'All','Me','Casting','Buffs','Combat','Target','Group','Zone','Nav','Spawns','Pet','MQ2'}

local function drawGlossary()
    ImGui.TextColored(C.HEADER[1],C.HEADER[2],C.HEADER[3],C.HEADER[4],'TLO Glossary')
    ImGui.TextDisabled('Covers both Lua mq.TLO.* and MQ2 ${} macro syntax')
    ImGui.Separator() ImGui.Spacing()
    ImGui.Text('Search:') ImGui.SameLine(60) ImGui.SetNextItemWidth(200)
    local fv,fc=ImGui.InputText('##glosf',glosFilter) if fc then glosFilter=fv end
    ImGui.SameLine() ImGui.SetNextItemWidth(120)
    local ni,cc=ImGui.Combo('##glosc',glosCatIdx,glosCats,#glosCats)
    if cc then glosCatIdx=ni glosCat=glosCats[ni+1] end
    ImGui.Spacing() ImGui.Separator()
    local shown=0
    local extras={}
    for _,p in ipairs(PLUGINS) do for _,t in ipairs(p.tlos) do table.insert(extras,t) end end
    local function showEntry(g,idx)
        local mc=(glosCat=='All' or g.cat==glosCat)
        local mt=(glosFilter=='' or g.tlo:lower():find(glosFilter:lower(),1,true) or g.notes:lower():find(glosFilter:lower(),1,true))
        if not(mc and mt) then return end
        shown=shown+1
        ImGui.TextColored(C.PREVIEW[1],C.PREVIEW[2],C.PREVIEW[3],C.PREVIEW[4],g.tlo) ImGui.SameLine(310)
        if g.ret=='bool' then ImGui.TextColored(C.OK[1],C.OK[2],C.OK[3],C.OK[4],g.ret)
        elseif g.ret=='number' then ImGui.TextColored(C.ORANGE[1],C.ORANGE[2],C.ORANGE[3],C.ORANGE[4],g.ret)
        elseif g.ret:find('%?') then ImGui.TextColored(C.WARN[1],C.WARN[2],C.WARN[3],C.WARN[4],g.ret)
        else ImGui.TextColored(C.PURPLE[1],C.PURPLE[2],C.PURPLE[3],C.PURPLE[4],g.ret) end
        ImGui.SameLine(380) ImGui.TextColored(C.MUTED[1],C.MUTED[2],C.MUTED[3],C.MUTED[4],'['..g.cat..']')
        ImGui.TextDisabled('  '..g.notes) ImGui.SameLine()
        local ic=g.tlo:gsub('%(pct%)','(50)'):gsub('%(N,','(1,'):gsub('%?','')
        if ImGui.SmallButton('Insert##gi'..idx) then bld.input=bld.input..ic end
        ImGui.Separator()
    end
    for i,g in ipairs(GLOSSARY) do showEntry(g,i) end
    for i,g in ipairs(extras) do showEntry(g,1000+i) end
    if shown==0 then ImGui.TextDisabled('No entries match.') end
end

-- ══════════════════════════════════════════════════════
--  MAIN WINDOW
-- ══════════════════════════════════════════════════════
local function drawWindow()
    if not running then return end
    if not open then return end

    local t = themeBridge.push()
    ImGui.SetNextWindowSize(760, 780, COND_FIRST)
    open = ImGui.Begin('Condition Builder###ConditionBuilderV4', open)

    if open then
        if ImGui.BeginTabBar('CBTabs4MA') then
            if ImGui.BeginTabItem('Builder')   then drawBuilder()       ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Tester')    then drawTester()        ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Templates') then drawTemplates()     ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Classes')   then drawClassPresets()  ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Rotation')  then drawRotation()      ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Combiner')  then drawCombiner()      ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Diff')      then drawDiff()          ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Spawns')    then drawSpawnInspector() ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Groups')    then drawCondGroups()    ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Events')    then drawEventHooks()    ImGui.EndTabItem() end
            if ImGui.BeginTabItem('StateMach') then drawStateMachine()  ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Snippets')  then drawSnippets()      ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Glossary')  then drawGlossary()      ImGui.EndTabItem() end
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
    themeBridge.pop(t)
end

-- ──────────────────────────────────────────────────────
-- COMMANDS  (your /cb [show|hide|toggle|clear|quit] system)
-- ──────────────────────────────────────────────────────
local function bindCB(arg)
    local a = tostring(arg or ''):lower()
    if a=='' or a=='toggle' then open=not open
    elseif a=='show'  then open=true
    elseif a=='hide'  then open=false
    elseif a=='clear' then bld.input='' bld.msg='Condition cleared.'
    elseif a=='quit' or a=='stop' then running=false
    else mq.cmd('/echo [ConditionBuilder] Usage: /cb [show|hide|toggle|clear|quit]') end
end

-- ──────────────────────────────────────────────────────
-- INIT
-- ──────────────────────────────────────────────────────
mq.bind('/cb', bindCB)
mq.imgui.init('ConditionBuilderV4', drawWindow)
mq.cmd('/echo [ConditionBuilder v4] Loaded. /cb to toggle — 13 tabs.')

-- ──────────────────────────────────────────────────────
-- MAIN LOOP
-- ──────────────────────────────────────────────────────
while running do
    tstTick()       -- condition timer polling
    mq.doevents()   -- process registered chat event hooks
    mq.delay(50)
end

mq.unbind('/cb')
mq.cmd('/echo [ConditionBuilder v4] Stopped.')
