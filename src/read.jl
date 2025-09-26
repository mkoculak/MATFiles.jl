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
    allSpaces = reinterpret(Int64, ntuple(i -> UInt8(' '), 8))
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
        name, content = read_data(mFile)
        push!(names, Symbol(name))
        push!(contents, content)
    end

    # Deal with subsystem data if present
    subContent = Any[]
    while !eof(mFile.io)
        content = read_subsystem(mFile)

        push!(subContent, content)
    end

    # Replace placeholders with data from the subsystem
    for (i, content) in enumerate(contents)
        if haskey(content, :oIDs)
            contents[i] = subContent[1][1].MCOS[1][content.oIDs[1]].data
        end
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
        emptyType = T == mxCHAR_CLASS ? Char : ConvertATypeMJ[T]
        tmp = Array{emptyType}(undef, 0,0)
    elseif sizeof(ConvertTypeMJ[dataType]) * prod(dims) != size
        println(position(mFile))
        error("Requested array of type $(ConvertTypeMJ[dataType]) \
        and dimensions $(Int.(dims)) does not match delcared size $size.")
    else
        tmp = read(mFile, dataType, dims)
    end

    # Account for Matlab's compressing data into smaller types
    if T == mxCHAR_CLASS
        data = Char.(tmp)
    elseif ConvertTypeMJ[dataType] != ConvertATypeMJ[T]
        data = similar(tmp, ConvertATypeMJ[T])
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

# Read objects of other classes (mostly types newer than v5 specs or custom made)
function read_data(mFile::MATFile, ::Type{mxOPAQUE_CLASS}, c)
    sName = parse_name(mFile)
    # Type system name
    tName = parse_name(mFile)
    # Class name
    cName = parse_name(mFile)
    # Object metadata
    name, metadata = read_data(mFile)

    # When type system is MCOS (Matlab Class Object System) we can use class name to check if we're in the subsystem
    if tName == "MCOS"
        if cName == "FileWrapper__"
            return sName, parse_cell_metadata(metadata)
        elseif metadata[1] == 0xdd000000 
            return sName, parse_metadata(mFile, tName, cName, name, metadata)
        else
            error("Expected 0xdd000000 as the first metadata field got $(metadata[1])")
        end
    end
end

function parse_cell_metadata(metadata)
    # Each cell in metadata contains different elements that need specialized parsing

    # Linking metadata
    linking = parse_linking(metadata)


    return linking, metadata[2:end]
end

function parse_linking(meta)
    metadata = meta[1]
    wrapperVersion, uniqueFields = reinterpret(Int32, metadata[1:8])
    # Always 8 Int32 offsets
    offsets = reinterpret(Int32, metadata[9:40])
    names = Char.(metadata[41:offsets[1]]) |> String |> x -> split(x, '\0', keepempty=false)

    # Class identifiers
    # WARN: made it into tuples, might need to change later
    cIden = reshape(reinterpret(Int32, metadata[offsets[1]+1:offsets[2]]), 4, :)
    cIden = tuple.(eachrow(cIden)...)

    # Object identifiers
    # WARN: made it into tuples, might need to change later
    oIden = reshape(reinterpret(Int32, metadata[offsets[3]+1:offsets[4]]), 6, :)
    oIden = tuple.(eachrow(oIden)...)

    # Type 2 Object property identifiers
    t2Idens = reinterpret(Int32, metadata[offsets[4]+1:offsets[5]])
    t2Iden = parse_object_identifiers(t2Idens)

    # Type 1 Object property identifiers
    t1Idens = reinterpret(Int32, metadata[offsets[2]+1:offsets[3]])
    t1Iden = parse_object_identifiers(t1Idens)

    # Dynamic property metadata
    dynProp = reinterpret(Int32, metadata[offsets[5]+1:offsets[6]])

    # Offsets 6 and 7 shouldn't have any information
    off6 = reinterpret(Int32, metadata[offsets[6]+1:offsets[7]])
    off7 = reinterpret(Int32, metadata[offsets[7]+1:offsets[8]])

    # Combine info from all regions
    objects = NamedTuple[]
    # Iterate over every object in the subsystem
    # Going in reversed order as nested types appear after the container
    for objIdx in reverse(1:length(oIden))
        obj = oIden[objIdx]
        # Skip the first empty row
        obj[1] == 0 && continue
        class = names[cIden[obj[1]+1][2]]
        objID = obj[6]

        if obj[4] != 0
            props = t1Iden[obj[4]]
        elseif obj[5] != 0
            props = t2Iden[obj[5]]
        else
            error("Couldn't parse object type properly.")
        end
        
        props = map(x -> (names[x[1]], x[2], x[3]), props)

        # Read the actual data of the object
        if class == "string"
            data = read_string(meta, props)
        elseif class == "duration"
            data = read_duration(meta, props)
        elseif class == "datetime"
            data = read_datetime(meta, props)
        else
            @warn "Reading not implemented for type \"$class\", writing a placeholder empty matrix instead."
            data = zeros(Float64,0,0)
        end

        # Correct the idx (for the first empty object) matching back to the objects in the main part of MAT file
        objIdx -= 1
        pushfirst!(objects, (; objIdx=objIdx, class=class, objID=objID, props=props, data=data))
    end

    return objects
