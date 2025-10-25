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

    @info "" wrapperVersion
    @info "" uniqueFields
    @info "" offsets
    @info "" names cIden
    @info "" oIden
    @info "" t2Iden
    @info "" t1Iden
    @info "" dynProp
    @info "" meta[end]
    # Combine info from all regions
    objects = NamedTuple[]
    # Iterate over every object in the subsystem
    # Going in reversed order as nested types appear after the container
    for objIdx in reverse(1:length(oIden))
        obj = oIden[objIdx]
        # @info obj
        # Skip the first empty row
        obj[1] == 0 && continue
        class = names[cIden[obj[1]+1][2]]
        objID = obj[6]

        if obj[4] != 0
            props = t1Iden[obj[4]]
        elseif obj[5] != 0
            if obj[5] > length(t2Iden)
                props = meta[end][obj[1]+1]
            else
                props = t2Iden[obj[5]]
            end
        else
            error("Couldn't parse object type properly.")
        end
        
        if !(typeof(props) <: Vector{<:NamedTuple})
            props = map(x -> (names[x[1]], x[2], x[3]), props)
        end

        # Read the actual data of the object
        if class == "calendarDuration"
            data = read_calendar_duration(meta, props)
        elseif class == "categorical"
            data = read_categorical(objects, meta, props)
        elseif class == "datetime"
            data = read_datetime(meta, props)
        elseif class == "dictionary"
            data = read_dictionary(objects, meta, props)
        elseif class == "duration"
            data = read_duration(meta, props)
        elseif class == "Map"
            data = read_map(objects, meta, props)
        elseif class == "string"
            data = read_string(meta, props)
        elseif class == "table"
            data = read_table(objects, meta, props)
        elseif class == "timetable"
            data = read_timetable(objects, meta, props)

        elseif class == "timeseries"
            data = read_timeseries(objects, meta, props)
        elseif class == "qualmetadata"
            data = read_qualmetadata(objects, meta, props)
        elseif class == "timemetadata"
            data = read_timemetadata(objects, meta, props)
        elseif class == "interpolation"
            data = read_interpolation(objects, meta, props)
        elseif class == "datametadata"
            data = read_datametadata(objects, meta, props)
        else
            @warn "Reading not implemented for type \"$class\", collecting properties into a NamedTuple."
            data = read_generic(objects, meta, props)
        end

        # Correct the idx (for the first empty object) matching back to the objects in the main part of MAT file
        objIdx -= 1
        pushfirst!(objects, (; objIdx=objIdx, class=class, objID=objID, props=props, data=data, names=names))
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

function parse_enum(mFile, tName, cName, name, metadata)
    # At this point there is not much more we can do to parse this
    return metadata[1]
end

# Read subsystem specific data structures
function read_subsystem(mFile::MATFile)
    # First layer is a matrix-wrapper containing each subsystem element as a mxUINT8 matrix
    # However, it does contain typical MAT file objects, so we can't parse it as such

    # Should be a miMATRIX with full element size
    mdataType, msize, mpsize = parse_tag(mFile)
    # Check if it is compressed and switch to uncompressed stream if necessary
    if mdataType == miCOMPRESSED
        tmp = ZlibDecompressorStream(IOBuffer(read(mFile.io, msize)))
        fileio = mFile.io
        mFile.io = tmp

        # Read the actual tag of uncompressed data
        mdataType, msize, mpsize = parse_tag(mFile)
    end

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
    names, content = read_data(mFile)

    # Revert to the original stream
    mFile.io = mdataType == miCOMPRESSED ? fileio : mFile.io

    # These elements do not have names, so we are skipping the return
    return names, content
end

