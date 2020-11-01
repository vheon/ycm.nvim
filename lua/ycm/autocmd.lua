-- just some lua for defining autocmds.
-- It mimics https://github.com/neovim/neovim/pull/12076 so that when it is
-- merged we can just lose this file.

local M = {
  _CB = {}
}

function M.define_augroup(group, clear)
  vim.cmd('augroup '..group)
  if clear then
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

function M.define_autocmd(events, pattern, callbacks, options)
  -- The upstream PR still doesn't have a buffer option but I think (hope) it
  -- will be added, so let's simulate this anyway for now.
  local buffer = options.buffer
  if buffer ~= nil then
    if type(buffer) == "number" then
      pattern = "<buffer="..buffer..">"
    else
      pattern = "<buffer>"
    end
  end

  local once = options.once and "++once" or ""
  local nested = options.nested and "++nested" or ""

  local cmd = prepare_cmd(callbacks.on_event, options.abuf)

  local group = options.group or "END"
  local event_str = table.concat(events, " ")
  vim.cmd("augroup "..group)
  local full = join("autocmd ", event_str, pattern, once, nested, cmd)
  vim.cmd(full)
  vim.cmd("augroup END")
end

return M
