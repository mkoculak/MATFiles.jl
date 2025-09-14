function write_mat(f, args...)
    open(f, "w") do file
        write_header!(file)
        
        # Write variables sequentially
        for arg in args
            write_data(file, arg)
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
    dFormat =DateFormat("e u dd HH:MM:SS Y")

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
function write_data(file, name, data::T) where T <: Matrix{<:Number}
    matType = ConvertType[eltype(T)]
    matVal = get_datatype_id(matType)

    println(matType, " ", matVal)
    arrType = ConvertAType[eltype(T)]
    arrVal = get_array_id(arrType)
    println("$arrType $arrVal")
    dims = size(data)

    write_matrix(file, name, arrVal, matVal, dims, data)
end

function get_datatype_id(T::Type{<:MatType})
    return findfirst(x -> values(x) == T, pairs(DataType))
end

function get_array_id(T::Type{<:MatArray})
    return findfirst(x -> values(x) == T, pairs(ArrayType))
end

function write_data(file, name, data::Matrix{<:AbstractChar})
    matType = miUINT16
    matVal = get_datatype_id(matType)

    arrType = mxCHAR_CLASS
    arrVal = get_array_id(arrType)

    dims = size(data)
    @info dims data
    write_matrix(file, name, arrVal, matVal, dims, UInt16.(data))
end

function write_matrix(file, name, arrVal, matVal, dims, data; colIds=Int[], rowIds=Int[])
    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)
    
    # Write flags subelement
    #! Clean up the sprase addition
    spr = isempty(rowIds) ? UInt32(0) : UInt32(length(data))
    write(file, Int32(6), Int32(8), UInt32(arrVal), spr)

    # Write dimensions subelement
    write(file, Int32(5), Int32(length(dims)*sizeof(Int32)), Int32.(dims)...)

    # Write name subelement
    if length(name) < 5
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 4))
        write(file, Int16(1), Int16(length(name)), asciiVector)
    else
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 8))
        write(file, Int32(1), Int32(length(name)), asciiVector)
    end

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

    # Write data
    println(matVal, length(data), " ", sizeof(DataType[matVal]))
    write(file, Int32(matVal), Int32(length(data)*sizeof(DataType[matVal])), data)
    write(file, padding(sizeof(data), 8))

    # Update the size of matrix
    mSize = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(mSize))
    # Return to the end of the file
    seekend(file)
end

padding(data, mSize) = data == 0 ? zeros(Int8, mSize) : zeros(Int8, cld(data, mSize) * mSize - data)

# Writing sparse matrices
function write_data(file, name, data::AbstractSparseArray)
    matType = ConvertType[eltype(data)]
    matVal = get_datatype_id(matType)

    arrType = mxSPARSE_CLASS
    arrVal = get_array_id(arrType)

    colIds = Int32.(data.colptr .- 1)
    rowIds = Int32.(data.rowval)
    nzval = data.nzval
    dims = (data.m, data.n)

    write_matrix(file, name, arrVal, matVal, dims, nzval, colIds=colIds, rowIds=rowIds)
end

# Writing eterogenous arrays as cell arrays
function write_data(file, name, data::AbstractArray)
    arrType = mxCELL_CLASS
    arrVal = get_array_id(arrType)

    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)

    # Write flags subelement
    write(file, Int32(6), Int32(8), UInt32(arrVal), UInt32(0))

    # Write dimensions subelement
    dims = size(data)
    dims = length(dims) == 1 ? (dims[1], 1) : dims
    write(file, Int32(5), Int32(length(dims)*sizeof(Int32)), Int32.(dims)...)

    # Write name subelement
    if length(name) < 5
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 4))
        write(file, Int16(1), Int16(length(name)), asciiVector)
    else
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 8))
        write(file, Int32(1), Int32(length(name)), asciiVector)
    end

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
function write_data(file, name, data::NamedTuple)
    arrType = mxSTRUCT_CLASS
    arrVal = get_array_id(arrType)

    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)

    @info arrVal
    # Write flags subelement
    write(file, Int32(6), Int32(8), UInt32(arrVal), UInt32(0))

    # Write dimensions subelement
    dims = (1,1)
    write(file, Int32(5), Int32(length(dims)*sizeof(Int32)), Int32.(dims)...)

    # Write name subelement
    if length(name) < 5
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 4))
        write(file, Int16(1), Int16(length(name)), asciiVector)
    else
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, padding(length(name), 8))
        write(file, Int32(1), Int32(length(name)), asciiVector)
    end

    # Write names of the fields
    fNames = String.(propertynames(data))
    nameNum = length.(fNames)
    nameSize = cld(maximum(nameNum), 8) * 8 # The might be a limit of 32 bytes per name

    # Field name lengths
    write(file, Int16(5), Int16(4), UInt32(nameSize))

    # Field names
    write(file, Int32(1), Int32(nameSize*length(fNames)))
    for fName in fNames
        asciiVector = Int8.([Char(x) for x in fName])
        append!(asciiVector, padding(length(fName), nameSize))
        write(file, asciiVector)
    end

    # Fields
    for field in propertynames(data)
        write_data(file, "", getproperty(data, field))
    end

    # Update the size of matrix
    mSize = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(mSize))
    # Return to the end of the file
    seekend(file)
end