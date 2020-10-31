--     Copyright 2020 Cedraro Andrea <a.cedraro@gmail.com>
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
--    limitations under the License.

-- XXX(andrea): this upper case M is really bugging me. Find a proper name.
-- Maybe just `ycm`? or `client` as in a client for `ycmd`?
local M = {}

-- XXX(andrea): find out if there is a better way in lua.
local plugin_directory = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

local complete_id = 0
local startcol = 0
local remote_job_id = nil

local buffers = {}
local Buffer = {}
Buffer.__index = Buffer

-- stolen from the vim module
local function pcall_ret(status, ...)
  if status then return ... end
end

local function nil_wrap(fn, ...)
  return pcall_ret(pcall(fn, ...))
end

-- XXX(andrea): should this be `Buffer:new`?
local function create_buffer(bufnr, ft, query)
  local self = setmetatable({}, Buffer)
  self.bufnr = bufnr
  self.ft = ft
  self.parser = nil_wrap(vim.treesitter.get_parser, bufnr, ft)
  if self.parser == nil then
    return nil
  end
  self.query = nil_wrap(vim.treesitter.parse_query, ft, query)
  if self.query == nil then
    return nil
  end
  self.tick = vim.api.nvim_buf_get_changedtick(bufnr)
  return self
end

-- XXX(andrea): is `parse` a good name?
function Buffer:parse()
  self.tick = vim.api.nvim_buf_get_changedtick(self.bufnr)
  return self.parser:parse()
end

function Buffer:require_refresh()
  return self.tick ~= vim.api.nvim_buf_get_changedtick(self.bufnr)
end

-- XXX(andrea): this function is taken from treesitter.lua in neovim repo
-- it looks useful on its own. Should we ask to add it as a method on the node
-- itself? or simply as part of the treesitter api like `vim.treesitter.get_node_text(node, bufnr)`
local a = vim.api
local function get_node_text(node, bufnr)
  local start_row, start_col, end_row, end_col = node:range()
  if start_row ~= end_row then
    return nil
  end
  local line = a.nvim_buf_get_lines(bufnr, start_row, start_row+1, true)[1]
  return string.sub(line, start_col+1, end_col)
end

function Buffer:identifiers()
  local tree = self:parse()

  local lines = vim.api.nvim_buf_line_count(self.bufnr)

  local identifiers = {}
  for _, node in self.query:iter_captures(tree:root(), self.bufnr, 1, lines) do
      local text = get_node_text(node, self.bufnr)
      if text ~= nil then
        identifiers[text] = true
      end
  end
  return vim.tbl_keys(identifiers)
end

function Buffer:identifier_at(row, col)
  local tree = self:parse()

  for _, node in self.query:iter_captures(tree:root(), self.bufnr, row, row + 1) do
    local start_row, start_col, end_row, end_col = node:range()
    if start_row == row and end_row == row and start_col < col and end_col >= col then
      -- XXX(andrea): check if this should be refined or if the first good one is enough
      return node
    end
  end
end


local function log(msg)
  vim.api.nvim_out_write(msg .. "\n")
end

local function init(jobid)
  remote_job_id = jobid

  -- We might be loaded lazily so we have to try to process the buffer we're in
  -- the same way we process buffer on FileType set.
  M.refresh_identifiers()
end

function M.start_ycm()
  local bin = plugin_directory .. "/build/ycm"
  if not vim.fn.executable(bin) then
    log "The ycm binary is not available. ycm.nvim cannot function without it"
    return
  end

  remote_job_id = vim.fn.jobstart( bin, { rpc = true, on_exit = M.on_exit } )
  if remote_job_id <= 0 then
    log "Failed to spawn ycm plugin"
    return
  end

  init(remote_job_id)
end

function M.on_exit(...)
  remote_job_id = nil
  -- XXX(andrea): we should:
  -- * remove all autocommands.
  -- * provide a command to setup the plugin again.
