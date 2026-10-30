" vim-mermaid: show Mermaid blocks of Markdown as ASCII art in a popup or a split.
if exists('g:loaded_mermaid')
  finish
endif
let g:loaded_mermaid = 1

command! -bar MermaidPreview call mermaid#preview()
command! -bar MermaidPreviewAll call mermaid#preview_all()
command! -bar MermaidClose call mermaid#close()

nnoremap <silent> <Plug>(mermaid-preview) <Cmd>MermaidPreview<CR>

augroup mermaid
  autocmd!
  autocmd BufWritePost * if get(g:, 'mermaid_auto_refresh', 0)
        \ | call mermaid#on_write(str2nr(expand('<abuf>')))
        \ | endif
augroup END
