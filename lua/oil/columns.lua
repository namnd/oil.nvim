local config = require("oil.config")
local constants = require("oil.constants")
local util = require("oil.util")
local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local M = {}

local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE
local FIELD_META = constants.FIELD_META

local all_columns = {}

---@alias oil.ColumnSpec string|table

---@class (exact) oil.ColumnDefinition
---@field render fun(entry: oil.InternalEntry, conf: nil|table): nil|oil.TextChunk
---@field parse fun(line: string, conf: nil|table): nil|string, nil|string
---@field meta_fields nil|table<string, fun(parent_url: string, entry: oil.InternalEntry, cb: fun(err: nil|string))>
---@field compare? fun(entry: oil.InternalEntry, parsed_value: any): boolean
---@field render_action? fun(action: oil.ChangeAction): string
---@field perform_action? fun(action: oil.ChangeAction, callback: fun(err: nil|string))

---@param name string
---@param column oil.ColumnDefinition
M.register = function(name, column)
  all_columns[name] = column
end

---@param adapter oil.Adapter
---@param defn oil.ColumnSpec
---@return nil|oil.ColumnDefinition
local function get_column(adapter, defn)
  local name = util.split_config(defn)
  return all_columns[name] or adapter.get_column(name)
end

---@param adapter_or_scheme string|oil.Adapter
---@return oil.ColumnSpec[]
M.get_supported_columns = function(adapter_or_scheme)
  local adapter
  if type(adapter_or_scheme) == "string" then
    adapter = config.get_adapter_by_scheme(adapter_or_scheme)
  else
    adapter = adapter_or_scheme
  end
  assert(adapter)
  local ret = {}
  for _, def in ipairs(config.columns) do
    if get_column(adapter, def) then
      table.insert(ret, def)
    end
  end
  return ret
end

---@param adapter oil.Adapter
---@param column_defs table[]
---@return fun(parent_url: string, entry: oil.InternalEntry, cb: fun(err: nil|string))
M.get_metadata_fetcher = function(adapter, column_defs)
  local keyfetches = {}
  local num_keys = 0
  for _, def in ipairs(column_defs) do
    local name = util.split_config(def)
    local column = get_column(adapter, name)
    if column and column.meta_fields then
      for k, v in pairs(column.meta_fields) do
        if not keyfetches[k] then
          keyfetches[k] = v
          num_keys = num_keys + 1
        end
      end
    end
  end
  if num_keys == 0 then
    return function(_, _, cb)
      cb()
    end
  end
  return function(parent_url, entry, cb)
    cb = util.cb_collect(num_keys, cb)
    local meta = {}
    entry[FIELD_META] = meta
    for k, v in pairs(keyfetches) do
      v(parent_url, entry, function(err, value)
        if err then
          cb(err)
        else
          meta[k] = value
          cb()
        end
      end)
    end
  end
end

local EMPTY = { "-", "Comment" }

---@param adapter oil.Adapter
---@param col_def oil.ColumnSpec
---@param entry oil.InternalEntry
---@return oil.TextChunk
M.render_col = function(adapter, col_def, entry)
  local name, conf = util.split_config(col_def)
  local column = get_column(adapter, name)
  if not column then
    -- This shouldn't be possible because supports_col should return false
    return EMPTY
  end

  -- Make sure all the required metadata exists before attempting to render
  if column.meta_fields then
    local meta = entry[FIELD_META]
    if not meta then
      return EMPTY
    end
    for k in pairs(column.meta_fields) do
      if not meta[k] then
        return EMPTY
      end
    end
  end
  local chunk = column.render(entry, conf)
  if type(chunk) == "table" then
    if chunk[1]:match("^%s*$") then
      return EMPTY
    end
  else
    if not chunk or chunk:match("^%s*$") then
      return EMPTY
    end
    if conf and conf.highlight then
      local highlight = conf.highlight
      if type(highlight) == "function" then
        highlight = conf.highlight(chunk)
      end
      return { chunk, highlight }
    end
  end
  return chunk
end

---@param adapter oil.Adapter
---@param line string
---@param col_def oil.ColumnSpec
---@return nil|string
---@return nil|string
M.parse_col = function(adapter, line, col_def)
  local name, conf = util.split_config(col_def)
  -- If rendering failed, there will just be a "-"
  if vim.startswith(line, "- ") then
    return nil, line:sub(3)
  end
  local column = get_column(adapter, name)
  if column then
    return column.parse(line, conf)
  end
end

---@param adapter oil.Adapter
---@param col_name string
---@param entry oil.InternalEntry
---@param parsed_value any
---@return boolean
M.compare = function(adapter, col_name, entry, parsed_value)
  local column = get_column(adapter, col_name)
  if column and column.compare then
    return column.compare(entry, parsed_value)
  else
    return false
  end
end

---@param adapter oil.Adapter
---@param action oil.ChangeAction
---@return string
M.render_change_action = function(adapter, action)
  local column = get_column(adapter, action.column)
  if not column then
    error(string.format("Received change action for nonexistant column %s", action.column))
  end
  if column.render_action then
    return column.render_action(action)
  else
    return string.format("CHANGE %s %s = %s", action.url, action.column, action.value)
  end
end

---@param adapter oil.Adapter
---@param action oil.ChangeAction
---@param callback fun(err: nil|string)
M.perform_change_action = function(adapter, action, callback)
  local column = get_column(adapter, action.column)
  if not column then
    return callback(
      string.format("Received change action for nonexistant column %s", action.column)
    )
  end
  column.perform_action(action, callback)
end

if has_devicons then
  M.register("icon", {
    render = function(entry, conf)
      local type = entry[FIELD_TYPE]
      local name = entry[FIELD_NAME]
      local meta = entry[FIELD_META]
      if type == "link" and meta then
        if meta.link then
          name = meta.link
        end
        if meta.link_stat then
          type = meta.link_stat.type
        end
      end
      local icon, hl
      if type == "directory" then
        icon = conf and conf.directory or ""
        hl = "OilDirIcon"
      else
        icon, hl = devicons.get_icon(name)
        icon = icon or (conf and conf.default_file or "")
      end
      if not conf or conf.add_padding ~= false then
        icon = icon .. " "
      end
      return { icon, hl }
    end,

    parse = function(line, conf)
      return line:match("^(%S+)%s+(.*)$")
    end,
  })
end

local default_type_icons = {
  directory = "dir",
  socket = "sock",
}
M.register("type", {
  render = function(entry, conf)
    local entry_type = entry[FIELD_TYPE]
    if conf and conf.icons then
      return conf.icons[entry_type] or entry_type
    else
      return default_type_icons[entry_type] or entry_type
    end
  end,

  parse = function(line, conf)
    return line:match("^(%S+)%s+(.*)$")
  end,
})

return M
