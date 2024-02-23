import std/[options, os]


const httpRequestMaxHeadersDefaultSize* {.intdefine.}: uint16 = 2048
    ## The default maximum size of all headers in a request, in bytes


const HttpRequestMaxHeadersCount*: uint8 = 32

type BufView[T: SomeInteger] = object
    idx: uint16
    len: T

type HttpRequestHeaderView = object
    name: BufView[uint16]
    value: BufView[uint16]

type HttpRequestState* {.pure.} = enum
    ## All possible states of an HttpRequest object.
    ## These states determine which actions can be performed on an object.

    Ready = 0.uint8
        ## The object is ready to have a request parsed into it

    ReadingMethod = 1.uint8
        ## The request's method is being read

    ReadingUri = 2.uint8
        ## The request's URI is being read
    
    ReadingProtocol = 3.uint8
        ## The request's protocol version is being written

    ReadingHeaderName = 4.uint8
        ## A header's name is being read

    ReadingHeaderValue = 5.uint8
        ## A header's value is being read

    InvalidRequest = 6.uint8
        ## A malformed or otherwise request was received, so parsing was terminated.
        ## This can happen before or after headers have been read, so you must not try to read headers or metadata from the request when this state is set.
        ## This can happen if malformed headers are received, the HTTP protocol doesn't match, header data size exceeded capacity, or the request body could not be read.

    Done = 7.uint8
        ## The request's metadata and headers have been fully read.
        ## From this state onward, the request's headers have been fully read, and the request can safely be passed to a handler.
        ## There still may be a body to read, and in fact they may be a fragment of that body in the buffer after `headersEndIdx`.

type HttpRequest*[Size: static uint16] = object
    ## An HTTP/1.1 request.
    ## This object contains all state related to an HTTP request and the parsing of it.
    ## 
    ## It reads all request headers and metadata into a single statically-allocated buffer, and access to individual values are done through openArray views into that buffer.
    ## This design allows all data to be accessed without copying any memory.
    ## While the design allows requests to be parsed very efficiently, it does have a few caveats:
    ##  - Nice interfaces such as `string` and `Table` are absent; openArray and accessor procs are used instead
    ##  - Request headers and metadata cannot exceed the statically-determined capacity of the request buffer
    ##  - Request bodies must be streamed by the end user and are not read automatically
    ## 
    ## Additionally, you cannot assume that `openArray` values returned by getters that have a 0 length have an index that was ever set.
    ## This is because indexes for empty values sometimes aren't set to save time.

    stateEnum: HttpRequestState
        ## The request's current state

    buffer: array[Size, char]
        ## The buffer that stores the request

    bufferLen: uint16
        ## The current length of the content in the buffer

    headersEndIdx: uint16
        ## The last index of the request's headers.
        ## Will be 0 until the entire request is read.
        ## 
        ## May be less than bufferLen.
        ## If it is less than bufferLen, then it means the content after it is part of the request body, or another request's (possibly partial) headers.

    httpMethodView: BufView[uint8]
        ## View of the request's method

    uriView: BufView[uint16]
        ## View of the request's URI

    headerViews: array[HttpRequestMaxHeadersCount, HttpRequestHeaderView]
        ## Views of the request's headers

    headersCount: uint8
        ## The total number of headers read


func capacity*(this: HttpRequest): uint16 {.inline.} =
    ## Returns the capacity of the request's internal buffer in bytes.
    ## The buffer's capacity determines the total size of headers and metadata in total that it can store and process.

    return this.buffer.len


func reset*(this: var HttpRequest, overwriteBufferWithZeros: bool = true) {.inline.} =
    ## Resets this HttpRequest object to its default state, allowing it to parse another request.
    ## By default it overwrites the request's buffer with zeros for security, but this can be overridden.
    
    this.stateEnum = HttpRequestState.Ready

    if overwriteBufferWithZeros:
        for c in this.buffer.mitems:
            c = '\0'
    
    this.bufferLen = 0
    this.headersEndIdx = 0
    this.httpMethodView = BufView[uint8].default
    this.uriView = BufView[uint16].default
    this.headerViews = array[this.headerViews.len, HttpRequestHeaderView].default
    this.headersCount = 0


