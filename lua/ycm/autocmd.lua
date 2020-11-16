-- just some lua for defining autocmds.
-- It mimics https://github.com/neovim/neovim/pull/12076 so that when it is
-- merged we can just lose this file.

local M = {
  _CB = {}
}

--[[
function M.augroup_define(group, clear)
  vim.cmd('augroup '..group)
  if clear then
    vim.cmd[[autocmd!]]
  end
  vim.cmd[[augroup END]]
end
--]]

function M.define_autocmd_group(group, opts)
  vim.cmd('augroup '..group)
  if opts.clear then
    vim.cmd[[autocmd!]]
  end
  vim.cmd[[augroup END]]
end

local function join(...)
  return table.concat({...}, " ")
end

local function prepare_cmd(cb, abuf)
  local key = tostring(cb)
  M._CB[key] = cb

  local fn = "require'ycm.autocmd'._CB['"..key.."']"
  if abuf then
    return string.format([[ call luaeval("%s(_A)", str2nr(expand('<abuf>'))) ]], fn)
  end
  return 'lua '..fn..'()'
end

function M.define_autocmd(spec)
  local event = spec.event
  if type(event) == 'table' then
    event = table.concat(event, ',')
  end
  local pattern = spec.pattern or "*"
  local once = spec.once and "++once" or ""
  local nested = spec.nested and "++nested" or ""

  local cmd = prepare_cmd(spec.callback, spec.abuf)

  local group = spec.group or "END"
  vim.cmd("augroup "..group)
  local full = join("autocmd", event, pattern, once, nested, cmd)
  vim.cmd(full)
  vim.cmd("augroup END")
end

--[[
function M.autocmd_define(events, pattern, callbacks, options)
  if type(events) == 'table' then
    events = table.concat(events, ',')
  end

  local once = options.once and "++once" or ""
  local nested = options.nested and "++nested" or ""

  local cmd = prepare_cmd(callbacks.on_event, options.abuf)

  local group = options.group or "END"
  vim.cmd("augroup "..group)
  local full = join("autocmd", events, pattern, once, nested, cmd)
  vim.cmd(full)
  vim.cmd("augroup END")
end
--]]

return M
