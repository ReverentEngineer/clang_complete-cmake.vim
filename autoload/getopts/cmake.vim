"
" File: cmake.vim
" Author: Jeffrey Hill <jeff@reverentengineer.com>
"
" Description: A clang_complete get_opts for CMake Server
"

let g:cmake_build_path = 'build'
let g:cmake_generator = 'Unix Makefiles'

let s:cmake_server_cookie = 'vim'
let s:cmake_server_socket = '/tmp/cmake-vim'
let s:cmake_server_header = '[== "CMake Server" ==['
let s:cmake_server_footer = ']== "CMake Server" ==]'

function! getopts#cmake#getopts()

    let l:source = getcwd()
    let l:build = l:source.'/'.g:cmake_build_path
   
    call s:CMakeServerStart()
    sleep 100m
    call s:CMakeSetup(l:source, l:build, g:cmake_generator)
endfunction

function! s:CMakeServerStart() 
    " Remove any remnants of a socket
    call jobstart('rm '.s:cmake_server_socket)

    " Start a CMake Server
    let s:cmake_server_job = jobstart('cmake -E server --experimental --pipe='.s:cmake_server_socket)
    
    " Sleep to give the server time to startup
    sleep 100m

    " Connect to the CMake Server
    let s:cmake_socket = sockconnect('pipe', s:cmake_server_socket, { 'on_data': 'g:OnCMakeServerRead' })
endfunction

function! g:OnCMakeServerRead(channel, data, name)
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
    return chansend(s:cmake_socket, l:msg)
endfunction

" Send handshake message
function! s:CMakeSetup(source, build, generator) 
    if !exists('s:cmake_handshake_complete') || s:cmake_handshake_complete == 0
        let l:handshake = { 'cookie': s:cmake_server_cookie, 'type': 'handshake', 'sourceDirectory': a:source, 'buildDirectory': a:build, 'protocolVersion': s:cmake_server_supported_versions[0], 'generator': g:cmake_generator }
        call s:CMakeSendMessage(l:handshake)
    else 
        echoe 'CMake Server already connected'
    endif
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
            for target in project['targets']
                for fileGroup in target['fileGroups']
                    for includePath in fileGroup['includePath']
                        call insert(l:cmake_includes, includePath['path'])
                    endfor
                endfor
            endfor
        endfor
    endfor
    let l:cmake_includes = uniq(l:cmake_includes)
    for path in l:cmake_includes
        let b:clang_user_options .= ' -I'.path
    endfor
endfunction


