--[[
  Soundmole - Audio Sample Explorer and Manager
  New implementation interacting with JS_ReaAPI and ReaImGui
]]

-- Initialization and dependencies
local reaper = reaper
local js = reaper.JS_Window_Find or error("This script requires JS_ReaAPI.")

local function normalize_path(path)
  if not path then return "" end
  local sep = package.config:sub(1, 1)
  path = path:gsub("[/\\]+", sep)
  -- Remove trailing separator for files
  if path:sub(-1) == sep then path = path:sub(1, -2) end
  return path
end

-- Load external utility libraries inline or via ReaPack
local json = require("json") -- Include JSON parsing library (or implement yours)
local ImGui = require("ImGui") -- Assume ReaImGui binding loaded
local JsApi = require("Jsapi") -- Js_ReaAPI bindings (assumed accessible)

-- Configuration Variables
local CACHE_DIR = normalize_path(reaper.GetResourcePath() .. "/Soundmole_cache/")
local WAVEFORM_CACHE_DIR = normalize_path(CACHE_DIR .. "waveforms/")
local UCS_DATA_PATH = normalize_path(reaper.GetResourcePath() .. "/Soundmole_ucs/ucs.csv")
local AUDIO_EXTENSIONS = {wav=true,music= true,mp3=true,flac=true,ogg=true,m4a=true}

-- Media Database and Cache tables
local media_db = {}
local waveform_cache = {}

-- OAuth and Freesound API Access Tokens and Helpers
local oauth_access_token = reaper.GetExtState("Soundmole", "oauth_access_token") or ""
local oauth_refresh_token = reaper.GetExtState("Soundmole", "oauth_refresh_token") or ""

-- Internal State variables
local playing_preview = nil
local playing_source = nil
local is_paused = false
local selected_row = 0
local ui_is_running = true
local main_context = ImGui.CreateContext('Soundmole')

-- Utility function to check if a file exists
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Utility function: scan directory recursively for audio files
local function scan_directory(dir_path)
  local results = {}
  local files = {}
  local folders = {dir_path}
  local sep = package.config:sub(1,1)
  while #folders > 0 do
    local folder = table.remove(folders)
    local i = 0
    while true do
      local file = reaper.EnumerateFiles(folder, i)
      if not file then break end
      local fpath = normalize_path(folder .. sep .. file)
      local ext = file:match("^.+%.(.+)$")
      if ext and AUDIO_EXTENSIONS[ext:lower()] then
        table.insert(results, fpath)
      end
      i = i + 1
    end
    i=0
    while true do
      local subdir = reaper.EnumerateSubdirectories(folder, i)
      if not subdir then break end
      table.insert(folders, normalize_path(folder .. sep .. subdir))
      i = i + 1
    end
  end
  return results
end

-- Utility function: load waveform cache or generate on demand
local function load_waveform(file_path)
  local cache_path = normalize_path(WAVEFORM_CACHE_DIR .. "/" .. file_path:match("([%w-_]+)%.%w+$") .. ".wfc")
  -- Load from cache
  if file_exists(cache_path) then
    local peaks = {}
    for line in io.lines(cache_path) do
      local vals = {}
      for val in line:gmatch("%S+") do
        table.insert(vals, tonumber(val))
      end
      table.insert(peaks, vals)
    end
    waveform_cache[file_path] = peaks
    return peaks
  else
    -- Generate waveform - placeholder: use ReaImGui or ReaAPI to generate waveform
    -- This could be a blocking op, consider deferred task
    local peaks = {} -- generate dummy or real data here
    waveform_cache[file_path] = peaks
    -- Save to cache
    local f = io.open(cache_path, "w")
    if f then
      for _, peak_vals in ipairs(peaks) do
        f:write(table.concat(peak_vals, " ").."\n")
      end
      f:close()
    end
    return peaks
  end
end

-- Utility function: create media item in REAPER project
local function insert_audio(path, pos, length, pitch, rate)
  local track = reaper.GetSelectedTrack(0, 0) or reaper.GetTrack(0,0)
  local item = reaper.CreateNewMIDIItemInProj(track, pos, pos + length, false)
  local take = reaper.AddTakeToMediaItem(item)
  local source = reaper.PCM_Source_CreateFromFile(path)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch or 0.0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate or 1.0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  reaper.UpdateArrange()
  return item
