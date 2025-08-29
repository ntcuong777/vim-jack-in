function! s:warn(str) abort
  echohl WarningMsg
  echomsg a:str
  echohl None
  let v:warningmsg = a:str
endfunction

function! s:RunRepl(cmd, is_bg) abort
  if exists(':Start') == 2
    execute 'Start' . (a:is_bg ? '!' : '') a:cmd
  else
    call s:warn('dispatch.vim not installed, please install it.')
    if has('nvim')
      call s:warn('neovim detected, falling back on termopen()')
      tabnew
      call termopen(a:cmd)
      tabprevious
    endif
  endif
endfunction

function! jack_in#boot_cmd(...)
  let l:boot_string = 'boot -x -i "(require ''cider.tasks)"'
  for [dep, inj] in items(g:jack_in_injections)
    let l:boot_string .= printf(' -d %s:%s', dep, inj['version'])
  endfor
  let l:boot_string .= ' cider.tasks/add-middleware'
  for inj in values(g:jack_in_injections)
    let l:boot_string .= ' -m '.inj['middleware']
  endfor
  if a:0 > 0 && a:1 != ''
    let l:boot_task = join(a:000, ' ')
  else
    let l:boot_task = g:default_boot_task
  endif
  return l:boot_string.' '.l:boot_task
endfunction

function! jack_in#boot(is_bg,...)
  call s:RunRepl(call(function('jack_in#boot_cmd'), a:000), a:is_bg)
endfunction

function! jack_in#lein_cmd(...)
  let l:lein_string = 'lein'
  for [dep, inj] in items(g:jack_in_injections)
    let l:dep_vector = printf('''[%s "%s"]''', dep, inj['version'])
    if !get(inj, 'lein_plugin')
      let l:lein_string .= ' update-in :dependencies conj '.l:dep_vector.' --'
      let l:lein_string .= ' update-in :repl-options:nrepl-middleware conj '.inj['middleware'].' --'
    else
      let l:lein_string .= ' update-in :plugins conj '.l:dep_vector.' --'
    endif
  endfor
  if a:0 > 0 && a:1 != ''
    let l:lein_task = join(a:000, ' ')
  else
    let l:lein_task = g:default_lein_task
  endif

  return l:lein_string.' '.l:lein_task
endfunction

function! jack_in#lein(is_bg, ...)
  call s:RunRepl(call(function('jack_in#lein_cmd'), a:000), a:is_bg)
endfunction

function! jack_in#clj_cmd(...)
  let l:clj_string = 'clojure'
  let l:deps_map = '{:deps {nrepl/nrepl {:mvn/version "1.3.1"} '
  let l:cider_opts = '-e "(require ''nrepl.cmdline) (nrepl.cmdline/-main \"--interactive\" \"--middleware\" \"['

  for [dep, inj] in items(g:jack_in_injections)
    if has_key(inj, 'version')
      let l:deps_map .= dep . ' {:mvn/version "' . inj['version'] . '"} '
    endif
    let l:cider_opts .= ' '.inj['middleware']
  endfor

  let l:deps_map .= '}}'
  let l:cider_opts .= ']\")"'
  let l:m = '-M '

  for arg in a:000
    if arg =~ '^-M:'
      let l:m = ''
      break
    endif
  endfor

  return l:clj_string . ' -Sdeps ''' . l:deps_map . ''' ' . join(a:000, ' ') . ' ' . l:m . l:cider_opts . ' '
endfunction

function! jack_in#clj(is_bg, ...)
  call s:RunRepl(call(function('jack_in#clj_cmd'), a:000), a:is_bg)
endfunction

" --- Babashka: linked lifecycle (server + client, cleanup on exit) ---------

function! jack_in#bb_linked_cmd(...) abort
  let l:port = 1667
  if a:0 > 0 && a:1 != ''
    let l:first = split(a:1)[0]
    if l:first =~ '^\d\+$'
      let l:port = str2nr(l:first)
    endif
  endif

  " Resolve current buffer dir and write .nrepl-port
  let l:dir = expand('%:p:h')
  if empty(l:dir) || !isdirectory(l:dir)
    call s:warn('Could not determine current file directory to write .nrepl-port')
    let l:portfile = ''
  else
    let l:portfile = l:dir . '/.nrepl-port'
    try
      call writefile([string(l:port)], l:portfile)
    catch
      call s:warn('Failed to write .nrepl-port in ' . l:dir)
      let l:portfile = ''
    endtry
  endif

  " Create a temp runner script to avoid quote hell with -Sdeps
  let l:tmpdir = has('nvim') ? stdpath('cache') : ($TMPDIR !=# '' ? $TMPDIR : '/tmp')
  if empty(l:tmpdir)
    let l:tmpdir = '/tmp'
  endif
  let l:script = l:tmpdir . '/bb_nrepl_linked_' . getpid() . '_' . reltimefloat(reltime()) . '.sh'

  " Build the script contents (POSIX sh)
  let l:lines = []
  call add(l:lines, '#!/bin/sh')
  call add(l:lines, 'set -e')
  call add(l:lines, '')
  call add(l:lines, 'PORT=' . l:port)
  if !empty(l:portfile)
    " Quote the path safely
    call add(l:lines, 'PORTFILE=' . shellescape(l:portfile))
  else
    call add(l:lines, 'PORTFILE=''''')
  endif
  call add(l:lines, '')
  call add(l:lines, 'bb nrepl-server "$PORT" &')
  call add(l:lines, 'pid=$!')
  call add(l:lines, '')
  call add(l:lines, 'cleanup() {')
  call add(l:lines, '  kill "$pid" 2>/dev/null || true')
  call add(l:lines, '  [ -n "$PORTFILE" ] && rm -f "$PORTFILE" || true')
  call add(l:lines, '  rm -f "$0" 2>/dev/null || true')
  call add(l:lines, '}')
  call add(l:lines, 'trap cleanup EXIT INT TERM HUP')
  call add(l:lines, '')
  " brief wait so the server binds
  call add(l:lines, 'sleep 0.3')
  call add(l:lines, '')
  " Use single quotes here so EDN is not re-interpreted by the shell
  call add(l:lines, "clojure -Sdeps '{:deps {nrepl/nrepl {:mvn/version \"1.3.1\"}}}' -M -m nrepl.cmdline --connect --host localhost --port \"$PORT\"")
  call add(l:lines, '')

  " Write + chmod + return command to run the script
  try
    call writefile(l:lines, l:script, 'b')
    call system('chmod +x ' . shellescape(l:script))
  catch
    call s:warn('Failed to create runner script for bb nREPL')
    return ''
  endtry

  " Return the command to execute
  return 'sh ' . shellescape(l:script)
endfunction

" Launch the linked shell in an interactive terminal.
" We intentionally ignore the bang to keep this session foregrounded & linked.
function! jack_in#bb_linked(is_bg, ...) abort
  let l:cmd = call(function('jack_in#bb_linked_cmd'), a:000)
  if empty(l:cmd)
    return
  endif

  if exists(':Start') == 2
    " dispatch.vim foreground job
    execute 'Start' l:cmd
    return
  endif

  if has('nvim')
    " Neovim terminal
    tabnew
    call termopen(l:cmd)
    startinsert
    return
  endif

  if exists(':terminal') == 2
    " Vim 8 terminal
    execute 'terminal ' . l:cmd
    startinsert
    return
  endif

  call s:warn('No dispatch.vim, :terminal, or Neovim available to run interactive REPL.')
endfunction
