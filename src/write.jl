function write_mat(f, data)
    open(f, "w") do file
        write_header!(file)
        write_data(file, data)
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

# Scalar types
function write_data(file, name, data::T) where T <: Number
    matType = ConvertType[T]
    matVal = get_datatype_id(matType)

    println(matType, " ", matVal)
    arrType = ConvertAType[T]
    arrVal = get_array_id(arrType)
    println("$arrType $arrVal")
    dims = (1,1)

    write_matrix(file, name, arrVal, matVal, dims, data)
end

function get_datatype_id(T::Type{<:MatType})
    return findfirst(x -> values(x) == T, pairs(DataType))
end

function get_array_id(T::Type{<:MatArray})
    return findfirst(x -> values(x) == T, pairs(ArrayType))
end

function write_matrix(file, name, arrVal, matVal, dims, data)
    # Write matrix tag but set size to zero, we'll overwrite this value at the end.
    write(file, Int32(14), Int32(0))
    # Remember where to write back
    sizePtr = position(file)
    
    # Write flags subelement
    write(file, Int32(6), Int32(8), UInt32(arrVal), UInt32(0))

    # Write dimensions subelement
    write(file, Int32(5), Int32(length(dims)*sizeof(Int32)), Int32.(dims)...)

    # Write name subelement
    if length(name) < 5
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, zeros(Int8, 4-length(name)))
        write(file, Int16(1), Int16(length(name)), asciiVector)
    else
        asciiVector = Int8.([Char(x) for x in name])
        append!(asciiVector, zeros(Int8, rest(length(name))))
        write(file, Int32(1), Int32(length(name)), asciiVector)
    end

    # Write data
    println(matVal, length(data), " ", sizeof(DataType[matVal]))
    write(file, Int32(matVal), Int32(length(data)*sizeof(DataType[matVal])), data, Int32(0))
    # ! Hardcoded alignment at the end - needs proper handling

    size = position(file) - sizePtr
    seek(file, sizePtr-4)
    write(file, Int32(size))

end

rest(x) = (cld(x, 8) * 8) - x