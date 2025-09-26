module MATIO

using CodecZlib: ZlibDecompressorStream, ZlibCompressorStream, TranscodingStreams.TOKEN_END
using Dates: DateFormat, format, now, DateTime, UTM, UNIXEPOCH, Month, Day, Millisecond
using SparseArrays: AbstractSparseArray, SparseMatrixCSC

const version = pkgversion(MATIO)

include("types.jl")
include("read.jl")
export read_mat

include("write.jl")
export write_mat

const preferences = Dict(
    "compress" => false,
    "packing" => false,
)

end #Module
