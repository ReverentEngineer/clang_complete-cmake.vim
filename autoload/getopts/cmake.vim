"
" File: cmake.vim
" Author: Jeffrey Hill <jeff@reverentengineer.com>
"
" Description: A clang_complete get_opts for CMake Server


if !exists('g:cmake_build_path')
    let g:cmake_build_path = 'build'
endif

if !exists('g:cmake_generator')
    let g:cmake_generator = 'Unix Makefiles'
endif

if !exists('g:cmake_server_socket')
    let g:cmake_server_socket = '/tmp/cmake-vim'
endif

let s:path = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:cmake_server_cookie = 'vim'
let s:cmake_server_header = "[== \"CMake Server\" ==["
let s:cmake_server_footer = "]== \"CMake Server\" ==]"

function! getopts#cmake#getopts()
    call s:IsCMakeServerRunning()
endfunction

function! s:IsCMakeServerRunning()
    let l:pgrep_cmd = 'pgrep -f "cmake -E server"'
    if has('nvim')
        call jobstart(l:pgrep_cmd, { 'on_exit': })
    elseif has('job')
        call job_start(l:pgrep_cmd, { 'on_exit': })
    else
        echoe "clang_complete-cmake: No job control supported in this version of vim."
    endif
endfunction

function! s:CMakeResultCheck(exit_status)
    if a:exit_status !=
        call s:CMakeServerStart()
        sleep 100m
    endif
    call s:CMakeServerConnect()
endfunction

function! s:NeovimCheck(job_id, data, event)
    call s:CMakeResultCheck(a:data)
endfunction

function! s:VimCheck(job, data)
    call s:CMakeResultCheck(a:data)
endfunction

function! s:CMakeServerStart() 
    let l:rm_socket_cmd = 'rm '.g:cmake_server_socket
    let l:cmake_server_cmd = 'cmake -E server --experimental --pipe='.g:cmake_server_socket
    if has('nvim')
        call jobstart(l:rm_socket_cmd)
        call jobstart(l:cmake_server_cmd, { 'detach': 1 })
    elseif has('job')
        call job_start(l:rm_socket_cmd)
        call job_start(l:cmake_server_cmd, { "stoponexit": "" })
    else
        echoe "clang_complete-cmake: No job control supported in this version of vim."
    endif
endfunction

function! s:CMakeServerConnect()
    if has('nvim')
        let s:cmake_socket = sockconnect('pipe', g:cmake_server_socket, { 'on_data': 'g:OnNeovimCMakeServerRead' })
    elseif has('job')
        let l:pipe_command = '/usr/bin/env nc -U '.g:cmake_server_socket
        let l:cmd_options = { 'out_cb': 'g:OnVimCMakeServerRead', 'out_mode': 'raw', 'in_mode': 'raw'}
        let s:cmake_server_pipe = job_start(l:pipe_command, l:cmd_options)
    else
        echoe "clang_complete-cmake: No job control supported in this version of vim."
    endif
endfunction

function! g:OnVimCMakeServerRead(channel, data)
    let l:index = 0
    let l:header = stridx(a:data, s:cmake_server_header, l:index)
    while l:header != -1
        let l:header = l:header + strlen(s:cmake_server_header) + 1 " +1 for newline
        let l:footer = stridx(a:data, s:cmake_server_footer, l:header)
        if l:header != -1 && l:footer != -1
            let l:length = l:footer - l:header
            let l:msg = strpart(a:data, l:header, l:length)

            let l:decoded_msg = json_decode(l:msg)
            call s:OnCMakeMessage(l:decoded_msg)

            let l:index = l:footer + strlen(s:cmake_server_footer)
            let l:header = stridx(a:data, s:cmake_server_header, l:index) 
        endif
    endwhile
endfunction

