module MATIO

import SparseArrays: SparseMatrixCSC
import CodecZlib: ZlibDecompressorStream

include("types.jl")
include("read.jl")
export read_mat

end