function value_or_default(elements, props, needle)
    nIdx = findfirst(x -> x[1] == needle, props)
    if !isnothing(nIdx)
        value = elements[3+props[nIdx][3]]
        # Handle values packed into a NamedTuple
        if isa(value, Vector{<:NamedTuple})
            # Pick the first element (should be the only one)
            value = length(value) == 1 ? value[1] : error("Unexpected vector of proerties of length $(length(value))")
            
            defaults = get_defaults(elements, needle)
            defaults = isnothing(defaults) ? NamedTuple() : defaults[1]
            pNames = Symbol[]
            pContent = Any[]

            # Check if each property is empty and take the default if that exists and is not empty
            for k in keys(value) 
                content = isempty(value[k]) ? get(defaults, k, value[k]) : value[k]
                push!(pNames, k)
                push!(pContent, content)
            end

            # Add properties that are only in defaults
            for k in keys(defaults)
                if !haskey(value, k)
                    push!(pNames, k)
                    push!(pContent, defaults[k])
                end
            end
        end
    else
        value = get_defaults(elements, needle)
    end

    return value
end

function get_defaults(elements, needle)
    idx = findfirst(x -> !isempty(x) && Symbol(needle) in keys(x[1]), elements[end])
    return isnothing(idx) ? nothing : elements[end][idx][1][Symbol(needle)]
end

function read_calendar_duration(elements, props)
    # Both properties and defaults are bundled in a NamedTuple
    cmps = value_or_default(elements, props, "components")
    fmt = value_or_default(elements, props, "fmt")

    if typeof(cmps) <: AbstractVector
        data = Matrix{Float64}(undef,0,0)
    else
        data = @. Month(cmps.months) + Day(cmps.days) + Millisecond(cmps.millis)
    end

    # TODO: Fix formating as it is ignored right now
    return data, fmt
end

function read_generic(objects, elements, props)
    propVec = []

    for prop in props
        push!(propVec, Symbol(prop[1]) => value_or_default(elements, props, prop[1]))
    end

    return (; propVec...)
end

function read_categorical(objects, elements, props)

    categoryNames = value_or_default(elements, props, "categoryNames")
    codes = value_or_default(elements, props, "codes")
    isProtected = value_or_default(elements, props, "isProtected")
    isOrdinal = value_or_default(elements, props, "isOrdinal")

    # Cleaning up types
    categoryNames = String.(vec.(categoryNames))
    codes = Int.(codes)
    # Returning as a NamedTuple as there is no categorical array type in Julia Base
    return (; categoryNames=categoryNames, codes=codes, isProtected=isProtected, isOrdinal=isOrdinal)
end

function read_datetime(elements, props)
    tz = value_or_default(elements, props, "tz")
    fmt = value_or_default(elements, props, "fmt")

    # Get the array with data
    dataIdx = props[map(x -> x[1]=="data", props)]
    if isempty(dataIdx)
        data = Matrix{Float64}(undef,0,0)
    else
        # Data is of type double, but is storing integers
        data = Int64.(elements[3+dataIdx[1][3]])
        # Convert to Julia's DateTime
        data = DateTime.(UTM.(UNIXEPOCH .+ data))
    end

    # TODO: Fix formating and timezone inclusion as it is ignored right now
    return data, fmt, tz
end

# Checks if the element is an object and if so returns the actual contents
function nested_object_check(element, objects)
    if eltype(element) == UInt32 && get(element, 1, nothing) == 0xdd000000
        # Minimal call to extract important metadata
        meta = parse_metadata("", "", "", "", element)
        dIdx = findfirst(x -> x.objIdx == meta.oIDs[1], objects)
        # Error if we cannot find the nested data
        isnothing(dIdx) && error("Nested object not parsed yet!")
        return objects[dIdx].data
    else
        return element
    end
end

function read_dictionary(objects, elements, props)
    data = value_or_default(elements, props, "data")

    # Check if the dictionary is empty
    haskey(data, :Unconfigured) && return Dict()

    # TODO: We perform this check in many objects - probably should abstract it
    # Check if the keys are another object
    dKey = nested_object_check(data.Key, objects)

    # Check if the values are another object
    dVal = nested_object_check(data.Value, objects)

    return Dict(zip(dKey, dVal))
end

function read_duration(elements, props)
    # Check if format property is given or has to be fetched from the "default" properties container
    fmt = value_or_default(elements, props, "fmt")

    # Get the array with data
    millisIdx = props[map(x -> x[1]=="millis", props)]
    if isempty(millisIdx)
        data = Matrix{Float64}(undef,0,0)
    else
        data = elements[3+millisIdx[1][3]]
    end

    return data, fmt
