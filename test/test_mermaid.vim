" Headless tests. Run with test/run.sh.
let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:fixtures = s:root . '/test/fixtures/'
let s:fake = s:root . '/test/fake bin/fake-renderer'

function! s:Fixture(name) abort
  return readfile(s:fixtures . a:name)
endfunction

" Open a writable copy of a fixture in the current window.
function! s:Open(name) abort
  let dir = tempname()
  call mkdir(dir, 'p')
  let path = dir . '/' . a:name
  call writefile(s:Fixture(a:name), path)
  execute 'edit' fnameescape(path)
endfunction

function! s:PreviewBuf() abort
  for w in range(1, winnr('$'))
    if getbufvar(winbufnr(w), 'mermaid_preview', 0)
      return winbufnr(w)
    endif
  endfor
  return 0
endfunction

function! s:PLines() abort
  let pbuf = s:PreviewBuf()
  return pbuf ? getbufline(pbuf, 1, '$') : []
endfunction

function! s:WaitFor(expr, ms) abort
  let waited = 0
  while !eval(a:expr) && waited < a:ms
    sleep 10m
    let waited += 10
  endwhile
  return eval(a:expr)
endfunction

function! s:WaitRendered(ms) abort
  return s:WaitFor('join(s:PLines(), "\n") =~# "RENDER\\|failed\\|timed out\\|not found"', a:ms)
endfunction

function! s:Setup() abort
  silent! MermaidClose
  silent! tabonly!
  silent! MermaidClose
  call popup_clear(1)
  silent! only!
  silent! %bwipeout!
  let g:mermaid_ascii_cmd = s:fake
  for name in ['mermaid_ascii_args', 'mermaid_split', 'mermaid_auto_refresh', 'mermaid_timeout_ms',
        \ 'mermaid_display', 'mermaid_popup_maxheight', 'mermaid_popup_maxwidth']
    execute 'unlet! g:' . name
  endfor
  messages clear
endfunction

" ---- scanner ----