end

function parse_object_identifiers(data)
    i = 1
    t2Iden = Any[]
    while i < length(data)
        if data[i] == 0
            i += 1
        else
            nBlocks = data[i]
            i += 1
            blocks = Tuple[]
            for j in 1:nBlocks
                push!(blocks, (data[i], data[i+1], data[i+2]))
                i += 3
            end
            push!(t2Iden, blocks)
        end
    end
    return t2Iden
end

function parse_metadata(mFile, tName, cName, name, metadata)
    # Parse object array dimensions from metadata
    nDims = Int(metadata[2])
    dims = Int.(metadata[3:2+nDims])

    # Get object IDs
    nIDs = prod(dims)
    oIDs = Int.(metadata[3+nDims:2+nDims+nIDs])

    # Get class ID (should be the last value)
    idx = 3+nDims+nIDs
    idx != length(metadata) && error("Metadata has more elements than expected")
    cID = metadata[idx]

    # Returning a named tuple of all metadata to be used while parsing subsystem info
    return (; name=name, tName=tName, cName=cName, dims=dims, nIDs=nIDs, oIDs=oIDs, cID=cID)
end

# Read subsystem specific data structures
function read_subsystem(mFile::MATFile)
    # First layer is a matrix-wrapper containing each subsystem element as a mxUINT8 matrix
    # However, it does contain typical MAT file objects, so we can't parse it as such

    # Should be a miMATRIX with full element size
    mdataType, msize, mpsize = parse_tag(mFile)
    # Should be a mxUINT8_CLASS with no flags and empty nzmax
    arrayType, c, g, l, nzmax = parse_flags(mFile)
    # Should be 1 x size
    dims = parse_dimensions(mFile)
    # Should be an empty name
    subName = parse_name(mFile)
    # Should be a miUINT8 tag
    dataType, size, psize = parse_tag(mFile)
    # Repeated version and endianess tags from the header
    version = read(mFile, UInt16)
    endian = String(read(mFile, 2))

    corr_ver = endian == "IM" ? 0x0100 : 0x0001
    version == corr_ver || @warn "Version number mismatch, got $version (expected $corr_ver)."
    # These are padded to 8 bytes
    skip_padding!(mFile, 4, 8)

    # Rest of the matrix should be contained in a struct that we can read as usual
    name, content = read_data(mFile)

    # These elements do not have names, so we are skipping the return
    return content
end

function value_or_default(elements, props, needle)
    nIdx = findfirst(x -> x[1] == needle, props)
    if !isnothing(nIdx)
        value = elements[3+props[nIdx][3]]
    else
        idx = findfirst(x -> !isempty(x) && Symbol(needle) in keys(x[1]), elements[end])
        value = elements[end][idx][1][Symbol(needle)]
    end

    return value
end

function read_datetime(elements, props)
    tz = value_or_default(elements, props, "tz")
    fmt = value_or_default(elements, props, "fmt")

    # Get the array with data
    dataIdx = props[map(x -> x[1]=="data", props)]
    # Data is of type double, but is storing integers
    data = Int64.(elements[3+dataIdx[1][3]])
    # Convert to Julia's DateTime
    data = DateTime.(UTM.(UNIXEPOCH .+ data))

    return data, fmt, tz
end

function read_duration(elements, props)
    # Check if format property is given or has to be fetched from the "default" properties container
    fmt = value_or_default(elements, props, "fmt")

    # Get the array with data
    millisIdx = props[map(x -> x[1]=="millis", props)]
    data = elements[3+millisIdx[1][3]]

    return data, fmt
end

function read_string(elements, props)
    # Check if we have only one property "any"
    if length(props) > 1 || props[1][1] != "any"
        error("Expected one property in string of class 'any', got $props")
    end

    # Find the element that holds the data - correct for offset in numbering
    element = elements[3+props[1][3]]

    version = element[1]
    nDims = element[2]
    dims = element[3:3+nDims-1]
    stringSizes = element[3+nDims:3+nDims+prod(dims)-1]
    # Convert the remaining elements to UInt16
    letters = reinterpret(UInt16, element[3+nDims+prod(dims):end])

    stringArray = fill("", dims...)
    ptr = 1
    for (i, sSize) in enumerate(stringSizes)
        # Skip sizes indicating missing string
        sSize == 0xffffffffffffffff && continue

        sSize = Int(sSize)
        stringArray[i] = String(Char.(letters[ptr:ptr+sSize-1]))
        ptr += sSize
    end

    return stringArray
end
