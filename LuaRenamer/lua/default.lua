--[[
  Shoko Lua Renamer – Comprehensive Metadata-Driven Filename Generator

  OVERVIEW:
    This script generates structured, metadata-rich filenames for anime files managed by Shoko Server.
    It constructs filenames from multiple configurable segments including release group, anime title,
    episode numbering, technical specifications, language tags, censorship indicators, year, and hash.

  KEY FEATURES:
    - Modular filename construction with customizable segment ordering
    - Granular control over technical media tags (resolution, codec, bitdepth, fps, HDR, audio)
    - Language detection with normalization (supports ISO codes and full names)
    - Optional audio language tags ([DUAL-AUDIO], [MULTI-AUDIO], [DUB])
    - Configurable logging system with multiple log levels (error, warn, info, debug)
    - Conditional file moving between Import Folders (restricted/unrestricted)
    - Files stay in place when no destination matches

  CONFIGURATION HIGHLIGHTS:
    - prefer_anidb_lang_lists: Use curated AniDB language lists vs physical track detection
    - include_audio_tag: Enable/disable audio language tags in filename
    - skip_unknown_release_group: Omit [Unknown] tag when release group is missing
    - destinations: Only restricted/unrestricted folders; unmatched files remain in import folder
    - media_tag_parts: Individual toggles for each technical property

  SHOKO REQUIREMENTS:
    - 'filename' MUST be a global variable (without extension)
    - 'subfolder' MUST be a table/array (Shoko builds the directory path from it)
    - 'destination' should be set only when moving files between Import Folders
    - File extension is automatically appended by Shoko

  FILENAME SEGMENT ORDER (customizable via 'parts' array):
    [GROUP] [ANIME_NAME] [EPISODE_NUMBER] [EPISODE_NAME?] (MEDIA_TAG) [LANG_TAG] [CEN/UNCEN] (YEAR) [CRC]
]]

-- ==========================
--       CONFIGURATION
-- ==========================
local config = {
  -- ANIME & EPISODE NAMING
  max_name_len = 100,               -- Maximum character length for anime title (truncated if exceeded).
  anime_language = Language.Romaji, -- Language preference for anime title (Romaji, English, Japanese, etc.).
  episode_language = Language.English, -- Language preference for episode title (if include_episode_name is enabled).
  space_char = "_",                 -- Character used to replace spaces in filenames (cleanspaces function).
  
  -- LANGUAGE DETECTION & TAGGING
  prefer_anidb_lang_lists = true,   -- If true, AniDB language lists override physical track detection (more curated but less file-specific).
  include_audio_tag = false,         -- Add audio language tags: [DUAL-AUDIO] (2 langs), [MULTI-AUDIO] (3+ langs), [DUB] (non-native dub).
  native_audio_langs = {            -- Languages considered 'native' for DUB tag logic (i.e., not dubbed if only these present).
    ["Japanese"] = true,
    ["Chinese"]  = true,
    ["Korean"]   = true,
  },
  
  -- OPTIONAL FILENAME COMPONENTS
  include_censorship = true,        -- Add [CEN] or [UNCEN] tag for restricted (adult) anime.
  include_crc = true,               -- Include [CRC] hash in filename (uppercase, if available).
  include_year = false,             -- Add release year in parentheses (position controlled by 'parts' array order).
  include_episode_name = false,     -- Include episode title in filename (skips generic names like "Episode 01").
  skip_unknown_release_group = false, -- If true, omit [Unknown] tag when release group metadata is missing.
  use_existing_location = false,    -- If true, Shoko reuses destination/subfolder of other files from the same series.
  
  -- LOGGING CONFIGURATION
  log = {
    enabled = true,                 -- Master switch for all custom logging below.
    level = "info",                 -- Minimum log level: "error" < "warn" < "info" < "debug".
    prefix = "LuaRenamer"            -- Prefix added to each log line for easy filtering in Shoko logs.
  },
  
  -- DESTINATION FOLDERS (FILE MOVING)
  destinations = {
    restricted   = "Saya Hentai Database",  -- Target Import Folder for restricted/adult anime.
    unrestricted = "Saya Anime Database",   -- Target Import Folder for normal anime.
    -- Note: Files that don't match either category remain in their current Import Folder (no move).
  },
  
  -- MEDIA TAG COMPONENTS (TECHNICAL SPECIFICATIONS)
  -- Individual toggles for each property in the (MEDIA_TAG) segment of the filename.
  -- Disabled properties are omitted; enabled properties appear in the order listed below.
  media_tag_parts = {
    resolution      = true,         -- Video resolution (e.g., 1080p, 720p, 2160p).
    codec           = true,         -- Video codec (e.g., HEVC, H264, AV1).
    bitdepth        = true,         -- Bit depth (e.g., 10bit, 8bit; omitted if 8bit or 0).
    fps             = false,        -- Frame rate (e.g., 23.98fps, 60fps; formatted to remove trailing zeros).
    hdr             = false,        -- HDR type (e.g., HDR10, DV; omitted if SDR).
    audio_codec     = false,        -- Audio codec(s) (e.g., AAC, FLAC, multiple joined with +).
    audio_channels  = false,        -- Audio channel configuration (e.g., 2ch, 5.1ch, multiple joined with +).
    source          = true,         -- Video source (e.g., BluRay, WEB, DVD; mapped via config.mapping.source).
  },
  
  -- FILENAME SANITIZATION
  illegal = {
    remove = true,                  -- If true, remove illegal Windows filename characters.
    replace = false,                -- If true (and remove=false), replace illegal characters with replacement string.
    replacement = "_",              -- Replacement character for illegal chars (used when replace=true).
    pattern = '[<>:"/\\|%?%*]'      -- Regex pattern matching illegal Windows filename characters.
  },
  
  -- VIDEO SOURCE MAPPING
  -- Standardizes raw source values to consistent tags in the filename.
  mapping = {
    source = {
      BD = "BluRay",
      WEB = "WEB",
      Web = "WEB",
      WEBRip = "WEB",
      DVD = "DVD",
      TV = "TV",
    }
  },
}

