--[[
    iina_osc.lua  —  IINA-style on-screen controller for mpv (Linux / any OS)
    ----------------------------------------------------------------------
    * Floating, rounded, translucent control panel at the bottom (like IINA)
    * Rewind / Play-Pause / Forward in the middle, volume on the left,
      audio / subtitles / playlist / fullscreen / quit on the right,
      zoom-out / zoom-in next to the volume
    * Thin seekbar with time, remaining time, cache, chapters and hover preview
    * Optional seek thumbnails via thumbfast.lua
    * Optional menus via uosc (falls back to mpv's built-in select menus, 0.39+)
    * Top title bar with gradient (border=no / fullscreen) + minimal  -  []  x
      window buttons in the top-right corner (they fade in/out with the panel)
    * Idle screen with a click-to-open button (zenity / kdialog / uosc)

    Requirements : mpv 0.37 or newer, and  osc=no  in mpv.conf
    Install      : ~/.config/mpv/scripts/iina_osc.lua
    Options      : ~/.config/mpv/script-opts/iina_osc.conf
    License      : MIT
--]]

local mp      = require "mp"
local msg     = require "mp.msg"
local utils   = require "mp.utils"
local options = require "mp.options"

---------------------------------------------------------------------------
-- Options (override in script-opts/iina_osc.conf)
---------------------------------------------------------------------------
local opts = {
    scale              = 1.0,       -- UI scale in a window
    scale_fullscreen   = 1.2,       -- UI scale in fullscreen
    panel_width        = 640,       -- max panel width (px, before scaling)
    panel_height       = 92,
    panel_margin       = 28,        -- distance from the bottom edge
    panel_radius       = 14,
    panel_color        = "#1E1E20",
    panel_opacity      = 0.72,      -- 0..1
    border_color       = "#FFFFFF",
    border_opacity     = 0.12,
    shadow_opacity     = 0.35,
    foreground_color   = "#FFFFFF",
    accent_color       = "#FFFFFF", -- seekbar progress colour (e.g. #0A84FF)
    font               = "Inter",
    time_font_size     = 13,
    hide_timeout       = 2000,      -- ms without mouse movement before hiding
    fade_duration      = 180,       -- ms
    keep_on_pause      = false,     -- stay visible while paused
    show_on_seek       = true,
    show_on_start      = true,
    title_bar          = "auto",    -- auto (border=no or fullscreen) | yes | no
    window_buttons     = "yes",     -- minimize/maximize/close (top right): yes (always) | windowed | auto (only with border=no) | no
    jump_seconds       = 10,
    quit_button        = true,      -- power button at the right end of the panel
    zoom_buttons       = true,      -- zoom-out / zoom-in buttons next to the volume
    zoom_step          = 0.1,       -- video-zoom step (log2: 0.1 = about 7%)
    zoom_min           = -2,        -- 25%
    zoom_max           = 3,         -- 800%
    volume_max         = 100,       -- right end of the volume slider
    menu_backend       = "auto",    -- auto | uosc | select
    thumbnails         = true,      -- use thumbfast if it is installed
    exact_seek_on_release = true,
    min_mouse_move     = 2,         -- px of movement needed to reveal the UI
}

local render, request_render, show, hide

options.read_options(opts, "iina_osc", function()
    if request_render then request_render() end
end)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = {
    osd_w = 0, osd_h = 0, hidpi = 1,
    mouse_x = -1, mouse_y = -1, mouse_in = false, mouse_left = false,
    visible = false, alpha = 0, target = 0, last_activity = 0, pinned = false,
    elements = {}, hover_id = nil, pressed = nil,
    dragging = nil, drag_el = nil, last_seek = nil,
    panel = nil, topbtn = nil, idle_box = nil,
    show_remaining = true,
    thumbfast = { width = 0, height = 0, disabled = true, available = false },
    thumb_shown = false, thumb_key = nil,
    -- mpv properties
    zoom = 0, pending_tip = nil,
    pause = false, time = 0, duration = 0, volume = 100, mute = false, speed = 1,
    fullscreen = false, maximized = false, border = true, idle = false, title = "",
    chapters = {}, cache = nil,
}

local overlay = mp.create_osd_overlay("ass-events")
local A = 1           -- global opacity multiplier for the current frame (fade)
local ass = {}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function fmt(n) return string.format("%.1f", n) end

local function now() return mp.get_time() end

local function ass_color(rgb)                 -- "#RRGGBB" -> "&HBBGGRR&"
    rgb = (rgb or "FFFFFF"):gsub("#", "")
    if #rgb ~= 6 then rgb = "FFFFFF" end
    return "&H" .. rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2) .. "&"
end

local function ass_alpha(opacity)             -- 0..1 -> "&HAA&"
    local a = math.floor(255 - 255 * clamp(opacity, 0, 1) + 0.5)
    return string.format("&H%02X&", a)
end

local function ass_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\239\187\191")
    s = s:gsub("{", "\\{")
    s = s:gsub("}", "\\}")
    s = s:gsub("\n", " ")
    return s
end

local function utf8_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

local function utf8_truncate(s, n)
    if n < 2 then return "" end
    if utf8_len(s) <= n then return s end
    local count, i = 0, 1
    while i <= #s do
        local c = s:byte(i)
        local l = (c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1
        count = count + 1
        if count > n - 1 then break end
        i = i + l
    end
    return s:sub(1, i - 1) .. "…"
end

local function fmt_time(t, hours)
    t = math.max(0, math.floor(t or 0))
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if hours then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

---------------------------------------------------------------------------
-- ASS drawing primitives (absolute coordinates, 1 unit = 1 screen pixel)
---------------------------------------------------------------------------
local function rrect_path(x, y, w, h, r)
    r = math.max(0, math.min(r, w / 2, h / 2))
    local k = 0.5523 * r
    local x2, y2 = x + w, y + h
    return table.concat({
        "m", fmt(x + r), fmt(y),
        "l", fmt(x2 - r), fmt(y),
        "b", fmt(x2 - r + k), fmt(y), fmt(x2), fmt(y + r - k), fmt(x2), fmt(y + r),
        "l", fmt(x2), fmt(y2 - r),
        "b", fmt(x2), fmt(y2 - r + k), fmt(x2 - r + k), fmt(y2), fmt(x2 - r), fmt(y2),
        "l", fmt(x + r), fmt(y2),
        "b", fmt(x + r - k), fmt(y2), fmt(x), fmt(y2 - r + k), fmt(x), fmt(y2 - r),
        "l", fmt(x), fmt(y + r),
        "b", fmt(x), fmt(y + r - k), fmt(x + r - k), fmt(y), fmt(x + r), fmt(y),
    }, " ")
end

local function circle_path(cx, cy, r) return rrect_path(cx - r, cy - r, 2 * r, 2 * r, r) end

local function line_path(x1, y1, x2, y2, width)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return "" end
    local nx, ny = -dy / len * width / 2, dx / len * width / 2
    return string.format("m %s %s l %s %s l %s %s l %s %s",
        fmt(x1 + nx), fmt(y1 + ny), fmt(x2 + nx), fmt(y2 + ny),
        fmt(x2 - nx), fmt(y2 - ny), fmt(x1 - nx), fmt(y1 - ny))
end

local function push(s) ass[#ass + 1] = s end

local function shape(path, color, opacity, extra)
    if path == "" then return end
    push(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a%s%s\\p1}%s{\\p0}",
        ass_color(color), ass_alpha(opacity * A), extra or "", path))
end

local function outline(path, color, opacity, width)
    push(string.format("{\\an7\\pos(0,0)\\shad0\\1a&HFF&\\bord%s\\3c%s\\3a%s\\p1}%s{\\p0}",
        fmt(width), ass_color(color), ass_alpha(opacity * A), path))
end

local function text(x, y, an, str, size, color, opacity, extra)
    push(string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\bord0\\shad0\\q2\\1c%s\\1a%s%s}%s",
        an, fmt(x), fmt(y), opts.font, fmt(size), ass_color(color),
        ass_alpha(opacity * A), extra or "", ass_escape(str)))
