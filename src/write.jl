"""
    write_mat(file, args...)

Write MAT files to disk.
"""
function write_mat(f, args...)
    open(f, "w") do file
        write_header!(file)
        
        ffile = preferences["compress"] ? IOBuffer() : file
        # Write variables sequentially
        for arg in args
            write_data(ffile, arg)
        end

        if preferences["compress"]
            write(file, Int32(15), Int32(0))
            sizePtr = position(file)

            cmprs = ZlibCompressorStream(file)
            write(cmprs, take!(ffile), TOKEN_END)

            # Update the size of matrix
            mSize = position(file) - sizePtr
            seek(file, sizePtr-4)
            write(file, Int32(mSize))
            # Return to the end of the file
            seekend(file)
        end
    end
end

function write_header!(file)
    mseg = "MATLAB 5.0 MAT-file, Platform: $(get_os()), Created on: $(get_date()) with MATIO.jl"

    write(file, rpad(mseg, 116), zeros(UInt8, 8), 0x0100, 0x4d49)

    return nothing
end

function get_os()
    os = if Sys.iswindows()
        "PCWIN"
    elseif Sys.islinux()
        "Linux"
    elseif Sys.isapple()
        "MacOS"
    elseif Sys.isbsd()
        "BSD"
    elseif Sys.isfreebsd()
        "FreeBSD"
    else
        ""
    end

    return os
end

function get_date()
    dFormat = DateFormat("e u dd HH:MM:SS Y")

    return format(now(), dFormat)
end

# Helper methods to parse names and data types of variables to be saved
write_data(file, name::Symbol) = write_data(file, String(name))

function write_data(file, name::String)
    !isascii(name) && error("Only ascii variable names are allowed, got \"$name\".")
    data = getfield(Main, Symbol(name))

    write_data(file, name, data)
end

# Fallback error for unsupported types
write_data(file, name, data) = error("Writing data of type $(typeof(data)) not yet implemented.")

# Variables read by MATIO
write_data(file, name, data::MATFile) = write_data(file, name, data.data)

# Scalar types - transform into 1x1 matrix
write_data(file, name, data::T) where T <: Union{Number, AbstractChar} = write_data(file, name, [data;;])

# String as a Char matrix
write_data(file, name, data::AbstractString) = write_data(file, name, reshape(collect(data),1,length(data)))

# Numerical matrices
function write_data(file, name, data::T) where T <: AbstractArray{<:Union{<:Number, Bool}}
    matVal = get_datatype_id(eltype(T))
    arrVal = get_array_id(eltype(T))
    dims = size(data)

    write_matrix(file, name, arrVal, matVal, dims, data)
end

get_datatype_id(T::Type) = get_datatype_id(ConvertTypeJM[T])
get_datatype_id(T::Type{<:Complex}) = get_datatype_id(ConvertTypeJM[real(T)])
get_datatype_id(T::Type{<:MatType}) = findfirst(x -> values(x) == T, pairs(MatDataType))

get_array_id(T::Type) = get_array_id(ConvertATypeJM[T])
get_array_id(T::Type{<:Complex}) = get_array_id(ConvertATypeJM[real(T)])
get_array_id(T::Type{<:MatArray}) = findfirst(x -> values(x) == T, pairs(ArrayType))

# Character matrices
function write_data(file, name, data::Matrix{<:AbstractChar})
    matVal = get_datatype_id(miUINT16)
    arrVal = get_array_id(mxCHAR_CLASS)

    dims = size(data)

    write_matrix(file, name, arrVal, matVal, dims, UInt16.(data))
end

function write_matrix(file, name, arrVal, matVal, dims, data; colIds=Int[], rowIds=Int[])
    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)
    
    #Identify data of complex type and set the flag
    cplx = eltype(data) <: Complex
    c = cplx ? 1 : 0

    # Identify boolean data and set the flag
    if eltype(data) == Bool
        l = 1
        # Change tyle of data from Bool to Int8
        data = UInt8.(data)
    else
        l = 0
    end

    # Choosing packing forces the matrix to be of mxDOUBLE type otherwise Matlab will not properly convert
    arrVal = preferences["packing"] ? 6 : arrVal
    # Write flags subelement
    isempty(rowIds) ? write_flags(file, arrVal; c=c, l=l) : write_flags(file, arrVal; c=c, l=l, nzmax=UInt32(length(data)))

    # Write dimensions subelement
    write_dimensions(file, Int32, dims)

    # Write name subelement
    write_name(file, name)

    # Sparse array subelements
    if !isempty(rowIds)
        # Write row indices
        #! Hardcoded matrix type IDs and data sizes - change everywhere
        write(file, Int32(5), Int32(length(rowIds)*sizeof(Int32)), rowIds)
        write(file, padding(sizeof(rowIds), 8))

        # Write column indices
        write(file, Int32(5), Int32(length(colIds)*sizeof(Int32)), colIds)
        write(file, padding(sizeof(colIds), 8))
    end

    subSize = length(data)*sizeof(MatDataType[matVal])

    # Write data
    if cplx
        # Write real part
        write(file, Int32(matVal), Int32(subSize), real.(data))
        write(file, padding(subSize, 8))
        # Write imaginary part
        write(file, Int32(matVal), Int32(subSize), imag.(data))
        write(file, padding(subSize, 8))
    else
        if preferences["packing"] && !isempty(data)
            newMatType = find_smallest_type(get_dtype(matVal), extrema(data))
            if get_dtype(matVal) != newMatType
                matVal = get_datatype_id(newMatType)
                data = ConvertTypeMJ[newMatType].(data)

                subSize = length(data)*sizeof(MatDataType[matVal])
            end
        end

        write(file, Int32(matVal), Int32(subSize), data)
        write(file, padding(subSize, 8))
    end


    # Update the size of matrix
    mSize = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(mSize))
    # Return to the end of the file
    seekend(file)