-- ==========================
--     UTILITY FUNCTIONS
-- ==========================

-- Safely navigate nested table structures without throwing errors.
-- Returns nil if any key in the path is missing, preventing nil indexing exceptions.
-- Usage: safe(file, "media", "video", "res") instead of file.media.video.res
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

-- Join non-empty strings from a list with a separator.
-- Empty strings and nil values are automatically filtered out.
-- Used to build filenames from metadata segments without extra separators.
local function join_nonempty(list, sep)
  local out = {}
  for _, v in ipairs(list) do
    if v and v ~= "" then
      table.insert(out, v)
    end
  end
  return table.concat(out, sep)
end

-- Sanitize filename strings by removing or replacing illegal Windows characters.
-- Behavior controlled by config.illegal (remove vs replace mode).
local function sanitize(str, cfg)
  if not str or str == "" then return str end
  if cfg.illegal.remove then
    str = str:gsub(cfg.illegal.pattern, "")
  elseif cfg.illegal.replace then
    str = str:gsub(cfg.illegal.pattern, cfg.illegal.replacement)
  end
  return str
end

-- Map raw video source values to standardized tags using config.mapping.source.
-- Returns empty string for "Unknown" or missing sources.
local function map_source(raw, cfg)
  if not raw or raw == "Unknown" then return "" end
  return cfg.mapping.source[raw] or raw
end

-- Normalize language codes and names to canonical forms (e.g., "jpn"/"ja" -> "Japanese").
-- Returns nil for unknown/unwanted values (e.g., "Unknown", "und", "") so they can be filtered.
-- Ensures consistent language names across different metadata sources (physical tracks, AniDB).
local function normalize_language(lang)
  if not lang then return nil end
  if type(lang) ~= "string" then lang = tostring(lang) end
  local l = lang:lower()
  -- ISO 639-2/639-1 codes and full names -> canonical form
  if l == "jpn" or l == "ja" or l == "japanese" then return "Japanese" end
  if l == "eng" or l == "en" or l == "english" then return "English" end
  if l == "chi" or l == "zh" or l == "chinese" then return "Chinese" end
  if l == "kor" or l == "ko" or l == "korean" then return "Korean" end
  if l == "unknown" or l == "und" or l == "" then return nil end
  -- Fallback: preserve original (for less common languages with correct capitalization)
  return lang
end

-- NOTE: Destination override functionality has been removed. Only restricted/unrestricted
-- destinations remain. Files that don't match either category stay in their import folder.

