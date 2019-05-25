struct BSONElem
  tag::BSONType
  pos::Int
end

BSONElem(tag::BSONType, io::IO) = BSONElem(tag, position(io))

mutable struct ParseCtx
  refindx::Vector{BSONElem}
  refs::Vector{Any}
  curref::Int32
end

ParseCtx() = ParseCtx([], [], -1)

struct ParseArrayIter{IOT <: IO, ET}
  io::IOT
  ctx::ParseCtx
  len::Int
end

ParseArrayIter(io::IOT, ::Type{ET}, ctx) where {IOT, ET} =
  ParseArrayIter{IOT, ET}(io, ctx, Int(read(io, Int32)) - 4)

Base.iterate(itr::ParseArrayIter) = iterate(itr, 0)

function Base.iterate(itr::ParseArrayIter{IOT, E}, len::Int) where {IOT, E}
  startpos = position(itr.io)
  tag = read(itr.io, BSONType)
  if tag == eof
    @assert len + sizeof(BSONType) == itr.len
    return nothing
  end

  while read(itr.io, UInt8) != 0x00 end

  obj = parse_tag(itr.io, tag, itr.ctx)::E
  (obj, len + position(itr.io) - startpos)
end

Base.isempty(itr::ParseArrayIter) = itr.len == 1

function skip_over(io::IO, tag::BSONType)
  len = if tag == document || tag == array
    read(io, Int32) - 4
  elseif tag == string
    read(io, Int32)
  elseif tag == binary
    read(io, Int32) + 1
  elseif tag == null
    0
  else
    sizeof(jtype(tag))
  end

  seek(io, position(io) + len)
  #@info "Skipped" tag len position(io)
end

"Create an index into the _backrefs entry in the root document"
function build_refs_indx!(io::IO, ctx::ParseCtx)
  # read the length of the root document
  len = read(io, Int32)
  #@info "BSON document is $len bytes"

  while (tag = read(io, BSONType)) ≠ eof
    name = parse_cstr_unsafe(io)
    #@info "Element head" String(name) tag position(io)

    if name == b"_backrefs"
      if tag != array
        error("_backrefs is not an array; tag = $tag")
      end

      len = read(io, Int32)
      #@info "Processing _backrefs" position(io) len

      while (tag = read(io, BSONType)) ≠ eof
        while read(io, UInt8) ≠ 0x00 end

        push!(ctx.refindx, BSONElem(tag, position(io)))
        push!(ctx.refs, nothing)
        skip_over(io, tag)
      end
    else
      #@info "Skipping $(String(name))"
      skip_over(io, tag)
    end
  end

  #@info "Finished building refs index" ctx
  seek(io, 0)
end

function setref(obj, ctx::ParseCtx)
  if ctx.curref ≠ -1
    @assert ctx.refs[ctx.curref] == nothing
    ctx.refs[ctx.curref] = obj
    ctx.curref = -1
  end
end

function parse_bin(io::IO, ctx::ParseCtx)::Vector{UInt8}
  len = read(io, Int32)
  subtype = read(io, 1)
  bin = read(io, len)
  setref(bin, ctx)
  bin
end

function parse_tag(io::IO, tag::BSONType, ctx::ParseCtx)
  if tag == null
    @assert ctx.curref == -1
  elseif tag == document
    parse_doc(io, ctx)
  elseif tag == array
    parse_any_array(io, ctx)
  elseif tag == string
    @assert ctx.curref == -1
    len = read(io, Int32)-1
    s = String(read(io, len))
    eof = read(io, 1)
    s
  elseif tag == binary
    parse_bin(io, ctx)
  else
    @assert ctx.curref == -1
    read(io, jtype(tag))
  end
end

function parse_type(io::IO,
                    name::BSONElem, params::BSONElem, ctx::ParseCtx)::Type
  @assert name.tag == array && params.tag == array
  curref = ctx.curref
  ctx.curref = -1

  seek(io, name.pos)
  T = resolve(ParseArrayIter(io, String, ctx))
  #@info "Union all type" T
  seek(io, params.pos)
  ctx.curref = curref
  p = constructtype(T, ParseArrayIter(io, Any, ctx))
  setref(p, ctx)
  p
end

function parse_any_array(io::IO, ctx::ParseCtx)::BSONArray
  len = read(io, Int32)
  ps = BSONArray()
  setref(ps, ctx)

  while (tag = read(io, BSONType)) ≠ eof
    # Note that arrays are dicts with the index as the key
    while read(io, UInt8) != 0x00
      nothing
    end
    push!(ps, parse_tag(io, tag, ctx))
  end

  ps
end

