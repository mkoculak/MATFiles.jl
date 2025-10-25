"""
    read_mat(file)

Read a Matlab MAT file from disk.
"""
function read_mat(file)
    open(file, "r") do io
        # Check the version of file.
        # MAT file v5 and newer starts with ascii-encoded "MATLAB", so we'll check the first four bytes
        magic = peek(io, UInt32)
        if magic != 0x4c54414d
            mFile = read_mat4(io, file)
        else
            # Parse information from the header
            version, endian, fsize = read_header(io)

            # Create an empty file to store pointer to stream and endian info
            mFile = MATFile(abspath(file), io, version, endian, NamedTuple())
            read_data!(mFile, fsize)
        end
        return mFile
    end
end

function read_header(io::IO)
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
        # @warn "File contains subsystem information, but no read function is implemented so it will be ignored."
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
        sNames, content = read_subsystem(mFile)

        push!(subContent, content)
    end

    @info subContent
    # Replace placeholders with data from the subsystem
    if !isempty(subContent)
        for (i, content) in enumerate(contents)
            # Skip all non-struct objects
            if !(typeof(content) <: NamedTuple)
                continue
            end
            # Special case for enums
            if haskey(content, :EnumerationInstanceTag)
                contents[i] = populate_enum(content, subContent)
            elseif haskey(content, :oIDs)
                contents[i] = subContent[1][1].MCOS[1][content.oIDs[1]].data
            end
        end
    end

    mFile.data = NamedTuple(zip(names, contents))

    return nothing
end

function populate_enum(content, subContent)
    className = subContent[1][1].MCOS[1][1].names[content.ClassName[1]]
    valueNames = [subContent[1][1].MCOS[1][1].names[x] for x in content.ValueNames]
    builtinClassName = subContent[1][1].MCOS[1][1].names[content.BuiltinClassName[1]]

    valObjects = [parse_metadata("", "", "", "", x) for x in content.Values]
    values = [subContent[1][1].MCOS[1][x.oIDs[1]].data for x in valObjects]

    return (; ClassName=className, ValueNames=valueNames, Values=values, ValueIndices=content.ValueIndices, BuiltinClassName=builtinClassName)
end