end


local function collect_and_send_refresh_identifiers()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  local ft = vim.bo.filetype
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local identifiers = buffer:identifiers()
  vim.rpcnotify(remote_job_id, "refresh_buffer_identifiers", ft, fp, identifiers)
end

function M.show_candidates(id, cands)
  -- throw away results for our of date requests
  if complete_id ~= id then
    return
  end

  local candidates = {}
  for _, candidate in ipairs(cands) do
    table.insert(candidates, {
      word = candidate,
      menu =  "[ID]",
      equal = 1,
      dup = 1,
      icase =  1,
      empty = 1,
    })
  end

  -- XXX(andrea): we could make the startcol part of the request to YCM that it
  -- would then send us back so that we would not store data computed in the
  -- request phase only to be used on the response phase. I'm not sure how
  -- better of a design would be :/
  vim.fn.complete(startcol, candidates)
end

local function nvim_b_get(bufnr, key)
  return nil_wrap(vim.api.nvim_buf_get_var, key)
end

local function check_requirement_for_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  if buffer ~= nil then
    return true
  end

  local ft = vim.bo.filetype
  if ft == "" then
    return false
  end

  -- XXX(andrea): I think it would be better to have something like:
  -- `if vim.b.ycm_nvim_largefile == 1 then`
  -- so either:
  -- * import the `nvim.lua` module
  -- * wait if it will be ever implemented on stdlib `vim` module
  -- * do not care about it
  if nvim_b_get(bufnr, 'ycm_nvim_largefile') == 1 then
    return false
  end
  local threshold = vim.g.ycm_disable_for_files_larger_than_kb
  if threshold == nil then
    threshold = 5000
  end
  threshold = threshold * 1024
  local fp = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.getfsize(fp) > threshold then
    vim.api.nvim_buf_set_var(bufnr, 'ycm_nvim_largefile', 1)
    return false, "ycm.nvim is disabled in this buffer; the file exceed the max size."
  end

  if nvim_b_get(bufnr, 'ycm_nvim_no_parser') == 1 then
    return false
  end

  -- XXX(andrea): the query should be for each filetype with some sane default
  -- for each but configurable by the user.
  local query = [[
    (identifier) @identifier
    (type_identifier) @type_identifier
    (field_identifier) @field_identifier
    (namespace_identifier) @namespace_identifier
  ]]
  local buffer = create_buffer(bufnr, ft, query)
  if not buffer then
    vim.api.nvim_buf_set_var(bufnr, 'ycm_nvim_no_parser', 1)
    return false, "ycm.nvim is disabled in this buffer; a suitable tree-sitter parser or identifier query is not available."
  end
  buffers[ bufnr ] = buffer

  return true
end

local function allowed_in_buffer()
  local allowed, msg = check_requirement_for_buffer()
  if msg ~= nil then
    log(msg)
  end
  return allowed
end

function M.initialize_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  if buffer ~= nil and buffer.ft ~= vim.bo.filetype then
    log("reset ycmbuffer due to change of filetype")
    buffers[bufnr] = nil
  end

  M.refresh_identifiers()
end

function M.refresh_identifiers()
  if not allowed_in_buffer() then
    return
  end
  collect_and_send_refresh_identifiers()
end

function M.refresh_identifiers_if_needed()
  if not allowed_in_buffer() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  if not buffer:require_refresh() then
    return
  end

  collect_and_send_refresh_identifiers()
end

-- XXX(andrea): right now ycmd is not able to handle unload of buffers for the
-- identifier completer (which is what we use). Adding it would require adding
-- the functionality to ycmd first. See if it is worth it and useful.
function M.on_buf_unload(bufnr)
  -- XXX(andrea): check if this is enough
  buffers[bufnr] = nil
  -- XXX(andrea): TODO
  -- vim.rpcnotify(remote_job_id, "unload", ft, query )
end