-- ==========================
--   FILENAME SEGMENT BUILDERS
-- ==========================

-- Build release group tag in square brackets (e.g., [Doki], [SubsPlease]).
-- Uses shortname if available, falls back to full name, then [Unknown].
-- Can be omitted entirely if config.skip_unknown_release_group=true and group is unknown.
local function build_group(file)
  if not file then return config.skip_unknown_release_group and "" or "[Unknown]" end
  local rg = safe(file, "anidb", "releasegroup")
  if rg then
    return "[" .. (rg.shortname or rg.name or "Unknown") .. "]"
  end
  return config.skip_unknown_release_group and "" or "[Unknown]"
end

-- ==========================
--      LOGGING SUPPORT
-- ==========================

-- Logging levels ordered by severity (lower number = higher priority).
local LEVEL_ORDER = { error = 1, warn = 2, info = 3, debug = 4 }

-- Centralized logging function with level-based filtering.
-- Only logs messages at or above the configured threshold level.
-- Formats messages with [prefix][LEVEL] prefix for easy filtering in Shoko logs.
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

-- Build anime title segment using preferred language.
-- Truncates to config.max_name_len and sanitizes illegal characters.
local function build_anime_name(anime, cfg)
  if not anime then return "Unknown Anime" end
  local n = anime:getname(cfg.anime_language) or anime.preferredname or "Unknown Anime"
  n = n:truncate(cfg.max_name_len)
  n = sanitize(n, cfg)
  return n
end

-- Build year tag in parentheses (e.g., "(2024)") if enabled and air date is available.
local function build_year(anime, cfg)
  if not cfg.include_year or not anime then return "" end
  local startyear = safe(anime, "airdate", "year")
  if startyear then
    return "(" .. tostring(startyear) .. ")"
  end
  return ""
end

-- Build episode number segment with proper zero-padding.
-- Handles single episodes, multi-episode ranges (e.g., "01-03"), and file versions (e.g., "01v2").
-- Omits episode number for movies with "Complete Movie" title.
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

-- Build episode title segment if enabled and meets criteria.
-- Only includes for single-episode files (not batches).
-- Skips generic names like "Episode 01", "OVA", "Complete Movie".
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

-- Collect and normalize audio and subtitle languages from file metadata.
-- If config.prefer_anidb_lang_lists=true, AniDB language lists override physical track detection.
-- Returns two arrays: normalized audio languages (dub) and subtitle languages.
-- Filters out "Unknown" and normalizes ISO codes (jpn->Japanese, eng->English, etc.).
local function collect_language_sets(file, anime, cfg)
  local raw_dub = {}
  local raw_sub = {}
  if not file then return raw_dub, raw_sub end

  -- Collect raw languages from physical tracks
  local audio_tracks = safe(file, "media", "audio") or {}
  for _, track in ipairs(audio_tracks) do
    if track.language then table.insert(raw_dub, track.language) end
  end

  local sub_tracks = safe(file, "media", "sublanguages") or {}
  for _, sl in ipairs(sub_tracks) do table.insert(raw_sub, sl) end

  -- Optionally override with curated AniDB language lists
  if cfg.prefer_anidb_lang_lists and file.anidb then
    local adub = safe(file, "anidb", "media", "dublanguages")
    local asub = safe(file, "anidb", "media", "sublanguages")
    if adub then raw_dub = adub end
    if asub then raw_sub = asub end
  end

  -- Normalize languages and remove duplicates/unknowns
  local dub_set = {}
  local sub_set = {}
  for _, lang in ipairs(raw_dub) do
    local norm = normalize_language(lang)
    if norm then dub_set[norm] = true end
  end
  for _, lang in ipairs(raw_sub) do
    local norm = normalize_language(lang)
    if norm then sub_set[norm] = true end
  end

  local dublangs = {}
  local sublangs = {}
  for l,_ in pairs(dub_set) do table.insert(dublangs, l) end
  for l,_ in pairs(sub_set) do table.insert(sublangs, l) end
  table.sort(dublangs)
  table.sort(sublangs)

  -- Debug logging of final normalized language sets
  if #dublangs > 0 then logcfg("debug", "Normalized audio languages => " .. table.concat(dublangs, ",")) end
  if #sublangs > 0 then logcfg("debug", "Normalized subtitle languages => " .. table.concat(sublangs, ",")) end
  return dublangs, sublangs