end

function read_map(objects, elements, props)
    serialization = value_or_default(elements, props, "serialization")

    # Possible types: 'char' (default) | 'double' | 'single' | 'int32' | 'uint32' | 'int64' | 'uint64'
    keyType = String(vec(serialization.keyType))
    keys = serialization.keys
    if keyType == "char"
        keys = String.(vec.(keys))
    end
    # Can be of 'any' type | 'char' | 'bool'| numerical
    # Matlab allows for assigning e.g. strings as values, but can't properly read back non-ascii characters
    valueType = String(vec(serialization.valueType))
    values = serialization.values
    if valueType == "char"
        values = String.(vec.(values))
    end
    
    return Dict(zip(keys, values))
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

function read_table(objects, elements, props)
    # Seems to have only the data property defaults, we will assume for now that that is always non-empty
    nDims = value_or_default(elements, props, "ndims")
    nRows = value_or_default(elements, props, "nrows")
    rowNames = value_or_default(elements, props, "rownames")
    nVars = value_or_default(elements, props, "nvars")
    varNames = value_or_default(elements, props, "varnames")
    # Parsing this generically does not work right now, so we'll do it manually
    pIdx = findfirst(x -> x[1] == "props", props)

    if isnothing(pIdx)
        data = Matrix{Float64}(undef,0,0)
    else
        prop = elements[3+props[pIdx][3]][1]

        data = value_or_default(elements, props, "data")
    end

    # Check if any column is actually a nested object from subsystem
    for (i, col) in enumerate(data)
        data[i] = nested_object_check(col, objects)
    end

    # For now we will treat a table as a NamedTuple of equal matrices
    if isempty(data)
        return(; data=data)
    else
        return (; zip(Symbol.(String.(vec.(varNames))), data)...)
    end
end

function read_timetable(objects, elements, props)
    prop = value_or_default(elements, props, "any")

    cNames = vec(String.(vec.(prop.varNames)))
    data = prop.data

    # Time stored as another object - exctracting the location and data
    meta = parse_metadata("", "", "", "", prop.rowTimes)
    dIdx = findfirst(x -> x.objIdx == meta.oIDs[1], objects)
    # Error if we cannot find the nested data
    isnothing(dIdx) && error("Nested object not parsed yet!")

    # WARN: Only extracting timestamps igoring all metadata
    times = vec(objects[dIdx].data[1])
    pushfirst!(cNames, "Time")

    return (; zip(Symbol.(cNames), [times, data...])...)
end

function read_timeseries(objects, elements, props)
    # @info props
    name = value_or_default(elements, props, "Name")
    dInfo = value_or_default(elements, props, "DataInfo")
    dInfo = nested_object_check(dInfo, objects)

    tInfo = value_or_default(elements, props, "TimeInfo")
    tInfo = nested_object_check(tInfo, objects)

    qInfo = value_or_default(elements, props, "QualityInfo")
    qInfo = nested_object_check(qInfo, objects)

    data = value_or_default(elements, props, "Data_")

    return (; Name=name, DataInfo=dInfo, TimeInfo=tInfo, QualityInfo=qInfo, Data_=data)
end

function read_qualmetadata(objects, elements, props)
    code = value_or_default(elements, props, "Code")
    desc = value_or_default(elements, props, "Description")
    uData = value_or_default(elements, props, "UserData")

    return (; Code=code, Description=desc, UserData=uData)
end

function read_timemetadata(objects, elements, props)
    # TODO: Make parsing more specific
    return read_generic(objects, elements, props)
end

function read_interpolation(objects, elements, props)
    fHandle = value_or_default(elements, props, "Fhandle")
    name = value_or_default(elements, props, "Name")

    return fHandle, name
end

function read_datametadata(objects, elements, props)
    interp = value_or_default(elements, props, "Interpolation")
    interp = nested_object_check(interp, objects)

    uData = value_or_default(elements, props, "UserData")
    uData = nested_object_check(uData, objects)

    return (; Interpolation=interp, UserData=uData)
end