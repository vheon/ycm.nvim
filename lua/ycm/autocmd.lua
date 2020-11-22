-- just some lua for defining autocmds.
-- It mimics https://github.com/neovim/neovim/pull/12076 so that when it is
-- merged we can just lose this file.

local M = {
  _CB = {}
}

function M.define_autocmd_group(group, opts)
  vim.cmd('augroup '..group)
  if opts.clear then
    vim.cmd('autocmd!')
  end
  vim.cmd('augroup END')
end

local function join(...)
  return table.concat({...}, " ")
end

local function lua_call(cb)
  local key = tostring(cb)
  M._CB[key] = cb
  return "lua require'ycm.autocmd'._CB['"..key.."']()"
end

function M.define_autocmd(spec)
  local event = spec.event
  if type(event) == 'table' then
    event = table.concat(event, ',')
  end
  local group = spec.group or ""
  local pattern = spec.pattern or "*"
  local once = spec.once and "++once" or ""
  local nested = spec.nested and "++nested" or ""

  local action = spec.command or ''
  local callback = spec.callback
  if callback ~= nil then
    action = lua_call(callback)
  end

  vim.cmd(join("autocmd", group, event, pattern, once, nested, action))
end

return M
