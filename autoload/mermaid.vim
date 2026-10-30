" vim-mermaid: logic. See :help mermaid.
let s:save_cpo = &cpo
set cpo&vim

" Preview bufnr -> {'src', 'mode', 'lnum', 'req', 'job', 'timer'}
let s:state = {}
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
  call s:cancel(a:pbuf)
  if has_key(s:state, a:pbuf)
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

function! s:cancel(pbuf) abort
  let st = get(s:state, a:pbuf, {})
  if empty(st)
    return
  endif
  if st.timer != -1
    call timer_stop(st.timer)
    let st.timer = -1
  endif
  if type(st.job) == v:t_job && job_status(st.job) ==# 'run'
    call job_stop(st.job, 'kill')
  endif
  let st.job = v:null
endfunction

function! s:current(pbuf, req) abort
  return has_key(s:state, a:pbuf) && s:state[a:pbuf].req == a:req && bufexists(a:pbuf)
endfunction

" Start a new render request for the preview buffer. 'out' holds lines shown
" before the rendered blocks (used for messages when there is no block).
function! s:start(pbuf, info, blocks, out) abort
  call s:cancel(a:pbuf)
  let s:next_req += 1
  let s:state[a:pbuf] = extend(a:info, {'req': s:next_req, 'job': v:null, 'timer': -1})
  call s:run({'pbuf': a:pbuf, 'req': s:next_req, 'blocks': a:blocks, 'idx': 0, 'out': a:out})
endfunction

" Render blocks one by one; each job's result is appended to r.out.
function! s:run(r) abort
  if !s:current(a:r.pbuf, a:r.req)
    return
  endif
  let st = s:state[a:r.pbuf]
  if a:r.idx >= len(a:r.blocks)
    let st.job = v:null
    let st.timer = -1
    return s:show(a:r.pbuf, a:r.out)
  endif
  let b = a:r.blocks[a:r.idx]
  let header = st.mode ==# 'all' ? ['-- line ' . b.start . ' --'] : []
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
  if s:current(a:ctx.r.pbuf, a:ctx.r.req)
    let s:state[a:ctx.r.pbuf].timer = -1
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
  if !s:current(a:ctx.r.pbuf, a:ctx.r.req)
    return
  endif
  let st = s:state[a:ctx.r.pbuf]
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

function! mermaid#preview() abort
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
  let pbuf = s:open_split()
  call s:start(pbuf, {'src': bufnr('%'), 'mode': 'single', 'lnum': b.start}, [b], [])
endfunction

function! mermaid#preview_all() abort
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
  let pbuf = s:open_split()
  call s:start(pbuf, {'src': bufnr('%'), 'mode': 'all', 'lnum': 0}, blocks, [])
endfunction

function! mermaid#close() abort
  let w = s:find_preview_win()
  if !w
    return s:msg('mermaid: no preview split in this tab')
  endif
  execute 'bwipeout' winbufnr(w)
endfunction

" BufWritePost handler: re-render every preview whose source is buf.
function! mermaid#on_write(buf) abort
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
