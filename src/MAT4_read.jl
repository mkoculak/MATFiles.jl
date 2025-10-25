function read_mat4(io::IO, file)
    # We'll assume endianess is the same for all the objects
    endian, _, _ = read_type(io)

    # MAT v4 files might contain a number of objects written sequentially
    # Each containing a 20-byte header and data but no indication upfront, so we read in a loop until EOF.
    seekend(io)
    fsize = position(io)
    seekstart(io)

    mFile = MATFile(abspath(file), io, UInt16(4), endian, NamedTuple())

    names = Symbol[]
    contents = Any[]

    while position(io) < fsize
        en, format, type = read_type(io)
        # Print a warning if endianess changes in the middle of the file
        endian != en && @warn "Endianess changed between objects!"

        nRows, nCols, imag, nameLen = Int.(ntuple(_ -> read(mFile, miUINT32), 4))

        @info en, format, type, nRows, nCols, imag, nameLen

        name = String(read(mFile, nameLen))
        push!(names, Symbol(rstrip(name, '\0')))

        data = read(mFile, format, (nRows, nCols))
        
        if imag == 1
            data = Complex.(data, read(mFile, format, (nRows, nCols)))
        end

        # Convert to letters if text type or to sparse representation
        if type == :text 
            data = Char.(data)
        elseif type == :sparse
            # For some reason complex sparse matrices do not have the flag but contain a fourth column
            if size(data)[2] == 4
                data = sparse(data[:,1], data[:,2], Complex.(data[:,3], data[:,4]))
            else
                data = sparse(data[:,1], data[:,2], data[:,3])
            end
        end


        push!(contents, data)
    end

    mFile.data = NamedTuple(zip(names, contents))

    return mFile
end

function read_type(io::IO)
    value = read(io, UInt32)

    # We expect a 4-digit number, so if its bigger, we byte swap
    sValues = string(value > UInt32(9999) ? bswap(value) : value)

    # If it is still bigger, we error
    length(sValues) > 4 && error("Unknown binary format!")
    # If it is smaller, pad missing zeros from the left
    sValues = length(sValues) < 4 ? lpad(sValues, 4, '0') : sValues
    
    if sValues[1] == '0'
        endian = "IM"
    elseif sValues[1] == '1'
        endian = "MI"
    else
        error("Binary format of type $(sValues[1]) not implemented!")
    end

    sValues[2] == 0 && error("Expected O in the header to be zero, got $(sValues[1]) instead.")

    format = Mat4Type[sValues[3]]
    type = Array4Type[sValues[4]]

    return endian, format, type
end