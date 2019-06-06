-- Drummer
-- 1.0.0 @markeats
-- llllllll.co/t/drummer
--
-- Description.
--
-- E1 : Sound
--

-- Mapping based on General MIDI Percussion Key Map
-- https://www.midi.org/specifications-old/item/gm-level-1-sound-set

local ControlSpec = require "controlspec"
local Formatters = require "formatters"
local MusicUtil = require "musicutil"
local UI = require "ui"

engine.name = "Timber"

local SCREEN_FRAMERATE = 15
local screen_dirty = true

local midi_in_device

local NUM_SAMPLES = 46

local DRUM_ANI_TIMEOUT = 0.2

local GlobalView = {}
local SampleView = {}

local pages
local global_view
local sample_view

local current_kit_id = 1
local current_sample_id = 0
local set_kit

local samples_meta = {}
for i = 0, NUM_SAMPLES - 1 do
  samples_meta[i] = {
    ready = false,
    length = 0
  }
end

local kits = {}

local specs = {}
specs.UNIPOLAR_DEFAULT_MAX = ControlSpec.new(0, 1, "lin", 0, 1, "")
specs.FILTER_FREQ = ControlSpec.new(20, 20000, "exp", 0, 20000, "Hz")
specs.TUNE = ControlSpec.new(-12, 12, "lin", 0.5, 0, "ST")
specs.AMP = ControlSpec.new(-48, 16, "db", 0, 0, "dB")


local function add_global_params()
  
  local kit_names = {}
  for _, v in ipairs(kits) do table.insert(kit_names, v.name) end
  params:add{type = "option", id = "kit", name = "Kit", options = kit_names, default = current_kit_id, action = function(value)
    current_kit_id = value
    set_kit(value)
    screen_dirty = true
  end}
  
  --TODO keep settings across kit swaps
  
  params:add{type = "number", id = "midi_in_device", name = "MIDI In Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  local channels = {"All"}
  for i = 1, 16 do table.insert(channels, i) end
  params:add{type = "option", id = "midi_in_channel", name = "MIDI In Channel", options = channels}
  
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = {"Off", "On"}, default = 1}
  
  params:add_separator()
  
  params:add{type = "control", id = "filter_cutoff", name = "Filter Cutoff", controlspec = specs.FILTER_FREQ, formatter = Formatters.format_freq, action = function(value)
    for k, v in ipairs(kits[current_kit_id].samples) do
      engine.filterFreq(k, value)
    end
    screen_dirty = true
  end}
  
  params:add{type = "option", id = "quality", name = "Quality", options = {"Low", "High"}, default = 2, action = function(value)
    local downSampleTo = 48000
    local bitDepth = 24
    if value == 1 then
      downSampleTo = 16000
      bitDepth = 8
    end
    for k, v in ipairs(kits[current_kit_id].samples) do
      engine.downSampleTo(k, downSampleTo)
      engine.bitDepth(k, bitDepth)
    end
    screen_dirty = true
  end}
  
  params:add_separator()
  
end

local function load_kits()
  local search_path = _path.code .. "drummer/kits/"
  for _, v in ipairs(util.scandir(search_path)) do
    local kit_path = search_path .. v .. "kit.lua"
    if util.file_exists(kit_path) then
      table.insert(kits, include("drummer/kits/" .. v .. "kit"))
    end
  end
end