end

---------------------------------------------------------------------------
-- Icons (vector, drawn around centre x,y with size s)
---------------------------------------------------------------------------
local icons = {}

function icons.play(x, y, s, op)
    shape(string.format("m %s %s l %s %s l %s %s",
        fmt(x - 0.32 * s), fmt(y - 0.42 * s), fmt(x + 0.48 * s), fmt(y),
        fmt(x - 0.32 * s), fmt(y + 0.42 * s)), opts.foreground_color, op)
end

function icons.pause(x, y, s, op)
    local bw, bh = 0.24 * s, 0.84 * s
    shape(rrect_path(x - 0.30 * s, y - bh / 2, bw, bh, bw * 0.3) .. " " ..
          rrect_path(x + 0.06 * s, y - bh / 2, bw, bh, bw * 0.3), opts.foreground_color, op)
end

function icons.rewind(x, y, s, op)
    local h = 0.38 * s
    shape(string.format("m %s %s l %s %s l %s %s m %s %s l %s %s l %s %s",
        fmt(x), fmt(y - h), fmt(x), fmt(y + h), fmt(x - 0.5 * s), fmt(y),
        fmt(x + 0.5 * s), fmt(y - h), fmt(x + 0.5 * s), fmt(y + h), fmt(x), fmt(y)),
        opts.foreground_color, op)
end

function icons.forward(x, y, s, op)
    local h = 0.38 * s
    shape(string.format("m %s %s l %s %s l %s %s m %s %s l %s %s l %s %s",
        fmt(x), fmt(y - h), fmt(x + 0.5 * s), fmt(y), fmt(x), fmt(y + h),
        fmt(x - 0.5 * s), fmt(y - h), fmt(x), fmt(y), fmt(x - 0.5 * s), fmt(y + h)),
        opts.foreground_color, op)
end

function icons.volume(x, y, s, op, level, muted)
    local fg = opts.foreground_color
    shape(string.format("m %s %s l %s %s l %s %s l %s %s l %s %s l %s %s",
        fmt(x - 0.5 * s), fmt(y - 0.17 * s), fmt(x - 0.25 * s), fmt(y - 0.17 * s),
        fmt(x + 0.02 * s), fmt(y - 0.45 * s), fmt(x + 0.02 * s), fmt(y + 0.45 * s),
        fmt(x - 0.25 * s), fmt(y + 0.17 * s), fmt(x - 0.5 * s), fmt(y + 0.17 * s)), fg, op)
    if muted then
        shape(line_path(x + 0.18 * s, y - 0.2 * s, x + 0.52 * s, y + 0.2 * s, 0.1 * s), fg, op)
        shape(line_path(x + 0.18 * s, y + 0.2 * s, x + 0.52 * s, y - 0.2 * s, 0.1 * s), fg, op)
    else
        local bw = 0.09 * s
        if level > 0 then
            shape(rrect_path(x + 0.15 * s, y - 0.15 * s, bw, 0.30 * s, bw / 2), fg, op)
        end
        if level > 0.34 then
            shape(rrect_path(x + 0.30 * s, y - 0.27 * s, bw, 0.54 * s, bw / 2), fg, op)
        end
        if level > 0.67 then
            shape(rrect_path(x + 0.45 * s, y - 0.39 * s, bw, 0.78 * s, bw / 2), fg, op)
        end
    end
end

function icons.subtitles(x, y, s, op)
    local fg = opts.foreground_color
    local w, h = 0.95 * s, 0.72 * s
    outline(rrect_path(x - w / 2, y - h / 2, w, h, 0.14 * s), fg, op, 0.08 * s)
    local lh = 0.09 * s
    shape(rrect_path(x - 0.30 * s, y + 0.04 * s, 0.20 * s, lh, lh / 2) .. " " ..
          rrect_path(x - 0.02 * s, y + 0.04 * s, 0.32 * s, lh, lh / 2) .. " " ..
          rrect_path(x - 0.30 * s, y - 0.14 * s, 0.36 * s, lh, lh / 2) .. " " ..
          rrect_path(x + 0.14 * s, y - 0.14 * s, 0.16 * s, lh, lh / 2), fg, op)
end