end

-- Build audio language tag based on detected dub languages.
-- [DUAL-AUDIO]: Exactly 2 audio languages present (any combination).
-- [MULTI-AUDIO]: 3 or more languages.
-- [DUB]: Non-native language(s) present (but not dual/multi criteria).
-- Native languages defined in config.native_audio_langs (Japanese, Chinese, Korean by default).
local function build_language_tag(dublangs, cfg)
  if not cfg.include_audio_tag then return "" end
  local total = #dublangs
  if total == 0 then return "" end
  local nonnative = 0
  for _, lang in ipairs(dublangs) do
    if not cfg.native_audio_langs[lang] then
      nonnative = nonnative + 1
    end
  end
  if total == 2 then
    return "[DUAL-AUDIO]"
  elseif total > 2 then
    return "[MULTI-AUDIO]"
  elseif nonnative > 0 then
    return "[DUB]"
  end
  return ""
end

-- Build censorship tag for restricted (adult) anime: [CEN] or [UNCEN].
-- Only applies to anime marked as restricted; skipped for normal anime.
local function build_censorship_tag(anime, file, cfg)
  if not cfg.include_censorship or not anime or not file then return "" end
  if not anime.restricted then return "" end
  local censored = safe(file, "anidb", "censored")
  if censored == nil then return "" end
  return censored and "[CEN]" or "[UNCEN]"
end

-- Build hash tag segment (currently CRC only, can be extended for MD5/SHA1).
-- CRC is converted to uppercase for consistency.
local function build_hash_tag(file, cfg)
  if not cfg.include_crc or not file then return "" end
  local crc = safe(file, "hashes", "crc")
  if crc then 
    return "[" .. crc:upper() .. "]" 
  end
  return ""
end

