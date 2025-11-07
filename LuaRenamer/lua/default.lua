--[[
  Shoko Lua Renamer – Detailed and Fully Configurable Media Tag Version

  Main Features:
    - Modular file name construction from metadata (release group, anime title, episode number, technical tags, language tags, censorship, year, hash).
    - Full configurability for technical media info segment; each property (resolution, codec, bitdepth, fps, HDR, audio codecs, channels, source) is toggled in config.media_tag_parts.
    - Ability to enable/disable inclusion of episode name in the file name (see config.include_episode_name).
    - "Year" tag (year_tag) position in filename structure is fully customizable by arranging entries in the 'parts' table below.

  IMPORTANT NOTES:
    - The variable 'filename' MUST be global, not local. Shoko needs to access it.
    - Do NOT add the file extension; Shoko will automatically append the original extension.
    - 'subfolder' MUST be a table (array); Shoko uses it to build the directory path.
    - 'destination' should be set only if you want Shoko to move files between Import Folders.
    - Change the order of filename segments by reordering the 'parts' array below.

    Current filename segment order:
      [GROUP] [ANIME_NAME] [EPISODE_NUMBER] [EPISODE_NAME?] (MEDIA_TAG) [LANG_TAG] [CEN/UNCEN] (YEAR) [CRC]
]]

-- ==========================
--       CONFIGURATION
-- ==========================
local config = {
  max_name_len = 100,               -- Maximum length (characters) for the anime title.
  anime_language = Language.Romaji, -- Preferred language for the anime title.
  episode_language = Language.English, -- Preferred language for the episode name (if enabled).
  space_char = "_",                 -- Whitespace replacement character (used with cleanspaces).
  prefer_anidb_lang_lists = true,   -- If true and AniDB info is available, use AniDB's language lists for dub/sub tags.
  include_audio_tag = false,         -- Add audio language tags ([DUAL-AUDIO], [MULTI-AUDIO], [DUB]).
  include_censorship = true,        -- Add [CEN]/[UNCEN] for restricted anime if enabled.
  include_crc = true,               -- Include CRC hash in filename (if available).
  include_year = false,             -- Add year, position controlled by the 'parts' array below.
  include_episode_name = false,     -- Include episode name if enabled and not generic.
  skip_unknown_release_group = false, -- If true, omit [Unknown] when release group metadata is missing.
  log = {                          -- Logging configuration for this script
    enabled = true,               -- Master switch; set false to silence all custom logs below
    level = "info",               -- Minimum level to output: error < warn < info < debug
    prefix = "LuaRenamer"          -- Prefix prepended to each log line for filtering
  },
  media_tag_parts = {               -- Toggle each media property here to show/hide in the filename's (media_tag) segment.
    resolution      = true,         -- Show video resolution (e.g. 1080p)
    codec           = true,         -- Show video codec (e.g. HEVC, H264)
    bitdepth        = true,         -- Show bit depth (e.g. 10bit)
    fps             = false,        -- Show frames per second (e.g. 23.98fps)
    hdr             = false,        -- Show HDR tag if present and not SDR
    audio_codec     = false,        -- Show listed audio codecs (e.g. AAC, FLAC)
    audio_channels  = false,        -- Show audio channel summary (e.g. 2ch, 6ch)
    source          = true,         -- Show video source (WEB, BluRay, etc.)
  },
  illegal = {                       -- Windows filename character cleanup.
    remove = true,                  -- If true, strip all illegal characters.
    replace = false,                -- If true, replace illegal characters (when remove=false).
    replacement = "_",              -- Replacement string for illegal chars (if replace=true).
    pattern = '[<>:"/\\|%?%*]'      -- Pattern for illegal Windows filename characters.
  },
  mapping = {                       -- Map raw video source values to standardized tag.
    source = {
      BD = "BluRay",
      WEB = "WEB",
      Web = "WEB",
      WEBRip = "WEB",
      DVD = "DVD",
      TV = "TV",
    }
  },
  native_audio_langs = {            -- Languages considered 'native': Japanese, Chinese, Korean (for DUB tag logic).
    ["Japanese"] = true,
    ["Chinese"]  = true,
    ["Korean"]   = true,
  },
}

-- ==========================
--       UTILITY FUNCTIONS
-- ==========================

-- Safely walk through nested tables using provided key sequence.
-- Returns nil if any key is missing.
-- Usage: safe(tbl, "key1", "key2", ...)
local function safe(tbl, ...)
  if tbl == nil then return nil end
  local ref = tbl
  for i = 1, select("#", ...) do
    local k = select(i, ...)
    if ref == nil then return nil end
    ref = ref[k]
  end
  return ref
end

-- Create a string by joining all non-empty entries in a list with a given separator.
-- Used to build filenames from multiple metadata segments.
local function join_nonempty(list, sep)
  local out = {}
  for _, v in ipairs(list) do
    if v and v ~= "" then
      table.insert(out, v)
    end
  end
  return table.concat(out, sep)