function icons.audio(x, y, s, op)
    local hs = { 0.30, 0.62, 0.95, 0.55, 0.30 }
    local bw, gap = 0.11 * s, 0.2 * s
    local parts = {}
    for i, hh in ipairs(hs) do
        parts[#parts + 1] = rrect_path(x + (i - 3) * gap - bw / 2, y - hh * s / 2, bw, hh * s, bw / 2)
    end
    shape(table.concat(parts, " "), opts.foreground_color, op)
end

function icons.playlist(x, y, s, op)
    local parts = {}
    for i = -1, 1 do
        local ly = y + i * 0.28 * s - 0.045 * s
        parts[#parts + 1] = rrect_path(x - 0.45 * s, ly, 0.12 * s, 0.09 * s, 0.045 * s)
        parts[#parts + 1] = rrect_path(x - 0.22 * s, ly, 0.67 * s, 0.09 * s, 0.045 * s)
    end
    shape(table.concat(parts, " "), opts.foreground_color, op)
end

local function corner(x0, y0, sx, sy, a, t)
    return string.format("m %s %s l %s %s l %s %s l %s %s l %s %s l %s %s",
        fmt(x0), fmt(y0), fmt(x0 + sx * a), fmt(y0), fmt(x0 + sx * a), fmt(y0 + sy * t),
        fmt(x0 + sx * t), fmt(y0 + sy * t), fmt(x0 + sx * t), fmt(y0 + sy * a),
        fmt(x0), fmt(y0 + sy * a))
end

function icons.fullscreen(x, y, s, op, is_fs)
    local a, t = 0.3 * s, 0.09 * s
    local p
    if not is_fs then
        local h = 0.42 * s
        p = { corner(x - h, y - h, 1, 1, a, t), corner(x + h, y - h, -1, 1, a, t),
              corner(x - h, y + h, 1, -1, a, t), corner(x + h, y + h, -1, -1, a, t) }
    else
        local g = 0.1 * s
        p = { corner(x - g, y - g, -1, -1, a, t), corner(x + g, y - g, 1, -1, a, t),
              corner(x - g, y + g, -1, 1, a, t), corner(x + g, y + g, 1, 1, a, t) }
    end
    shape(table.concat(p, " "), opts.foreground_color, op)
end

local function arc_path(cx, cy, r, w, a1, a2, steps)
    local ro, ri, pts = r + w / 2, r - w / 2, {}
    for i = 0, steps do
        local a = a1 + (a2 - a1) * i / steps
        pts[#pts + 1] = { cx + ro * math.cos(a), cy + ro * math.sin(a) }
    end
    for i = steps, 0, -1 do
        local a = a1 + (a2 - a1) * i / steps
        pts[#pts + 1] = { cx + ri * math.cos(a), cy + ri * math.sin(a) }
    end
    local p = { "m", fmt(pts[1][1]), fmt(pts[1][2]) }
    for i = 2, #pts do
        p[#p + 1] = "l"; p[#p + 1] = fmt(pts[i][1]); p[#p + 1] = fmt(pts[i][2])
    end
    return table.concat(p, " ")
end

function icons.zoom(x, y, s, op, plus)          -- magnifier with + or -
    local fg = opts.foreground_color
    local r = 0.30 * s
    local ox, oy = x - 0.09 * s, y - 0.09 * s
    shape(arc_path(ox, oy, r, 0.09 * s, 0, 2 * math.pi, 28), fg, op)
    shape(line_path(ox + r * 0.75, oy + r * 0.75, x + 0.47 * s, y + 0.47 * s, 0.13 * s), fg, op)
    local t, l = 0.08 * s, 0.30 * s
    shape(rrect_path(ox - l / 2, oy - t / 2, l, t, t / 2), fg, op)
    if plus then shape(rrect_path(ox - t / 2, oy - l / 2, t, l, t / 2), fg, op) end
end

function icons.power(x, y, s, op)               -- quit
    local fg = opts.foreground_color
    shape(arc_path(x, y + 0.05 * s, 0.36 * s, 0.10 * s,
                   -math.pi / 2 + 0.62, 3 * math.pi / 2 - 0.62, 26), fg, op)
    shape(rrect_path(x - 0.05 * s, y - 0.48 * s, 0.10 * s, 0.46 * s, 0.05 * s), fg, op)
end

---------------------------------------------------------------------------
-- Actions & menus
---------------------------------------------------------------------------
local HAS_UOSC = nil
local MPV_MINOR = tonumber((mp.get_property("mpv-version", "") or ""):match("%d+%.(%d+)")) or 0

local function detect_uosc()
    if opts.menu_backend == "uosc" then return true end
    if opts.menu_backend == "select" then return false end
    local dir = mp.command_native({ "expand-path", "~~/scripts/uosc" })
    return (dir and (utils.file_info(dir) or utils.file_info(dir .. ".lua"))) and true or false
end

local function open_menu(kind)
    if HAS_UOSC == nil then HAS_UOSC = detect_uosc() end
    if HAS_UOSC then
        local map = { sub = "subtitles", audio = "audio", playlist = "items",
                      chapters = "chapters", main = "menu" }
        mp.commandv("script-binding", "uosc/" .. map[kind])
        return
    end
    if MPV_MINOR >= 39 then
        local map = { sub = "select-sid", audio = "select-aid",
                      playlist = "select-playlist", chapters = "select-chapter" }
        if map[kind] then
            mp.commandv("script-binding", "select/" .. map[kind])
            return
        end
    end
    if kind == "sub" then mp.commandv("cycle", "sub")
    elseif kind == "audio" then mp.commandv("cycle", "audio")
    elseif kind == "playlist" then mp.command("show-text ${playlist} 3000")
    elseif kind == "main" then mp.osd_message("Install uosc to get the main menu", 2)
    end
end

local function open_file_dialog()
    if HAS_UOSC == nil then HAS_UOSC = detect_uosc() end
    if HAS_UOSC then
        mp.commandv("script-binding", "uosc/open-file")
        return
    end
    local home = os.getenv("HOME") or "."
    local dialogs = {
        { "zenity", "--file-selection", "--title=Open media" },
        { "kdialog", "--getopenfilename", home },
        { "yad", "--file", "--title=Open media" },
    }
    local function try(i)
        local args = dialogs[i]
        if not args then
            mp.osd_message("Install zenity or kdialog (or uosc) to open files", 3)
            return
        end
        mp.command_native_async({ name = "subprocess", args = args,
                                  capture_stdout = true, playback_only = false },
            function(_, res)
                if type(res) ~= "table" then return try(i + 1) end
                if res.error_string == "init" then return try(i + 1) end  -- not installed
                if res.status == 0 and res.stdout and res.stdout ~= "" then
                    local path = res.stdout:gsub("[\r\n]+$", ""):gsub("|$", "")
                    mp.commandv("loadfile", path, "replace")
                end
            end)
    end
    try(1)
end

local function change_volume(d) mp.commandv("add", "volume", d) end

local function zoom_percent(z) return math.floor(2 ^ (z or 0) * 100 + 0.5) end
local function zoom_label() return string.format("Zoom %d%%", zoom_percent(state.zoom)) end

local function zoom_set(z)
    z = clamp(z, opts.zoom_min, opts.zoom_max)
    if math.abs(z) < 0.001 then z = 0 end
    mp.set_property_number("video-zoom", z)
    mp.osd_message(string.format("Zoom %d%%", zoom_percent(z)), 1)
end
local function zoom_by(d) zoom_set((state.zoom or 0) + d) end
local function zoom_reset()
    mp.set_property_number("video-pan-x", 0)
    mp.set_property_number("video-pan-y", 0)
    zoom_set(0)
end
local function zoom_in() zoom_by(opts.zoom_step) end
local function zoom_out() zoom_by(-opts.zoom_step) end

local function chapter_at(t)
    local title
    for _, c in ipairs(state.chapters or {}) do
        if c.time and c.time <= t then title = c.title else break end
    end
    return title
end

local function clear_thumb()
    if state.thumb_shown then
        mp.commandv("script-message-to", "thumbfast", "clear")
        state.thumb_shown, state.thumb_key = false, nil
    end
end

---------------------------------------------------------------------------
-- Hit testing
---------------------------------------------------------------------------
local function in_box(b, x, y)
    return b ~= nil and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2
end

local function add_element(id, x1, y1, x2, y2, props)
    local e = props or {}
    e.id, e.x1, e.y1, e.x2, e.y2 = id, x1, y1, x2, y2
    state.elements[#state.elements + 1] = e
    return e
end

local function hit(x, y, field)                 -- topmost element under (x,y)
    for i = #state.elements, 1, -1 do
        local e = state.elements[i]
        if in_box(e, x, y) and (field == nil or e[field] ~= nil) then return e end
    end
end

local function button(id, x, y, box, draw, props)
    local hov = state.hover_id == id
    local pressed = state.pressed and state.pressed.id == id
    local half = box / 2
    if hov then
        shape(rrect_path(x - half, y - half, box, box, box * 0.24), opts.foreground_color,
              pressed and 0.22 or 0.13)
    end
    draw(pressed and 0.65 or (hov and 1.0 or 0.86))
    if hov and props and props.tip then
        local label = type(props.tip) == "function" and props.tip() or props.tip
        state.pending_tip = { x = x, label = label }
    end
    add_element(id, x - half, y - half, x + half, y + half, props)
end

local function tooltip(x, bottom, label, sc, w)
    local fs = 12 * sc
    local tw = utf8_len(label) * fs * 0.56 + 18 * sc
    local th = fs + 10 * sc
    x = clamp(x, tw / 2 + 4 * sc, w - tw / 2 - 4 * sc)
    shape(rrect_path(x - tw / 2, bottom - th, tw, th, 6 * sc), opts.panel_color, 0.92)
    text(x, bottom - th / 2, 5, label, fs, opts.foreground_color, 1)
    return th
end

---------------------------------------------------------------------------
-- Layout: bottom panel
---------------------------------------------------------------------------
local function draw_panel(w, h, sc)
    local FG, ACC = opts.foreground_color, opts.accent_color
    local W = math.min(opts.panel_width * sc, w - 20 * sc)
    if W < 220 * sc then return end
    local H = opts.panel_height * sc
    local px = math.floor((w - W) / 2)
    local py = math.floor(h - opts.panel_margin * sc - H)
    local r = opts.panel_radius * sc
    local compact = W < 440 * sc
    local tiny = W < 340 * sc
    state.panel = { x1 = px, y1 = py, x2 = px + W, y2 = py + H }

    -- glass body: soft shadow + translucent fill + hairline border
    shape(rrect_path(px, py + 3 * sc, W, H, r), "#000000", opts.shadow_opacity, "\\blur" .. fmt(12 * sc))
    shape(rrect_path(px, py, W, H, r), opts.panel_color, opts.panel_opacity)
    outline(rrect_path(px, py, W, H, r), opts.border_color, opts.border_opacity, 1 * sc)

    -- the panel itself: swallows clicks, right-click = main menu, wheel = volume
    add_element("panel", px, py, px + W, py + H, {
        rclick = function() open_menu("main") end,
        wheel  = function(d) change_volume(d * 5) end,
    })

    local cy = py + 33 * sc
    local cx = px + W / 2
    local jump = opts.jump_seconds

    state.pending_tip = nil
    -- the side groups are only drawn while they fit next to the centre buttons
    local centre_l = cx - 80 * sc
    local centre_r = cx + 80 * sc

    -- centre: rewind / play-pause / forward
    local bx_l, bx_r = cx - 58 * sc, cx + 58 * sc
    button("back", bx_l, cy, 34 * sc, function(op) icons.rewind(bx_l, cy, 20 * sc, op) end, {
        click  = function() mp.commandv("seek", -jump, "relative") end,
        rclick = function() mp.commandv("seek", -60, "relative") end,
        tip    = "-" .. jump .. "s",
    })
    button("play", cx, cy, 42 * sc, function(op)
        if state.pause then icons.play(cx + 2 * sc, cy, 26 * sc, op)
        else icons.pause(cx, cy, 26 * sc, op) end
    end, { click = function() mp.commandv("cycle", "pause") end })
    button("fwd", bx_r, cy, 34 * sc, function(op) icons.forward(bx_r, cy, 20 * sc, op) end, {
        click  = function() mp.commandv("seek", jump, "relative") end,
        rclick = function() mp.commandv("seek", 60, "relative") end,
        tip    = "+" .. jump .. "s",
    })

    -- left: volume, then zoom out / zoom in
    local left_end = px + 8 * sc
    local zoom_room = function(vlen) return px + (46 + vlen + 6 + 24 + 34 + 16) * sc <= centre_l end
    if not tiny then
        local vlen = compact and 60 or 86
        if opts.zoom_buttons and not zoom_room(vlen) and zoom_room(60) then vlen = 60 end
        local vfrac = clamp((state.volume or 0) / opts.volume_max, 0, 1)
        local vix = px + 26 * sc
        button("mute", vix, cy, 30 * sc, function(op)
            icons.volume(vix, cy, 17 * sc, op, vfrac, state.mute)
        end, {
            click = function() mp.commandv("cycle", "mute") end,
            wheel = function(d) change_volume(d * 5) end,
        })
        local vx1 = px + 46 * sc
        local vx2 = vx1 + vlen * sc
        local vh = 4 * sc
        local vhov = state.hover_id == "volume" or state.dragging == "volume"
        shape(rrect_path(vx1, cy - vh / 2, vx2 - vx1, vh, vh / 2), FG, 0.22)
        if vfrac > 0 then
            shape(rrect_path(vx1, cy - vh / 2, (vx2 - vx1) * vfrac, vh, vh / 2), FG,
                  state.mute and 0.35 or 0.92)
        end
        if vhov then
            local kx = vx1 + (vx2 - vx1) * vfrac
            shape(circle_path(kx, cy, 6 * sc), FG, 1)
            state.pending_tip = { x = kx, label = tostring(math.floor((state.volume or 0) + 0.5)) }
        end
        add_element("volume", vx1 - 6 * sc, cy - 12 * sc, vx2 + 6 * sc, cy + 12 * sc, {
            drag = "volume", tx1 = vx1, tx2 = vx2,
            wheel = function(d) change_volume(d * 5) end,
        })
        left_end = vx2 + 6 * sc
    end
    if opts.zoom_buttons then
        local zx1 = left_end + 24 * sc
        local zx2 = zx1 + 34 * sc
        if zx2 + 16 * sc <= centre_l then
            local zoomed = math.abs(state.zoom or 0) > 0.001
            local zprops = function(fn) return {
                click  = fn,
                rclick = zoom_reset,                       -- right click = back to 100%
                wheel  = function(d) zoom_by(d * opts.zoom_step) end,
                tip    = zoom_label,
            } end
            button("zoom_out", zx1, cy, 30 * sc, function(op)
                icons.zoom(zx1, cy, 18 * sc, op, false)
            end, zprops(zoom_out))
            button("zoom_in", zx2, cy, 30 * sc, function(op)
                icons.zoom(zx2, cy, 18 * sc, op, true)
            end, zprops(zoom_in))
            if zoomed then                                 -- small dot = "zoom is active"
                shape(circle_path((zx1 + zx2) / 2, cy + 13 * sc, 1.8 * sc), opts.accent_color, 0.9)
            end
        end
    end

    -- right (right to left): quit / fullscreen / playlist / subtitles / audio (+ speed pill)
    local right = {}
    if opts.quit_button then
        right[#right + 1] = { id = "quit", icon = function(x, op) icons.power(x, cy, 17 * sc, op) end, props = {
            click  = function() mp.commandv("quit") end,
            rclick = function() mp.commandv("quit-watch-later") end,
            tip    = "Quit",
        } }
    end
    right[#right + 1] = { id = "fs", icon = function(x, op) icons.fullscreen(x, cy, 17 * sc, op, state.fullscreen) end, props = {
        click = function() mp.commandv("cycle", "fullscreen") end,
        tip   = state.fullscreen and "Exit fullscreen" or "Fullscreen",
    } }
    right[#right + 1] = { id = "playlist", icon = function(x, op) icons.playlist(x, cy, 18 * sc, op) end, props = {
        click  = function() open_menu("playlist") end,
        rclick = function() open_menu("chapters") end,
        tip    = "Playlist",
    } }
    right[#right + 1] = { id = "sub", icon = function(x, op) icons.subtitles(x, cy, 19 * sc, op) end, props = {
        click  = function() open_menu("sub") end,
        rclick = function() mp.commandv("cycle", "sub-visibility") end,
        tip    = "Subtitles",
    } }
    right[#right + 1] = { id = "audio", icon = function(x, op) icons.audio(x, cy, 17 * sc, op) end, props = {
        click  = function() open_menu("audio") end,
        rclick = function() mp.commandv("cycle", "audio") end,
        tip    = "Audio",
    } }

    local bxr = px + W - 26 * sc
    local min_x = centre_r
    local last_x
    for _, b in ipairs(right) do
        if bxr - 16 * sc < min_x then break end
        local x = bxr
        button(b.id, x, cy, 32 * sc, function(op) b.icon(x, op) end, b.props)
        last_x = x
        bxr = bxr - 34 * sc
    end
    if last_x and math.abs((state.speed or 1) - 1) > 0.001 then
        local pw = 40 * sc
        local sx = last_x - 26 * sc - pw / 2
        if sx - pw / 2 >= min_x then
            local hov = state.hover_id == "speed"
            shape(rrect_path(sx - pw / 2, cy - 10 * sc, pw, 20 * sc, 10 * sc), FG, hov and 0.26 or 0.14)
            text(sx, cy, 5, string.format("%g×", state.speed), 12 * sc, FG, 0.95)
            add_element("speed", sx - pw / 2, cy - 12 * sc, sx + pw / 2, cy + 12 * sc, {
                click = function() mp.set_property_number("speed", 1) end,
                wheel = function(d) mp.commandv("add", "speed", d * 0.25) end,
            })
        end
    end

    -- bottom row: time | seekbar | remaining
    local ty = py + H - 24 * sc
    local dur = state.duration or 0
    local pos = state.time or 0
    local long = dur >= 3600
    local tw = (long and 58 or 40) * sc
    local fs = opts.time_font_size * sc
    text(px + 16 * sc, ty, 4, fmt_time(pos, long), fs, FG, 0.9)
    local right_label = state.show_remaining and ("-" .. fmt_time(math.max(0, dur - pos), long))
                        or fmt_time(dur, long)
    text(px + W - 16 * sc, ty, 6, right_label, fs, FG, 0.9)
    add_element("time_right", px + W - 20 * sc - tw, ty - 10 * sc, px + W - 6 * sc, ty + 10 * sc, {
        click = function() state.show_remaining = not state.show_remaining; request_render() end,
    })

    local sx1 = px + 16 * sc + tw + 10 * sc
    local sx2 = px + W - 16 * sc - tw - 10 * sc
    local sw = sx2 - sx1
    local shov = state.hover_id == "seekbar" or state.dragging == "seek"
    local bh = (shov and 6 or 4) * sc
    local frac = dur > 0 and clamp(pos / dur, 0, 1) or 0

    shape(rrect_path(sx1, ty - bh / 2, sw, bh, bh / 2), FG, 0.22)
    -- buffered ranges (streams / network files)
    local ranges = type(state.cache) == "table" and state.cache["seekable-ranges"] or nil
    if dur > 0 and type(ranges) == "table" then
        for _, rg in ipairs(ranges) do
            local a = clamp((rg["start"] or 0) / dur, 0, 1)
            local b = clamp((rg["end"] or 0) / dur, 0, 1)
            if b > a then shape(rrect_path(sx1 + sw * a, ty - bh / 2, sw * (b - a), bh, bh / 2), FG, 0.16) end
        end
    end
    if frac > 0 then shape(rrect_path(sx1, ty - bh / 2, sw * frac, bh, bh / 2), ACC, 1) end
    -- chapter marks
    if dur > 0 then
        for _, c in ipairs(state.chapters or {}) do
            if c.time and c.time > 0 and c.time < dur then
                local cxm = sx1 + sw * c.time / dur
                shape(rrect_path(cxm - 1 * sc, ty - bh / 2, 2 * sc, bh, 0), opts.panel_color, 0.9)
            end
        end
    end
    -- IINA-style knob (thin vertical pill)
    local kx = sx1 + sw * frac
    local kh = (shov and 16 or 12) * sc
    shape(rrect_path(kx - 2 * sc, ty - kh / 2, 4 * sc, kh, 2 * sc), FG, 1, "\\blur" .. fmt(0.6 * sc))

    add_element("seekbar", sx1 - 6 * sc, ty - 12 * sc, sx2 + 6 * sc, ty + 12 * sc, {
        drag = "seek", tx1 = sx1, tx2 = sx2,
        wheel = function(d) mp.commandv("seek", d * 5, "relative") end,
    })

    -- hover preview (time, chapter, thumbnail)
    if shov and dur > 0 and state.mouse_in then
        local mx = clamp(state.mouse_x, sx1, sx2)
        local ht = (mx - sx1) / sw * dur
        shape(rrect_path(mx - 0.75 * sc, ty - 9 * sc, 1.5 * sc, 18 * sc, 0), FG, 0.55)
        local label = fmt_time(ht, long)
        local chap = chapter_at(ht)
        if chap and chap ~= "" then label = utf8_truncate(chap, 40) .. "   " .. label end
        local th = tooltip(mx, py - 8 * sc, label, sc, w)

        local tf = state.thumbfast
        if opts.thumbnails and tf.available and not tf.disabled and (tf.width or 0) > 0 then
            local tww, thh = tf.width, tf.height
            local tx = math.floor(clamp(mx - tww / 2, 8 * sc, w - tww - 8 * sc))
            local tyy = math.floor(py - 8 * sc - th - 6 * sc - thh)
            shape(rrect_path(tx - 3 * sc, tyy - 3 * sc, tww + 6 * sc, thh + 6 * sc, 6 * sc),
                  opts.panel_color, 0.92)
            local key = string.format("%.2f|%d|%d", ht, tx, tyy)
            if key ~= state.thumb_key then
                state.thumb_key = key
                mp.commandv("script-message-to", "thumbfast", "thumb", ht, tx, tyy)
                state.thumb_shown = true
            end
        end
    else
        clear_thumb()
        if state.pending_tip then
            tooltip(state.pending_tip.x, py - 8 * sc, state.pending_tip.label, sc, w)
        end
    end
end

---------------------------------------------------------------------------
-- Layout: top title bar & window buttons
---------------------------------------------------------------------------
local function window_buttons_wanted()
    local wb = opts.window_buttons
    if wb == "no" then return false end
    if wb == "windowed" then return not state.fullscreen end
    if wb == "auto" then return (not state.fullscreen) and state.border == false end
    return true                                     -- "yes" (default): always
end

local function draw_window_buttons(w, h, sc)
    -- minimal  −  □  ×  buttons in the top-right corner
    local by = 22 * sc
    local bw, bhh, gap = 30 * sc, 24 * sc, 2 * sc
    local t = math.max(1, 1.2 * sc)                -- stroke width
    local a = 9 * sc                               -- glyph size
    local x_close = w - 10 * sc - bw / 2
    local x_max   = x_close - bw - gap
    local x_min   = x_max - bw - gap
    local FG = opts.foreground_color
    local restore = state.maximized or state.fullscreen

    local function frame(x, y, side)               -- square outline without overlaps
        return table.concat({
            rrect_path(x, y, side, t, 0),
            rrect_path(x, y + side - t, side, t, 0),
            rrect_path(x, y + t, t, side - 2 * t, 0),
            rrect_path(x + side - t, y + t, t, side - 2 * t, 0),
        }, " ")
    end

    local items = {
        { id = "win_min", x = x_min, act = function()
              if state.fullscreen then mp.set_property_bool("fullscreen", false) end
              mp.set_property_bool("window-minimized", true)
          end,
          draw = function(x, op)
              shape(rrect_path(x - a / 2, by - t / 2, a, t, 0), FG, op)
          end },
        { id = "win_max", x = x_max, act = function()
              if state.fullscreen then mp.set_property_bool("fullscreen", false)
              else mp.commandv("cycle", "window-maximized") end
          end,
          draw = function(x, op)
              if restore then                       -- "restore" = two stacked squares
                  local s2 = a * 0.78
                  local o = a - s2
                  local fx, fy = x - a / 2, by - a / 2 + o
                  shape(frame(fx, fy, s2), FG, op)
                  shape(rrect_path(fx + o, by - a / 2, s2, t, 0) .. " " ..
                        rrect_path(fx + o + s2 - t, by - a / 2 + t, t, s2 - t - o, 0), FG, op)
              else
                  shape(frame(x - a / 2, by - a / 2, a), FG, op)
              end
          end },
        { id = "win_close", x = x_close, act = function() mp.commandv("quit") end,
          draw = function(x, op)
              local g = a / 2
              shape(line_path(x - g, by - g, x + g, by + g, t * 1.1), FG, op)
              shape(line_path(x - g, by + g, x + g, by - g, t * 1.1), FG, op)
          end },
    }

    for _, it in ipairs(items) do
        local hov = state.hover_id == it.id
        local pressed = state.pressed and state.pressed.id == it.id
        local x1, y1 = it.x - bw / 2, by - bhh / 2
        if hov then
            if it.id == "win_close" then
                shape(rrect_path(x1, y1, bw, bhh, 6 * sc), "#E5484D", pressed and 0.75 or 0.92)
            else
                shape(rrect_path(x1, y1, bw, bhh, 6 * sc), FG, pressed and 0.24 or 0.14)
            end
        end
        it.draw(it.x, hov and 1 or 0.85)
        add_element(it.id, x1, y1, x1 + bw, y1 + bhh, { click = it.act })
    end
    state.topbtn = { x1 = x_min - bw / 2, y1 = by - bhh / 2, x2 = x_close + bw / 2, y2 = by + bhh / 2 }
end

local function draw_topbar(w, h, sc)
    local mode = opts.title_bar
    local show_title = mode == "yes" or (mode == "auto" and (state.fullscreen or state.border == false))
    local with_buttons = window_buttons_wanted()
    if not show_title and not with_buttons then return end

    -- dark gradient so the title and the buttons stay readable on bright video
    local bh, n = (show_title and 76 or 56) * sc, 18
    for i = 0, n - 1 do
        local y1 = math.floor(bh * i / n)
        local y2 = math.floor(bh * (i + 1) / n)
        local f = 1 - i / n
        shape(rrect_path(0, y1, w, y2 - y1, 0), "#000000", (show_title and 0.55 or 0.45) * f * f)
    end

    if show_title then
        local reserve = with_buttons and 110 * sc or 24 * sc
        local max_chars = math.floor((w - 2 * reserve) / (7.5 * sc))
        local title = utf8_truncate(state.title or "", max_chars)
        text(w / 2, 22 * sc, 5, title, 14 * sc, opts.foreground_color, 0.95, "\\b1")
    end

    if with_buttons then draw_window_buttons(w, h, sc) end
end

---------------------------------------------------------------------------
-- Layout: idle screen
---------------------------------------------------------------------------
local function draw_idle(w, h, sc)
    local cx, cy = w / 2, h / 2 - 24 * sc
    local R = 46 * sc
    local hov = state.hover_id == "idle_open"
    shape(circle_path(cx, cy, R), "#FFFFFF", hov and 0.16 or 0.08)
    outline(circle_path(cx, cy, R), "#FFFFFF", 0.28, 1.5 * sc)
    icons.play(cx + 4 * sc, cy, 32 * sc, hov and 1 or 0.85)
    text(cx, cy + R + 26 * sc, 5, "Drop a video here", 18 * sc, "#FFFFFF", 0.85, "\\b1")
    text(cx, cy + R + 50 * sc, 5, "or click the button / press O to open a file", 13 * sc, "#FFFFFF", 0.5)
    state.idle_box = { x1 = cx - R, y1 = cy - R, x2 = cx + R, y2 = cy + R }
    add_element("idle_open", cx - R, cy - R, cx + R, cy + R, { click = open_file_dialog })
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local last_areas = {}
local function set_area(section, b)
    local x1, y1, x2, y2 = 0, 0, 0, 0
    if b then
        x1, y1 = math.floor(b.x1), math.floor(b.y1)
        x2, y2 = math.ceil(b.x2), math.ceil(b.y2)
    end
    local key = x1 .. "," .. y1 .. "," .. x2 .. "," .. y2
    if last_areas[section] ~= key then
        last_areas[section] = key
        mp.set_mouse_area(x1, y1, x2, y2, section)
    end
end

render = function()
    ass = {}
    state.elements = {}
    state.panel, state.topbtn, state.idle_box = nil, nil, nil
    local w, h = state.osd_w, state.osd_h
    local visible = state.alpha > 0.001

    if w > 0 and h > 0 then
        local sc = (state.fullscreen and opts.scale_fullscreen or opts.scale) * (state.hidpi or 1)
        if state.idle then
            A = 1
            draw_idle(w, h, sc)
            if window_buttons_wanted() then draw_window_buttons(w, h, sc) end
        elseif visible then
            A = state.alpha
            draw_topbar(w, h, sc)
            draw_panel(w, h, sc)
        end
    end

    if state.dragging then
        set_area("iina_panel", { x1 = 0, y1 = 0, x2 = w, y2 = h })
    elseif state.idle then
        set_area("iina_panel", state.idle_box)
    else
        set_area("iina_panel", visible and state.panel or nil)
    end
    set_area("iina_top", (visible or state.idle) and state.topbtn or nil)
    if state.idle or not visible then clear_thumb() end

    overlay.res_x = math.max(w, 1)
    overlay.res_y = math.max(h, 1)
    overlay.data = table.concat(ass, "\n")
    overlay:update()
end

local render_pending = false
request_render = function()
    if render_pending then return end
    render_pending = true
    mp.add_timeout(0.016, function()
        render_pending = false
        render()
    end)
end

---------------------------------------------------------------------------
-- Show / hide with fade
---------------------------------------------------------------------------
local anim_timer
local function anim_step()
    local d = opts.fade_duration / 1000
    local step = d > 0 and (1 / 60) / d or 1
    if state.alpha < state.target then
        state.alpha = math.min(state.target, state.alpha + step)
    else
        state.alpha = math.max(state.target, state.alpha - step)
    end
    render()
    if state.alpha == state.target then anim_timer:kill() end
end
anim_timer = mp.add_periodic_timer(1 / 60, anim_step)
anim_timer:kill()

local function set_target(t)
    state.target = t
    if state.alpha ~= t and not anim_timer:is_enabled() then anim_timer:resume() end
end

show = function()
    state.last_activity = now()
    if not state.visible then
        state.visible = true
        set_target(1)
    end
end

hide = function()
    if state.visible then
        state.visible = false
        set_target(0)
    end
end

mp.add_periodic_timer(0.1, function()
    if not state.visible or state.idle or state.pinned or state.dragging then return end
    if opts.keep_on_pause and state.pause then return end
    if state.mouse_in and (in_box(state.panel, state.mouse_x, state.mouse_y) or
                           in_box(state.topbtn, state.mouse_x, state.mouse_y)) then
        state.last_activity = now()
        return
    end
    local timeout = state.mouse_left and 0.4 or opts.hide_timeout / 1000
    if now() - state.last_activity > timeout then hide() end
end)

---------------------------------------------------------------------------
-- Mouse input
---------------------------------------------------------------------------
local function drag_update()
    local e = state.drag_el
    if not e then return end
    local frac = clamp((state.mouse_x - e.tx1) / math.max(1, e.tx2 - e.tx1), 0, 1)
    if state.dragging == "seek" then
        local dur = state.duration or 0
        if dur > 0 then
            local t = frac * dur
            if not state.last_seek or math.abs(t - state.last_seek) > 0.05 then
                state.last_seek = t
                mp.commandv("seek", t, "absolute+keyframes")
            end
        end
    elseif state.dragging == "volume" then
        mp.set_property_number("volume", math.floor(frac * opts.volume_max + 0.5))
        if state.mute then mp.set_property_bool("mute", false) end
    end
end

local function on_left_down()
    local e = hit(state.mouse_x, state.mouse_y)
    state.pressed = e
    if e and e.drag then
        state.dragging, state.drag_el, state.last_seek = e.drag, e, nil
        drag_update()
    end
    show()
    request_render()
end

local function on_left_up()
    if state.dragging then
        if state.dragging == "seek" and state.last_seek and opts.exact_seek_on_release then
            mp.commandv("seek", state.last_seek, "absolute+exact")
        end
        state.dragging, state.drag_el = nil, nil
    else
        local e = hit(state.mouse_x, state.mouse_y)
        if e and state.pressed and e.id == state.pressed.id and e.click then e.click() end
    end
    state.pressed = nil
    show()
    request_render()
end

local function on_right()
    local e = hit(state.mouse_x, state.mouse_y, "rclick")
    if e then e.rclick() end
end

local function on_wheel(d)
    local e = hit(state.mouse_x, state.mouse_y, "wheel")
    if e then e.wheel(d) end
    show()
end

local function setup_input(section)
    mp.set_key_bindings({
        { "mbtn_left",     on_left_up, on_left_down },
        { "mbtn_left_dbl", function() end },
        { "mbtn_right",    on_right },
        { "wheel_up",      function() on_wheel(1) end },
        { "wheel_down",    function() on_wheel(-1) end },
    }, section, "force")
    mp.enable_key_bindings(section)
    mp.set_mouse_area(0, 0, 0, 0, section)
    last_areas[section] = "0,0,0,0"
end
setup_input("iina_panel")
setup_input("iina_top")

mp.observe_property("mouse-pos", "native", function(_, m)
    if type(m) ~= "table" or m.x == nil then return end
    local moved = math.abs(m.x - state.mouse_x) + math.abs(m.y - state.mouse_y)
    local was_in = state.mouse_in
    state.mouse_x, state.mouse_y = m.x, m.y
    state.mouse_in = m.hover and true or false
    if was_in and not state.mouse_in then state.mouse_left = true end
    if state.mouse_in then state.mouse_left = false end

    if state.dragging then drag_update() end
    if state.mouse_in and moved >= opts.min_mouse_move then show() end

    local e = state.mouse_in and hit(m.x, m.y) or nil
    state.hover_id = e and e.id or nil
    if state.alpha > 0 or state.idle then request_render() end
end)

---------------------------------------------------------------------------
-- Property observers
---------------------------------------------------------------------------
local function prop(name, kind, key, on_change)
    mp.observe_property(name, kind, function(_, v)
        state[key] = v
        if on_change then on_change(v) end
        if state.alpha > 0 or state.idle or key == "idle" then request_render() end
    end)
end

prop("pause", "bool", "pause", function() show() end)
prop("time-pos", "number", "time")
prop("duration", "number", "duration")
prop("volume", "number", "volume")
prop("mute", "bool", "mute")
prop("speed", "number", "speed")
prop("video-zoom", "number", "zoom")
prop("fullscreen", "bool", "fullscreen")
prop("window-maximized", "bool", "maximized")
prop("border", "bool", "border")
prop("idle-active", "bool", "idle")
prop("media-title", "string", "title")
prop("chapter-list", "native", "chapters")
prop("demuxer-cache-state", "native", "cache")
prop("display-hidpi-scale", "number", "hidpi")

mp.observe_property("osd-dimensions", "native", function(_, d)
    if type(d) == "table" then state.osd_w, state.osd_h = d.w or 0, d.h or 0 end
    request_render()
end)

mp.register_event("file-loaded", function() if opts.show_on_start then show() end end)

mp.add_timeout(1, function()
    msg.verbose(string.format("window_buttons=%s border=%s fullscreen=%s -> buttons %s",
        tostring(opts.window_buttons), tostring(state.border), tostring(state.fullscreen),
        window_buttons_wanted() and "shown" or "hidden"))
end)
mp.register_event("seek", function() if opts.show_on_seek and not state.dragging then show() end end)

mp.register_script_message("thumbfast-info", function(json)
    local data = utils.parse_json(json)
    if type(data) == "table" then state.thumbfast = data end
end)

---------------------------------------------------------------------------
-- Script bindings (use in input.conf as  KEY script-binding iina_osc/<name>)
---------------------------------------------------------------------------
mp.add_key_binding(nil, "toggle", function()
    state.pinned = not state.pinned
    if state.pinned then show() else state.last_activity = now() end
    mp.osd_message(state.pinned and "Controls: always visible" or "Controls: auto-hide", 1)
end)
mp.add_key_binding(nil, "peek", function() show() end)
mp.add_key_binding(nil, "open-file", open_file_dialog)
mp.add_key_binding(nil, "menu", function() open_menu("main") end)
mp.add_key_binding(nil, "zoom-in", zoom_in, { repeatable = true })
mp.add_key_binding(nil, "zoom-out", zoom_out, { repeatable = true })
mp.add_key_binding(nil, "zoom-reset", zoom_reset)
mp.add_key_binding(nil, "quit", function() mp.commandv("quit") end)

request_render()
