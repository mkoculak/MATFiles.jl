module MATIO

using CodecZlib: ZlibDecompressorStream, ZlibCompressorStream, TranscodingStreams.TOKEN_END
using Dates: DateFormat, DateTime, Month, Day, Millisecond, UTM, UNIXEPOCH, format, now
using SparseArrays: AbstractSparseArray, SparseMatrixCSC, sparse

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