end

-- Sanitize a string: remove or replace illegal Windows filename characters, depending on config.
local function sanitize(str, cfg)
  if not str or str == "" then return str end
  if cfg.illegal.remove then
    str = str:gsub(cfg.illegal.pattern, "")
  elseif cfg.illegal.replace then
    str = str:gsub(cfg.illegal.pattern, cfg.illegal.replacement)
  end
  return str
end

-- Standardize raw video 'source' value using config.mapping.source mapping table.
local function map_source(raw, cfg)
  if not raw or raw == "Unknown" then return "" end
  return cfg.mapping.source[raw] or raw
end

-- ==========================
--    SEGMENT GENERATORS
-- ==========================

-- Construct the release group name segment in square brackets.
-- Falls back to [Unknown] if unavailable.
local function build_group(file)
  if not file then return config.skip_unknown_release_group and "" or "[Unknown]" end
  local rg = safe(file, "anidb", "releasegroup")
  if rg then
    return "[" .. (rg.shortname or rg.name or "Unknown") .. "]"
  end
  return config.skip_unknown_release_group and "" or "[Unknown]"
end

-- ==========================
--       LOGGING SUPPORT
-- ==========================
local LEVEL_ORDER = { error = 1, warn = 2, info = 3, debug = 4 }
local function logcfg(level, msg)
  local cfg = config.log
  if not cfg or not cfg.enabled then return end
  local threshold = LEVEL_ORDER[cfg.level] or LEVEL_ORDER.info
  local this = LEVEL_ORDER[level] or LEVEL_ORDER.info
  if this > threshold then return end
  local full = string.format("[%s][%s] %s", cfg.prefix, level:upper(), msg)
  if level == "debug" then
    logdebug(full)
  elseif level == "info" then
    log(full)
  elseif level == "warn" then
    logwarn(full)
  else
    logerror(full)
  end
end

-- Construct the anime title segment using the preferred language, truncated and sanitized.
local function build_anime_name(anime, cfg)
  if not anime then return "Unknown Anime" end
  local n = anime:getname(cfg.anime_language) or anime.preferredname or "Unknown Anime"
  n = n:truncate(cfg.max_name_len)
  n = sanitize(n, cfg)
  return n
end

-- Construct the year segment in parentheses, if enabled and available.
-- E.g.: "(2024)"
local function build_year(anime, cfg)
  if not cfg.include_year or not anime then return "" end
  local startyear = safe(anime, "airdate", "year")
  if startyear then
    return "(" .. tostring(startyear) .. ")"
  end
  return ""
end

