function read_mat(file)
    open(file, "r") do io
        # Parse information from the header
        version, endian, fsize = read_header(io)

        # Create an empty file to store pointer to stream and endian info
        mFile = MATFile(abspath(file), io, version, endian, NamedTuple())
        read_data!(mFile, fsize)

        return mFile
    end
end

function read_header(io::IO)
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
    # We'll collect their names and contents to merge them into a NamedTuple at the end.
    names = Symbol[]
    contents = Any[]

    while position(mFile) < fsize
        name, content = read_data(mFile)
        push!(names, Symbol(name))
        push!(contents, content)
    end

    mFile.data = NamedTuple(zip(names, contents))

    return nothing
end

# Reading top level structures (should always be matrices)
function read_data(mFile::MATFile)
    dataType, size, psize = parse_tag(mFile)

    name, content = read_data(mFile, dataType, size)

    #Account for possible padding
    skip_padding!(mFile, size, psize)

    return name, content
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

function skip_padding!(mFile::MATFile, size, psize)
    if psize != size
        skip(mFile.io, psize - size)
    end
    return nothing
end

# Read the content of Matrix data type (should always contain other data types)
function read_data(mFile::MATFile, ::Type{miMATRIX}, size)
    # Account for empty matrices (always resolved to a numerical array)
    # Matlab uses them as placeholders for empty elements
    size == 0 && return "", Array{Float64}(undef, 0, 0)

    arrayType, c, g, l, nzmax = parse_flags(mFile)
    dims = parse_dimensions(mFile)
    name = parse_name(mFile)

    data = read_data(mFile, arrayType, dims, c)
    # # Add the imaginary part if matrix contains complex numbers
    # if c == '1'
    #     data = Complex.(data, read_data(mFile, arrayType, dims))
    # end

    return name, data
end

function parse_flags(mFile::MATFile)
    dataType, size, psize = parse_tag(mFile)

    # Written as UInt32, but data stored in separate bytes
    tmp = reinterpret(NTuple{4, UInt8}, read(mFile, dataType))
    # Get the importants bits for complex, global, and local flag
    _, _, _, _, c, g, l, _ = bitstring(tmp[2])
    arrayType = get_atype(tmp[1])

    # Second 4 bytes only used in sparse arrays
    nzmax = read(mFile, dataType)

    return arrayType, c, g, l, nzmax
end

function parse_dimensions(mFile::MATFile)
    dataType, size, psize = parse_tag(mFile)

    ndims = size ÷ sizeof(dataType)
    dims = read(mFile, dataType, ndims)

    #Account for possible padding
    skip_padding!(mFile, size, psize)

    return dims
end

function parse_name(mFile::MATFile)
    dataType, size, psize = parse_tag(mFile)
    name = String(read(mFile, size))

    skip_padding!(mFile, size, psize)
    return name
end

# Read matrix types containing numbers or chars
function read_data(mFile::MATFile, T::Type{<:NumArray}, dims, c)
    dataType, size, psize = parse_tag(mFile)

    tmp = read(mFile, dataType, dims)

    # Account for Matlab's compressing data into smaller types
    if T == mxCHAR_CLASS
        data = Char.(tmp)
    elseif ConvertType[dataType] != ConvertAType[T]
        data = similar(tmp, ConvertAType[T])
        data .= tmp
    else
        data = tmp
    end

    #Account for possible padding
    skip_padding!(mFile, size, psize)

    # Add the imaginary part if matrix contains complex numbers
    if c == '1'
        data = Complex.(data, read_data(mFile, T, dims, 0))
    end

    return data
end

# Read sparse matrix type
function read_data(mFile::MATFile, ::Type{mxSPARSE_CLASS}, dims, c)
    # Indices have the same structure as dimensions subelement, so we reuse the method
    rowIds = Int.(parse_dimensions(mFile))
    colIds = Int.(parse_dimensions(mFile)) .+ 1

    dataType, size, psize = parse_tag(mFile)

    # Parameter `dims` reflects full dimensions of the matrix, so we estimate the number
    # of elements from size from the tag
    N = size ÷ sizeof(dataType)
    data = read(mFile, dataType, N)

    #Account for possible padding
    skip_padding!(mFile, size, psize)

    # Add the imaginary part if matrix contains complex numbers
    if c == '1'
        data = Complex.(data, read(mFile, dataType, N))

        #Account for possible padding as both real and imaginary part should match is size
        skip_padding!(mFile, size, psize)
    end

    smatrix = SparseMatrixCSC(dims..., colIds, rowIds, data)
    return smatrix
end

function read_data(mFile::MATFile, ::Type{mxCELL_CLASS}, dims, c)
    data = Array{Any}(undef, Tuple(dims))

    for i in range(1,prod(dims))
        # We ignore the `name` as it should be empty
        name, tmp = read_data(mFile)
        data[i] = tmp
    end

    # Check if it can be easily brought into a concrete type
    if isconcretetype(typejoin(typeof.(data)...))
        data = identity.(data)
    end

    return data
end