func setState(this: var HttpRequest, newState: HttpRequestState) {.inline.} =
    ## Sets the request's state

    this.stateEnum = newState


func viewToOpenArray(this: HttpRequest, view: BufView): openArray[char] {.inline.} =
    ## Converts a BufView to an openArray for an HttpRequest's buffer
    
    return this.buffer.toOpenArray(view.idx, view.idx + view.len - 1)


func state*(this: HttpRequest): HttpRequestState {.inline.} =
    ## Gets the request's current state
    
    return this.stateEnum


func httpMethod*(this: HttpRequest): openArray[char] {.inline.} =
    ## Gets the request method
    
    return this.viewToOpenArray(this.httpMethodView)


func uri*(this: HttpRequest): openArray[char] {.inline.} =
    ## Gets the request URI
    
    return this.viewToOpenArray(this.uriView)


func getHeader*(this: HttpRequest, name: openArray[char]): Option[openArray[char]] {.inline.} =
    ## Gets the value of the request header with the specified name (case-insensitive).
    ## If the header is not in the request, None will be returned.
    ## 
    ## If you just want to iterate over all headers, use the `headers` iterator.

    for i in 0.uint8 ..< this.headersCount:
        block nextHeader:
            let header = this.headerViews[i]

            # The names' lengths do not match
            if header.name.len.int != name.len:
                continue

            # Case-insensitive compare specified name and header name
            for j in 0 ..< name.len:
                let nameChar = name[j]
                let headChar = this.buffer[header.name.idx + j.uint16]

                if likely(
                    (nameChar.uint8 + (32 * (nameChar in 'A'..'Z').uint8)) != (headChar.uint8 + (32 * (headChar in 'A'..'Z').uint8))
                ):
                    break nextHeader

            return some this.viewToOpenArray(header.value)

    # No matching header was found
    return none[openArray[char]]()


iterator headers*(this: HttpRequest): (openArray[char], openArray[char]) {.inline.} =
    ## Iterates over all request headers.
    ## Headers are returned as a tuple of the name and value.
    ## The header name is in its original case.
    ## 
    ## If you just want to get a header by name (in a case-insensitive way), use `getHeader` instead.

    for i in 0.uint8 ..< this.headersCount:
        let hdr = this.headerViews[i]
        let name = hdr.name
        let val = hdr.value

        yield (
            this.buffer.toOpenArray(name.idx, name.idx + name.len - 1),
            this.buffer.toOpenArray(val.idx, val.idx + val.len - 1),
        )


func bufferFragment*(this: HttpRequest): openArray[char] {.inline.} =
    ## Returns the fragment of the request buffer that was left over after parsing.
    ## This may be empty, and if not, it is likely an incomplete part of the full request body.
    ## This proc should be used before streaming a request body.
    ## It could also be part of another incoming request.
    
    return this.buffer.toOpenArray(this.headersEndIdx, this.bufferLen - 1)


func initHttpRequest*(size: static uint16 = httpRequestMaxHeadersDefaultSize): HttpRequest[size] =
    ## Creates a new HTTP request, optionally with a custom buffer size

    return HttpRequest[size].default


func nextChunkInfo*(
    this: HttpRequest,
    desiredWriteSize: uint16 = httpRequestMaxHeadersDefaultSize,
): (ptr UncheckedArray[uint8], int) {.inline.} =
    ## Returns a pointer to the buffer to write the next chunk to, and the max number of bytes that can be written to it.
    ## Do not write more bytes than the number returned by this proc, otherwise memory corruption or crashing will occur.
    ## If the max size returned is 0, no more data can be written until the object is reset.
    ## If the request's status is `InvalidRequest` or `Done`, 0 will be returned for the max value, and the pointer will be nil.
    ## Assume that the returned pointer is nil if the max write size is 0.
    ## 
    ## Once data has been written, call `ingest`, specifying the number of bytes that were written.
    
    if this.stateEnum in HttpRequestState.InvalidRequest..HttpRequestState.Done:
        return (nil, 0)

    let maxSize = min(desiredWriteSize, this.buffer.len.uint16 - this.bufferLen).int

    return (cast[ptr UncheckedArray[uint8]](addr this.buffer[this.bufferLen]), maxSize)