function! g:OnNeovimCMakeServerRead(channel, data, name)
    let l:message_begun = 0
    for item in a:data
        if item == s:cmake_server_header
            let l:message_begun = 1
        elseif item == s:cmake_server_footer
            let l:message_begun = 0
        elseif l:message_begun == 1
            let l:msg = json_decode(item)
            call s:OnCMakeMessage(msg)
        endif
    endfor
endfunction

function! s:OnCMakeMessage(msg) 
    let l:type = a:msg['type'] 
    if l:type== 'hello'
        let s:cmake_server_supported_versions = a:msg['supportedProtocolVersions']
        if exists('*FindRootDirectory')
            let l:source = FindRootDirectory()
        else 
            let l:source = getcwd()
        endif
        let l:build = l:source.'/'.g:cmake_build_path
        call s:CMakeSetup(l:source, l:build, g:cmake_generator)
    elseif l:type == 'reply'
        call s:OnCMakeReply(a:msg)
    elseif l:type == 'error'
        echoe a:msg['inReplyTo'].' caused: '.a:msg['errorMessage']
    endif
endfunction

function! s:OnCMakeReply(msg)
    let l:inReplyTo = a:msg['inReplyTo']
    if l:inReplyTo == 'handshake'
        let s:cmake_handshake_complete = 1
        call g:CMakeConfigure('')
    elseif l:inReplyTo == 'configure'
        let s:cmake_configured = 1
        call g:CMakeGenerate()
    elseif l:inReplyTo == 'compute'
        let s:cmake_generated = 1
        call g:CMakeGetCodeModel()
    elseif l:inReplyTo == 'codemodel'
        call s:CMakeParseCodeModel(a:msg)
    endif
endfunction

function! s:CMakeSendMessage(msg)
    let l:msg = "\n".s:cmake_server_header."\n".json_encode(a:msg)."\n".s:cmake_server_footer."\n"
    if has('nvim')
        let l:count = chansend(s:cmake_socket, l:msg)
    else 
        sleep 100m
        let l:count = strlen(ch_sendraw(s:cmake_server_pipe, l:msg))
    endif
    return l:count
endfunction

" Send handshake message
function! s:CMakeSetup(source, build, generator) 
    let l:handshake = { 'cookie': s:cmake_server_cookie, 'type': 'handshake', 'sourceDirectory': a:source, 'buildDirectory': a:build, 'protocolVersion': s:cmake_server_supported_versions[0], 'generator': g:cmake_generator }
    call s:CMakeSendMessage(l:handshake)
endfunction

" Send configure message
function! g:CMakeConfigure(cache_arguments)
    let l:configure = { 'cookie': s:cmake_server_cookie, 'type': 'configure', 'cacheArguments': a:cache_arguments }
    call s:CMakeSendMessage(l:configure)
endfunction

" Send compute message
function! g:CMakeGenerate()
    let l:compute = { 'cookie': s:cmake_server_cookie, 'type': 'compute' }
    call s:CMakeSendMessage(l:compute)
endfunction

" Request code model
function! g:CMakeGetCodeModel()
    let l:code_model = { 'cookie': s:cmake_server_cookie, 'type': 'codemodel' }
    call s:CMakeSendMessage(l:code_model)
endfunction

function! s:CMakeParseCodeModel(codemodel)
    let l:cmake_includes = []
    for configuration in a:codemodel['configurations']
        for project in configuration['projects']
            if has_key(project, 'targets')
                for target in project['targets']
                    if has_key(target, 'fileGroups')
                        for fileGroup in target['fileGroups']
                            if has_key(fileGroup, 'includePath')
                                for includePath in fileGroup['includePath']
                                    call insert(l:cmake_includes, includePath['path'])
                                endfor
                            endif
                        endfor
                    endif
                endfor
            endif
        endfor
    endfor
    let l:cmake_includes = uniq(l:cmake_includes)
    for path in l:cmake_includes
        let b:clang_user_options .= ' -I'.path
    endfor
endfunction


