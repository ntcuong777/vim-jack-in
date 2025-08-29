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

" --- Babashka --------------------------------------------------------------

function! jack_in#bb_linked_cmd(...) abort
  " Default port
  let l:port = 1667
  if a:0 > 0 && a:1 != ''
    let l:first = split(a:1)[0]
    if l:first =~ '^\d\+$'
      let l:port = str2nr(l:first)
    endif
  endif

  " Write .nrepl-port next to the current file
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

  " nREPL CLI client via tools.deps (ensure it's present with -Sdeps)
  let l:client = 'clojure -Sdeps ''{:deps {nrepl/nrepl {:mvn/version "1.3.1"}}}'' -M -m nrepl.cmdline --connect --host localhost --port ' . l:port

  " Build combined shell command
  let l:sh = []
  call add(l:sh, 'sh -c ''set -e;')
  call add(l:sh,                 'bb nrepl-server ' . l:port . ' &')
  call add(l:sh,                 'pid=$!;')
  " cleanup kills server and removes .nrepl-port if we wrote one
  if !empty(l:portfile)
    call add(l:sh, 'cleanup(){ kill "$pid" 2>/dev/null || true; rm -f ' . shellescape(l:portfile) . '; };')
  else
    call add(l:sh, 'cleanup(){ kill "$pid" 2>/dev/null || true; };')
  endif
  call add(l:sh,                 'trap cleanup EXIT INT TERM HUP;')
  call add(l:sh,                 'sleep 0.3;')
  call add(l:sh,                 l:client . ';''')

  return join(l:sh, ' ')
endfunction
