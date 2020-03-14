"     Copyright 2020 Cedraro Andrea <a.cedraro@gmail.com>
" Licensed under the Apache License, Version 2.0 (the "License");
" you may not use this file except in compliance with the License.
" You may obtain a copy of the License at
"
" http://www.apache.org/licenses/LICENSE-2.0
"
" Unless required by applicable law or agreed to in writing, software
" distributed under the License is distributed on an "AS IS" BASIS,
" WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
" See the License for the specific language governing permissions and
"    limitations under the License.

if exists('g:loaded_ycm')
    finish
endif
let g:loaded_ycm = 1

let s:plugin_directory = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')

" XXX(andrea): this has to be in VimL because is less of a pain than call
" jobstart with a luacallback from here than do it from lua itself.
function! s:start_ycm()
  let l:plugin_bin = s:plugin_directory . '/build/ycm'
  if !executable(l:plugin_bin)
    echomsg "The ycm binary is not available. ycm.nvim cannot function without it"
    return
  endif

  try
    let l:ycm_plugin_id = jobstart([l:plugin_bin], { 'rpc': v:true, 'on_exit': { job_id, data, event -> luaeval("require'ycm'.on_exit(_A[1], _A[2], _A[3])", [job_id, data, event]) } })
    if l:ycm_plugin_id > 0
      call luaeval("require'ycm'.init(_A)", l:ycm_plugin_id)
    else
      echomsg "Failed to spawn ycm plugin"
      return
    endif
  catch
    echomsg v:throwpoint
    echomsg v:exception
  endtry
endfunction

function! s:setup()
  augroup ycm
    autocmd!
    " XXX(andrea): the FileType event should also handle the case where a
    " buffer change Filetype after it is loaded.
    autocmd FileType * lua require'ycm'.initialize_buffer()
    " autocmd FileType * lua require'ycm'.refresh_identifiers()

    " XXX(andrea): all the autocmd that follow should actually be for <buffer>
    " that has been validated and are compatible. Otherwise we are firing lua
    " function only to do checks we already know failed and exit.
    autocmd BufUnload * call luaeval("require'ycm'.on_buf_unload(_A)", str2nr(expand('<abuf>')))

    autocmd TextChanged * lua require'ycm'.refresh_identifiers()
    autocmd InsertLeave * lua require'ycm'.refresh_identifiers_if_needed()

    autocmd TextChangedI * lua require'ycm'.complete()
    autocmd TextChangedP * lua require'ycm'.complete_p()
  augroup END

  set completeopt=menuone,noinsert,noselect
  set shortmess+=c
  call s:start_ycm()
endfunction

call s:setup()
