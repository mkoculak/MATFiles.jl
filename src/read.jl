function read_mat(file)
    open(file, "r") do io
        # Parse information from the header
        version, endian, fsize = read_header(io)

        # Create an empty file to store pointer to stream and endian info
        mFile = MATFile(abspath(file), f, version, endian, NamedTuple())
        read_data!(mFile, fsize)

        return mFile
    end
end

function read_header(mFile::MATFile)
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

# Main reading function
function read_data!(mFile::MATFile, fsize::Int)
    # Top level consists of subsequent matrices (not know upfront).
    # We'll collect their labels and contents to merge them into a NamedTuple at the end.
    labels = Symbol[]
    contents = Any[]

    while position(mFile) < fsize
        label, content = read_data(mFile)
        push!(labels, Symbol(label))
        push!(contents, content)
    end

    mFile.data = NamedTuple(zip(labels, contents))

    return nothing
end

# Reading top level structures (should always be matrices)
function read_data(mFile::MATFile)
    
end

function parse_tag(mFile::MATFile)
    # Check for compressed format
    temp = read(mFile, miUINT32)
    # In compressed, two higher bytes represent the size.
    # If they are zero, either this is a long format or an empty data container.
    if temp < 256
        dataType = get_dtype(temp)
        size = read(mFile, miUINT32)
        # Account for padding to 8 bytes
        psize = cld(size, 8) * 8
    else
        d, size = reinterpret(NTuple{2, UInt16}, temp)
        dataType = get_dtype(d)
        # Account for padding to 8 bytes
        psize = cld(size+4, 8) * 8 - 4
    end

    return dataType, size, psize
end