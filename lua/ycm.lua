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
local queries = require'nvim-treesitter.query'
local autocmd = require'ycm.autocmd'

-- XXX(andrea): find out if there is a better way in lua.
local plugin_directory = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

local last_request = {
  id = 0,
  startcol = 0
}
local remote_job_id = nil

local buffers = {}

local Buffer = {}

function Buffer:new(bufnr, ft)
  local lang = parsers.ft_to_lang(ft)
  self.__index = self
  return setmetatable({
    bufnr = bufnr,
    ft = ft,
    -- XXX(andrea): once we start integrating more with nvim-treesitter we
    -- should probably pass the lang directly
    parser = parsers.get_parser(bufnr, lang),
    query = queries.get_query(lang, 'completion'),
    tick = vim.api.nvim_buf_get_changedtick(bufnr)
  }, Buffer)
end

-- XXX(andrea): if we set we up as nvim-treesitter module do we have to call `parse` on our own?
function Buffer:root()
  return self.parser:parse():root()
end

function Buffer:changedtick()
  self.tick = vim.api.nvim_buf_get_changedtick(self.bufnr)
end

function Buffer:require_refresh()
  return self.tick ~= vim.api.nvim_buf_get_changedtick(self.bufnr)
end

function Buffer:identifiers()
  local root = self:root()
  local start_row, _, end_row, _ = root:range()

  local identifiers = {}
  for _, node in self.query:iter_captures(root, self.bufnr, start_row, end_row + 1) do
      local text = tsq.get_node_text(node, self.bufnr)
      if text ~= nil then
        identifiers[text] = true
      end
  end
  return vim.tbl_keys(identifiers)
end

function Buffer:identifier_at(row, col)
  for _, node in self.query:iter_captures(self:root(), self.bufnr, row, row + 1) do
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

local function collect_and_send_refresh_identifiers(buffer)
  local fp = vim.api.nvim_buf_get_name(buffer.bufnr)
  vim.rpcnotify(remote_job_id, "refresh_buffer_identifiers", buffer.ft, fp, buffer:identifiers())
  buffer:changedtick()
end

