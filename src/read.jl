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
    endian = String(read(io, 2))

    corr_ver = endian == "IM" ? 0x0100 : 0x0001
    version == corr_ver || @warn "Version number mismatch, got $version (expected $corr_ver)."

    return version, endian, fsize
end

# Main reading function
function read_data!(mFile::MATFile, fsize::Int)
    # Top level consists of subsequent matrices (not know upfront).
    # We'll collect their names and contents to merge them into a NamedTuple at the end.
    names = Symbol[]
    contents = Any[]

    while position(mFile) < fsize
        @info position(mFile) fsize
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

    name, data = read_data(mFile, arrayType, c)

    # Convert to Bool if proper flag is set
    if l == '1'
        data = Bool.(data)
    end

    return name, data
end

# Read variable compressed with zlib
function read_data(mFile::MATFile, ::Type{miCOMPRESSED}, size)
    # Switch the stream for the uncompressed and than revert it
    fileio = mFile.io
    mFile.io = ZlibDecompressorStream(IOBuffer(read(fileio, size)))

    dataType, size, psize = parse_tag(mFile)
    name, data = read_data(mFile, dataType, size)

    mFile.io = fileio

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
function read_data(mFile::MATFile, T::Type{<:NumArray}, c)
    dims = parse_dimensions(mFile)
    name = parse_name(mFile)

    dataType, size, psize = parse_tag(mFile)

    # Make sure declared size matches data type x dimensions of an array
    if size == 0
        emptyType = T == mxCHAR_CLASS ? Char : ConvertAType[T]
        tmp = Array{emptyType}(undef, 0,0)
    elseif sizeof(ConvertType[dataType]) * prod(dims) != size
        println(position(mFile))
        error("Requested array of type $(ConvertType[dataType]) \
        and dimensions $(Int.(dims)) does not match delcared size $size.")
    else
        tmp = read(mFile, dataType, dims)
    end

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
        dataType, size, psize = parse_tag(mFile)
        data = Complex.(data, read(mFile, dataType, dims))
        #Account for possible padding
        skip_padding!(mFile, size, psize)
    end

    return name, data
end

# Read sparse matrix type
function read_data(mFile::MATFile, ::Type{mxSPARSE_CLASS}, c)
    dims = parse_dimensions(mFile)
    name = parse_name(mFile)

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
        dataType, size, psize = parse_tag(mFile)
        data = Complex.(data, read(mFile, dataType, N))

        #Account for possible padding as both real and imaginary part should match is size
        skip_padding!(mFile, size, psize)
    end

    smatrix = SparseMatrixCSC(dims..., colIds, rowIds, data)
    return name, smatrix
end

# Read cell arrays
function read_data(mFile::MATFile, ::Type{mxCELL_CLASS}, c)
    dims = parse_dimensions(mFile)
    cName = parse_name(mFile)

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

    return cName, data
end

# Read struct arrays
function read_data(mFile::MATFile, ::Type{mxSTRUCT_CLASS}, c)
    dims = parse_dimensions(mFile)
    sName = parse_name(mFile)
    
    # Get the number of names/fields in the struct
    nameLen = parse_dimensions(mFile)
    fNames = parse_names(mFile, nameLen)

    structs = NamedTuple[]
    # Account for a matrix of structs
    for j in 1:prod(dims)
        fData = []
        for i in fNames
            name, data = read_data(mFile)
            push!(fData, data)
        end
        push!(structs, NamedTuple(zip(fNames, fData)))
    end
    # Using identity function to infer the common eltype of vector elements
    return sName, identity.(structs)
end

function parse_names(mFile::MATFile, nameLen)
    dataType, size, psize = parse_tag(mFile)

    nNames = Int(size ÷ nameLen[1])
    names = [read(mFile, dataType, nameLen[1]) for i in 1:nNames]

    #Account for possible padding
    skip_padding!(mFile, size, psize)

    names = map(x -> strip(String(Char.(x)), '\0'), names)

    # Need symbols for construction of a NamedTuple
    return Symbol.(names)
end
