import std/[httpcore]


const httpResponseMaxHeadersDefaultSize* {.intdefine.}: uint16 = 2048
    ## The default maximum size of all headers in a response, in bytes


type HttpResponseState* {.pure.} = enum
    ## All possible states of an HttpResponse object.
    ## These states determine which actions can be performed on an object.

    Ready = 0
        ## The object is ready to have a response status written to it
    
    WritingHeaders = 1
        ## Response headers are being written or are ready to be written

    Composed = 2
        ## The response status and headers are fully constructed and can be written to a socket

    Done = 3
        ## The response's headers have been fully read.
        ## From this state onward, the response's headers have been fully read, and the response can safely be reset without losing anything that was not already read.
        ## At this stage, it would make sense to write the response body.


when sizeof(HttpResponseState) > 1:
    {.fatal: "HttpResponseState enum values must not exceed 8 bits".}


type HttpResponse*[Size: static uint16] = object
    ## An HTTP/1.1 response.
    ## This object contains the response status and headers, but not body.
    ## 
    ## It facilitates construction of a response sequentially, starting with its status and then subsequent headers before finishing it.
    ## This allows the entire response to be written without the need to reorder headers or copy them into a final buffer before being written to a socket.
    ## While the design allows responses to be composed very efficiently, it does have a few caveats:
    ##  - Response objects are final, and cannot be modified (the objects can be reset, but not modified while composing them)
    ##  - Response headers cannot exceed the statically-determined capacity of the response buffer
    ##  - Response bodies must be written separately
    ## 
    ## This object type is best used for composition of responses, not as an intermediate object to modify and query.

    stateEnum: HttpResponseState
        ## The response's current state

    buffer: array[Size, char]
        ## The buffer that stores the response

    bufferLen: uint16
        ## The current length of the content in the buffer

    readLen: uint16
        ## The number of bytes marked as read by `markRead` so far


func capacity*(this: HttpResponse): uint16 {.inline.} =
    ## Returns the capacity of the response's internal buffer in bytes.
    ## The buffer's capacity determines the total size of headers and metadata in total that it can store.

    return this.buffer.len


func reset*(this: var HttpResponse, overwriteBufferWithZeros: bool = true) {.inline.} =
    ## Resets this HttpRespobse object to its default state, allowing it to parse another request.
    ## By default it overwrites the response's buffer with zeros for security, but this can be overridden.
    
    this.stateEnum = HttpResponseState.Ready

    if overwriteBufferWithZeros:
        for c in this.buffer.mitems:
            c = '\0'
    
    this.bufferLen = 0
    this.readLen = 0


func state*(this: HttpResponse): HttpResponseState {.inline.} =
    ## Gets the response's current state
    
    return this.stateEnum


template writeProtoHeader(buf) =
    buf[0] = 'H'
    buf[1] = 'T'
    buf[2] = 'T'
    buf[3] = 'P'
    buf[4] = '/'
    buf[5] = '1'
    buf[6] = '.'
    buf[7] = '1'
    buf[8] = ' '


type AddStatusResult* {.pure.} = enum
    ## Possible results of calling `addStatus`
    
    Success = 0.uint8
        ## Success
    
    BadState = 1.uint8
        ## The HttpResponse object's state was not Ready, and therefore a status could not be added.
        ## A status was probably already added.


func addStatus*(this: var HttpResponse, statusCode: SomeInteger or HttpCode, statusMessage: openArray[char]): AddStatusResult {.inline.} =
    ## Adds an HTTP status to the response, assuming one has not yet been added since initialization or `reset` was called.
    ## Performs no validity checks on the status code; assumes that it is between 100-599 (inclusive).
    ## There also no checks performed on the status message.

    if unlikely(this.stateEnum != HttpResponseState.Ready):
        return AddStatusResult.BadState

    writeProtoHeader(this.buffer)

    var codeTmp = statusCode.uint

    # Serialize status code manually for exactly 3 digits
    this.buffer[11] = char('0'.uint + codeTmp mod 10)
    codeTmp = codeTmp div 10
    this.buffer[10] = char('0'.uint + codeTmp mod 10)
    codeTmp = codeTmp div 10
    this.buffer[9] = char('0'.uint + codeTmp mod 10)

    this.buffer[12] = ' '

    let msgLen = statusMessage.len

    for i in 0 ..< msgLen:
        this.buffer[i + 13] = statusMessage[i]

    this.buffer[msgLen + 13] = '\r'
    this.buffer[msgLen + 14] = '\n'

    this.bufferLen = (msgLen + 15).uint16

    this.stateEnum = HttpResponseState.WritingHeaders

    return AddStatusResult.Success


func addStatus*(this: var HttpResponse, statusCode: HttpCode): AddStatusResult {.inline.} =
    ## Adds an HTTP status to the response, assuming one has not yet been added since initialization or `reset` was called

    if unlikely(this.stateEnum != HttpResponseState.Ready):
        return AddStatusResult.BadState

    writeProtoHeader(this.buffer)

    let statusStr = $statusCode
    let statusLen = statusStr.len

    for i in 0 ..< statusLen:
        this.buffer[i + 9] = statusStr[i]

    this.buffer[9 + statusLen] = '\r'
    this.buffer[10 + statusLen] = '\n'

    this.bufferLen = (11 + statusLen).uint16

    this.stateEnum = HttpResponseState.WritingHeaders

    return AddStatusResult.Success