function load_bits_array(io::IO, ::Type{T}, sizes,
                         data::BSONElem, ctx::ParseCtx) where T
  arr = if sizeof(T) == 0
      fill(T(), sizes...)
    else
      @assert data.tag == binary
      reshape(T[reinterpret(T, parse_bin(io, ctx))...], sizes...)
    end

    setref(arr, ctx)
    arr
end

function load_array(io::IO, ::Type{T}, sizes, ctx::ParseCtx) where T
    arr = Array{T}(undef, sizes...)
    setref(arr, ctx)
    bsonarr = ParseArrayIter(io, T, ctx)

    if (itr = iterate(bsonarr)) ≠ nothing
      for (i, len) = enumerate(sizes), j = 1:len
        (elem, s) = itr
        arr[i, j] = elem
        itr = iterate(bsonarr, s)
      end
    end

    arr
end

function parse_array(io::IO, ttype::BSONElem, size::BSONElem,
                     data::BSONElem, ctx::ParseCtx)::AbstractArray
  # Save current ref incase T is a backref
  curref = ctx.curref
  ctx.curref = -1

  seek(io, ttype.pos)
  T::Type = parse_tag(io, ttype.tag, ctx)
  #@info "New array type" T

  ctx.curref = curref

  seek(io, size.pos)
  sizes = (ParseArrayIter(io, Int64, ctx)...,)

  seek(io, data.pos)
  if isbitstype(T)
    load_bits_array(io, T, sizes, data, ctx)
  else
    load_array(io, T, sizes, ctx)
  end
end

function parse_backref(io::IO, ref::BSONElem, ctx::ParseCtx)
  seek(io, ref.pos)
  id = if ref.tag == int64
    convert(Int32, read(io, Int64))
  elseif ref.tag == int32
    read(io, Int32)
  else
    error("Expecting Int type found: $ref_tag")
  end

  if ctx.refs[id] ≠ nothing
    ctx.refs[id]
  else
    ctx.curref = id
    obj = ctx.refindx[id]
    seek(io, obj.pos)
    ctx.refs[id] = parse_tag(io, obj.tag, ctx)
  end
end

function load_dict!(io::IOT, d::Dict{K, V},
                    ctx::ParseCtx) where {K, V, IOT <: IO}
  setref(d, ctx)

  kvs = ParseArrayIter(io, Any, ctx)
  ks::ParseArrayIter{IOT, K}, vs::ParseArrayIter{IOT, V} = (kvs...,)
  for (k, v) in zip(kvs...)
      d[k] = v
  end

  d
end

function load_struct!(io::IO, x::T, ctx::ParseCtx) where T
  setref(x, ctx)

  local p
  for outer p = enumerate(ParseArrayIter(io, Any, ctx))
    (i, field) = p
    f = convert(fieldtype(T, i), field)
    ccall(:jl_set_nth_field, Nothing, (Any, Csize_t, Any), x, i-1, f)
  end

  @assert p[1] == fieldcount(T) "$(p[1]) ≠ $(fieldcount(T))"
  x
end

function parse_struct(io::IO, ttype::BSONElem, data::BSONElem, ctx::ParseCtx)
  # Save current ref incase T is a backref
  curref = ctx.curref
  ctx.curref = -1

  seek(io, ttype.pos)
  @assert ttype.tag == document
  T = parse_doc(io, ctx)::Type
  #@info "New struct type" T

  seek(io, data.pos)
  ctx.curref = curref

  if isprimitive(T)
    @assert isbitstype(T)
    @assert data.tag == binary
    bits = parse_bin(io, ctx)
    ccall(:jl_new_bits, Any, (Any, Ptr{Cvoid}), T, bits)
  elseif T <: Dict
    load_dict!(io, T(), ctx)
  else
    @assert data.tag == array
    load_struct!(io, ccall(:jl_new_struct_uninit, Any, (Any,), T), ctx)
  end
end

function parse_any_doc(io::IO, ctx::ParseCtx)::BSONDict
  len = read(io, Int32)
  dic = BSONDict()
  setref(dic, ctx)

  while (tag = read(io, BSONType)) ≠ eof
    cstr = parse_cstr_unsafe(io)
    k = ccall(:jl_symbol_n, Symbol, (Ptr{UInt8}, Int), cstr, length(cstr))
    dic[k] = parse_tag(io, tag, ctx)
  end

  dic
end

