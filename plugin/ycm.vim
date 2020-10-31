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
  lua require'ycm'.start_ycm()
endfunction

call s:setup()