func ingest*(this: var HttpRequest, chunkLen: int) {.inline.} =
    ## Ingests a new chunk of data and parses it.
    ## Call this after writing to the pointer provided by `nextChunkInfo`, specifying the number of bytes that were actually written.
    ## This proc will manipulate the request passed to it, notably updating its status.

    block exit:
        if this.stateEnum == HttpRequestState.Ready:
            this.stateEnum = HttpRequestState.ReadingMethod

        while this.stateEnum < HttpRequestState.InvalidRequest:
            template invalidReq(doBreak: static bool = true) =
                this.setState(HttpRequestState.InvalidRequest)

                when doBreak:
                    break

            if unlikely(chunkLen < 1):
                # Stream ended

                if unlikely(this.stateEnum < HttpRequestState.Done):
                    # The request wasn't finished parsing, so set its state to invalid
                    invalidReq(doBreak = false)

                    # TODO Return a specific error status
                
                # Nothing left to parse
                break

            let chunkEnd = this.bufferLen + chunkLen.uint16 - 1

            const protoName = "HTTP/1.1"
            const protoNameLen = protoName.len

            var i = this.bufferLen
            while i <= chunkEnd:
                var c = this.buffer[i]

                template finishReq() =
                    this.headersEndIdx = i + 1
                    this.setState(HttpRequestState.Done)

                if c == '\0':
                    # NUL isn't allowed in headers at all
                    invalidReq()

                    # TODO Return a specific error status

                case this.stateEnum:
                of HttpRequestState.ReadingMethod:
                    template mtd(): var BufView[uint8] = this.httpMethodView

                    if unlikely(c == ' '):
                        # Method fully read, progress state and set index of URI view
                        this.setState(HttpRequestState.ReadingUri)
                        this.uriView.idx = i + 1
                    else:
                        inc mtd().len

                of HttpRequestState.ReadingUri:
                    if unlikely(c == ' '):
                        # URI fully read, progress state.
                        # We cannot preemptively set the next header view index because we don't know if there will be any headers.
                        this.setState(HttpRequestState.ReadingProtocol)
                    else:
                        inc this.uriView.len

                of HttpRequestState.ReadingProtocol:
                    # We use the current index as our length tracker since we don't need to actually store the protocol version.
                    # We can derive the needed index from the URI view since it was the last thing to be read before the protocol.
                    let protoEndIdx = this.uriView.idx + this.uriView.len + protoNameLen + 2

                    if unlikely(i == protoEndIdx):
                        let beginIdx = protoEndIdx - protoNameLen - 2

                        # Offset range by -2 to account for trailing CR LF
                        if unlikely(
                            this.buffer[beginIdx] != protoName[0] and
                            this.buffer[beginIdx + 1] != protoName[1] and
                            this.buffer[beginIdx + 2] != protoName[2] and
                            this.buffer[beginIdx + 3] != protoName[3] and
                            this.buffer[beginIdx + 4] != protoName[4] and
                            this.buffer[beginIdx + 5] != protoName[5] and
                            this.buffer[beginIdx + 6] != protoName[6] and
                            this.buffer[beginIdx + 7] != protoName[7]
                        ):
                            # Unsupported protocol version
                            invalidReq()

                            # TODO Return a specific error status
                        else:
                            # Protocol is supported, progress state
                            this.setState(HttpRequestState.ReadingHeaderName)

                of HttpRequestState.ReadingHeaderName:
                    template hname(): var BufView[uint16] = this.headerViews[this.headersCount].name
                    template invalidChar(): bool =
                        c != '-' and
                        c notin '0'..'9' and
                        c notin 'A'..'Z' and
                        c != '_' and
                        c notin 'a'..'z'

                    template invalidCharErr() =
                        invalidReq()

                        # TODO Return a specific error status

                    # Whitespace is not allowed in the name reading phase, as described by RFC 7230 3.2.4 https://tools.ietf.org/html/rfc7230#section-3.2.4
                    # A proxy must be able to strip this whitespace out, but this code isn't intended to be used as a rugged proxy that gracefully
                    # handles malformed messages. If a malformed request comes in, we won't try to fix it.

                    if unlikely(hname().idx == 0):
                        # First character of the name

                        if unlikely(c == '\r'):
                            # Likely the beginning of the end for request headers
                            hname().idx = i
                        elif unlikely(invalidChar()):
                            # Invalid header name
                            invalidReq(doBreak = false)

                            if c == '\n':
                                # TODO Return specific error status about truncated header

                                break
                            else:
                                # TODO Return a specific error status about bad char

                                break
                        else:
                            hname().idx = i
                            inc hname().len

                    elif unlikely(hname().len == 0):
                        # The last character wasn't valid for the header name because its length wasn't incremented.
                        # This probably means the last character was \r.

                        if likely(c == '\n'):
                            # End of headers
                            finishReq()
                            break
                        else:
                            # Last character was presumably \r, but a \n did not follow
                            invalidCharErr()
                            
                    elif likely(not invalidChar()):
                        inc hname().len
                    elif likely(c == ':'):
                        # Header name fully read, progress state
                        this.setState(HttpRequestState.ReadingHeaderValue)
                    else:
                        invalidCharErr()
                
                of HttpRequestState.ReadingHeaderValue:
                    template hval(): var BufView[uint16] = this.headerViews[this.headersCount].value
                    template invalidChar(): bool = c notin ' '..'~'

                    template invalidCharErr() =
                        invalidReq()

                        # TODO Return a specific error status

                    template endHeader() =
                        inc this.headersCount

                        # Get ready to read next header, if any
                        this.setState(HttpRequestState.ReadingHeaderName)

                    if unlikely(hval().idx == 0):
                        # First character of value

                        if unlikely(c != ' '):
                            if unlikely(c == '\r'):
                                # Likely the beginning of the end for this header
                                hval().idx = i
                            elif unlikely(invalidChar()):
                                # Invalid value character
                                invalidCharErr()
                            else:
                                hval().idx = i
                                inc hval().len

                    elif unlikely(hval().len == 0):
                        if likely(c == '\n'):
                            # Header successfully read

                            endHeader()
                        else:
                            # Last character was presumably \r, but a \n did not follow
                            invalidCharErr()
                            
                    elif likely(c == '\n' and this.buffer[i - 1] == '\r'):
                        endHeader()
                    elif likely(not invalidChar()):
                        inc hval().len
                    elif unlikely(c != '\r'):
                        invalidCharErr()
                
                of HttpRequestState.InvalidRequest..HttpRequestState.Done, HttpRequestState.Ready:
                    # Anything that would have set it to InvalidRequest should have already returned, so we can handle these both the same
                    break

                inc i

            # Chunk read and processed
            this.bufferLen += chunkLen.uint16


runnableExamples:
    import std/[times]

    let testReqData = readFile("req.txt")

    var readCount = 0
    proc read(outputBuf: ptr UncheckedArray[char], readLen: int): int {.inline.} =
        let willRead = min(readLen, testReqData.len - readCount)

        for i in 0 ..< willRead:
            outputBuf[i] = testReqData[readCount + i]

        readCount += willRead

        return willRead

    let startTime = epochTime()

    var req = initHttpRequest()

    for i in 0 ..< 10_000_000:
        let (bufPtr, len) = req.nextChunkInfo(1024)

        req.ingest(read(bufPtr, len))
        req.reset()

        readCount = 0

    echo epochTime() - startTime