-- Build comprehensive media technical info tag: (resolution codec bitdepth fps HDR audio source).
-- Each property is individually controlled by config.media_tag_parts toggles.
-- Properties appear in a fixed order; disabled properties are omitted.
-- Examples: (1080p HEVC 10bit BluRay), (720p H264 WEB), (2160p HEVC HDR10 BluRay).
local function build_media_tags(file, cfg)
  if not file then return "" end
  local parts_cfg = cfg.media_tag_parts

  -- VIDEO PROPERTIES
  local res      = safe(file, "media", "video", "res") or ""
  local codec    = safe(file, "media", "video", "codec") or ""
  
  -- Bit depth (omit 8bit and 0 as they're standard/unknown)
  local bitdepth = ""
  local bd       = safe(file, "media", "video", "bitdepth")
  if parts_cfg.bitdepth and bd and bd ~= 8 and bd ~= 0 then
    bitdepth = bd .. "bit"
  end

  -- Frame rate (formatted to remove trailing zeros: 23.98fps, 60fps)
  local fps = ""
  local vfps = safe(file, "media", "video", "framerate")
  if parts_cfg.fps and vfps and vfps > 0 then
    local fpsstr = string.format("%.2f", vfps)
    fpsstr = fpsstr:gsub("%.?0+$", "")
    fps = fpsstr .. "fps"
  end

  -- HDR type (omit SDR as it's the default)
  local hdr = ""
  local video_dynamic_range = safe(file, "media", "video", "dynamicrange")
  if parts_cfg.hdr and video_dynamic_range and video_dynamic_range ~= "SDR" then
    hdr = video_dynamic_range
  end

  -- AUDIO PROPERTIES (multiple tracks aggregated)
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
    
    -- Multiple codecs joined with + (e.g., AAC+FLAC)
    if parts_cfg.audio_codec and next(codec_set) then
      local tmp = {}
      for c,_ in pairs(codec_set) do table.insert(tmp, c) end
      table.sort(tmp)
      audio_codec = table.concat(tmp, "+")
    end
    
    -- Channel counts formatted without decimals for whole numbers (2ch, 5.1ch)
    if parts_cfg.audio_channels and next(channel_set) then
      local tmp = {}
      for c,_ in pairs(channel_set) do 
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

  -- VIDEO SOURCE (mapped to standardized values)
  local source = ""
  if parts_cfg.source then
    source = map_source(safe(file, "anidb", "source"), cfg)
  end

  -- Assemble all enabled properties in fixed order
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
--   MAIN EXECUTION LOGIC
-- ==========================

-- FALLBACK: Handle cases where essential metadata is missing.
-- If anime or file object is unavailable, use the original filename (sanitized).
-- No destination is set, so the file remains in its current Import Folder.
if not anime or not file then
  logcfg("warn", "Missing anime or file metadata; using fallback naming (no move).")
  local rawname = (file and file.name or "Unknown File")
  -- Delegate illegal character removal to Shoko engine via output variable
  remove_illegal_chars = true
  filename = rawname
  subfolder = { "Unmapped Files" }
  -- Destination left nil: file stays in current Import Folder
  logcfg("info", "Fallback filename (stay) => " .. filename)
  return
end

logcfg("debug", "Starting rename for file: " .. (file.name or "(no name)"))
logcfg("debug", "Anime candidate: " .. (anime.preferredname or anime:getname(config.anime_language) or "(unknown)"))

-- STEP 1: Build all filename segments from metadata.
-- Each segment builder handles its own nil-safety and returns empty string if data unavailable.
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

-- STEP 2: Assemble filename segments in desired order.
-- Reorder entries in this array to change the filename structure.
local parts = {
  group,       -- [ReleaseGroup]
  animename,   -- Anime title
  epnum,       -- Episode number/range (e.g., 01, 01-03, 01v2)
  epname,      -- Episode name (conditional, single-episode only)
  media_tag,   -- (Technical specifications: resolution, codec, etc.)
  langtag,     -- [DUAL-AUDIO], [MULTI-AUDIO], [DUB], or empty
  centag,      -- [CEN] or [UNCEN] for restricted anime
  year_tag,    -- (Year) if enabled
  crctag       -- [CRC] hash
}

-- STEP 3: Build and sanitize the final filename.
-- Joins non-empty segments with spaces, normalizes whitespace, removes illegal characters.
-- IMPORTANT: 'filename' must remain a global variable without extension (Shoko requirement).
filename = join_nonempty(parts, " "):cleanspaces(config.space_char)
filename = sanitize(filename, config)
logcfg("debug", "Final filename => " .. filename)

-- STEP 4: Build the target subfolder name.
-- Format: "Anime Name [anidb-12345]" or "Anime Name [anidb-err]" if ID unavailable.
local foldername = ""
if anime.id then
  foldername = animename .. " [anidb-" .. tostring(anime.id) .. "]"
else
  foldername = animename .. " [anidb-err]"
end
subfolder = { foldername }
logcfg("debug", "Subfolder => " .. foldername)

-- STEP 5: Determine destination Import Folder for file movement.
-- Only restricted/unrestricted destinations are supported.
-- If neither matches (or config empty), destination remains nil and file stays in place.
use_existing_anime_location = config.use_existing_location
if anime.restricted and config.destinations.restricted then
  destination = config.destinations.restricted
elseif (not anime.restricted) and config.destinations.unrestricted then
  destination = config.destinations.unrestricted
else
  destination = nil -- File stays in current Import Folder
end
logcfg("debug", "Destination => " .. tostring(destination))

-- ==========================
--    SUMMARY LOG OUTPUT
-- ==========================
-- Logs the original and new file paths for comparison (INFO level).
-- Only logs when the filename actually changes (case-insensitive comparison).
-- If destination is nil (file stays), displays "(stay)" instead of destination folder.

local original_name = file.name or "(no original name)"
-- file.extension already includes the leading dot per Shoko API (e.g., ".mkv")
local extension = file.extension or ""

-- Construct original full path (before rename/move)
local import_loc = safe(file, "importfolder", "location") or "(unknown-import)"
local original_rel = file.path or original_name
local original_full_path = import_loc .. "/" .. original_rel

-- Construct new full path (after rename/move)
local new_full_path
if destination then
  new_full_path = table.concat({ tostring(destination), foldername, filename .. extension }, "/")
else
  new_full_path = table.concat({ "(stay)", foldername, filename .. extension }, "/")
end

-- Only log if filename changed (case-insensitive comparison)
if original_name:lower() ~= filename:lower() then
  logcfg("info", string.format("%-8s : %s", "ORIGINAL", original_full_path))
  logcfg("info", string.format("%-8s : %s", "NEW", new_full_path))
else
  logcfg("debug", "Filename unchanged; summary suppressed.")
end