function set_kit(id)
  if #kits > 0 then
    if kits[id].samples then
      
      params:clear()
      add_global_params()
      
      for k, v in ipairs(kits[id].samples) do
        
        local sample_id = k - 1
        
        engine.loadSample(sample_id, _path.dust .. v.file)
        
        local file = string.sub(v.file, string.find(v.file, "/[^/]*$") + 1, string.find(v.file, ".[^.]*$") - 1)
        local name_prefix = string.sub(file, 1, 7)
        
        -- Add params
        
        params:add{type = "control", id = "tune_" .. sample_id, name = name_prefix .. " Tune", controlspec = specs.TUNE, formatter = Formatters.round(0.1), action = function(value)
          engine.originalFreq(sample_id, MusicUtil.note_num_to_freq(60 - value))
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "decay_" .. sample_id, name = name_prefix .. " Decay", controlspec = specs.UNIPOLAR_DEFAULT_MAX, formatter = Formatters.unipolar_as_percentage, action = function(value)
          engine.ampDecay(sample_id, util.linlin(0, 0.9, 0.01, math.min(5, samples_meta[sample_id].length), value))
          engine.ampSustain(sample_id, util.linlin(0.9, 1, 0, 1, value))
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "pan_" .. sample_id, name = name_prefix .. " Pan", controlspec = ControlSpec.PAN, formatter = Formatters.bipolar_as_pan_widget, action = function(value)
          engine.pan(sample_id, value)
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "amp_" .. sample_id, name = name_prefix .. " Amp", controlspec = specs.AMP, action = function(value)
          engine.amp(sample_id, value)
          screen_dirty = true
        end}
        
        params:add_separator()
        
        sample_view = SampleView.new()
      end
      
      pages = UI.Pages.new(1, #kits[current_kit_id].samples + 1)
      screen_dirty = true
      
    end
  end
end

local function clear_kit()
  current_sample_id = 0
  engine.clearSamples(0, NUM_SAMPLES - 1)
  for i = 0, NUM_SAMPLES - 1 do
    samples_meta[i].ready = false
    samples_meta[i].length = 0
  end
end

local function sample_loaded(id, streaming, num_frames, num_channels, sample_rate)
  samples_meta[id].ready = true
  samples_meta[id].length = num_frames / sample_rate
  
  -- Set sample defaults
  
  engine.playMode(id, 3)
  engine.ampAttack(id, 0)
  engine.filterFreq(id, 24000)
  
  screen_dirty = false
end

local function sample_load_failed(id, error_status)
  samples_meta[id].ready = false
  samples_meta[id].length = 0
  print("Sample load failed", error_status)
  screen_dirty = true
end

local function set_sample_id(id)
   current_sample_id = util.clamp(id, 0, NUM_SAMPLES - 1)
end

local function note_on(voice_id, sample_id, vel)
  
  if samples_meta[sample_id].ready then
    vel = vel or 1
    -- print("note_on", voice_id, sample_id, vel)
    engine.noteOn(voice_id, sample_id, MusicUtil.note_num_to_freq(60), vel)
    
    if voice_id == 35 or voice_id == 36 then
      global_view.timeouts.bd = DRUM_ANI_TIMEOUT
    elseif voice_id == 38 or voice_id == 40 then
      global_view.timeouts.sd = DRUM_ANI_TIMEOUT
    elseif voice_id == 39 then
      global_view.timeouts.cp = DRUM_ANI_TIMEOUT
    elseif voice_id == 42 or voice_id == 44 then
      global_view.timeouts.ch = DRUM_ANI_TIMEOUT
    elseif voice_id == 46 then
      global_view.timeouts.oh = DRUM_ANI_TIMEOUT
    elseif voice_id == 49 or voice_id == 51 or voice_id == 55 or voice_id == 57 or voice_id == 59 then
      global_view.timeouts.cy = DRUM_ANI_TIMEOUT
    elseif voice_id == 41 or voice_id == 43 or voice_id == 45 then
      global_view.timeouts.lt = DRUM_ANI_TIMEOUT
    elseif voice_id == 47 or voice_id == 48 then
      global_view.timeouts.mt = DRUM_ANI_TIMEOUT
    elseif voice_id == 50 then
      global_view.timeouts.ht = DRUM_ANI_TIMEOUT
    elseif voice_id == 56 then
      global_view.timeouts.cb = DRUM_ANI_TIMEOUT
    end
    
    screen_dirty = true
  end
end

local function set_pitch_bend_voice(voice_id, bend_st)
  engine.pitchBendVoice(voice_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_sample(sample_id, bend_st)
  engine.pitchBendSample(sample_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_all(bend_st)
  engine.pitchBendAll(MusicUtil.interval_to_ratio(bend_st))
end


-- Encoder input
function enc(n, delta)
  
  -- Global
  if n == 1 then
    pages:set_index_delta(delta, false)
    if pages.index > 1 then
      set_sample_id(pages.index - 2)
    end
  
  else
    
    if pages.index == 1 then
      global_view:enc(n, delta)
    else
      sample_view:enc(n, delta)
    end
    
  end
  screen_dirty = true
end

-- Key input
function key(n, z)
  
  if pages.index == 1 then
    global_view:key(n, z)
  else
    sample_view:key(n, z)
  end
  
  screen_dirty = true
end

-- OSC events
local function osc_event(path, args, from)
  
  if path == "/engineSampleLoaded" then
    sample_loaded(args[1], args[2], args[3], args[4], args[5])
    
  elseif path == "/engineSampleLoadFailed" then
    sample_load_failed(args[1], args[2])
    
  end
end

-- MIDI input
local function midi_event(device_id, data)
  
  local msg = midi.to_msg(data)
  local channel_param = params:get("midi_in_channel")
  
  -- MIDI In
  if device_id == params:get("midi_in_device") then
    if channel_param == 1 or (channel_param > 1 and msg.ch == channel_param - 1) then
      
      -- Note on
      if msg.type == "note_on" then
        
        local sample_id
        for k, v in ipairs(kits[current_kit_id].samples) do
          if v.note == msg.note then
            sample_id = k - 1
            break
          end
        end
        
        if sample_id then
          note_on(msg.note, sample_id, msg.vel / 127)
          
          if params:get("follow") > 1 then
            set_sample_id(sample_id)
          end
        end
      
      -- Pitch bend
      elseif msg.type == "pitchbend" then
        local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
        local bend_range = params:get("bend_range")
        set_pitch_bend_all(bend_st * bend_range)
        
      end
    end
  end
  
end

local function reconnect_midi_ins()
  midi_in_device.event = nil
  midi_in_device = midi.connect(params:get("midi_in_device"))
  midi_in_device.event = function(data) midi_event(params:get("midi_in_device"), data) end
end


local function update()
  global_view:update()
end


-- Views

GlobalView.__index = GlobalView

function GlobalView.new()
  local global = {
    timeouts = {
      bd = 0,
      sd = 0,
      cp = 0,
      ch = 0,
      oh = 0,
      cy = 0,
      lt = 0,
      mt = 0,
      ht = 0,
      cb = 0
    }
  }
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:enc(n, delta)
  if n == 2 then
    params:delta("filter_cutoff", delta)
    
  elseif n == 3 then
    params:delta("quality", delta)
    
  end
  screen_dirty = true
end

function GlobalView:key(n, z)
  if z == 1 then
    if n == 2 then
      
      if #kits > 0 then
        current_kit_id = current_kit_id % #kits + 1
        clear_kit()
        set_kit(current_kit_id)
      end
      
    elseif n == 3 then
      -- TODO
      -- note_on(kits[current_kit_id].samples[1].note, 1, 1)
      
    end
    screen_dirty = true
  end
end

function GlobalView:update()
  
  for k, v in pairs(self.timeouts) do
    self.timeouts[k] = math.max(v - 1 / SCREEN_FRAMERATE, 0)
  end
  
  screen_dirty = true
end

function GlobalView:redraw()
  
  -- Draw drum kit
  
  -- local scale = util.explin(specs.FILTER_FREQ.minval, specs.FILTER_FREQ.maxval, 0.65, 1, params:get("filter_cutoff")) --TODO
  local cx, cy = 63, 40
  
  -- screen.line_width(0.75)
  
  local nod = 0
  if self.timeouts.bd > 0 or self.timeouts.sd > 0 then nod = 1 end
  
  -- Hair
  screen.level(3)
  -- screen.circle(cx, cy - 16, 3.5)
  screen.move(cx - 4.5, cy - 11)
  screen.line(cx - 4.5, cy - 16 + nod * 0.5)
  screen.arc(cx, cy - 16 + nod * 0.5, 4.5, math.pi, math.pi * 2)
  screen.line(cx + 4.5, cy - 11)
  screen.stroke()
  
  -- Bangs
  screen.move(cx - 3, cy - 15.5 + nod)
  screen.line(cx + 3, cy - 15.5 + nod)
  screen.stroke()
  -- Cheeks
  screen.move(cx + 1.5, cy - 13 + nod)
  screen.line(cx + 1.5, cy - 15.5 + nod)
  screen.stroke()
  screen.move(cx - 1.5, cy - 13 + nod)
  screen.line(cx - 1.5, cy - 15.5 + nod)
  screen.stroke()
  -- Jaw
  screen.arc(cx, cy - 14 + nod, 2, math.pi * 2, math.pi)
  screen.stroke()
  
  -- Shoulders
  -- screen.arc(cx - 3, cy - 6, 3.5, math.pi, math.pi * 1.5)
  -- screen.arc(cx + 3, cy - 6, 3.5, math.pi * 1.5, math.pi * 2)
  -- screen.move(cx - 7.5, cy - 9.5)
  -- screen.line(cx + 7.5, cy - 9.5)
  -- screen.stroke()
  -- Arm
  -- screen.move(cx + 4, cy - 8.5)
  -- screen.line(cx + 15.5, cy - 2)
  -- screen.stroke()
  
  -- CP
  if self.timeouts.cp > 0 then
    screen.level(15)
    screen.move(cx, cy - 10)
    screen.line(cx + 6, cy - 16)
    screen.stroke()
    screen.move(cx + 5, cy - 10)
    screen.line(cx + 9, cy - 16)
    screen.stroke()
  end
  
  -- BD
  if self.timeouts.bd > 0 then screen.level(15) else screen.level(3) end
  screen.circle(cx, cy + 9, 10.5)
  screen.stroke()
  
  -- SD
  if self.timeouts.sd > 0 then screen.level(15) else screen.level(3) end
  screen.move(cx + 11, cy + 0.5)
  screen.line(cx + 22.5, cy + 0.5)
  screen.line(cx + 22.5, cy + 5.5)
  screen.line(cx + 13, cy + 5.5)
  screen.stroke()
  -- Stand
  screen.move(cx + 16.5, cy + 5.5)
  screen.line(cx + 16.5, cy + 14)
  screen.line(cx + 20.5, cy + 19)
  screen.stroke()
  screen.move(cx + 16.5, cy + 14)
  screen.line(cx + 12.5, cy + 19)
  screen.stroke()
  
  -- HH
  if self.timeouts.ch > 0 or self.timeouts.oh > 0 then screen.level(15) else screen.level(3) end
  local mod_y_l, mod_y_r = 0, 0
  if self.timeouts.oh > 0 then
    mod_y_l = math.random(-2, -1)
    mod_y_r = math.random(-2, -1)
  end
  screen.move(cx + 19, cy - 5.5 + mod_y_l)
  screen.line(cx + 32, cy - 5.5 + mod_y_r)
  screen.stroke()
  screen.move(cx + 19, cy - 3.5)
  screen.line(cx + 32, cy - 3.5)
  screen.stroke()
  -- Stand
  screen.move(cx + 25.5, cy - 3.5)
  screen.line(cx + 25.5, cy + 14)
  screen.line(cx + 29.5, cy + 19)
  screen.stroke()
  screen.move(cx + 25.5, cy + 14)
  screen.line(cx + 21.5, cy + 19)
  screen.stroke()
  
  -- LT
  if self.timeouts.lt > 0 then screen.level(15) else screen.level(3) end
  screen.move(cx - 13, cy + 2.5)
  screen.line(cx - 19.5, cy + 2.5)
  screen.line(cx - 19.5, cy + 15.5)
  screen.line(cx - 12, cy + 15.5)
  screen.stroke()
  -- Feet
  screen.move(cx - 19.5, cy + 16)
  screen.line(cx - 19.5, cy + 19)
  screen.stroke()
  screen.move(cx - 13.5, cy + 16)
  screen.line(cx - 13.5, cy + 19)
  screen.stroke()
  
  -- MT
  if self.timeouts.mt > 0 then screen.level(15) else screen.level(3) end
  screen.move(cx - 8, cy - 0.5)
  screen.line(cx - 12.5, cy - 0.5)
  screen.line(cx - 12.5, cy - 7.5)
  screen.line(cx - 2.5, cy - 7.5)
  screen.line(cx - 2.5, cy - 4)
  screen.stroke()
  
  -- HT
  if self.timeouts.ht > 0 then screen.level(15) else screen.level(3) end
  screen.move(cx + 7, cy - 1.5)
  screen.line(cx + 12.5, cy - 1.5)
  screen.line(cx + 12.5, cy - 7.5)
  screen.line(cx + 2.5, cy - 7.5)
  screen.line(cx + 2.5, cy - 4)
  screen.stroke()
  
  -- CY
  if self.timeouts.cy > 0 then screen.level(15) else screen.level(3) end
  screen.move(cx - 17, cy - 14)
  screen.line(cx - 30, cy - 20)
  screen.stroke()
  -- Stand
  screen.move(cx - 23.5, cy - 16.5)
  screen.line(cx - 23.5, cy + 14)
  screen.line(cx - 27.5, cy + 19)
  screen.stroke()
  screen.move(cx - 23.5, cy + 14)
  screen.line(cx - 19.5, cy + 19)
  screen.stroke()
  
  -- CB
  if self.timeouts.cb > 0 then
    screen.level(15)
    screen.move(cx + 27, cy - 13)
    screen.text("Donk!")
    screen.fill()
  end
  
  -- screen.line_width(1)
  
  -- Title
  screen.level(15)
  -- screen.move(63, 60)
  screen.move(63, 9)
  screen.text_center(kits[current_kit_id].name)
  screen.fill()
  
end


SampleView.__index = SampleView

function SampleView.new()
  
  local tune_dial = UI.Dial.new(4.5, 19, 22, 0, -12, 12, 0.1, 0, {0}, "ST")
  local decay_dial = UI.Dial.new(36, 32, 22, params:get("decay_" .. current_sample_id) * 100, 0, 100, 1, 0, nil, "%", "Decay")
  local pan_dial = UI.Dial.new(67.5, 19, 22, params:get("pan_" .. current_sample_id) * 100, -100, 100, 1, 0, {0}, nil, "Pan")
  local amp_dial = UI.Dial.new(99, 32, 22, params:get("amp_" .. current_sample_id), specs.AMP.minval, specs.AMP.maxval, 0.1, nil, {0}, "dB")
  
  pan_dial.active = false
  amp_dial.active = false
  
  local sample_view = {
    tab_id = 1,
    tune_dial = tune_dial,
    decay_dial = decay_dial,
    pan_dial = pan_dial,
    amp_dial = amp_dial
  }
  setmetatable(SampleView, {__index = SampleView})
  setmetatable(sample_view, SampleView)
  return sample_view
end

function SampleView:enc(n, delta)
  
  if n == 2 then
    if self.tab_id == 1 then
      params:delta("tune_" .. current_sample_id, delta)
    else
      params:delta("pan_" .. current_sample_id, delta)
    end
    
  elseif n == 3 then
    if self.tab_id == 1 then
      params:delta("decay_" .. current_sample_id, delta * 2)
    else
      params:delta("amp_" .. current_sample_id, delta * 2)
    end
    
    
  end
  screen_dirty = true
end

function SampleView:key(n, z)
  if z == 1 then
    if n == 2 then
      self.tab_id = self.tab_id % 2 + 1
      self.tune_dial.active = self.tab_id == 1
      self.decay_dial.active = self.tab_id == 1
      self.pan_dial.active = self.tab_id == 2
      self.amp_dial.active = self.tab_id == 2
      
    elseif n == 3 then
      note_on(kits[current_kit_id].samples[current_sample_id + 1].note, current_sample_id, 1)
      
    end
    screen_dirty = true
  end
end

function SampleView:redraw()
  
  screen.level(3)
  screen.move(4, 9)
  screen.text(MusicUtil.note_num_to_name(kits[current_kit_id].samples[current_sample_id + 1].note, true))
  
  local title = kits[current_kit_id].samples[current_sample_id + 1].file
  title = string.sub(title, string.find(title, "/[^/]*$") + 1, string.find(title, ".[^.]*$") - 1)
  if string.len(title) > 19 then
    title = string.sub(title, 1, 16) .. "..."
  end
  
  screen.level(15)
  screen.move(63, 9)
  screen.text_center(title)
  
  screen.fill()
  
  self.tune_dial:set_value(params:get("tune_" .. current_sample_id))
  self.decay_dial:set_value(params:get("decay_" .. current_sample_id) * 100)
  self.pan_dial:set_value(params:get("pan_" .. current_sample_id) * 100)
  self.amp_dial:set_value(params:get("amp_" .. current_sample_id))
  
  self.tune_dial:redraw()
  self.decay_dial:redraw()
  self.pan_dial:redraw()
  self.amp_dial:redraw()
  
  if params:get("amp_" .. current_sample_id) > 2 then
    screen.level(15)
    screen.move(110, 46)
    screen.text_center("!")
    screen.fill()
  end
  
end


-- Drawing functions

local function draw_background_rects()
  -- 4px edge margins. 8px gutter.
  screen.level(1)
  screen.rect(4, 22, 56, 38)
  screen.rect(68, 22, 56, 38)
  screen.fill()
end

function redraw()
  
  screen.clear()
  
  -- draw_background_rects()
  
  if #kits == 0 then
    screen.level(15)
    screen.move(64, 30)
    screen.text_center("No kits found in")
    screen.move(64, 41)
    screen.level(3)
    screen.text_center("code/drummer/kits/")
    screen.fill()
    screen.update()
    return
  end
  
  pages:redraw()
  
  if pages.index == 1 then
    global_view:redraw()
  else
    sample_view:redraw()
  end
  
  screen.update()
end


function init()
  
  osc.event = osc_event
  
  midi_in_device = midi.connect(1)
  midi_in_device.event = function(data) midi_event(1, data) end
  
  -- UI
  global_view = GlobalView.new()
  
  screen.aa(1)
  
  local screen_redraw_metro = metro.init()
  screen_redraw_metro.event = function()
    update()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  
  screen_redraw_metro:start(1 / SCREEN_FRAMERATE)
  
  
  engine.generateWaveforms(0)
  
  load_kits()
  set_kit(1)
  
end