func initHttpResponse*(size: static uint16 = httpResponseMaxHeadersDefaultSize): HttpResponse[size] {.inline.} =
    ## Initializes a new HttpResponse object.
    ## Note that `size` must be at least large enough to accomodate the initial headers size and trailing CRLF, which will be 52 bytes, which accomodates for the longest status message defined for `HttpCode`.

    when size < 52:
        {.fatal: "Your HTTP response's internal buffer must be at least 52 bytes long. This is the minimum size to accomodate the longest standard HTTP status message without any additional headers."}

    return HttpResponse[size](
        stateEnum: HttpResponseState.Ready,
        buffer: array[size, char].default,
        bufferLen: 0,
        readLen: 0,
    )


func isHeaderNameValid*(name: openArray[char]): bool {.inline.} =
    ## Returns whether the provided header name is valid according to the HTTP spec

    for c in name:
        if unlikely(
            c != '-' and
            c notin '0'..'9' and
            c notin 'A'..'Z' and
            c != '_' and
            c notin 'a'..'z'
        ):
            return false
    
    return true


func isHeaderValueValid*(value: openArray[char]): bool {.inline.} =
    ## Returns whether the provided header value is valid according to the HTTP spec
    
    for c in value:
        if unlikely(c notin ' '..'~'):
            return false
    
    return true


type AddHeaderResult* {.pure.} = enum
    ## Possible results of calling `addHeader`

    Success = 0.uint8
        ## Success
    
    BadState = 1.uint8
        ## The HttpResponse object's state was not WritingHeaders, and therefore no headers could be added.
        ## Either a status had not yet been added, or the response's headers were ended.
    
    InsufficientCapacity = 2.uint8
        ## The response's buffer does not have enough space left in it to write the header


func addHeader*(this: var HttpResponse, name: openArray[char], value: openArray[char]): AddHeaderResult {.inline.} =
    ## Adds a header to the response.
    ## 
    ## Performs no validity checks on names or values; assumes they are valid for insertion into HTTP responses.
    ## Use `isHeaderNameValid` and `isHeaderValueValid` to manually check them before making this call.
    ## 
    ## HTTP supports multiple headers with the same name, so no duplicate checks are performed.

    if unlikely(this.stateEnum != HttpResponseState.WritingHeaders):
        return AddHeaderResult.BadState

    let nameLen = name.len
    let valLen = value.len

    # Named lengths to avoid magic values
    const separatorLen = 2 # ": "
    const resEndLen = 4 # Trailing "\r\n\r\n"
    const extraCharsLen = separatorLen + resEndLen

    # Capacity check, taking into account the extra CRLF used for the end of the headers section
    if unlikely(nameLen + valLen + extraCharsLen + this.bufferLen.int > this.buffer.len):
        return AddHeaderResult.InsufficientCapacity

    # Write name
    for i in 0 ..< nameLen:
        this.buffer[this.bufferLen.int + i] = name[i]

    this.bufferLen += nameLen.uint16

    # Add separator
    this.buffer[this.bufferLen] = ':'
    this.buffer[this.bufferLen + 1] = ' '

    this.bufferLen += separatorLen

    # Write value
    for i in 0 ..< valLen:
        this.buffer[this.bufferLen.int + i] = value[i]

    this.bufferLen += valLen.uint16

    # Add trailing CRLF
    this.buffer[this.bufferLen] = '\r'
    this.buffer[this.bufferLen + 1] = '\n'

    this.bufferLen += 2

    return AddHeaderResult.Success


func endHeaders*(this: var HttpResponse) =
    ## Ends the response's headers section and makes it ready to be written to a socket

    this.buffer[this.bufferLen] = '\r'
    this.buffer[this.bufferLen + 1] = '\n'

    this.bufferLen += 2

    this.stateEnum = HttpResponseState.Composed


func nextChunkInfo*(
    this: HttpResponse,
    desiredReadSize: uint16 = httpResponseMaxHeadersDefaultSize,
): (ptr UncheckedArray[uint8], int) {.inline.} =
    ## Returns a pointer to the buffer to read the next chunk from, and the max number of bytes that can be read from it.
    ## Do not read more bytes than the number returned by this proc, otherwise crashing will occur or garbage will be read.
    ## If the max size returned is 0, no more data can be read until the object is reset.
    ## If the request's status is anything besides `Composed`, 0 will be returned for the max value, and the pointer will be nil.
    ## Assume that the returned pointer is nil if the max write size is 0.
    ## 
    ## Once data has been read, call `markRead`, specifying the number of bytes that were read.
    
    if unlikely(this.stateEnum != HttpResponseState.Composed):
        return (nil, 0)

    return (cast[ptr UncheckedArray[uint8]](addr this.buffer[this.readLen]), min(desiredReadSize, this.bufferLen - this.readLen).int)


func markRead*(this: var HttpResponse, len: SomeInteger) {.inline.} =
    ## Marks that X number of bytes have been read from the response.
    ## Call this after reading from the buffer pointer returned by `nextChunkInfo`, and make sure `len` is the exact number of bytes that were read from it.

    this.readLen += len.uint16

    if this.readLen >= this.bufferLen:
        this.stateEnum = HttpResponseState.Done
