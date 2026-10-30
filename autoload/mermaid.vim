" vim-mermaid: logic. See :help mermaid.
let s:save_cpo = &cpo
set cpo&vim

" Preview bufnr -> {'src', 'mode', 'lnum', 'req', 'job', 'timer'}
let s:state = {}
" Popup mode keeps its state in t:mermaid_popup:
" {'req', 'job', 'timer', 'popup_id', 'snap'}
" Pending popup req -> its state, while the request has an augroup.
let s:watched = {}
let s:next_req = 0
let s:install = 'go install github.com/AlexanderGrooff/mermaid-ascii@latest'

function! s:opt(name, default) abort
  return get(g:, a:name, a:default)
endfunction

function! s:msg(text) abort
  echohl WarningMsg
  echomsg a:text
  echohl None
endfunction

" Scan Markdown lines for fenced code blocks (CommonMark rules) and return
" the mermaid ones as a List of {'start', 'end', 'body'} with 1-based line
" numbers. 'end' is the closer line, or the last line for an unclosed block.
function! mermaid#scan(lines) abort
  let blocks = []
  let n = len(a:lines)
  let i = 0
  while i < n
    let m = matchlist(a:lines[i], '^\( \{0,3}\)\(`\{3,}\|\~\{3,}\)\(.*\)$')
    " A backtick fence's info string must not contain a backtick.
    if empty(m) || (m[2][0] ==# '`' && m[3] =~# '`')
      let i += 1
      continue
    endif
    let indent = len(m[1])
    let closer = '^ \{0,3}' . (m[2][0] ==# '`' ? '`' : '\~')
          \ . '\{' . len(m[2]) . ',}[ \t]*$'
    let j = i + 1
    while j < n && a:lines[j] !~# closer
      let j += 1
    endwhile
    if matchstr(m[3], '^\s*\zs\S\+') ==# 'mermaid'
      let body = map(a:lines[i + 1 : j - 1],
            \ {_, l -> substitute(l, '^ \{0,' . indent . '}', '', '')})
      call add(blocks, {'start': i + 1, 'end': j < n ? j + 1 : n, 'body': body})
    endif
    let i = j + 1
  endwhile
  return blocks
endfunction

function! s:block_at(blocks, lnum) abort
  for b in a:blocks
    if b.start <= a:lnum && a:lnum <= b.end
      return b
    endif
  endfor
  return {}
endfunction

function! s:is_empty(body) abort
  return empty(filter(copy(a:body), 'v:val =~# "\\S"'))
endfunction

function! s:check_cmd() abort
  let cmd = s:opt('mermaid_ascii_cmd', 'mermaid-ascii')
  if executable(cmd)
    return 1
  endif
  echohl ErrorMsg
  echomsg printf('mermaid: renderer not found: g:mermaid_ascii_cmd = %s. Install it with: %s',
        \ string(cmd), s:install)
  echohl None
  return 0
endfunction

" Return 'popup' or 'split', or '' after an error for an unknown value.
function! s:display() abort
  let d = s:opt('mermaid_display', 'popup')
  if index(['popup', 'split'], d) >= 0
    return d
  endif
  echohl ErrorMsg
  echomsg printf("mermaid: g:mermaid_display must be 'popup' or 'split', not %s", string(d))
  echohl None
  return ''
endfunction

function! s:has_popup() abort
  return has('popupwin')
endfunction

function! s:find_preview_win() abort
  for w in gettabinfo(tabpagenr())[0].windows
    if getbufvar(winbufnr(w), 'mermaid_preview', 0)
      return w
    endif
  endfor
  return 0
endfunction

" Return the preview buffer of this tab, opening the split if needed.
" The cursor stays in the current window.
function! s:open_split() abort
  let pwin = s:find_preview_win()
  if pwin
    return winbufnr(pwin)
  endif
  let srcwin = win_getid()
  execute 'botright' (s:opt('mermaid_split', 'vertical') ==# 'horizontal' ? 'new' : 'vnew')
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nowrap nomodifiable
  setlocal filetype=mermaid-ascii
  let b:mermaid_preview = 1
  autocmd BufWipeout <buffer> call s:on_wipeout(str2nr(expand('<abuf>')))
  let pbuf = bufnr('%')
  call win_gotoid(srcwin)
  return pbuf
endfunction

function! s:on_wipeout(pbuf) abort
  if has_key(s:state, a:pbuf)
    call s:cancel(s:state[a:pbuf])
    call remove(s:state, a:pbuf)
  endif
endfunction

function! s:show(pbuf, lines) abort
  if !bufexists(a:pbuf)
    return
  endif
  call setbufvar(a:pbuf, '&modifiable', 1)
  silent call deletebufline(a:pbuf, 1, '$')
  call setbufline(a:pbuf, 1, empty(a:lines) ? [''] : a:lines)
  call setbufvar(a:pbuf, '&modifiable', 0)
endfunction

" Stop the job and timer of a request state and invalidate its request.
function! s:cancel(st) abort
  let a:st.req = 0
  if a:st.timer != -1
    call timer_stop(a:st.timer)
    let a:st.timer = -1
  endif
  if type(a:st.job) == v:t_job && job_status(a:st.job) ==# 'run'
    call job_stop(a:st.job, 'kill')
  endif
  let a:st.job = v:null
endfunction

function! s:current(r) abort
  return a:r.st.req == a:r.req
endfunction

" Start a new render request for the preview buffer. 'out' holds lines shown
" before the rendered blocks (used for messages when there is no block).
function! s:start(pbuf, info, blocks, out) abort
  if has_key(s:state, a:pbuf)
    call s:cancel(s:state[a:pbuf])
  endif
  let s:next_req += 1
  let st = extend(a:info, {'req': s:next_req, 'job': v:null, 'timer': -1})
  let s:state[a:pbuf] = st
  call s:run({'st': st, 'req': s:next_req, 'mode': st.mode, 'blocks': a:blocks,
        \ 'idx': 0, 'out': a:out, 'Show': function('s:show', [a:pbuf])})
endfunction

" Render blocks one by one; each job's result is appended to r.out.
" r.Show(lines) gets the result.
function! s:run(r) abort
  if !s:current(a:r)
    return
  endif
  let st = a:r.st
  if a:r.idx >= len(a:r.blocks)
    let st.job = v:null
    let st.timer = -1
    return a:r.Show(a:r.out)
  endif
  let b = a:r.blocks[a:r.idx]
  let header = a:r.mode ==# 'all' ? ['-- line ' . b.start . ' --'] : []
  if s:is_empty(b.body)
    return s:next(a:r, header + ['(empty mermaid block)'])
  endif
  let ctx = {'r': a:r, 'header': header, 'stdout': '', 'stderr': '',
        \ 'exited': 0, 'closed': 0, 'status': -1, 'done': 0}
  let cmd = [s:opt('mermaid_ascii_cmd', 'mermaid-ascii')]
        \ + s:opt('mermaid_ascii_args', []) + ['-f', '-']
  let job = job_start(cmd, {
        \ 'out_mode': 'raw', 'err_mode': 'raw',
        \ 'out_cb': function('s:on_out', [ctx, 'stdout']),
        \ 'err_cb': function('s:on_out', [ctx, 'stderr']),
        \ 'close_cb': function('s:on_close', [ctx]),
        \ 'exit_cb': function('s:on_exit', [ctx]),
        \ })
  if job_status(job) ==# 'fail'
    return s:next(a:r, header + ['mermaid-ascii failed to start: ' . string(cmd)])
  endif
  let ctx.job = job
  let st.job = job
  let ctx.timeout = s:opt('mermaid_timeout_ms', 5000)
  let st.timer = timer_start(ctx.timeout, function('s:on_timeout', [ctx]))
  call ch_sendraw(job, join(b.body, "\n") . "\n")
  call ch_close_in(job)
endfunction

function! s:next(r, lines) abort
  let a:r.out += a:lines
  let a:r.idx += 1
  call s:run(a:r)
endfunction

function! s:on_out(ctx, key, ch, msg) abort
  let a:ctx[a:key] .= a:msg
endfunction

function! s:on_close(ctx, ch) abort
  let a:ctx.closed = 1
  call s:finish(a:ctx)
endfunction

function! s:on_exit(ctx, job, status) abort
  let a:ctx.exited = 1
  let a:ctx.status = a:status
  call s:finish(a:ctx)
endfunction

function! s:on_timeout(ctx, timer) abort
  if a:ctx.done
    return
  endif
  let a:ctx.done = 1
  call job_stop(a:ctx.job, 'kill')
  if s:current(a:ctx.r)
    let a:ctx.r.st.timer = -1
    call s:next(a:ctx.r, a:ctx.header
          \ + [printf('mermaid-ascii timed out after %d ms', a:ctx.timeout)])
  endif
endfunction

function! s:lines(text) abort
  let lines = split(substitute(a:text, "\r", '', 'g'), "\n", 1)
  while !empty(lines) && lines[-1] ==# ''
    call remove(lines, -1)
  endwhile
  return lines
endfunction

" Finish a job only after it exited and its output is drained.
function! s:finish(ctx) abort
  if a:ctx.done || !a:ctx.exited || !a:ctx.closed
    return
  endif
  let a:ctx.done = 1
  if !s:current(a:ctx.r)
    return
  endif
  let st = a:ctx.r.st
  call timer_stop(st.timer)
  let st.timer = -1
  if a:ctx.status == 0
    let lines = s:lines(a:ctx.stdout)
  else
    let lines = [printf('mermaid-ascii failed (exit %d):', a:ctx.status)]
          \ + s:lines(a:ctx.stderr)
  endif
  call s:next(a:ctx.r, a:ctx.header + lines)
endfunction

" ---- popup mode ----

function! s:popup_state() abort
  if !exists('t:mermaid_popup')
    let t:mermaid_popup = {'req': 0, 'job': v:null, 'timer': -1, 'popup_id': 0, 'snap': []}
  endif
  return t:mermaid_popup
endfunction

function! s:snapshot() abort
  return [bufnr('%'), win_getid(), line('.'), col('.'), b:changedtick]
endfunction

" Stop the pending render of this tab and close its popup. Return 1 when
" there was something to stop or close.
function! s:popup_reset(st) abort
  let found = a:st.req != 0 || a:st.popup_id != 0
  call s:popup_unwatch(a:st.req)
  call s:cancel(a:st)
  if a:st.popup_id
    call popup_close(a:st.popup_id)
    let a:st.popup_id = 0
  endif
  return found
endfunction

" While a render is pending, leaving the source or moving the cursor or
" changing the text drops the request. Each request has its own augroup.
function! s:popup_watch(st, req) abort
  let snap = a:st.snap
  execute 'augroup mermaid_popup_' . a:req
    autocmd!
    for ev in ['CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'WinLeave', 'BufLeave']
      execute printf('autocmd %s * call s:popup_event(%d, %d, %s)',
            \ ev, a:req, snap[1], string(ev =~# 'Leave$'))
    endfor
  augroup END
  let s:watched[a:req] = a:st
endfunction

function! s:popup_unwatch(req) abort
  if has_key(s:watched, a:req)
    call remove(s:watched, a:req)
    execute 'autocmd! mermaid_popup_' . a:req
    execute 'augroup! mermaid_popup_' . a:req
  endif
endfunction

function! s:popup_event(req, winid, leave) abort
  let st = get(s:watched, a:req, {})
  if empty(st) || st.req != a:req
    return s:popup_unwatch(a:req)
  endif
  if win_getid() != a:winid
    return
  endif
  if a:leave || s:snapshot() != st.snap
    call s:popup_unwatch(a:req)
    call s:cancel(st)
  endif
endfunction

function! s:popup_start(mode, blocks) abort
  if !s:has_popup()
    echohl ErrorMsg
    echomsg "mermaid: popup mode needs +popupwin; set g:mermaid_display = 'split'"
    echohl None
    return
  endif
  let st = s:popup_state()
  call s:popup_reset(st)
  let s:next_req += 1
  let st.req = s:next_req
  let st.snap = s:snapshot()
  call s:popup_watch(st, st.req)
  call s:run({'st': st, 'req': st.req, 'mode': a:mode, 'blocks': a:blocks,
        \ 'idx': 0, 'out': [], 'Show': function('s:popup_show', [st])})
endfunction

function! s:popup_show(st, lines) abort
  call s:popup_unwatch(a:st.req)
  let a:st.req = 0
  " Backstop for events that did not fire: the source must be unchanged.
  if s:snapshot() != a:st.snap
    return
  endif
  let a:st.popup_id = popup_create(empty(a:lines) ? [''] : a:lines, {
        \ 'line': 'cursor+1', 'col': 'cursor', 'pos': 'topleft',
        \ 'border': [], 'padding': [0, 1, 0, 1], 'title': ' mermaid ',
        \ 'wrap': 0, 'scrollbar': 1, 'resize': 0,
        \ 'maxheight': s:opt('mermaid_popup_maxheight', max([1, &lines - 4])),
        \ 'maxwidth': s:opt('mermaid_popup_maxwidth', max([1, &columns - 4])),
        \ 'moved': 'any', 'filtermode': 'n',
        \ 'filter': function('s:popup_filter'),
        \ 'callback': function('s:popup_closed', [a:st]),
        \ })
endfunction

" Esc closes the popup. Ctrl-j/k scroll one line, Ctrl-d/u half a page;
" they are eaten even at the end or when all lines fit, so the popup stays.
" Every other key goes to Vim as usual.
function! s:popup_filter(id, key) abort
  if a:key ==# "\<Esc>"
    call popup_close(a:id)
    return 1
  endif
  let pos = popup_getpos(a:id)
  let height = pos.core_height
  let step = get({"\<C-j>": 1, "\<C-k>": -1,
        \ "\<C-d>": max([1, height / 2]), "\<C-u>": -max([1, height / 2])}, a:key, 0)
  if step == 0
    return 0
  endif
  let last = max([1, line('$', a:id) - height + 1])
  call popup_setoptions(a:id, {'firstline': min([last, max([1, pos.firstline + step])])})
  return 1
endfunction

function! s:popup_closed(st, id, result) abort
  if a:st.popup_id == a:id
    let a:st.popup_id = 0
  endif
endfunction

" ---- commands ----

function! mermaid#preview() abort
  let display = s:display()
  if display ==# ''
    return
  endif
  if exists('b:mermaid_preview')
    return s:msg('mermaid: run this in a Markdown buffer, not in the preview')
  endif
  let b = s:block_at(mermaid#scan(getline(1, '$')), line('.'))
  if empty(b)
    return s:msg('mermaid: no mermaid block under the cursor')
  endif
  if s:is_empty(b.body)
    return s:msg('mermaid: empty mermaid block')
  endif
  if !s:check_cmd()
    return
  endif
  if display ==# 'popup'
    return s:popup_start('single', [b])
  endif
  let pbuf = s:open_split()
  call s:start(pbuf, {'src': bufnr('%'), 'mode': 'single', 'lnum': b.start}, [b], [])
endfunction

function! mermaid#preview_all() abort
  let display = s:display()
  if display ==# ''
    return
  endif
  if exists('b:mermaid_preview')
    return s:msg('mermaid: run this in a Markdown buffer, not in the preview')
  endif
  let blocks = mermaid#scan(getline(1, '$'))
  if empty(blocks)
    return s:msg('mermaid: no mermaid block in this buffer')
  endif
  if !s:check_cmd()
    return
  endif
  if display ==# 'popup'
    return s:popup_start('all', blocks)
  endif
  let pbuf = s:open_split()
  call s:start(pbuf, {'src': bufnr('%'), 'mode': 'all', 'lnum': 0}, blocks, [])
endfunction

" Close the popup and the split of this tab, whichever exist.
function! mermaid#close() abort
  let found = exists('t:mermaid_popup') && s:popup_reset(t:mermaid_popup)
  let w = s:find_preview_win()
  if w
    execute 'bwipeout' winbufnr(w)
  elseif !found
    call s:msg(s:opt('mermaid_display', 'popup') ==# 'split'
          \ ? 'mermaid: no preview split in this tab' : 'mermaid: no preview popup in this tab')
  endif
endfunction

" BufWritePost handler: re-render every preview whose source is buf.
" Popup previews are never refreshed.
function! mermaid#on_write(buf) abort
  if s:opt('mermaid_display', 'popup') !=# 'split'
    return
  endif
  for [key, st] in items(s:state)
    let pbuf = str2nr(key)
    if st.src != a:buf || !bufexists(pbuf)
      continue
    endif
    let blocks = mermaid#scan(getbufline(a:buf, 1, '$'))
    let info = {'src': a:buf, 'mode': st.mode, 'lnum': st.lnum}
    if st.mode ==# 'all'
      call s:start(pbuf, info, blocks, empty(blocks) ? ['mermaid: no mermaid block in this buffer'] : [])
      continue
    endif
    let b = s:block_at(blocks, st.lnum)
    if empty(b)
      let after = filter(copy(blocks), 'v:val.start >= st.lnum')
      let b = empty(after) ? {} : after[0]
    endif
    if empty(b)
      call s:start(pbuf, info, [], ['mermaid: block not found'])
    else
      let info.lnum = b.start
      call s:start(pbuf, info, [b], [])
    endif
  endfor
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
