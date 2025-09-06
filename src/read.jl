function read_mat(file)
    open(file, "r") do io
        
        version, endian, fsize = parse_header(io)

        data = parse_data(io, fsize)

        return MATFile(abspath(file), version, endian, data)
    end
end

function parse_header(io::IO)
    # Check the version of file.
    # MAT file v4 starts with four bytes set to zero
    magic = peek(io, Int32)
    iszero(magic) && error("Detected MAT file v4 which is not implemented!")

    # Read the description
    desc = String(read(io, 116))
    @debug desc

    # Offset might contain information about presence of a subsystem-specific data.
    # All zeros or spaces indicate no information.
    allSpaces = reinterpret(Int64, fill(UInt8(' '), 8))[1]
    # Otherwise, interpret it as the end of standard elements and start of user defined ones.
    offset = read(io, Int64)
    @debug "File offset: $offset (should be either 0 or $allSpaces)"

    if iszero(offset) || isequal(offset, allSpaces)
        seekend(io)
        fsize = position(io)
        seek(io, 124)
    else
        @warn "File contains subsystem information, but no read function is implemented so it will be ignored."
        fsize = offset
    end

    # Version field in v5 should have 0x0100 in big endian encoding
    version = read(io, UInt16)
    version == 0x0100 || @warn "Version number mismatch, got $version (expected 0x0100)."
    endian = String(read(io, 2))

    return version, endian, fsize
end

function parse_data(io, fsize)
    return NamedTuple()
end