end

function write_flags(file, arrID; c=0, g=0, l=0, nzmax=Int32(0))
    # Setting flags through bit twiddling
    flags = UInt8(8c) | UInt8(4g) | UInt8(2l)
    full_info = reinterpret(UInt32, (UInt8(arrID), flags, UInt16(0)))
    write(file, reinterpret(Int128, (Int32(6), Int32(8), full_info, nzmax)))
end

function write_dimensions(file, dataType, dims)
    id = get_datatype_id(dataType)
    dimsSpan = Int32(length(dims)*sizeof(dataType))
    # Add padding in case the number of dims is odd
    write(file, Int32(id), dimsSpan, dataType.(dims)..., padding(dimsSpan,8))
end

function write_name(file, name)
    if length(name) < 5
        asciiVector = UInt32(0)
        for (i,n) in enumerate(name)
            asciiVector |= UInt32(n) << (8 * (4-i))
        end
        write(file, reinterpret(Int64, (Int16(1), Int16(length(name)), asciiVector)))
    else
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 8))
        write(file, Int32(1), Int32(length(name)), asciiVector)
    end
end

function padding(data, mSize)
    if data == 0
        mSize == 4 ? zeros(Int8, mSize) : zeros(Int8, 0)
    else
        zeros(Int8, cld(data, mSize) * mSize - data)
    end
end

function find_smallest_type(T::Type{<:MatNumber}, dataRange)
    try
        newT = SmallerType[T]
        all(typemin(ConvertTypeMJ[newT]) .< dataRange .< typemax(ConvertTypeMJ[newT])) && find_smallest_type(newT, dataRange)
    catch
        return T
    end
end

# Writing sparse matrices
function write_data(file, name, data::AbstractSparseArray)
    matVal = get_datatype_id(eltype(data))
    arrVal = get_array_id(mxSPARSE_CLASS)

    colIds = Int32.(data.colptr .- 1)
    rowIds = Int32.(data.rowval)
    nzval = data.nzval
    dims = (data.m, data.n)

    write_matrix(file, name, arrVal, matVal, dims, nzval, colIds=colIds, rowIds=rowIds)
end

# Writing eterogenous arrays as cell arrays
function write_data(file, name, data::AbstractArray)
    arrVal = get_array_id(mxCELL_CLASS)

    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)

    # Write flags subelement
    write_flags(file, arrVal)

    # Write dimensions subelement
    dims = length(size(data)) == 1 ? (length(data), 1) : size(data)
    write_dimensions(file, Int32, dims)

    # Write name subelement
    write_name(file, name)

    for i in 1:prod(dims)
        write_data(file, "", data[i])
    end

    # Update the size of matrix
    mSize = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(mSize))
    # Return to the end of the file
    seekend(file)
end

# Writing structs
write_data(file, name, data::NamedTuple) = write_data(file, name, [data;])

function write_data(file, name, data::Vector{<:NamedTuple})
    # Basic check if NamedTuples are of the same type (have the same set of fields)
    if !isconcretetype(eltype(data))
        @warn "Variable $name includes NamedTuples with different fields, saving as a cell array instead."
        
        write_data(file, name, [data;;])
        return nothing
    end

    arrVal = get_array_id(mxSTRUCT_CLASS)

    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)

    # Write flags subelement
    write_flags(file, arrVal)

    # Write dimensions subelement
    write_dimensions(file, Int32, (1,length(data)))

    # Write name subelement
    write_name(file, name)

    # Write names of the fields
    fNames = String.(propertynames(data[1]))
    nameNum = length.(fNames)
    maxNameSize = maximum(nameNum) + 1 # There might be a limit of 32 bytes per name

    # Field name lengths
    write(file, Int16(5), Int16(4), UInt32(maxNameSize))

    # Field names
    fullSize = maxNameSize*length(fNames)
    write(file, Int32(1), Int32(fullSize))
    for fName in fNames
        asciiVector = Int8.([Char(x) for x in fName])
        append!(asciiVector, padding(length(fName), maxNameSize))
        write(file, asciiVector)
    end
    # Pad this whole section
    write(file, padding(fullSize, 8))

    # Fields
    # First one is written in full
    for field in propertynames(data[1])
        write_data(file, "", getproperty(data[1], field))
    end

    #Others can be shortened if they contain numerical matrices
    for datum in data[2:end]
        for field in propertynames(datum)
            f = getproperty(datum, field)
            if isempty(f) && eltype(f) <: Number
                write_empty(file)
            else
                write_data(file, "", f)
            end
        end
    end
    # Update the size of matrix
    mSize = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(mSize))
    # Return to the end of the file
    seekend(file)
end

# Placeholder matrix for empty numerical matrix
write_empty(file) = write(file, UInt32(14), UInt32(0))