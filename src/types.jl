# Hierarchy of possible data types
abstract type MatType end

abstract type MatNumber <: MatType end
abstract type MatUnicode <: MatType end

struct miINT8       <: MatNumber end
struct miUINT8      <: MatNumber end
struct miINT16      <: MatNumber end
struct miUINT16     <: MatNumber end
struct miINT32      <: MatNumber end
struct miUINT32     <: MatNumber end
struct miSINGLE     <: MatNumber end
struct miDOUBLE     <: MatNumber end
struct miINT64      <: MatNumber end
struct miUINT64     <: MatNumber end
struct miMATRIX     <: MatType end
struct miCOMPRESSED <: MatType end
struct miUTF8       <: MatUnicode end
struct miUTF16      <: MatUnicode end
struct miUTF32      <: MatUnicode end

const DataType = Dict(
    1  => miINT8,
    2  => miUINT8,
    3  => miINT16,
    4  => miUINT16,
    5  => miINT32,
    6  => miUINT32,
    7  => miSINGLE,
    9  => miDOUBLE,
    12 => miINT64,
    13 => miUINT64,
    14 => miMATRIX,
    15 => miCOMPRESSED,
    16 => miUTF8,
    17 => miUTF16,
    18 => miUTF32,
)

get_dtype(idx::Integer) = DataType[Int(idx)]

const ConvertType = Dict(
    miINT8      => Int8,
    miUINT8     => UInt8,
    miINT16     => Int16,
    miUINT16    => UInt16,
    miINT32     => Int32,
    miUINT32    => UInt32,
    miSINGLE    => Float32,
    miDOUBLE    => Float64,
    miINT64     => Int64,
    miUINT64    => UInt64,
    miUTF8      => UInt8,
    miUTF16     => UInt16,
    miUTF32     => UInt32,
)

# Hierarchy of possible array types
abstract type MatArray end

# Includes all numerical and char array types
abstract type NumArray  <: MatArray end

struct mxUNKNOWN_CLASS  <: MatArray end
struct mxCELL_CLASS     <: MatArray end
struct mxSTRUCT_CLASS   <: MatArray end
struct mxOBJECT_CLASS   <: MatArray end
struct mxCHAR_CLASS     <: NumArray end
struct mxSPARSE_CLASS   <: MatArray end
struct mxDOUBLE_CLASS   <: NumArray end
struct mxSINGLE_CLASS   <: NumArray end
struct mxINT8_CLASS     <: NumArray end
struct mxUINT8_CLASS    <: NumArray end
struct mxINT16_CLASS    <: NumArray end
struct mxUINT16_CLASS   <: NumArray end
struct mxINT32_CLASS    <: NumArray end
struct mxUINT32_CLASS   <: NumArray end
struct mxINT64_CLASS    <: NumArray end
struct mxUINT64_CLASS   <: NumArray end
struct mxFUNCTION_CLASS <: MatArray end
struct mxOPAQUE_CLASS   <: MatArray end

const ArrayType = Dict(
    0  => mxUNKNOWN_CLASS,
    1  => mxCELL_CLASS,
    2  => mxSTRUCT_CLASS,
    3  => mxOBJECT_CLASS,
    4  => mxCHAR_CLASS,
    5  => mxSPARSE_CLASS,
    6  => mxDOUBLE_CLASS,
    7  => mxSINGLE_CLASS,
    8  => mxINT8_CLASS,
    9  => mxUINT8_CLASS,
    10 => mxINT16_CLASS,
    11 => mxUINT16_CLASS,
    12 => mxINT32_CLASS,
    13 => mxUINT32_CLASS,
    14 => mxINT64_CLASS,
    15 => mxUINT64_CLASS,
    16 => mxFUNCTION_CLASS,
    17 => mxOPAQUE_CLASS,
)

get_atype(idx::Integer) = ArrayType[Int(idx)]

const ConvertAType = Dict(
    mxDOUBLE_CLASS  => Float64,
    mxSINGLE_CLASS  => Float32,
    mxINT8_CLASS    => Int8,
    mxUINT8_CLASS   => UInt8,
    mxINT16_CLASS   => Int16,
    mxUINT16_CLASS  => UInt16,
    mxINT32_CLASS   => Int32,
    mxUINT32_CLASS  => UInt32,
    mxINT64_CLASS   => Int64,
    mxUINT64_CLASS  => UInt64,
)

# Main output data type
mutable struct MATFile
    path::String
    ios::IOStream
    version::String
    endian::String
    data::NamedTuple
end