function! Test_scan_none() abort
  call assert_equal([], mermaid#scan(s:Fixture('none.md')))
endfunction

function! Test_scan_two_blocks() abort
  let blocks = mermaid#scan(s:Fixture('two.md'))
  call assert_equal(2, len(blocks))
  call assert_equal({'start': 3, 'end': 6, 'body': ['graph LR', 'A --> B']}, blocks[0])
  call assert_equal({'start': 12, 'end': 15, 'body': ['graph TD', 'C --> D']}, blocks[1])
endfunction

function! Test_scan_tilde() abort
  call assert_equal([{'start': 1, 'end': 4, 'body': ['graph LR', 'T --> U']}],
        \ mermaid#scan(s:Fixture('tilde.md')))
endfunction

function! Test_scan_four_backticks() abort
  call assert_equal([{'start': 1, 'end': 5, 'body': ['graph LR', '```', 'X --> Y']}],
        \ mermaid#scan(s:Fixture('four_backtick.md')))
endfunction

function! Test_scan_mismatched_closer() abort
  call assert_equal([{'start': 1, 'end': 5, 'body': ['graph LR', '~~~', 'M --> N']}],
        \ mermaid#scan(s:Fixture('mismatch.md')))
endfunction

function! Test_scan_nested_in_markdown_example() abort
  call assert_equal([], mermaid#scan(s:Fixture('nested.md')))
endfunction

function! Test_scan_empty() abort
  call assert_equal([{'start': 1, 'end': 3, 'body': ['']}], mermaid#scan(s:Fixture('empty.md')))
endfunction

function! Test_scan_unclosed() abort
  call assert_equal([{'start': 2, 'end': 4, 'body': ['graph LR', 'U --> V']}],
        \ mermaid#scan(s:Fixture('unclosed.md')))
endfunction

function! Test_scan_indented() abort
  call assert_equal([{'start': 1, 'end': 5, 'body': ['graph LR', '  I --> J', 'K --> L']}],
        \ mermaid#scan(s:Fixture('indented.md')))
endfunction

" ---- commands (split mode) ----

function! Test_no_block_message() abort
  let g:mermaid_display = 'split'
  call s:Open('none.md')
  let out = execute('MermaidPreview')
  call assert_match('no mermaid block under the cursor', out)
  call assert_equal(1, winnr('$'))
  call s:Open('two.md')
  7
  call assert_match('no mermaid block under the cursor', execute('MermaidPreview'))
  call assert_equal(1, winnr('$'))
  call s:Open('nested.md')
  call assert_match('no mermaid block in this buffer', execute('MermaidPreviewAll'))
  call assert_equal(1, winnr('$'))
endfunction

function! Test_empty_block_message() abort
  let g:mermaid_display = 'split'
  call s:Open('empty.md')
  2
  call assert_match('empty mermaid block', execute('MermaidPreview'))
  call assert_equal(1, winnr('$'))
endfunction

function! Test_cursor_on_opener_body_closer() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  for [lnum, want] in [[3, 'A --> B'], [5, 'A --> B'], [6, 'A --> B'], [12, 'C --> D'], [15, 'C --> D']]
    execute lnum
    MermaidPreview
    call assert_true(s:WaitFor('index(s:PLines(), "RENDER: ' . want . '") >= 0', 3000),
          \ 'line ' . lnum . ': ' . string(s:PLines()))
    call assert_equal(['RENDER: ' . (want =~# 'A' ? 'graph LR' : 'graph TD'), 'RENDER: ' . want], s:PLines())
  endfor
endfunction

function! Test_unclosed_and_indented_render() abort
  let g:mermaid_display = 'split'
  call s:Open('unclosed.md')
  4
  MermaidPreview
  call s:WaitRendered(3000)
  call assert_equal(['RENDER: graph LR', 'RENDER: U --> V'], s:PLines())
  call s:Open('indented.md')
  1
  MermaidPreview
  call s:WaitFor('get(s:PLines(), 1, "") =~# "I"', 3000)
  call assert_equal(['RENDER: graph LR', 'RENDER:   I --> J', 'RENDER: K --> L'], s:PLines())
endfunction

function! Test_renderer_error() abort
  let g:mermaid_display = 'split'
  call s:Open('fail.md')
  MermaidPreview
  call s:WaitRendered(3000)
  call assert_equal(['mermaid-ascii failed (exit 3):', 'fake error: unsupported'], s:PLines())
endfunction

function! Test_timeout() abort
  let g:mermaid_display = 'split'
  let g:mermaid_timeout_ms = 300
  call s:Open('hang.md')
  MermaidPreview
  call assert_true(s:WaitRendered(3000))
  call assert_equal(['mermaid-ascii timed out after 300 ms'], s:PLines())
endfunction

function! Test_missing_binary() abort
  let g:mermaid_display = 'split'
  let g:mermaid_ascii_cmd = '/nonexistent/mermaid-ascii'
  call s:Open('two.md')
  3
  let out = execute('MermaidPreview')
  call assert_match('g:mermaid_ascii_cmd', out)
  call assert_match('go install github.com/AlexanderGrooff/mermaid-ascii@latest', out)
  call assert_equal(1, winnr('$'))
endfunction

function! Test_cmd_path_with_space_and_args() abort
  let g:mermaid_display = 'split'
  call assert_match(' ', g:mermaid_ascii_cmd)
  let g:mermaid_ascii_args = ['-a', 'two words']
  call s:Open('two.md')
  3
  MermaidPreview
  call s:WaitRendered(3000)
  call assert_equal(['RENDER: graph LR', 'RENDER: A --> B'], s:PLines())
endfunction

function! Test_preview_all() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  MermaidPreviewAll
  call s:WaitFor('len(s:PLines()) == 6', 3000)
  call assert_equal(['-- line 3 --', 'RENDER: graph LR', 'RENDER: A --> B',
        \ '-- line 12 --', 'RENDER: graph TD', 'RENDER: C --> D'], s:PLines())
endfunction

function! Test_split_reuse_and_cursor_stays() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  let src = bufnr('%')
  3
  MermaidPreview
  let pbuf = s:PreviewBuf()
  call assert_equal(2, winnr('$'))
  call assert_equal(src, bufnr('%'))
  call assert_equal(3, line('.'))
  12
  MermaidPreview
  MermaidPreviewAll
  call assert_equal(2, winnr('$'))
  call assert_equal(pbuf, s:PreviewBuf())
  call assert_equal(src, bufnr('%'))
  call assert_equal('nofile', getbufvar(pbuf, '&buftype'))
  call assert_equal('mermaid-ascii', getbufvar(pbuf, '&filetype'))
  call assert_equal(0, getbufvar(pbuf, '&modifiable'))
  call assert_equal(0, getbufvar(pbuf, '&swapfile'))
endfunction

function! Test_vertical_and_horizontal() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_equal('row', winlayout()[0])
  MermaidClose
  let g:mermaid_split = 'horizontal'
  MermaidPreview
  call assert_equal('col', winlayout()[0])
endfunction

function! Test_close() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  3
  MermaidPreview
  let pbuf = s:PreviewBuf()
  MermaidClose
  call assert_equal(1, winnr('$'))
  call assert_false(bufexists(pbuf))
endfunction

function! Test_manual_quit_then_save_no_reopen() abort
  let g:mermaid_display = 'split'
  let g:mermaid_auto_refresh = 1
  call s:Open('two.md')
  3
  MermaidPreview
  call s:WaitRendered(3000)
  wincmd p
  call assert_true(exists('b:mermaid_preview'))
  quit
  call assert_equal(1, winnr('$'))
  silent write
  sleep 300m
  call assert_equal(1, winnr('$'))
endfunction

function! Test_close_during_delayed_render() abort
  let g:mermaid_display = 'split'
  call s:Open('delay.md')
  1
  MermaidPreview
  MermaidClose
  sleep 1500m
  call assert_equal(1, winnr('$'))
  call assert_equal(0, s:PreviewBuf())
endfunction

function! Test_new_preview_during_delayed_render() abort
  let g:mermaid_display = 'split'
  call s:Open('delay.md')
  1
  MermaidPreview
  6
  MermaidPreview
  let seen = []
  for i in range(150)
    call add(seen, join(s:PLines(), "\n"))
    sleep 10m
  endfor
  " The old job is killed; neither its output nor its exit may show.
  call assert_equal(-1, match(seen, 'DELAY\|failed'))
  call assert_equal(['RENDER: graph LR', 'RENDER: FAST'], s:PLines())
endfunction

function! Test_auto_refresh_off_by_default() abort
  let g:mermaid_display = 'split'
  call s:Open('two.md')
  3
  MermaidPreview
  call s:WaitRendered(3000)
  call setline(5, 'A --> Z')
  silent write
  sleep 300m
  call assert_equal(['RENDER: graph LR', 'RENDER: A --> B'], s:PLines())
endfunction

function! Test_auto_refresh_single() abort
  let g:mermaid_display = 'split'
  let g:mermaid_auto_refresh = 1
  call s:Open('two.md')
  12
  MermaidPreview
  call s:WaitRendered(3000)
  " The block moves down one line; the stored opener line is now blank.
  call append(0, 'new first line')
  call setline(15, 'C --> E')
  silent write
  call assert_true(s:WaitFor('index(s:PLines(), "RENDER: C --> E") >= 0', 3000), string(s:PLines()))
  " Delete the block: nothing at or after the stored line.
  silent 13,$delete
  silent write
  call assert_true(s:WaitFor('s:PLines() == ["mermaid: block not found"]', 3000), string(s:PLines()))
endfunction

function! Test_auto_refresh_all() abort
  let g:mermaid_display = 'split'
  let g:mermaid_auto_refresh = 1
  call s:Open('two.md')
  MermaidPreviewAll
  call s:WaitFor('len(s:PLines()) == 6', 3000)
  call setline(5, 'A --> Z')
  silent write
  call assert_true(s:WaitFor('index(s:PLines(), "RENDER: A --> Z") >= 0', 3000), string(s:PLines()))
  call assert_equal(6, len(s:PLines()))
endfunction

function! Test_save_other_buffer_does_not_touch_preview() abort
  let g:mermaid_display = 'split'
  let g:mermaid_auto_refresh = 1
  call s:Open('two.md')
  3
  MermaidPreview
  call s:WaitRendered(3000)
  let want = s:PLines()
  " Buffer B in another window of the same tab.
  split
  call s:Open('tilde.md')
  call setline(3, 'T --> W')
  silent write
  sleep 300m
  call assert_equal(want, s:PLines())
endfunction

" Smoke test with the real renderer. Skipped when mermaid-ascii is not on PATH.
function! Test_real_cli_flowchart() abort
  let g:mermaid_display = 'split'
  if !executable('mermaid-ascii')
    throw 'skip: mermaid-ascii not on PATH'
  endif
  let g:mermaid_ascii_cmd = 'mermaid-ascii'
  call s:Open('flowchart.md')
  4
  MermaidPreview
  call assert_true(s:WaitFor('join(s:PLines()) =~# "C"', 5000), string(s:PLines()))
  let text = join(s:PLines(), "\n")
  call assert_match('│ A ├', text)
  call assert_match('►│ C │', text)
endfunction

function! Test_plug_mapping() abort
  call assert_match('MermaidPreview', maparg('<Plug>(mermaid-preview)', 'n'))
endfunction

" ---- popup mode (headless) ----

function! s:PopupLines() abort
  let ids = popup_list()
  return empty(ids) ? [] : getbufline(winbufnr(ids[0]), 1, '$')
endfunction

function! s:WaitPopup(ms) abort
  return s:WaitFor('!empty(popup_list())', a:ms)
endfunction

" A delayed render must never show a popup.
function! s:AssertNoPopupFor(ms) abort
  let waited = 0
  while waited < a:ms
    call assert_equal([], popup_list())
    sleep 50m
    let waited += 50
  endwhile
endfunction

function! Test_popup_is_default() abort
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  call assert_equal(['RENDER: graph LR', 'RENDER: A --> B'], s:PopupLines())
  call assert_equal(1, winnr('$'))
  call assert_equal(0, s:PreviewBuf())
  let o = popup_getoptions(popup_list()[0])
  call assert_equal(' mermaid ', o.title)
  " An empty 'border' list means a border on all four sides.
  call assert_equal([], o.border)
  call assert_equal([0, 1, 0, 1], o.padding)
  let pos = popup_getpos(popup_list()[0])
  call assert_equal(pos.core_width + 4, pos.width)
  call assert_equal(pos.core_height + 2, pos.height)
  call assert_equal(0, o.wrap)
  call assert_equal(1, o.scrollbar)
  call assert_equal(0, o.resize)
  " popup_getoptions() does not report 'filtermode'; see
  " Test_term_cmdline_esc_not_eaten.
  call assert_equal(max([1, &lines - 4]), o.maxheight)
  call assert_equal(max([1, &columns - 4]), o.maxwidth)
  " 'moved': 'any' is stored as [lnum, col, col] of the cursor.
  call assert_equal(3, o.moved[0])
  call assert_equal(popup_list()[0], t:mermaid_popup.popup_id)
endfunction

function! Test_popup_filter_keys() abort
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  let id = popup_list()[0]
  let Filter = popup_getoptions(id).filter
  call assert_equal(0, Filter(id, 'j'))
  call assert_equal(0, Filter(id, ':'))
  call assert_equal([id], popup_list())
  call assert_equal(1, Filter(id, "\<Esc>"))
  call assert_equal([], popup_list())
  call assert_equal(0, t:mermaid_popup.popup_id)
endfunction

function! Test_popup_close_command() abort
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  MermaidClose
  call assert_equal([], popup_list())
  call assert_match('no preview popup in this tab', execute('MermaidClose'))
endfunction

function! Test_popup_close_during_delayed_render() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  MermaidClose
  call s:AssertNoPopupFor(1500)
  call assert_equal(0, t:mermaid_popup.req)
endfunction

function! Test_popup_new_request_during_delayed_render() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  6
  MermaidPreview
  let seen = []
  for i in range(150)
    call add(seen, join(s:PopupLines(), "\n"))
    sleep 10m
  endfor
  call assert_equal(-1, match(seen, 'DELAY\|failed'))
  call assert_equal(['RENDER: graph LR', 'RENDER: FAST'], s:PopupLines())
  call assert_equal(1, len(popup_list()))
endfunction

" Headless Vim does not fire CursorMoved by itself; doautocmd stands in for
" the event here. Test_term_* checks real event dispatch.
function! Test_popup_cursor_away_and_back_drops_result() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  2
  doautocmd <nomodeline> CursorMoved
  1
  call s:AssertNoPopupFor(1500)
endfunction

function! Test_popup_cursor_moved_drops_result() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  " No event: the snapshot check at show time drops it.
  2
  call s:AssertNoPopupFor(1500)
endfunction

function! Test_popup_window_switch_drops_result() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  split
  close
  call s:AssertNoPopupFor(1500)
endfunction

function! Test_popup_buffer_switch_drops_result() abort
  call s:Open('delay.md')
  let src = bufnr('%')
  1
  MermaidPreview
  enew
  execute 'buffer' src
  1
  call s:AssertNoPopupFor(1500)
endfunction

function! Test_popup_edit_drops_result() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  call setline(9, 'edited')
  call s:AssertNoPopupFor(1500)
endfunction

function! Test_popup_unchanged_delayed_result_shows() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  call assert_equal(['RENDER: DELAY', 'RENDER: graph LR'], s:PopupLines())
endfunction

function! Test_popup_tabs_are_independent() abort
  " Tab 1: a shown popup.
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  let id1 = popup_list()[0]
  " Tab 2: a pending render, then MermaidClose.
  tabnew
  call s:Open('delay.md')
  1
  MermaidPreview
  MermaidClose
  call assert_equal(id1, gettabvar(1, 'mermaid_popup').popup_id)
  call assert_false(empty(popup_getpos(id1)))
  " Tab 2: a new preview does not close tab 1's popup.
  6
  MermaidPreview
  call assert_true(s:WaitFor('len(popup_list()) == 2', 3000))
  call assert_false(empty(popup_getpos(id1)))
  call assert_equal(id1, gettabvar(1, 'mermaid_popup').popup_id)
  call assert_notequal(id1, t:mermaid_popup.popup_id)
endfunction

function! Test_popup_leaving_tab_drops_pending_render() abort
  call s:Open('delay.md')
  1
  MermaidPreview
  tabnew
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  sleep 1500m
  call assert_equal(1, len(popup_list()))
  call assert_equal(['RENDER: graph LR', 'RENDER: A --> B'], s:PopupLines())
  call assert_equal(0, gettabvar(1, 'mermaid_popup').req)
  call assert_equal(0, gettabvar(1, 'mermaid_popup').popup_id)
endfunction

function! Test_popup_renderer_error() abort
  call s:Open('fail.md')
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  call assert_equal(['mermaid-ascii failed (exit 3):', 'fake error: unsupported'], s:PopupLines())
endfunction

function! Test_popup_timeout() abort
  let g:mermaid_timeout_ms = 300
  call s:Open('hang.md')
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  call assert_equal(['mermaid-ascii timed out after 300 ms'], s:PopupLines())
endfunction

function! Test_popup_messages_stay_messages() abort
  call s:Open('none.md')
  call assert_match('no mermaid block under the cursor', execute('MermaidPreview'))
  call s:Open('empty.md')
  2
  call assert_match('empty mermaid block', execute('MermaidPreview'))
  call assert_equal([], popup_list())
endfunction

function! Test_popup_preview_all() abort
  call s:Open('two.md')
  MermaidPreviewAll
  call assert_true(s:WaitPopup(3000))
  call assert_equal(['-- line 3 --', 'RENDER: graph LR', 'RENDER: A --> B',
        \ '-- line 12 --', 'RENDER: graph TD', 'RENDER: C --> D'], s:PopupLines())
  call assert_equal(1, winnr('$'))
endfunction

function! Test_popup_oversized_output() abort
  enew
  call setline(1, ['```mermaid'] + map(range(100), '"N" . v:val') + ['```'])
  1
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  let pos = popup_getpos(popup_list()[0])
  call assert_equal(max([1, &lines - 4]), pos.core_height)
  call assert_equal(1, pos.scrollbar)
  call popup_clear(1)
  let g:mermaid_popup_maxheight = 5
  let g:mermaid_popup_maxwidth = 6
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  let pos = popup_getpos(popup_list()[0])
  call assert_equal(5, pos.core_height)
  call assert_equal(6, pos.core_width)
endfunction

function! Test_popup_no_auto_refresh() abort
  let g:mermaid_auto_refresh = 1
  call s:Open('two.md')
  3
  MermaidPreview
  call assert_true(s:WaitPopup(3000))
  call popup_clear(1)
  silent write
  call s:AssertNoPopupFor(300)
endfunction

function! Test_unknown_display_value() abort
  let g:mermaid_display = 'tab'
  call s:Open('two.md')
  3
  call assert_match("g:mermaid_display must be 'popup' or 'split'", execute('MermaidPreview'))
  call assert_match("g:mermaid_display must be 'popup' or 'split'", execute('MermaidPreviewAll'))
  sleep 300m
  call assert_equal([], popup_list())
  call assert_equal(1, winnr('$'))
endfunction

function! Test_popup_needs_popupwin() abort
  " Replace the script-local s:has_popup() to act like Vim without +popupwin.
  let sid = matchstr(execute('scriptnames'), '\d\+\ze: \S*autoload/mermaid\.vim')
  call assert_notequal('', sid)
  execute "function! <SNR>" . sid . "_has_popup()\nreturn 0\nendfunction"
  try
    call s:Open('two.md')
    3
    call assert_match('popup mode needs +popupwin', execute('MermaidPreview'))
    sleep 300m
    call assert_equal([], popup_list())
    call assert_equal(1, winnr('$'))
  finally
    execute "function! <SNR>" . sid . "_has_popup()\nreturn has('popupwin')\nendfunction"
  endtry
endfunction

function! Test_real_cli_popup() abort
  if !executable('mermaid-ascii')
    throw 'skip: mermaid-ascii not on PATH'
  endif
  let g:mermaid_ascii_cmd = 'mermaid-ascii'
  call s:Open('flowchart.md')
  4
  MermaidPreview
  call assert_true(s:WaitFor('join(s:PopupLines()) =~# "C"', 5000), string(s:PopupLines()))
  let text = join(s:PopupLines(), "\n")
  call assert_match('│ A ├', text)
  call assert_match('►│ C │', text)
endfunction

" ---- popup mode (real key events in a child Vim) ----

" Start a child Vim in a terminal window with the plugin and the fake renderer.
function! s:Term(name) abort
  if !has('terminal')
    throw 'skip: no +terminal'
  endif
  let dir = tempname()
  call mkdir(dir, 'p')
  call writefile(s:Fixture(a:name), dir . '/' . a:name)
  let buf = term_start(['vim', '-Nu', 'NONE', '-i', 'NONE', '-n',
        \ '--cmd', 'set rtp^=' . s:root, '--cmd', 'runtime plugin/mermaid.vim',
        \ '--cmd', 'let g:mermaid_ascii_cmd = ' . string(s:fake),
        \ dir . '/' . a:name], {'term_rows': 20, 'term_cols': 60, 'cwd': dir})
  call s:TermWaitFor(buf, '"' . a:name . '"', 3000)
  return buf
endfunction

function! s:Screen(buf) abort
  return join(map(range(1, 20), 'term_getline(a:buf, v:val)'), "\n")
endfunction

" The screen as one line, for assert messages.
function! s:Shot(buf) abort
  return join(map(split(s:Screen(a:buf), "\n"), 'substitute(v:val, "\\s\\+$", "", "")'), ' | ')
endfunction

function! s:TermWaitFor(buf, pat, ms) abort
  let waited = 0
  while s:Screen(a:buf) !~# a:pat && waited < a:ms
    call term_wait(a:buf, 20)
    let waited += 20
  endwhile
  return s:Screen(a:buf) =~# a:pat
endfunction

function! s:TermWaitGone(buf, pat, ms) abort
  let waited = 0
  while s:Screen(a:buf) =~# a:pat && waited < a:ms
    call term_wait(a:buf, 20)
    let waited += 20
  endwhile
  return s:Screen(a:buf) !~# a:pat
endfunction

function! s:TermStop(buf) abort
  call term_sendkeys(a:buf, "\<Esc>:qa!\r")
  call s:WaitFor('job_status(term_getjob(' . a:buf . ')) !=# "run"', 2000)
endfunction

function! Test_term_cursor_move_closes_popup() abort
  let buf = s:Term('two.md')
  call term_sendkeys(buf, ":3\r:MermaidPreview\r")
  call assert_true(s:TermWaitFor(buf, 'RENDER: A --> B', 3000), s:Shot(buf))
  call assert_match('mermaid', s:Shot(buf))
  call term_sendkeys(buf, 'j')
  call assert_true(s:TermWaitGone(buf, 'RENDER', 2000), s:Shot(buf))
  call s:TermStop(buf)
endfunction

function! Test_term_esc_closes_popup_other_keys_pass() abort
  let buf = s:Term('two.md')
  call term_sendkeys(buf, ":3\r:MermaidPreview\r")
  call assert_true(s:TermWaitFor(buf, 'RENDER: A --> B', 3000), s:Shot(buf))
  " 'x' does not move the cursor: the popup stays and the key reaches Vim.
  call term_sendkeys(buf, 'x')
  call assert_true(s:TermWaitFor(buf, '\n``mermaid', 2000), s:Shot(buf))
  call assert_match('RENDER: A --> B', s:Shot(buf))
  call term_sendkeys(buf, "\<Esc>")
  call assert_true(s:TermWaitGone(buf, 'RENDER', 2000), s:Shot(buf))
  call s:TermStop(buf)
endfunction

function! Test_term_cmdline_esc_not_eaten() abort
  let buf = s:Term('two.md')
  call term_sendkeys(buf, ":3\r:MermaidPreview\r")
  call assert_true(s:TermWaitFor(buf, 'RENDER: A --> B', 3000), s:Shot(buf))
  " Esc in Command-line mode must cancel the command line, not close the popup.
  call term_sendkeys(buf, ":abc")
  call assert_true(s:TermWaitFor(buf, '\n:abc', 2000), s:Shot(buf))
  call term_sendkeys(buf, "\<Esc>")
  call assert_true(s:TermWaitGone(buf, '\n:abc', 2000), s:Shot(buf))
  call assert_match('RENDER: A --> B', s:Screen(buf))
  call s:TermStop(buf)
endfunction

function! Test_term_cursor_away_and_back_drops_result() abort
  let buf = s:Term('delay.md')
  call term_sendkeys(buf, ":1\r:MermaidPreview\r")
  call term_wait(buf, 200)
  call term_sendkeys(buf, 'j')
  call term_wait(buf, 100)
  call term_sendkeys(buf, 'k')
  call assert_false(s:TermWaitFor(buf, 'RENDER: DELAY', 2000), s:Shot(buf))
  " Control: without a move the same render shows.
  call term_sendkeys(buf, ":MermaidPreview\r")
  call assert_true(s:TermWaitFor(buf, 'RENDER: DELAY', 3000), s:Shot(buf))
  call s:TermStop(buf)
endfunction

" ---- runner ----

let s:failed = 0
let s:results = []
for s:name in sort(map(split(execute('function /^Test_'), "\n"), 'matchstr(v:val, "Test_\\w\\+")'))
  call s:Setup()
  let v:errors = []
  try
    execute 'call ' . s:name . '()'
  catch /^skip:/
    call add(s:results, 'skip ' . s:name . ' (' . v:exception . ')')
    continue
  catch
    call add(v:errors, 'exception: ' . v:exception . ' @ ' . v:throwpoint)
  endtry
  if empty(v:errors)
    call add(s:results, 'ok   ' . s:name)
  else
    let s:failed += 1
    call add(s:results, 'FAIL ' . s:name)
    call extend(s:results, map(copy(v:errors), '"     " . v:val'))
  endif
endfor
call add(s:results, s:failed ? s:failed . ' failed' : 'all passed')
call writefile(s:results, $MERMAID_TEST_OUT)
if s:failed
  cquit!
endif
qall!
