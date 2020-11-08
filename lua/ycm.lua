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

local parsers = require'nvim-treesitter.parsers'
local tsq = require'vim.treesitter.query'
local autocmd = require'ycm.autocmd'

-- XXX(andrea): find out if there is a better way in lua.
local plugin_directory = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

local complete_id = 0
local startcol = 0
local remote_job_id = nil

local buffers = {}

-- stolen from the vim module
local function pcall_ret(status, ...)
  if status then return ... end
end

local function nil_wrap(fn, ...)
  return pcall_ret(pcall(fn, ...))
end

local Buffer = {}

function Buffer:new(bufnr, ft, query)
  self.__index = self
  return setmetatable({
    bufnr = bufnr,
    ft = ft,
    -- XXX(andrea): once we start integrating more with nvim-treesitter we
    -- should probably pass the lang directly
    parser = parsers.get_parser(bufnr, parsers.ft_to_lang(ft)),
    query = nil_wrap(vim.treesitter.parse_query, ft, query),
    tick = vim.api.nvim_buf_get_changedtick(bufnr)
  }, Buffer)
end

-- XXX(andrea): is `parse` a good name?
-- XXX(andrea): if we set we up as nvim-treesitter module do we have to call `parse` on our own?
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
function Buffer:identifiers()
  local tree = self:parse()

  local lines = vim.api.nvim_buf_line_count(self.bufnr)

  local identifiers = {}
  for _, node in self.query:iter_captures(tree:root(), self.bufnr, 1, lines) do
      local text = tsq.get_node_text(node, self.bufnr)
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

local function collect_and_send_refresh_identifiers()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  local ft = vim.bo.filetype
  local fp = vim.api.nvim_buf_get_name(bufnr)
  local identifiers = buffer:identifiers()
  vim.rpcnotify(remote_job_id, "refresh_buffer_identifiers", ft, fp, identifiers)
end

local function show_candidates(id, cands)
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

  if vim.b.ycm_nvim_largefile then
    return false
  end
  local threshold = vim.g.ycm_disable_for_files_larger_than_kb
  if threshold == nil then
    threshold = 5000
  end
  threshold = threshold * 1024
  local fp = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.getfsize(fp) > threshold then
    vim.b.ycm_nvim_largefile = true
    return false, "ycm.nvim is disabled in this buffer; the file exceed the max size."
  end

  if vim.b.ycm_nvim_no_parser then
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

  if not parsers.has_parser() then
    vim.b.ycm_nvim_no_parser = true
    return false, "ycm.nvim is disabled in this buffer; a suitable tree-sitter parser is not available."
  end

  local buffer = Buffer:new(bufnr, ft)
  if buffer.query == nil then
    vim.b.ycm_nvim_no_parser = true
    return false, "ycm.nvim is disabled in this buffer; a suitable tree-sitter query is not available."
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

local function refresh_identifiers()
  if not allowed_in_buffer() then
    return
  end
  collect_and_send_refresh_identifiers()
end

local function initialize_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  if buffer ~= nil and buffer.ft ~= vim.bo.filetype then
    log("reset ycmbuffer due to change of filetype")
    buffers[bufnr] = nil
  end

  refresh_identifiers()
end

function refresh_identifiers_if_needed()
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
local function on_buf_unload(bufnr)
  -- XXX(andrea): check if this is enough
  log( "on_buf_unload "..bufnr)
  buffers[bufnr] = nil
  -- XXX(andrea): TODO
  -- vim.rpcnotify(remote_job_id, "unload", ft, query )
end

local function get_position()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1, cursor[2]
end

local function complete()
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

  local query = tsq.get_node_text(identifier, bufnr)
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

local function complete_p()
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

  complete()
end

local function setup_autocmds()
  autocmd.define_augroup('ycm', true)
  -- XXX(andrea): the FileType event should also handle the case where a
  -- buffer change Filetype after it is loaded.
  autocmd.define_autocmd({'FileType'}, '*', {on_event = initialize_buffer}, {group='ycm'})
  -- autocmd.define_autocmd({'FileType'}, '*', refresh_identifiers)

  -- XXX(andrea): all the autocmd that follow should actually be for <buffer>
  -- that has been validated and are compatible. Otherwise we are firing lua
  -- function only to do checks we already know failed and exit.
  autocmd.define_autocmd({'BufUnload'}, '*', {on_event = on_buf_unload}, {abuf = true, group='ycm'})

  autocmd.define_autocmd({'TextChanged'}, '*', {on_event = refresh_identifiers}, {group = 'ycm'})
  autocmd.define_autocmd({'InsertLeave'}, '*', {on_event = refresh_identifiers_if_needed}, {group = 'ycm'})

  autocmd.define_autocmd({'TextChangedI'}, '*', {on_event = complete}, {group = 'ycm'})
  autocmd.define_autocmd({'TextChangedP'}, '*', {on_event = complete_p}, {group = 'ycm'})
end

local function on_exit(...)
  remote_job_id = nil
  -- XXX(andrea): we should:
  -- * remove all autocommands.
  -- * provide a command to setup the plugin again.
end

local function start_ycm()
  local bin = plugin_directory .. "/build/ycm"
  if not vim.fn.executable(bin) then
    log "The ycm binary is not available. ycm.nvim cannot function without it"
    return
  end

  remote_job_id = vim.fn.jobstart( bin, { rpc = true, on_exit = on_exit } )
  if remote_job_id <= 0 then
    log "Failed to spawn ycm plugin"
    return
  end

  -- We might be loaded lazily so we have to try to process the buffer we're in
  -- the same way we process buffer on FileType set.
  refresh_identifiers()
end


local function setup()
  vim.o.completeopt = "menuone,noinsert,noselect"
  vim.cmd[[set shortmess+=c]]

  setup_autocmds()
  start_ycm()
end


return {
  setup = setup,
  show_candidates = show_candidates
}