function parse_doc(io::IO, ctx::ParseCtx)
  startpos = position(io)
  len = read(io, Int32)

  seen::Int64 = 0
  see(it::Int64) = seen = seen | it
  saw(it::Int64)::Bool = seen & it != 0
  only_saw(it::Int64)::Bool = seen == it

  # First decide if this document is tagged with a Julia type. Saving the BSON tag types
  local tref, tdata, ttype, ttypename, ttag, tname, tparams, tpath,
        tsize, tvar, tbody
  local k::AbstractVector{UInt8}

  for _ in 1:6
    if (tag = read(io, BSONType)) == eof
      break
    end
    k = parse_cstr_unsafe(io)
    #@info "Read key" String(k)

    if k == b"tag"
      if tag == string && (dtag = parse_doc_tag(io)) isa Int64
        #@info "Read tag" dtag
        see(SEEN_TAG | dtag)
        continue
      else
        @goto FALLBACK
      end
    end

    if k == b"ref"
      see(SEEN_REF)
      tref = BSONElem(tag, io)
    elseif k == b"data"
      see(SEEN_DATA)
      tdata = BSONElem(tag, io)
    elseif k == b"type"
      see(SEEN_TYPE)
      ttype = BSONElem(tag, io)
    elseif k == b"typename"
      see(SEEN_TYPENAME)
      ttypename = BSONElem(tag, io)
    elseif k == b"name"
      see(SEEN_NAME)
      tname = BSONElem(tag, io)
    elseif k == b"params"
      see(SEEN_PARAMS)
      tparams = BSONElem(tag, io)
    elseif k == b"path"
      see(SEEN_PATH)
      tpath = BSONElem(tag, io)
    elseif k == b"size"
      see(SEEN_SIZE)
      tsize = BSONElem(tag, io)
    elseif k == b"var"
      see(SEEN_VAR)
      tvar = BSONElem(tag, io)
    elseif k == b"body"
      see(SEEN_BODY)
      tbody = BSONElem(tag, io)
    elseif k == b"_backrefs"
      nothing
    else
      @goto FALLBACK
    end

    skip_over(io, tag)
  end
  endpos = position(io)

  ret = if only_saw(SEEN_TAG | SEEN_REF | SEEN_TAG_BACKREF)
    #@info "Found backref" tref
    parse_backref(io, tref, ctx)
  elseif only_saw(SEEN_TAG | SEEN_TYPE | SEEN_DATA | SEEN_TAG_STRUCT)
    #@info "Found Struct" ttype tdata
    parse_struct(io, ttype, tdata, ctx)
  elseif only_saw(SEEN_TAG | SEEN_NAME | SEEN_PARAMS | SEEN_TAG_DATATYPE)
    #@info "Found Type" tname tparams
    parse_type(io, tname, tparams, ctx)
  elseif only_saw(SEEN_TAG | SEEN_NAME | SEEN_TAG_SYMBOL)
    #@info "Found Symbol" tname
    seek(io, tname.pos)
    len = read(io, Int32)-1
    cstr = parse_cstr_unsafe(io)
    @assert len == length(cstr)
    ccall(:jl_symbol_n, Symbol, (Ptr{UInt8}, Int), cstr, len)
  elseif only_saw(SEEN_TAG | SEEN_DATA | SEEN_TAG_TUPLE)
    #@info "Found Tuple" tdata
    seek(io, tdata.pos)
    (ParseArrayIter(io, Any, ctx)...,)
  elseif only_saw(SEEN_TAG | SEEN_DATA | SEEN_TAG_SVEC)
    #@info "Found svec" tdata
    seek(io, tdata.pos)
    Core.svec(ParseArrayIter(io, Any, ctx)...)
  elseif only_saw(SEEN_TAG | SEEN_TAG_UNION)
    Union{}
  elseif only_saw(SEEN_TAG | SEEN_TYPENAME | SEEN_PARAMS | SEEN_TAG_ANON)
    (:anonymous, ttypename, tparams)
  elseif only_saw(SEEN_TAG | SEEN_PATH | SEEN_TAG_REF)
    (:ref, tpath)
  elseif only_saw(SEEN_TAG | SEEN_TYPE | SEEN_SIZE | SEEN_DATA | SEEN_TAG_ARRAY)
    parse_array(io, ttype, tsize, tdata, ctx)
  elseif only_saw(SEEN_TAG | SEEN_VAR | SEEN_BODY | SEEN_TAG_UNIONALL)
    (:unionall, tvar, tbody)
  else
    @goto FALLBACK
  end

  seek(io, endpos)
  return ret

  @label FALLBACK
  #@info "Found plain dictionary"
  # This doc doesn't appear to be tagged with all the necessay julia type info
  seek(io, startpos)
  parse_any_doc(io, ctx)
end

function direct_parse(io::IO)
  ctx = ParseCtx()
  build_refs_indx!(io, ctx)
  parse_doc(io, ctx)
end

function directtrip(ting::T) where {T}
  io = IOBuffer()
  bson(io, Dict(:stuff => ting))
  seek(io, 0)
  ctx = ParseCtx()
  build_refs_indx!(io, ctx)
  try
    parse_doc(io, ctx)[:stuff]
  catch e
    @error "Error during parsing" io ctx
    rethrow(e)
  end
end
