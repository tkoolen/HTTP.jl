# Based on src/http/ngx_http_parse.c from NGINX copyright Igor Sysoev
#
# Additional changes are licensed under the same terms as NGINX and
# copyright Joyent, Inc. and other Node contributors. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#

const start_state = s_start_req_or_res
const strict = true

mutable struct Parser
    state::UInt8
    header_state::UInt8
    index::UInt8
    flags::UInt8
    isheadresponse::Bool
    upgrade::Bool
    content_length::UInt64
    fieldbuffer::IOBuffer
    valuebuffer::IOBuffer
    method::HTTP.Method
    major::Int16
    minor::Int16
    url::HTTP.URI
    status::Int32
    onheader::Function
    onbody::Function
    onheaderscomplete::Function
end

Parser() = Parser(start_state, 0x00, 0, 0, false, false, 0, IOBuffer(), IOBuffer(), Method(0), 0, 0, HTTP.URI(), 0, x->nothing, x->nothing, ()->nothing)

const DEFAULT_PARSER = Parser()

function reset!(p::Parser)
    p.state = start_state
    p.header_state = 0x00
    p.index = 0x00
    p.flags = 0x00
    p.isheadresponse = false
    p.upgrade = false
    p.content_length = 0x0000000000000000
    truncate(p.fieldbuffer, 0)
    truncate(p.valuebuffer, 0)
    p.method = Method(0)
    p.major = 0
    p.minor = 0
    p.url = HTTP.URI()
    p.status = 0
    p.onheader = x->nothing
    p.onbody = x->nothing
    p.onheaderscomplete = ()->nothing
end

isrequest(p::Parser) = p.status == 0
headerscomplete(p::Parser) = p.state >= s_headers_done
messagecomplete(p::Parser) = p.state >= s_message_done
waitingforeof(p::Parser) = p.state == s_body_identity_eof
upgrade(p::Parser) = p.upgrade

struct ParsingError <: Exception
    code::ParsingErrorCode
    msg::String
end
ParsingError(code::ParsingErrorCode) = ParsingError(code, "")

function Base.show(io::IO, e::ParsingError)
    println(io, string("HTTP.ParsingError: ",
                       ParsingErrorCodeMap[e.code],
                       e.msg == "" ? "" : "\n",
                       e.msg))
end

"""
    HTTP.parse([HTTP.Request, HTTP.Response], str; kwargs...)

Parse a `HTTP.Request` or `HTTP.Response` from a string. `str` must contain at least one
full request or response (but may include more than one). Supported keyword arguments include:

  * `extra`: a `Ref{String}` that will be used to store any extra bytes beyond a full request or response
"""
function parse(T::Type{<:Union{Request, Response}}, str;
               extraref::Ref{SubArray{UInt8,1}}=Ref{SubArray{UInt8,1}}())

    r = T(body=FIFOBuffer())
    p = DEFAULT_PARSER
    reset!(p)
#    p.isheadresponse = method in ("HEAD", "CONNECT")
    p.onbody = x->write(r.body, x)
    p.onheader = x->appendheader(r, x)
    bytes = Vector{UInt8}(str)
    n = parse!(p, bytes)
    extra = view(bytes, n+1:length(bytes))
    if T == Request
        r.uri = p.url
        r.method = p.method
    else
        r.status = p.status
    end
    r.major = p.major
    r.minor = p.minor
    !headerscomplete(p) && throw(ParsingError(HPE_HEADERS_INCOMPLETE))
    if p.content_length != ULLONG_MAX && !messagecomplete(p)
        throw(ParsingError(HPE_BODY_INCOMPLETE))
    end
    if upgrade(p)
        extraref[] = extra
    end
    close(r.body)
    return r
end


macro errorif(cond, err)
    esc(:($cond && @err($err)))
end

macro err(code)
    esc(:(throw(ParsingError($code))))
end

macro strictcheck(cond)
    esc(:(strict && @errorif($cond, HPE_STRICT)))
end


const ByteView = typeof(view(UInt8[], 1:0))

parse!(p::Parser, bytes)::Int = parse!(p, view(bytes, 1:length(bytes)))

