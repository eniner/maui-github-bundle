local mq = require('mq')

local M = {}

local themes = {
    ['template'] = {
        windowBg = {0.03, 0.05, 0.10, 1.00},
        titleBg = {0.02, 0.03, 0.07, 1.00},
        titleBgActive = {0.03, 0.05, 0.12, 1.00},
        button = {0.10, 0.18, 0.31, 0.95},
        buttonHovered = {0.16, 0.27, 0.44, 1.00},
        buttonActive = {0.21, 0.33, 0.52, 1.00},
        frameBg = {0.09, 0.15, 0.26, 0.95},
        frameBgHovered = {0.14, 0.22, 0.36, 1.00},
        frameBgActive = {0.16, 0.24, 0.40, 1.00},
        header = {0.10, 0.18, 0.31, 0.95},
        text = {1.00, 0.95, 0.20, 1.00},
        border = {0.74, 0.66, 0.34, 0.95},
        separator = {0.44, 0.52, 0.72, 0.90},
        popupBg = {0.06, 0.08, 0.14, 0.98},
        checkMark = {1.00, 0.95, 0.20, 1.00},
    },
    ['neon_purple'] = {
        windowBg = {0.05, 0.05, 0.05, 0.95},
        titleBg = {0.1, 0.05, 0.15, 1.0},
        titleBgActive = {0.3, 0.1, 0.4, 1.0},
        button = {0.5, 0.1, 0.7, 1.0},
        buttonHovered = {0.7, 0.2, 0.9, 1.0},
        buttonActive = {0.4, 0.05, 0.6, 1.0},
        frameBg = {0.15, 0.1, 0.2, 1.0},
        frameBgHovered = {0.25, 0.15, 0.3, 1.0},
        frameBgActive = {0.30, 0.18, 0.36, 1.0},
        header = {0.4, 0.15, 0.55, 1.0},
        text = {0.95, 0.85, 1.0, 1.0},
        border = {0.6, 0.2, 0.8, 0.5},
        separator = {0.5, 0.2, 0.7, 0.8},
        popupBg = {0.08, 0.04, 0.12, 0.98},
        checkMark = {0.95, 0.85, 1.0, 1.0},
    },
    ['cyber_blue'] = {
        windowBg = {0.02, 0.02, 0.08, 0.95},
        titleBg = {0.05, 0.1, 0.2, 1.0},
        titleBgActive = {0.1, 0.3, 0.5, 1.0},
        button = {0.1, 0.4, 0.8, 1.0},
        buttonHovered = {0.2, 0.5, 0.95, 1.0},
        buttonActive = {0.05, 0.3, 0.6, 1.0},
        frameBg = {0.1, 0.15, 0.25, 1.0},
        frameBgHovered = {0.15, 0.25, 0.35, 1.0},
        frameBgActive = {0.12, 0.21, 0.32, 1.0},
        header = {0.15, 0.4, 0.65, 1.0},
        text = {0.85, 0.95, 1.0, 1.0},
        border = {0.2, 0.6, 0.9, 0.5},
        separator = {0.2, 0.5, 0.8, 0.8},
        popupBg = {0.04, 0.08, 0.14, 0.98},
        checkMark = {0.85, 0.95, 1.0, 1.0},
    },
    ['toxic_green'] = {
        windowBg = {0.02, 0.05, 0.02, 0.95},
        titleBg = {0.05, 0.15, 0.05, 1.0},
        titleBgActive = {0.1, 0.4, 0.1, 1.0},
        button = {0.2, 0.7, 0.2, 1.0},
        buttonHovered = {0.3, 0.9, 0.3, 1.0},
        buttonActive = {0.15, 0.5, 0.15, 1.0},
        frameBg = {0.1, 0.2, 0.1, 1.0},
        frameBgHovered = {0.15, 0.3, 0.15, 1.0},
        frameBgActive = {0.13, 0.24, 0.13, 1.0},
        header = {0.2, 0.6, 0.2, 1.0},
        text = {0.85, 1.0, 0.85, 1.0},
        border = {0.3, 0.8, 0.3, 0.5},
        separator = {0.25, 0.7, 0.25, 0.8},
        popupBg = {0.04, 0.10, 0.04, 0.98},
        checkMark = {0.85, 1.0, 0.85, 1.0},
    },
    ['hot_pink'] = {
        windowBg = {0.08, 0.02, 0.05, 0.95},
        titleBg = {0.2, 0.05, 0.1, 1.0},
        titleBgActive = {0.5, 0.1, 0.3, 1.0},
        button = {0.9, 0.2, 0.5, 1.0},
        buttonHovered = {1.0, 0.4, 0.7, 1.0},
        buttonActive = {0.7, 0.1, 0.4, 1.0},
        frameBg = {0.2, 0.1, 0.15, 1.0},
        frameBgHovered = {0.3, 0.15, 0.25, 1.0},
        frameBgActive = {0.25, 0.13, 0.20, 1.0},
        header = {0.7, 0.15, 0.4, 1.0},
        text = {1.0, 0.85, 0.95, 1.0},
        border = {0.9, 0.3, 0.6, 0.5},
        separator = {0.8, 0.25, 0.5, 0.8},
        popupBg = {0.15, 0.06, 0.10, 0.98},
        checkMark = {1.0, 0.85, 0.95, 1.0},
    },
    ['orange_blaze'] = {
        windowBg = {0.05, 0.03, 0.0, 0.95},
        titleBg = {0.15, 0.08, 0.0, 1.0},
        titleBgActive = {0.4, 0.2, 0.0, 1.0},
        button = {0.9, 0.5, 0.1, 1.0},
        buttonHovered = {1.0, 0.6, 0.2, 1.0},
        buttonActive = {0.7, 0.4, 0.05, 1.0},
        frameBg = {0.2, 0.12, 0.05, 1.0},
        frameBgHovered = {0.3, 0.18, 0.08, 1.0},
        frameBgActive = {0.26, 0.16, 0.07, 1.0},
        header = {0.7, 0.4, 0.1, 1.0},
        text = {1.0, 0.95, 0.85, 1.0},
        border = {0.9, 0.5, 0.2, 0.5},
        separator = {0.8, 0.45, 0.15, 0.8},
        popupBg = {0.16, 0.10, 0.04, 0.98},
        checkMark = {1.0, 0.95, 0.85, 1.0},
    },
    ['ice_blue'] = {
        windowBg = {0.02, 0.05, 0.08, 0.95},
        titleBg = {0.05, 0.12, 0.18, 1.0},
        titleBgActive = {0.1, 0.25, 0.4, 1.0},
        button = {0.2, 0.6, 0.8, 1.0},
        buttonHovered = {0.3, 0.75, 0.95, 1.0},
        buttonActive = {0.15, 0.5, 0.65, 1.0},
        frameBg = {0.1, 0.18, 0.25, 1.0},
        frameBgHovered = {0.15, 0.25, 0.35, 1.0},
        frameBgActive = {0.13, 0.22, 0.30, 1.0},
        header = {0.2, 0.5, 0.7, 1.0},
        text = {0.9, 0.98, 1.0, 1.0},
        border = {0.3, 0.7, 0.9, 0.5},
        separator = {0.25, 0.65, 0.85, 0.8},
        popupBg = {0.06, 0.12, 0.18, 0.98},
        checkMark = {0.9, 0.98, 1.0, 1.0},
    },
    ['matrix_hack'] = {
        windowBg = {0.0, 0.0, 0.0, 0.98},
        titleBg = {0.0, 0.08, 0.0, 1.0},
        titleBgActive = {0.0, 0.25, 0.0, 1.0},
        button = {0.0, 0.5, 0.0, 1.0},
        buttonHovered = {0.0, 0.7, 0.0, 1.0},
        buttonActive = {0.0, 0.35, 0.0, 1.0},
        frameBg = {0.0, 0.12, 0.0, 1.0},
        frameBgHovered = {0.0, 0.2, 0.0, 1.0},
        frameBgActive = {0.0, 0.17, 0.0, 1.0},
        header = {0.0, 0.4, 0.0, 1.0},
        text = {0.0, 1.0, 0.0, 1.0},
        border = {0.0, 0.6, 0.0, 0.7},
        separator = {0.0, 0.5, 0.0, 0.9},
        popupBg = {0.0, 0.06, 0.0, 0.98},
        checkMark = {0.0, 1.0, 0.0, 1.0},
    },
    ['term_hack'] = {
        windowBg = {0.0, 0.02, 0.0, 0.98},
        titleBg = {0.0, 0.1, 0.05, 1.0},
        titleBgActive = {0.0, 0.3, 0.15, 1.0},
        button = {0.0, 0.6, 0.3, 1.0},
        buttonHovered = {0.0, 0.8, 0.4, 1.0},
        buttonActive = {0.0, 0.45, 0.22, 1.0},
        frameBg = {0.0, 0.15, 0.08, 1.0},
        frameBgHovered = {0.0, 0.25, 0.12, 1.0},
        frameBgActive = {0.0, 0.20, 0.10, 1.0},
        header = {0.0, 0.5, 0.25, 1.0},
        text = {0.2, 1.0, 0.6, 1.0},
        border = {0.0, 0.7, 0.35, 0.7},
        separator = {0.0, 0.6, 0.3, 0.9},
        popupBg = {0.0, 0.08, 0.04, 0.98},
        checkMark = {0.2, 1.0, 0.6, 1.0},
    },
}

