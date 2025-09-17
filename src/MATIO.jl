module MATIO

import Dates: DateFormat, format, now
import SparseArrays: AbstractSparseArray, SparseMatrixCSC
import CodecZlib: ZlibDecompressorStream, ZlibCompressorStream, TranscodingStreams.TOKEN_END

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