local function get_position()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1, cursor[2]
end

function M.complete()
  if not allowed_in_buffer() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  local row, col = get_position()

  local identifier = buffer:identifier_at(row, col)
  if identifier == nil then
    return
  end

  local query = get_node_text(identifier, bufnr)
  if query == nil then
    return
  end
  local querylen = query:len()

  if querylen >= 2 then
    complete_id = complete_id + 1
    startcol = col + 1 - querylen
    vim.rpcnotify(remote_job_id, "complete", complete_id, buffer.ft, query )
  end
end

function M.complete_p()
  if not allowed_in_buffer() then
    return
  end

  -- if we were called while the popup is visible because we've selected a
  -- candidate do not do the usual completion work.
  -- XXX(andrea): when https://github.com/neovim/neovim/pull/12076 is merged
  -- we should just do:
  --   if not vim.tbl_isempty(vim.v.completed_item) then
  --     return
  --   end
  local selected = vim.v.completed_item
  if selected.word ~= nil then
    return
  end

  M.complete()
end



-- Debug layer

local debughl_ns = vim.api.nvim_create_namespace("ycmtsdebughl")

local function highlight(bufnr, line, col_start, col_end)
  vim.api.nvim_buf_add_highlight(bufnr, debughl_ns, "WildMenu", line, col_start, col_end)
end
local function highlight_node(bufnr, node)
  local start_row, start_col, end_row, end_col = node:range()

  vim.api.nvim_buf_clear_namespace(0, debughl_ns, 0, -1)
  if start_row == end_row then
    highlight(bufnr, start_row, start_col, end_col)
  else
    highlight(bufnr, start_row, start_col, -1)
    for line = start_row + 1, end_row - 1 do
      highlight(bufnr, line, 0, -1)
    end
    highlight(bufnr, end_row, 0, end_col)
  end
end

local function print_identifier_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  local row, col = get_position()
  local tree = buffer:parse()

  local at_cursor = tree:root():named_descendant_for_range(row, col, row, col)
  if at_cursor ~= nil then
    log("ts node type -> "..at_cursor:type())
    highlight_node(bufnr, at_cursor)
  end
end

local function nvim_clear_augroup(group)
  vim.cmd("augroup "..group.." | autocmd! | augroup END")
end

M._CB = {}

local function join(...)
  return table.concat({...}, " ")
end

local function nvim_autocmd(definition)
  local group = definition.group or "END"

  local event = definition.event
  if event == nil then
    error("event is required")
  end

  local pat = "*"
  local buffer = definition.buffer
  if buffer ~= nil then
    if type(buffer) == "number" then
      pat = "<buffer="..buffer..">"
    else
      pat = "<buffer>"
    end
  end

  local once = definition.once and "++once" or ""
  local nested = definition.nested and "++nested" or ""

  local cb = definition.cmd
  if cb == nil then
    error("cmd is required")
  end

  M._CB[cb] = cb
  local cmd = "lua require'ycm'._CB["..tostring(cb).."]()"

  vim.cmd("augroup "..group)
  vim.cmd(join("autocmd ", event, pat, once, nested, cmd))
  vim.cmd("augroup END")
end

function M.enable_ts_debug_layer_for_buffer()
  if not allowed_in_buffer() then
    return
  end

  nvim_clear_augroup("ycmtsdebug")
  nvim_autocmd {
    group = "ycmtsdebug",
    event = "CursorMoved",
    cmd = print_identifier_at_cursor,
    buffer = true
  }
  nvim_autocmd {
    group = "ycmtsdebug",
    event = "InsertEnter",
    cmd = M.disable_ts_debug_layer,
    buffer = true
  }
  print_identifier_at_cursor()
end

function M.disable_ts_debug_layer()
  nvim_clear_augroup("ycmtsdebug")
  vim.api.nvim_buf_clear_namespace(0, debughl_ns, 0, -1)
end

return M