function parse!(parser::Parser, bytes::ByteView)::Int
    isempty(bytes) && throw(ArgumentError("bytes must not be empty"))
    len = length(bytes)
    @debug(PARSING_DEBUG, "parse!")
    p_state = parser.state
    @debug(PARSING_DEBUG, len)
    @debug(PARSING_DEBUG, ParsingStateCode(p_state))

    p = 0
    while p < len && p_state != s_message_done

        @debug(PARSING_DEBUG, "top of while($p < $len)")
        @debug(PARSING_DEBUG, ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])
        @debug(PARSING_DEBUG, Base.escape_string(string(ch)))

        if p_state == s_dead
            #= this state is used after a 'Connection: close' message
             # the parser will error out if it reads another message
            =#
            @errorif(ch != CR && ch != LF, HPE_CLOSED_CONNECTION)

        elseif p_state == s_start_req_or_res
            (ch == CR || ch == LF) && continue
            parser.flags = 0
            parser.content_length = ULLONG_MAX

            if ch == 'H'
                p_state = s_res_or_resp_H
            else
                p_state = s_start_req
                p -= 1
            end

        elseif p_state == s_res_or_resp_H
            if ch == 'T'
                p_state = s_res_HT
            else
                @errorif(ch != 'E', HPE_INVALID_CONSTANT)
                parser.method = HEAD
                parser.index = 3
                p_state = s_req_method
            end

        elseif p_state == s_start_res
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            if ch == 'H'
                p_state = s_res_H
            elseif ch == CR || ch == LF
            else
                @err HPE_INVALID_CONSTANT
            end

        elseif p_state == s_res_H
            @strictcheck(ch != 'T')
            p_state = s_res_HT

        elseif p_state == s_res_HT
            @strictcheck(ch != 'T')
            p_state = s_res_HTT

        elseif p_state == s_res_HTT
            @strictcheck(ch != 'P')
            p_state = s_res_HTTP

        elseif p_state == s_res_HTTP
            @strictcheck(ch != '/')
            p_state = s_res_first_http_major

        elseif p_state == s_res_first_http_major
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_res_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_res_http_major
            if ch == '.'
                p_state = s_res_first_http_minor
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major *= Int16(10)
            parser.major += Int16(ch - '0')
            @errorif(parser.major > 999, HPE_INVALID_VERSION)

        #= first digit of minor HTTP version =#
        elseif p_state == s_res_first_http_minor
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_res_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_res_http_minor
            if ch == ' '
                p_state = s_res_first_status_code
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor *= Int16(10)
            parser.minor += Int16(ch - '0')
            @errorif(parser.minor > 999, HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            if !isnum(ch)
                ch == ' ' && continue
                @err(HPE_INVALID_STATUS)
            end
            parser.status = Int32(ch - '0')
            p_state = s_res_status_code

        elseif p_state == s_res_status_code
            if !isnum(ch)
                if ch == ' '
                    p_state = s_res_status_start
                elseif ch == CR
                    p_state = s_res_line_almost_done
                elseif ch == LF
                    p_state = s_header_field_start
                else
                    @err(HPE_INVALID_STATUS)
                end
            else
                parser.status *= Int32(10)
                parser.status += Int32(ch - '0')
                @errorif(parser.status > 999, HPE_INVALID_STATUS)
            end

        elseif p_state == s_res_status_start
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                p_state = s_res_status
                parser.index = 1
            end

        elseif p_state == s_res_status
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            end

        elseif p_state == s_res_line_almost_done
            @strictcheck(ch != LF)
            p_state = s_header_field_start

        elseif p_state == s_start_req
            (ch == CR || ch == LF) && continue
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            @errorif(!isalpha(ch), HPE_INVALID_METHOD)

            parser.method = Method(0)
            parser.index = 2

            if ch == 'A'
                parser.method = ACL
            elseif ch == 'B'
                parser.method = BIND
            elseif ch == 'C'
                parser.method = CONNECT
            elseif ch == 'D'
                parser.method = DELETE
            elseif ch == 'G'
                parser.method = GET
            elseif ch == 'H'
                parser.method = HEAD
            elseif ch == 'L'
                parser.method = LOCK
            elseif ch == 'M'
                parser.method = MKCOL
            elseif ch == 'N'
                parser.method = NOTIFY
            elseif ch == 'O'
                parser.method = OPTIONS
            elseif ch == 'P'
                parser.method = POST
            elseif ch == 'R'
                parser.method = REPORT
            elseif ch == 'S'
                parser.method = SUBSCRIBE
            elseif ch == 'T'
                parser.method = TRACE
            elseif ch == 'U'
                parser.method = UNLOCK
            else
                @err(HPE_INVALID_METHOD)
            end
            p_state = s_req_method

        elseif p_state == s_req_method
            matcher = string(parser.method)
            @debug(PARSING_DEBUG, matcher)
            @debug(PARSING_DEBUG, parser.index)
            @debug(PARSING_DEBUG, Base.escape_string(string(ch)))
            if ch == ' ' && parser.index == length(matcher) + 1
                p_state = s_req_spaces_before_url
            elseif parser.index > length(matcher)
                @err(HPE_INVALID_METHOD)
            elseif ch == matcher[parser.index]
                @debug(PARSING_DEBUG, "nada")
            elseif isalpha(ch)
                ci = @shifted(parser.method, Int(parser.index) - 1, ch)
                if ci == @shifted(POST, 1, 'U')
                    parser.method = PUT
                elseif ci == @shifted(POST, 1, 'A')
                    parser.method =  PATCH
                elseif ci == @shifted(CONNECT, 1, 'H')
                    parser.method =  CHECKOUT
                elseif ci == @shifted(CONNECT, 2, 'P')
                    parser.method =  COPY
                elseif ci == @shifted(MKCOL, 1, 'O')
                    parser.method =  MOVE
                elseif ci == @shifted(MKCOL, 1, 'E')
                    parser.method =  MERGE
                elseif ci == @shifted(MKCOL, 2, 'A')
                    parser.method =  MKACTIVITY
                elseif ci == @shifted(MKCOL, 3, 'A')
                    parser.method =  MKCALENDAR
                elseif ci == @shifted(SUBSCRIBE, 1, 'E')
                    parser.method =  SEARCH
                elseif ci == @shifted(REPORT, 2, 'B')
                    parser.method =  REBIND
                elseif ci == @shifted(POST, 1, 'R')
                    parser.method =  PROPFIND
                elseif ci == @shifted(PROPFIND, 4, 'P')
                    parser.method =  PROPPATCH
                elseif ci == @shifted(PUT, 2, 'R')
                    parser.method =  PURGE
                elseif ci == @shifted(LOCK, 1, 'I')
                    parser.method =  LINK
                elseif ci == @shifted(UNLOCK, 2, 'S')
                    parser.method =  UNSUBSCRIBE
                elseif ci == @shifted(UNLOCK, 2, 'B')
                    parser.method =  UNBIND
                elseif ci == @shifted(UNLOCK, 3, 'I')
                    parser.method =  UNLINK
                else
                    @err(HPE_INVALID_METHOD)
                end
            elseif ch == '-' && parser.index == 2 && parser.method == MKCOL
                @debug(PARSING_DEBUG, "matched MSEARCH")
                parser.method = MSEARCH
                parser.index -= 1
            else
                @err(HPE_INVALID_METHOD)
            end
            parser.index += 1
            @debug(PARSING_DEBUG, parser.index)

        elseif p_state == s_req_spaces_before_url
            ch == ' ' && continue
            if parser.method == CONNECT
                p_state = s_req_server_start
            else
                p_state = s_req_url_start
            end
            p -= 1

        elseif @anyeq(p_state, s_req_url_start,
                               s_req_server_start,
                               s_req_server,
                               s_req_server_with_at,
                               s_req_path,
                               s_req_query_string_start,
                               s_req_query_string,
                               s_req_fragment_start,
                               s_req_fragment,
                               s_req_schema,
                               s_req_schema_slash,
                               s_req_schema_slash_slash)
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
                if @anyeq(ch, ' ', CR, LF)
                    @errorif(@anyeq(p_state, s_req_schema, s_req_schema_slash,
                                             s_req_schema_slash_slash,
                                             s_req_server_start),
                             HPE_INVALID_URL)
                    if ch == ' '
                        p_state = s_req_http_start
                    else
                        parser.major = Int16(0)
                        parser.minor = Int16(9)
                        p_state = ifelse(ch == CR, s_req_line_almost_done,
                                                   s_header_field_start)
                    end
                    break
                end
                p_state = URIs.parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, HPE_INVALID_URL)
                p += 1
            end

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state >= s_req_http_start
                @debug(PARSING_DEBUG, "onurl $parser.method $(String(parser.valuebuffer))")
                url = take!(parser.valuebuffer)
                parser.url = URIs.http_parser_parse_url(url, 1, length(url), parser.method == CONNECT)
            end

        elseif p_state == s_req_http_start
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(HPE_INVALID_CONSTANT)
            end

        elseif p_state == s_req_http_H
            @strictcheck(ch != 'T')
            p_state = s_req_http_HT

        elseif p_state == s_req_http_HT
            @strictcheck(ch != 'T')
            p_state = s_req_http_HTT

        elseif p_state == s_req_http_HTT
            @strictcheck(ch != 'P')
            p_state = s_req_http_HTTP

        elseif p_state == s_req_http_HTTP
            @strictcheck(ch != '/')
            p_state = s_req_first_http_major

        #= first digit of major HTTP version =#
        elseif p_state == s_req_first_http_major
            @errorif(ch < '1' || ch > '9', HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_req_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_req_http_major
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(HPE_INVALID_VERSION)
            else
                parser.major *= Int16(10)
                parser.major += Int16(ch - '0')
                @errorif(parser.major > 999, HPE_INVALID_VERSION)
            end

        #= first digit of minor HTTP version =#
        elseif p_state == s_req_first_http_minor
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_req_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_req_http_minor
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                #= XXX allow spaces after digit? =#
                @errorif(!isnum(ch), HPE_INVALID_VERSION)
                parser.minor *= Int16(10)
                parser.minor += Int16(ch - '0')
                @errorif(parser.minor > 999, HPE_INVALID_VERSION)
            end

        #= end of request line =#
        elseif p_state == s_req_line_almost_done
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_header_field_start
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                #= they might be just sending \n instead of \r\n so this would be
                 * the second \n to denote the end of headers=#
                p_state = s_headers_almost_done
                p -= 1
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), HPE_INVALID_HEADER_TOKEN)
                parser.index = 1
                p_state = s_header_field

                if c == 'c'
                    parser.header_state = h_C
                elseif c == 'p'
                    parser.header_state = h_matching_proxy_connection
                elseif c == 't'
                    parser.header_state = h_matching_transfer_encoding
                elseif c == 'u'
                    parser.header_state = h_matching_upgrade
                else
                    parser.header_state = h_general
                end

                write(parser.fieldbuffer, bytes[p])
            end

        elseif p_state == s_header_field
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug(PARSING_DEBUG, Base.escape_string(string(ch)))
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                if c == Char(0)
                    @errorif(ch != ':', HPE_INVALID_HEADER_TOKEN)
                    break
                end
                h = parser.header_state
                @debug(PARSING_DEBUG, h)
                if h == h_general

                elseif h == h_C
                    parser.index += 1
                    parser.header_state = c == 'o' ? h_CO : h_general
                elseif h == h_CO
                    parser.index += 1
                    parser.header_state = c == 'n' ? h_CON : h_general
                elseif h == h_CON
                    parser.index += 1
                    if c == 'n'
                        parser.header_state = h_matching_connection
                    elseif c == 't'
                        parser.header_state = h_matching_content_length
                    else
                        parser.header_state = h_general
                    end
                #= connection =#
                elseif h == h_matching_connection
                    parser.index += 1
                    if parser.index > length(CONNECTION) || c != CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONNECTION)
                        parser.header_state = h_connection
                    end
                #= proxy-connection =#
                elseif h == h_matching_proxy_connection
                    parser.index += 1
                    if parser.index > length(PROXY_CONNECTION) || c != PROXY_CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(PROXY_CONNECTION)
                        parser.header_state = h_connection
                    end
                #= content-length =#
                elseif h == h_matching_content_length
                    parser.index += 1
                    if parser.index > length(CONTENT_LENGTH) || c != CONTENT_LENGTH[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONTENT_LENGTH)
                        parser.header_state = h_content_length
                    end
                #= transfer-encoding =#
                elseif h == h_matching_transfer_encoding
                    parser.index += 1
                    if parser.index > length(TRANSFER_ENCODING) || c != TRANSFER_ENCODING[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(TRANSFER_ENCODING)
                        parser.header_state = h_transfer_encoding
                    end
                #= upgrade =#
                elseif h == h_matching_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(UPGRADE)
                        parser.header_state = h_upgrade
                    end
                elseif @anyeq(h, h_connection, h_content_length, h_transfer_encoding, h_upgrade)
                    if ch != ' '
                        parser.header_state = h_general
                    end
                else
                    error("Unknown header_state")
                end
                p += 1
            end

            if ch == ':'
                p_state = s_header_value_discard_ws
            else
                @assert tokens[Int(ch)+1] != Char(0) || !strict && ch == ' '
            end
            write(parser.fieldbuffer, view(bytes, start:p-1))

        elseif p_state == s_header_value_discard_ws
            (ch == ' ' || ch == '\t') && continue
            if ch == CR
                p_state = s_header_value_discard_ws_almost_done
                continue
            end
            if ch == LF
                p_state = s_header_value_discard_lws
                continue
            end
            p_state = s_header_value_start
            p -= 1
        elseif p_state == s_header_value_start
            p_state = s_header_value
            parser.index = 1
            c = lower(ch)

            if parser.header_state == h_upgrade
                parser.flags |= F_UPGRADE
                parser.header_state = h_general
            elseif parser.header_state == h_transfer_encoding
                #= looking for 'Transfer-Encoding: chunked' =#
                parser.header_state =  ifelse(c == 'c', h_matching_transfer_encoding_chunked, h_general)

            elseif parser.header_state == h_content_length
                @errorif(!isnum(ch), HPE_INVALID_CONTENT_LENGTH)
                @errorif((parser.flags & F_CONTENTLENGTH > 0) != 0, HPE_UNEXPECTED_CONTENT_LENGTH)
                parser.flags |= F_CONTENTLENGTH
                parser.content_length = UInt64(ch - '0')

            elseif parser.header_state == h_connection
                #= looking for 'Connection: keep-alive' =#
                if c == 'k'
                    parser.header_state = h_matching_connection_keep_alive
                #= looking for 'Connection: close' =#
                elseif c == 'c'
                    parser.header_state = h_matching_connection_close
                elseif c == 'u'
                    parser.header_state = h_matching_connection_upgrade
                else
                    parser.header_state = h_matching_connection_token
                end
            #= Multi-value `Connection` header =#
            elseif parser.header_state == h_matching_connection_token_start
            else
              parser.header_state = h_general
            end
            write(parser.valuebuffer, bytes[p])

        elseif p_state == s_header_value
            start = p
            h = parser.header_state
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug(PARSING_DEBUG, Base.escape_string(string('\'', ch, '\'')))
                @debug(PARSING_DEBUG, strict)
                @debug(PARSING_DEBUG, isheaderchar(ch))
                if ch == CR
                    p_state = s_header_almost_done
                    break
                elseif ch == LF
                    p_state = s_header_value_lws
                    break
                elseif strict && !isheaderchar(ch)
                    @err(HPE_INVALID_HEADER_TOKEN)
                end

                c = lower(ch)

                @debug(PARSING_DEBUG, h)
                if h == h_general
                    crlf = findfirst(x->(x == bCR || x == bLF), view(bytes, p:len))
                    p = crlf == 0 ? len : p + crlf - 2

                elseif h == h_connection || h == h_transfer_encoding
                    error("Shouldn't get here.")
                elseif h == h_content_length
                    t = UInt64(0)
                    if ch == ' '
                    else
                        if !isnum(ch)
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        t = parser.content_length
                        t *= UInt64(10)
                        t += UInt64(ch - '0')

                        #= Overflow? Test against a conservative limit for simplicity. =#
                        @debug(PARSING_DEBUG, "this content_length 1")
                        @debug(PARSING_DEBUG, Int(parser.content_length))
                        if div(ULLONG_MAX - 10, 10) < t
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        parser.content_length = t
                     end

                #= Transfer-Encoding: chunked =#
                elseif h == h_matching_transfer_encoding_chunked
                    parser.index += 1
                    if parser.index > length(CHUNKED) || c != CHUNKED[parser.index]
                        h = h_general
                    elseif parser.index == length(CHUNKED)
                        h = h_transfer_encoding_chunked
                    end

                elseif h == h_matching_connection_token_start
                    #= looking for 'Connection: keep-alive' =#
                    if c == 'k'
                        h = h_matching_connection_keep_alive
                    #= looking for 'Connection: close' =#
                    elseif c == 'c'
                        h = h_matching_connection_close
                    elseif c == 'u'
                        h = h_matching_connection_upgrade
                    elseif tokens[Int(c)+1] > '\0'
                        h = h_matching_connection_token
                    elseif c == ' ' || c == '\t'
                    #= Skip lws =#
                    else
                        h = h_general
                    end
                #= looking for 'Connection: keep-alive' =#
                elseif h == h_matching_connection_keep_alive
                    parser.index += 1
                    if parser.index > length(KEEP_ALIVE) || c != KEEP_ALIVE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(KEEP_ALIVE)
                        h = h_connection_keep_alive
                    end

                #= looking for 'Connection: close' =#
                elseif h == h_matching_connection_close
                    parser.index += 1
                    if parser.index > length(CLOSE) || c != CLOSE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(CLOSE)
                        h = h_connection_close
                    end

                #= looking for 'Connection: upgrade' =#
                elseif h == h_matching_connection_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(UPGRADE)
                        h = h_connection_upgrade
                    end

                elseif h == h_matching_connection_token
                    if ch == ','
                        h = h_matching_connection_token_start
                        parser.index = 1
                    end

                elseif h == h_transfer_encoding_chunked
                    if ch != ' '
                        h = h_general
                    end

                elseif @anyeq(h, h_connection_keep_alive, h_connection_close, h_connection_upgrade)
                    if ch == ','
                        if h == h_connection_keep_alive
                            parser.flags |= F_CONNECTION_KEEP_ALIVE
                        elseif h == h_connection_close
                            parser.flags |= F_CONNECTION_CLOSE
                        elseif h == h_connection_upgrade
                            parser.flags |= F_CONNECTION_UPGRADE
                        end
                        h = h_matching_connection_token_start
                        parser.index = 1
                    elseif ch != ' '
                        h = h_matching_connection_token
                    end

                else
                    p_state = s_header_value
                    h = h_general
                end
                p += 1
            end
            parser.header_state = h

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state != s_header_value
                parser.onheader(String(take!(parser.fieldbuffer)) =>
                                String(take!(parser.valuebuffer)))
            end

        elseif p_state == s_header_almost_done
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            p -= 1
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
            else
                #= finished the header =#
                if parser.header_state == h_connection_keep_alive
                    parser.flags |= F_CONNECTION_KEEP_ALIVE
                elseif parser.header_state == h_connection_close
                    parser.flags |= F_CONNECTION_CLOSE
                elseif parser.header_state == h_transfer_encoding_chunked
                    parser.flags |= F_CHUNKED
                elseif parser.header_state == h_connection_upgrade
                    parser.flags |= F_CONNECTION_UPGRADE
                end
                p_state = s_header_field_start
            end

        elseif p_state == s_header_value_discard_ws_almost_done
            @strictcheck(ch != LF)
            p_state = s_header_value_discard_lws

        elseif p_state == s_header_value_discard_lws
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_discard_ws
            else
                if parser.header_state == h_connection_keep_alive
                    parser.flags |= F_CONNECTION_KEEP_ALIVE
                elseif parser.header_state == h_connection_close
                    parser.flags |= F_CONNECTION_CLOSE
                elseif parser.header_state == h_connection_upgrade
                    parser.flags |= F_CONNECTION_UPGRADE
                elseif parser.header_state == h_transfer_encoding_chunked
                    parser.flags |= F_CHUNKED
                end

                #= header value was empty =#
                p_state = s_header_field_start
                parser.onheader(String(take!(parser.fieldbuffer)) => "")
                p -= 1
            end

        elseif p_state == s_headers_almost_done
            @strictcheck(ch != LF)
            p -= 1
            if (parser.flags & F_TRAILING) > 0
                #= End of a chunked request =#
                p_state = s_message_done
                continue
            end

            #= Cannot use chunked encoding and a content-length header together
            per the HTTP specification. =#
            @errorif((parser.flags & F_CHUNKED) > 0 && (parser.flags & F_CONTENTLENGTH) > 0, HPE_UNEXPECTED_CONTENT_LENGTH)

            p_state = s_headers_done
            parser.state = p_state
            parser.onheaderscomplete()

            #= Set this here so that on_headers_complete() callbacks can see it =#
            @debug(PARSING_DEBUG, "checking for upgrade...")
            if (parser.flags & F_UPGRADE > 0) && (parser.flags & F_CONNECTION_UPGRADE > 0)
                parser.upgrade = isrequest(parser) || parser.status == 101
            else
                parser.upgrade = isrequest(parser) && parser.method == CONNECT
            end
            @debug(PARSING_DEBUG, parser.upgrade)
            #= Here we call the headers_complete callback. This is somewhat
            * different than other callbacks because if the user returns 1, we
            * will interpret that as saying that this message has no body. This
            * is needed for the annoying case of recieving a response to a HEAD
            * request.
            *
            * We'd like to use CALLBACK_NOTIFY_NOADVANCE() here but we cannot, so
            * we have to simulate it by handling a change in errno below.
            =#
            @debug(PARSING_DEBUG, "headersdone")

        elseif p_state == s_headers_done
            @strictcheck(ch != LF)
            if parser.flags & F_CHUNKED > 0
                #= chunked encoding - ignore Content-Length header =#
                p_state = s_chunk_size_start
            elseif parser.isheadresponse ||
                   parser.content_length == 0 ||
                   parser.upgrade && isrequest(parser) && parser.method == CONNECT
                p_state = s_message_done
            elseif parser.content_length != ULLONG_MAX
                #= Content-Length header given and non-zero =#
                p_state = s_body_identity
            elseif http_message_needs_eof(parser)
                #= Read body until EOF =#
                p_state = s_body_identity_eof
            else
                #= Assume content-length 0 - read the next =#
                p_state = s_message_done
            end

        elseif p_state == s_body_identity
            to_read = Int(min(parser.content_length, len - p + 1))
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            parser.onbody(view(bytes, p:p + to_read - 1))

            #= The difference between advancing content_length and p is because
            * the latter will automaticaly advance on the next loop iteration.
            * Further, if content_length ends up at 0, we want to see the last
            * byte again for our message complete callback.
            =#
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_message_done
            end

        #= read until EOF =#
        elseif p_state == s_body_identity_eof
            parser.onbody(view(bytes, p:len))
            p = len

        elseif p_state == s_chunk_size_start
            assert(parser.flags & F_CHUNKED > 0)

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            assert(parser.flags & F_CHUNKED > 0)
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                @debug(PARSING_DEBUG, unhex_val)
                if unhex_val == -1
                    if ch == ';' || ch == ' '
                        p_state = s_chunk_parameters
                        continue
                    end
                    @err(HPE_INVALID_CHUNK_SIZE)
                end
                t = parser.content_length
                t *= UInt64(16)
                t += UInt64(unhex_val)

                #= Overflow? Test against a conservative limit for simplicity. =#
                @debug(PARSING_DEBUG, "this content_length 2")
                @debug(PARSING_DEBUG, Int(parser.content_length))
                if div(ULLONG_MAX - 16, 16) < t
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            assert(parser.flags & F_CHUNKED > 0)
            #= just ignore this shit. TODO check for overflow =#
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)

            if parser.content_length == 0
                parser.flags |= F_TRAILING
                p_state = s_header_field_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            to_read = Int(min(parser.content_length, len - p + 1))

            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            parser.onbody(view(bytes, p:p + to_read - 1))

            #= See the explanation in s_body_identity for why the content
            * length and data pointers are managed this way.
            =#
            parser.content_length -= to_read
            p += Int(to_read) - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length == 0)
            @strictcheck(ch != CR)
            p_state = s_chunk_data_done

        elseif p_state == s_chunk_data_done
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)
            p_state = s_chunk_size_start

        else
            error("unhandled state")
        end
    end
    @assert p_state == s_message_done || p == len || p == len + 1
    if p > len # FIXME
        p = len
    end

    parser.state = p_state

    @debug(PARSING_DEBUG, "exiting $(ParsingStateCode(p_state))")
    return p
end

#= Does the parser need to see an EOF to find the end of the message? =#
function http_message_needs_eof(parser)
    #= See RFC 2616 section 4.4 =#
    if (isrequest(parser) || # FIXME request never needs EOF ??
        div(parser.status, 100) == 1 || #= 1xx e.g. Continue =#
        parser.status == 204 ||     #= No Content =#
        parser.status == 304 ||     #= Not Modified =#
        parser.isheadresponse)       #= response to a HEAD request =#
        return false
    end

    if (parser.flags & F_CHUNKED > 0) || parser.content_length != ULLONG_MAX
        return false
    end

    return true
end

function http_should_keep_alive(parser)
    if parser.major > 0 && parser.minor > 0
        #= HTTP/1.1 =#
        if parser.flags & F_CONNECTION_CLOSE > 0
            return false
        end
    else
        #= HTTP/1.0 or earlier =#
        if !(parser.flags & F_CONNECTION_KEEP_ALIVE > 0)
            return false
        end
    end

  return !http_message_needs_eof(parser)
end