local function show_candidates(id, cands)
  -- throw away results for out of date requests
  if last_request.id ~= id then
    return
  end

  local candidates = {}
  for _, candidate in ipairs(cands) do
    table.insert(candidates, {
      word = candidate,
      menu = "[ID]",
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
  vim.fn.complete(last_request.startcol, candidates)
end

local function current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = buffers[bufnr]

  if buffer ~= nil then
    return buffer
  end

  local ft = vim.bo.filetype
  if ft == "" then
    return
  end

  -- XXX(andrea): this is a feature of YCM. I don't remember if it is ycmd to
  -- become slow or if it is the client taking long to process it. We should
  -- try with this lua/msgpack implementation and see if it is still a problem.
  if vim.b.ycm_nvim_largefile then
    return
  end
  local threshold = vim.g.ycm_disable_for_files_larger_than_kb
  if threshold == nil then
    threshold = 5000
  end
  threshold = threshold * 1024
  local fp = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.getfsize(fp) > threshold then
    vim.b.ycm_nvim_largefile = true
    log("ycm.nvim is disabled in this buffer; the file exceed the max size.")
    return
  end

  -- XXX(andrea): could we instead create a buffer anyway but mark it invalid?
  -- Would that simplify things?
  if vim.b.ycm_nvim_no_parser then
    return
  end

  if not parsers.has_parser() then
    vim.b.ycm_nvim_no_parser = true
    log("ycm.nvim is disabled in this buffer; a suitable tree-sitter parser is not available.")
    return
  end

  local buffer = Buffer:new(bufnr, ft)
  if buffer.query == nil then
    vim.b.ycm_nvim_no_parser = true
    log("ycm.nvim is disabled in this buffer; a suitable tree-sitter query is not available.")
    return
  end
  buffers[ bufnr ] = buffer

  return buffer
end

local function refresh_identifiers()
  local buffer = current_buffer()
  if buffer ~= nil then
    collect_and_send_refresh_identifiers(buffer)
  end
end

local function initialize_buffer()
  local buffer = current_buffer()

  if buffer ~= nil and buffer.ft ~= vim.bo.filetype then
    log("reset ycmbuffer due to change of filetype")
    buffers[buffer.bufnr] = nil
    vim.b.ycm_nvim_no_parser = nil
  end

  refresh_identifiers()
end

function refresh_identifiers_if_needed()
  local buffer = current_buffer()
  if buffer ~= nil and buffer:require_refresh() then
    collect_and_send_refresh_identifiers(buffer)
  end
end

-- XXX(andrea): right now ycmd is not able to handle unload of buffers for the
-- identifier completer (which is what we use). Adding it would require adding
-- the functionality to ycmd first. See if it is worth it and useful.
local function on_buf_unload(bufnr)
  -- XXX(andrea): check if this is enough
  -- log( "on_buf_unload "..bufnr)
  buffers[bufnr] = nil
  -- XXX(andrea): TODO
  -- vim.rpcnotify(remote_job_id, "unload", ft, query )
end

local function get_position()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return row - 1, col
end

local function complete(buffer)
  buffer = buffer or current_buffer()
  if buffer == nil then
    return
  end

  local row, col = get_position()

  local identifier = buffer:identifier_at(row, col)
  if identifier == nil then
    return
  end

  local input = tsq.get_node_text(identifier, buffer.bufnr)
  if input == nil then
    return
  end
  local inputlen = input:len()

  if inputlen >= 2 then
    last_request.id = last_request.id + 1
    local _, start_col = identifier:range()
    last_request.startcol = start_col + 1

    vim.rpcnotify(remote_job_id, "complete", last_request.id, buffer.ft, input)
  end
end

local function complete_p()
  local buffer = current_buffer()
  if buffer == nil then
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

  complete(buffer)
end

--[[
--XXX(andrea): old API for autocmds
local function setup_autocmds()
  autocmd.augroup_define('ycm', true)
  -- XXX(andrea): the FileType event should also handle the case where a
  -- buffer change Filetype after it is loaded.
  autocmd.autocmd_define('FileType', '*', {on_event = initialize_buffer}, {group='ycm'})
  -- autocmd.autocmd_define({'FileType'}, '*', refresh_identifiers)

  -- XXX(andrea): all the autocmd that follow should actually be for <buffer>
  -- that has been validated and are compatible. Otherwise we are firing lua
  -- function only to do checks we already know failed and exit.
  autocmd.autocmd_define('BufUnload', '*', {on_event = on_buf_unload}, {abuf = true, group='ycm'})

  autocmd.autocmd_define('TextChanged', '*', {on_event = refresh_identifiers}, {group = 'ycm'})
  autocmd.autocmd_define('InsertLeave', '*', {on_event = refresh_identifiers_if_needed}, {group = 'ycm'})

  autocmd.autocmd_define('TextChangedI', '*', {on_event = complete}, {group = 'ycm'})
  autocmd.autocmd_define('TextChangedP', '*', {on_event = complete_p}, {group = 'ycm'})
end
--]]
local function setup_autocmds()
  autocmd.define_autocmd_group('ycm', { clear = true })
  -- XXX(andrea): the FileType event should also handle the case where a
  -- buffer change Filetype after it is loaded.
  autocmd.define_autocmd {
    event = 'FileType',
    callback = initialize_buffer,
    group = 'ycm'
  }
  -- autocmd.autocmd_define({'FileType'}, '*', refresh_identifiers)

  -- XXX(andrea): all the autocmd that follow should actually be for <buffer>
  -- that has been validated and are compatible. Otherwise we are firing lua
  -- function only to do checks we already know failed and exit.
  autocmd.define_autocmd {
    event = 'BufUnload',
    callback = on_buf_unload,
    abuf = true,
    group='ycm'
  }

  autocmd.define_autocmd {
    event = 'TextChanged',
    callback = refresh_identifiers,
    group = 'ycm'
  }
  autocmd.define_autocmd {
    event = 'InsertLeave',
    callback = refresh_identifiers_if_needed,
    group = 'ycm'
  }

  autocmd.define_autocmd {
    event = 'TextChangedI',
    callback = complete,
    group = 'ycm'
  }
  autocmd.define_autocmd {
    event = 'TextChangedP',
    callback = complete_p,
    group = 'ycm'
  }
end

local function on_exit(...)
  remote_job_id = nil
  -- XXX(andrea): we should:
  -- * remove all autocommands.
  -- * provide a command to setup the plugin again.
end

local function start_ycm()
  local bin = plugin_directory .. "/build/bin/ycm"
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
  -- XXX(andrea): would this be better to be something like:
  -- vim.o.completeopt = {"menuone", "noinsert", "noselect"}
  vim.o.completeopt = "menuone,noinsert,noselect"
  -- XXX(andrea): would this be better to be something like:
  -- vim.o.shortmess = vim.o.shortmess + 'c'
  vim.cmd[[set shortmess+=c]]

  -- XXX(andrea): maybe we should first start the process and if successful
  -- setup the autocmds.
  setup_autocmds()
  start_ycm()
end


return {
  setup = setup,
  show_candidates = show_candidates
}