end

-- OAuth token refresh
local function refresh_oauth_token()
  local client_id = reaper.GetExtState("Soundmole", "oauth_client_id")
  local client_secret = reaper.GetExtState("Soundmole", "oauth_client_secret")
  if client_id == "" or client_secret == "" or oauth_refresh_token == nil then return false end
  local token_url = "https://freesound.org/apiv2/oauth2/access_token/"
  local data = {
    grant_type = "refresh_token",
    refresh_token = oauth_refresh_token,
    client_id = client_id,
    client_secret = client_secret
  }
  local resp = http_post(token_url, data)
  if resp == nil then return false end
  local tbl = json.decode(resp)
  if tbl == nil or not tbl.access_token then return false end
  oauth_access_token = tbl.access_token
  oauth_refresh_token = tbl.refresh_token or oauth_refresh_token
  reaper.SetExtState("Soundmole", "oauth_access_token", oauth_access_token, true)
  reaper.SetExtState("Soundmole", "oauth_refresh_token", oauth_refresh_token, true)
  return true
end

-- Freesound search function
local function freesound_search(query, page)
  page = page or 1
  local token = oauth_access_token
  if token == "" then reaper.ShowMessageBox("Please login via OAuth first.", "OAuth Needed", 0) return end
  local base_url = "https://freesound.org/apiv2/search/text/"
  local search_url = string.format("%s?query=%s&page=%d&token=%s", base_url, query, page, token)
  local res = http_get(search_url)

  if res == nil then reaper.ShowMessageBox("API request failed or empty response.", "Freesound Error", 0) return end

  local data = json.decode(res)
  if data == nil or data.results == nil then
    reaper.ShowMessageBox("JSON parsing failed or unexpected structure.", "Freesound Error", 0)
    return
  end

  -- Process results (populate media_db or your UI here)
  media_db = data.results
  reaper.ShowConsoleMsg("Freesound returned " .. #media_db .. " results.\n")
end

-- OAuth authorization opening
local function open_oauth_authorization()
  local client_id = reaper.GetExtState("Soundmole", "oauth_client_id")
  if not client_id or client_id == "" then
    reaper.ShowMessageBox("Please set your OAuth client ID in settings.", "OAuth Setup", 0)
    return
  end
  local url = string.format("https://freesound.org/apiv2/oauth2/authorize/?client_id=%s&response_type=code&redirect_uri=%s",
    client_id,
    reaper.GetExtState("Soundmole", "oauth_redirect_uri") or "urn:ietf:wg:oauth:2.0:oob"
  )
  if OS == "OSX32" or OS == "OSX64" then os.execute("open '" .. url .. "'")
  elseif reaper.GetOS():find("Win") then os.execute('start "" "' .. url .. '"')
  else os.execute("xdg-open '" .. url .. "'") end
end

-- Render the main GUI window and controls
local function main_loop()
  local visible, open = reaper.ImGui_Begin(main_context, "Soundmole - Audio Sample Explorer", true)
  if not visible then
    reaper.ImGui_DestroyContext(main_context)
    return
  end

  reaper.ImGui_Text(main_context, "OAuth Token Management")
  if reaper.ImGui_Button(main_context, "Open OAuth Authorization URL") then
    open_oauth_authorization()
  end

  local _, oauth_code = reaper.ImGui_InputText(main_context, "Paste Authorization Code", "", 256)
  if oauth_code ~= "" and reaper.ImGui_Button(main_context, "Exchange Code for Token") then
    -- Insert code to call OAuth token exchange function here
    -- ...
  end

  reaper.ImGui_Separator(main_context)

  local _, search_query = reaper.ImGui_InputText(main_context, "Search Sounds", "", 256)
  if search_query ~= "" and reaper.ImGui_Button(main_context, "Search Freesound") then
    freesound_search(search_query)
  end

  -- TODO: Add UI to list media_db results, render waveforms with caching; playback preview controls with pitch/rate sliders

  if reaper.ImGui_Button(main_context, "Quit") then
    ui_is_running = false
  end

  reaper.ImGui_End(main_context)

  if ui_is_running then
    reaper.defer(main_loop)
  else
    reaper.ImGui_DestroyContext(main_context)
  end
end

-- Start the GUI loop
reaper.defer(main_loop)