-- Construct the episode number segment. Supports single/multi-episode numbers, adds version when present.
local function build_episode_number(anime, episode, episodes, file)
  if not anime or not file then return "" end
  local engepname = episode and episode:getname(Language.English) or ""
  local is_movie = (anime.type == AnimeType.Movie)
  if is_movie and engepname:find("^Complete Movie") then
    return ""
  end

  local epcount = 0
  local etype = episode and episode.type
  if etype and anime.episodecounts and anime.episodecounts[etype] then
    epcount = anime.episodecounts[etype]
  end
  local padding = math.max(#tostring(epcount > 0 and epcount or 0), 2)

  local epnum = ""
  if episodes and #episodes > 0 then
    if #episodes == 1 then
      epnum = episode_numbers(padding)
    else
      epnum = episode_numbers(padding)
      if epnum == "" then
        table.sort(episodes, function(a,b) return a.number < b.number end)
        local first = episodes[1].number
        local last  = episodes[#episodes].number
        epnum = string.format("%0" .. padding .. "d-%0" .. padding .. "d", first, last)
      end
    end
  end

  local fver = safe(file, "anidb", "version")
  if fver and fver > 1 and epnum ~= "" then
    epnum = epnum .. "v" .. fver
  end
  return epnum
end

-- Construct the episode name segment, if enabled and criteria met.
local function build_episode_name(anime, episode, episodes, cfg)
  if not cfg.include_episode_name then return "" end
  if not episode or not episodes or #episodes ~= 1 then return "" end
  local enname = episode:getname(Language.English) or ""
  if enname == "" then return "" end
  -- Skip generic episode names
  if enname:find("^Episode") or enname:find("^OVA") or enname:find("^Complete Movie") then
    return ""
  end
  local epname = episode:getname(cfg.episode_language) or ""
  epname = sanitize(epname, cfg)
  return epname
end

-- Collect dub and subtitle languages, using AniDB lists if enabled and available.
local function collect_language_sets(file, anime, cfg)
  local dublangs = {}
  local sublangs = {}
  
  if not file then return dublangs, sublangs end
  
  -- Safely collect audio languages
  local audio_tracks = safe(file, "media", "audio")
  if audio_tracks then
    dublangs = from(audio_tracks):select("language"):distinct():toArray()
  end
  
  -- Safely collect subtitle languages
  local sub_tracks = safe(file, "media", "sublanguages")
  if sub_tracks then
    sublangs = from(sub_tracks):distinct():toArray()
  end
  
  -- Prefer AniDB lists if available
  if cfg.prefer_anidb_lang_lists and file.anidb then
    local adub = safe(file, "anidb", "media", "dublanguages")
    local asub = safe(file, "anidb", "media", "sublanguages")
    if adub then dublangs = from(adub):distinct():toArray() end
    if asub then sublangs = from(asub):distinct():toArray() end
  end
  return dublangs, sublangs
end

-- Build language tag ([DUAL-AUDIO], [MULTI-AUDIO], [DUB]) based on detected languages.
local function build_language_tag(dublangs, cfg)
  if not cfg.include_audio_tag then return "" end
  local total = #dublangs
  if total == 0 then return "" end
  local nonnative = 0
  for _, lang in ipairs(dublangs) do
    -- Convert Language enum to string for comparison if needed
    local langstr = type(lang) == "string" and lang or tostring(lang)
    if not cfg.native_audio_langs[langstr] and langstr ~= "Unknown" then
      nonnative = nonnative + 1
    end
  end
  if nonnative == 1 and total == 2 then
    return "[DUAL-AUDIO]"
  elseif total > 2 then
    return "[MULTI-AUDIO]"
  elseif nonnative > 0 then
    return "[DUB]"
  end
  return ""
end

-- Build censorship tag ([CEN] or [UNCEN]) for restricted anime if enabled.
local function build_censorship_tag(anime, file, cfg)
  if not cfg.include_censorship or not anime or not file then return "" end
  if not anime.restricted then return "" end
  local censored = safe(file, "anidb", "censored")
  if censored == nil then return "" end
  return censored and "[CEN]" or "[UNCEN]"
end

-- Build hash tag segment ([CRC]), can be extended for other hashes.
local function build_hash_tag(file, cfg)
  if not cfg.include_crc or not file then return "" end
  local crc = safe(file, "hashes", "crc")
  if crc then 
    return "[" .. crc:upper() .. "]" 
  end
  return ""
end

-- Build media technical info tag (resolution, codec, bitdepth, fps, HDR, audio codecs, channels, source).
-- Controlled entirely by config.media_tag_parts toggles.
local function build_media_tags(file, cfg)
  if not file then return "" end
  local parts_cfg = cfg.media_tag_parts

  -- Extract candidate media properties from file metadata
  local res      = safe(file, "media", "video", "res") or ""
  local codec    = safe(file, "media", "video", "codec") or ""
  local bitdepth = ""
  local bd       = safe(file, "media", "video", "bitdepth")
  if parts_cfg.bitdepth and bd and bd ~= 8 and bd ~= 0 then
    bitdepth = bd .. "bit"
  end

  local fps = ""
  local vfps = safe(file, "media", "video", "framerate")
  if parts_cfg.fps and vfps and vfps > 0 then
    local fpsstr = string.format("%.2f", vfps)
    -- Remove trailing zeros and decimal point if whole number
    fpsstr = fpsstr:gsub("%.?0+$", "")
    fps = fpsstr .. "fps"
  end

  local hdr = ""
  local video_dynamic_range = safe(file, "media", "video", "dynamicrange")
  if parts_cfg.hdr and video_dynamic_range and video_dynamic_range ~= "SDR" then
    hdr = video_dynamic_range
  end

  -- Audio codecs and channel summary
  local audio_codec = ""
  local channels    = ""
  if parts_cfg.audio_codec or parts_cfg.audio_channels then
    local tracks = safe(file, "media", "audio") or {}
    local channel_set = {}
    local codec_set   = {}
    for _, track in ipairs(tracks) do
      if parts_cfg.audio_codec and track.codec then
        codec_set[track.codec] = true
      end
      if parts_cfg.audio_channels and track.channels then
        channel_set[track.channels] = true
      end
    end
    if parts_cfg.audio_codec and next(codec_set) then
      local tmp = {}
      for c,_ in pairs(codec_set) do table.insert(tmp, c) end
      table.sort(tmp)
      audio_codec = table.concat(tmp, "+")
    end
    if parts_cfg.audio_channels and next(channel_set) then
      local tmp = {}
      for c,_ in pairs(channel_set) do 
        -- Format channels properly (remove decimal if it's a whole number)
        local ch_str = type(c) == "number" and string.format("%.1f", c):gsub("%.0$", "") or tostring(c)
        table.insert(tmp, ch_str) 
      end
      table.sort(tmp, function(a, b) 
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return a < b
      end)
      channels = table.concat(tmp, "+") .. "ch"
    end
  end

  local source = ""
  if parts_cfg.source then
    source = map_source(safe(file, "anidb", "source"), cfg)
  end

  -- Build the list in fixed order per config toggles
  local tag_parts = {}
  if parts_cfg.resolution    and res ~= ""       then table.insert(tag_parts, res) end
  if parts_cfg.codec         and codec ~= ""     then table.insert(tag_parts, codec) end
  if parts_cfg.bitdepth      and bitdepth ~= ""  then table.insert(tag_parts, bitdepth) end
  if parts_cfg.fps           and fps ~= ""       then table.insert(tag_parts, fps) end
  if parts_cfg.hdr           and hdr ~= ""       then table.insert(tag_parts, hdr) end
  if parts_cfg.audio_codec   and audio_codec ~= "" then table.insert(tag_parts, audio_codec) end
  if parts_cfg.audio_channels and channels ~= "" then table.insert(tag_parts, channels) end
  if parts_cfg.source        and source ~= ""    then table.insert(tag_parts, source) end

  if #tag_parts == 0 then return "" end
  return "(" .. table.concat(tag_parts, " ") .. ")"
end

-- ==========================
--         MAIN LOGIC
-- ==========================

-- Safety check: ensure minimum required data is available
if not anime or not file then
  logcfg("warn", "Missing anime or file; using fallback naming.")
  local rawname = (file and file.name or "Unknown File")
  filename = rawname:gsub('[<>:"/\\|%?%*]', "")
  subfolder = { "Unmapped Files" }
  destination = "Unsorted"
  logcfg("info", "Fallback filename: " .. filename)
  return
end

logcfg("debug", "Starting rename for file: " .. (file.name or "(no name)"))
logcfg("debug", "Anime candidate: " .. (anime.preferredname or anime:getname(config.anime_language) or "(unknown)"))

-- Step 1: Build all filename segments from metadata
local group      = build_group(file)
if group ~= "" then logcfg("debug", "Group segment => " .. group) else logcfg("debug", "Group segment omitted") end
local animename  = build_anime_name(anime, config)
logcfg("debug", "Anime name segment => " .. animename)
local epnum      = build_episode_number(anime, episode, episodes, file)
if epnum ~= "" then logcfg("debug", "Episode number segment => " .. epnum) end
local epname     = build_episode_name(anime, episode, episodes, config)
if epname ~= "" then logcfg("debug", "Episode title segment => " .. epname) end
local dublangs, sublangs = collect_language_sets(file, anime, config)
if #dublangs > 0 then logcfg("debug", "Audio languages => " .. table.concat(dublangs, ",")) end
if #sublangs > 0 then logcfg("debug", "Subtitle languages => " .. table.concat(sublangs, ",")) end
local langtag    = build_language_tag(dublangs, config)
if langtag ~= "" then logcfg("debug", "Language tag => " .. langtag) end
local centag     = build_censorship_tag(anime, file, config)
if centag ~= "" then logcfg("debug", "Censorship tag => " .. centag) end
local year_tag   = build_year(anime, config)
if year_tag ~= "" then logcfg("debug", "Year tag => " .. year_tag) end
local crctag     = build_hash_tag(file, config)
if crctag ~= "" then logcfg("debug", "CRC tag => " .. crctag) end
local media_tag  = build_media_tags(file, config)
if media_tag ~= "" then logcfg("debug", "Media tag => " .. media_tag) end

-- Step 2: Construct a parts table in desired filename order.
-- To change file name format, reorder entries here.
local parts = {
  group,       -- [ReleaseGroup]
  animename,   -- Anime title
  epnum,       -- Episode number / range (empty for certain movie types)
  epname,      -- Episode name (conditional)
  media_tag,   -- (Technical info: resolution, codec, etc.)
  langtag,     -- [DUB]/[DUAL-AUDIO]/[MULTI-AUDIO] or empty
  centag,      -- [CEN]/[UNCEN] if restricted
  year_tag,    -- (Year) – if available or empty
  crctag       -- [CRC]
}

-- Step 3: Build and sanitize the filename
filename = join_nonempty(parts, " "):cleanspaces(config.space_char)
filename = sanitize(filename, config)
logcfg("info", "Final filename => " .. filename)

-- Step 4: Build the target folder name from anime ID, fallback for error/unknown.
foldername = ""
if anime.id then
  foldername = animename .. " [anidb-" .. tostring(anime.id) .. "]"
else
  foldername = animename .. " [anidb-err]"
end
subfolder = { foldername }
logcfg("debug", "Subfolder => " .. foldername)

-- Step 5: Set destination folder for file move based on restriction (adult/hentai logic).
if anime.restricted then
  destination = "Saya Hentai Database"
else
  destination = "Saya Anime Database"
end
logcfg("info", "Destination => " .. tostring(destination))