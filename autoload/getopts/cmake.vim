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

" If there are no cache arguments, set empty arguments. 
if !exists('g:cmake_cache_arguments')
    let g:cmake_cache_arguments = []
endif

let s:path = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:cmake_server_cookie = 'vim'
let s:cmake_server_header = "[== \"CMake Server\" ==["
let s:cmake_server_footer = "]== \"CMake Server\" ==]"
let s:cmake_server_socket = tempname()
let s:cmake_socket_buffer = ''
let s:message_begun = 0

function! getopts#cmake#getopts()
    call s:CMakeServerStart()
    sleep 100m
    call s:CMakeServerConnect()
endfunction

function! s:CMakeServerStart() 
    let l:rm_socket_cmd = 'rm '.s:cmake_server_socket
    let l:cmake_server_cmd = 'cmake -E server --experimental --pipe='.s:cmake_server_socket
    if has('nvim')
        call jobstart(l:rm_socket_cmd)
        call jobstart(l:cmake_server_cmd)
    elseif has('job')
        call job_start(l:rm_socket_cmd)
        call job_start(l:cmake_server_cmd)
    else
        echoe "clang_complete-cmake: No job control supported in this version of vim."
    endif
endfunction

function! s:CMakeServerConnect()
    if has('nvim')
        let s:cmake_socket = sockconnect('pipe', s:cmake_server_socket, { 'on_data': 'g:OnNeovimCMakeServerRead' })
    elseif has('job')
        let l:pipe_command = '/usr/bin/env nc -U '.s:cmake_server_socket
        let l:cmd_options = { 'out_cb': 'g:OnVimCMakeServerRead', 'out_mode': 'raw', 'in_mode': 'raw'}
        let s:cmake_server_pipe = job_start(l:pipe_command, l:cmd_options)
    else
        echoe "clang_complete-cmake: No job control supported in this version of vim."
    endif
endfunction

function! g:OnVimCMakeServerRead(channel, data)
    let l:index = 0
    let s:cmake_socket_buffer .= a:data
    let l:header = stridx(s:cmake_socket_buffer, s:cmake_server_header, l:index)
    while l:header != -1
        let l:header = l:header + strlen(s:cmake_server_header) + 1 " +1 for newline
        let l:footer = stridx(s:cmake_socket_buffer, s:cmake_server_footer, l:header)
        if l:header != -1 && l:footer != -1
            let l:length = l:footer - l:header
            let l:msg = strpart(s:cmake_socket_buffer, l:header, l:length)

            let l:decoded_msg = json_decode(l:msg)
            call s:OnCMakeMessage(l:decoded_msg)

            let l:index = l:footer + strlen(s:cmake_server_footer) + 1
            let l:header = stridx(s:cmake_socket_buffer, s:cmake_server_header, l:index) 
        endif
    endwhile
    if l:index < strlen(s:cmake_socket_buffer)
        let l:length = strlen(s:cmake_socket_buffer) - l:index
        let s:cmake_socket_buffer = strpart(s:cmake_socket_buffer, l:index, l:length)
    else
        let s:cmake_socket_buffer = ''
    endif
endfunction

function! g:OnNeovimCMakeServerRead(channel, data, name)
    for item in a:data
        if item == s:cmake_server_header
            let s:message_begun = 1
        elseif item == s:cmake_server_footer
            let l:msg = json_decode(s:cmake_socket_buffer)
            call s:OnCMakeMessage(l:msg)
            let s:cmake_socket_buffer = ''
            let s:message_begun = 0
        elseif s:message_begun == 1
            let s:cmake_socket_buffer .= item
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

        if len(l:source) > 0
            let l:build = l:source.'/'.g:cmake_build_path
            call s:CMakeSetup(l:source, l:build, g:cmake_generator)
        endif
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
        call g:CMakeConfigure(g:cmake_cache_arguments)
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
    let l:file_path=resolve(expand('%:p'))
    for configuration in a:codemodel['configurations']
        for project in configuration['projects']
            if has_key(project, 'targets')
                for target in project['targets']
                    if has_key(target, 'sourceDirectory')
                        let l:src_dir = resolve(target['sourceDirectory'])
                        if stridx(l:file_path, l:src_dir) == 0
                            if has_key(target, 'fileGroups')
                                for fileGroup in target['fileGroups']
                                    if has_key(fileGroup, 'sources')
                                        for src in fileGroup['sources']
                                            if l:file_path == l:src_dir.'/'.src
                                                if has_key(fileGroup, 'includePath')
                                                    for includePath in fileGroup['includePath']
                                                        let b:clang_user_options .= ' -I'.includePath['path']
                                                    endfor
                                                endif
                                                if has_key(fileGroup, 'defines')
                                                    for define in fileGroup['defines']
                                                        let b:clang_user_options .= ' -D'.define
                                                    endfor
                                                endif
                                                if has_key(fileGroup, 'compileFlags')
                                                    let b:clang_user_options .= fileGroup['compileFlags']
                                                endif
                                                return
                                            endif
                                        endfor
                                    endif
                                endfor
                            endif
                        endif
                    endif
                endfor
            endif
        endfor
    endfor
endfunction