local cache = {
    key = 'template',
    nextReadAt = 0,
}

local function get_theme_key()
    local now = mq.gettime and mq.gettime() or 0
    if now < cache.nextReadAt then
        return cache.key
    end
    cache.nextReadAt = now + 2000

    local path = string.format('%s/%s_%s.ini', mq.configDir, mq.TLO.EverQuest.Server(), mq.TLO.Me.CleanName())
    local f = io.open(path, 'r')
    if f then
        local inMaui = false
        for line in f:lines() do
            local header = line:match('^%s*%[([^%]]+)%]%s*$')
            if header then
                inMaui = (header == 'MAUI')
            elseif inMaui then
                local key, value = line:match('^%s*([^=]+)%s*=%s*(.-)%s*$')
                if key and value and key:lower() == 'theme' and themes[value] then
                    cache.key = value
                    break
                end
            end
        end
        f:close()
    end
    return cache.key
end

function M.push()
    local key = get_theme_key()
    local t = themes[key] or themes.template
    local token = {colors = 0, vars = 0}
    local function pushc(col, rgba)
        ImGui.PushStyleColor(col, rgba[1], rgba[2], rgba[3], rgba[4])
        token.colors = token.colors + 1
    end
    pushc(ImGuiCol.WindowBg, t.windowBg)
    pushc(ImGuiCol.TitleBg, t.titleBg)
    pushc(ImGuiCol.TitleBgActive, t.titleBgActive)
    pushc(ImGuiCol.Button, t.button)
    pushc(ImGuiCol.ButtonHovered, t.buttonHovered)
    pushc(ImGuiCol.ButtonActive, t.buttonActive)
    pushc(ImGuiCol.FrameBg, t.frameBg)
    pushc(ImGuiCol.FrameBgHovered, t.frameBgHovered)
    pushc(ImGuiCol.FrameBgActive, t.frameBgActive)
    pushc(ImGuiCol.Header, t.header)
    pushc(ImGuiCol.HeaderHovered, t.buttonHovered)
    pushc(ImGuiCol.HeaderActive, t.buttonActive)
    pushc(ImGuiCol.Text, t.text)
    pushc(ImGuiCol.Border, t.border)
    pushc(ImGuiCol.Separator, t.separator)
    pushc(ImGuiCol.PopupBg, t.popupBg)
    pushc(ImGuiCol.CheckMark, t.checkMark)

    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 4)
    token.vars = token.vars + 1
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 4)
    token.vars = token.vars + 1
    return token
end

function M.pop(token)
    if token and token.vars and token.vars > 0 then
        ImGui.PopStyleVar(token.vars)
    end
    if token and token.colors and token.colors > 0 then
        ImGui.PopStyleColor(token.colors)
    end
end

return M
