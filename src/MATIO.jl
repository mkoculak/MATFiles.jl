module MATIO

import Dates: DateFormat, format, now
import SparseArrays: AbstractSparseArray, SparseMatrixCSC
import CodecZlib: ZlibDecompressorStream

include("types.jl")
include("read.jl")
export read_mat

include("write.jl")
export write_mat

end
