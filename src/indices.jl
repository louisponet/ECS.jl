#Almost exact copy of the sparse_int_set in DataStructures.jl
const INT_PER_PAGE = div(ccall(:jl_getpagesize, Clong, ()), sizeof(Int))
const INT_PER_PAGE_1 = INT_PER_PAGE - 1
# we use this to mark pages not in use, it must never be written to.
const NULL_INT_PAGE = Vector{Int}()

const Page = NamedTuple{(:id, :offset), Tuple{Int, Int}}

mutable struct Indices
    packed ::Vector{Int}
    reverse::Vector{Vector{Int}}
    counters::Vector{Int}  # counts the number of real elements in each page of reverse.
end

Indices() = Indices(Int[], Vector{Int}[], Int[])

Indices(indices) = union!(Indices(), indices)

Base.eltype(::Type{Indices}) = Int

Base.empty(::Indices) = Indices()

function Base.empty!(s::Indices)
    empty!(s.packed)
    empty!(s.reverse)
    empty!(s.counters)
    return s
end

Base.isempty(s::Indices) = isempty(s.packed)

Base.copy(s::Indices) = copy!(Indices(), s)

function Base.copy!(to::Indices, from::Indices)
    to.packed = copy(from.packed)
    #we want to keep the null pages === NULL_INT_PAGE
    resize!(to.reverse, length(from.reverse))
    for i in eachindex(from.reverse)
        page = from.reverse[i]
        if page === NULL_INT_PAGE
            to.reverse[i] = NULL_INT_PAGE
        else
            to.reverse[i] = copy(from.reverse[i])
        end
    end
    to.counters = copy(from.counters)
    return to
end

Base.lastindex(s::Indices) = s.packed[end]

@inline function pageid_offset(i)
    if INT_PER_PAGE & (INT_PER_PAGE - 1) === 0   
        t1 = i - 1
        pageid = div(t1, INT_PER_PAGE)
        t2 = t1 & INT_PER_PAGE_1
        return (id = pageid + 1, offset = t2 + 1)
    else
        return NamedTuple{(:id, :offset)}(divrem(i - 1, INT_PER_PAGE) .+ 1 )
    end
end

@inline function Base.in(i, s::Indices)
    pageid, offset = pageid_offset(i)
    rev = s.reverse
    if pageid > length(rev)
        return false
    else
        page = @inbounds rev[pageid]
        return page !== NULL_INT_PAGE && !isempty(page) && @inbounds page[offset] != 0
    end
end

Base.length(s::Indices) = length(s.packed)
Base.size(s::Indices)   = (length(s.packed),)

Base.@propagate_inbounds @inline function Base.getindex(s::Indices, p::Page)
    id, offset = p
    @boundscheck if id > length(s.reverse)
        throw(BoundsError(s, p))
    end
    page = @inbounds s.reverse[id]

    @boundscheck if page === NULL_INT_PAGE
        throw(BoundsError(s, p))
    end
    i = @inbounds page[offset]
    @boundscheck if i === 0
        throw(BoundsError(s, p))
    end
    return i 
end

Base.@propagate_inbounds @inline Base.getindex(s::Indices, i::Integer) = getindex(s, pageid_offset(i))

@inline function Base.push!(s::Indices, i::Integer)
    i <= 0 && throw(DomainError("Only positive Ints allowed."))

    pageid, offset = pageid_offset(i)
    pages = s.reverse
    plen = length(pages)

    if pageid > plen
        # Create new null pages up to pageid and fresh (zero-filled) one at pageid
        sizehint!(pages, pageid)
        sizehint!(s.counters, pageid)
        for i in 1:pageid - plen - 1
            push!(pages, NULL_INT_PAGE)
            push!(s.counters, 0)
        end
        push!(pages, zeros(Int, INT_PER_PAGE))
        push!(s.counters, 0)
    elseif pages[pageid] === NULL_INT_PAGE || isempty(pages[pageid])
        #assign a page to previous null page
        pages[pageid] = zeros(Int, INT_PER_PAGE)
    end
    page = pages[pageid]
    if page[offset] == 0
        @inbounds page[offset] = length(s) + 1
        @inbounds s.counters[pageid] += 1
        push!(s.packed, i)
        return s
    end
    return s
end

@inline function Base.push!(s::Indices, is::Integer...)
    for i in is
        push!(s, i)
    end
    return s
end

@inline Base.@propagate_inbounds function Base.pop!(s::Indices)
    if isempty(s)
        throw(ArgumentError("Cannot pop an empty set."))
    end
    id = pop!(s.packed)
    pageid, offset = pageid_offset(id)
    @inbounds s.reverse[pageid][offset] = 0
    @inbounds s.counters[pageid] -= 1
    cleanup!(s, pageid)
    return id
end

@inline Base.@propagate_inbounds function Base.pop!(s::Indices, id::Integer)
    id < 0 && throw(ArgumentError("Int to pop needs to be positive."))

    @boundscheck if !in(id, s)
        throw(BoundsError(s, id))
    end
    @inbounds begin
        packed_endid = s.packed[end]
        from_page, from_offset = pageid_offset(id)
        to_page, to_offset = pageid_offset(packed_endid)

        packed_id = s.reverse[from_page][from_offset]
        s.packed[packed_id] = packed_endid
        s.reverse[to_page][to_offset] = s.reverse[from_page][from_offset]
        s.reverse[from_page][from_offset] = 0
        s.counters[from_page] -= 1
        pop!(s.packed)
    end
    cleanup!(s, from_page)
    return id
end

@inline function cleanup!(s::Indices, pageid::Int)
    if s.counters[pageid] == 0
        s.reverse[pageid] = NULL_INT_PAGE
    end
end

@inline function Base.pop!(s::Indices, id::Integer, default)
    id < 0 && throw(ArgumentError("Int to pop needs to be positive."))
    return in(id, s) ? (@inbounds pop!(s, id)) : default
end
Base.popfirst!(s::Indices) = pop!(s, first(s))

@inline Base.iterate(set::Indices, args...) = iterate(set.packed, args...)

Base.last(s::Indices) = isempty(s) ? throw(ArgumentError("Empty set has no last element.")) : last(s.packed)

Base.union(s::Indices, ns) = union!(copy(s), ns)
function Base.union!(s::Indices, ns)
    for n in ns
        push!(s, n)
    end
    return s
end

Base.intersect(s1::Indices) = copy(s1)
Base.intersect(s1::Indices, ss...) = intersect(s1, intersect(ss...))
function Base.intersect(s1::Indices, ns)
    s = Indices()
    for n in ns
        n in s1 && push!(s, n)
    end
    return s
end

Base.intersect!(s1::Indices, ss...) = intersect!(s1, intersect(ss...))

#Is there a more performant way to do this?
Base.intersect!(s1::Indices, ns) = copy!(s1, intersect(s1, ns))

Base.setdiff(s::Indices, ns) = setdiff!(copy(s), ns)
function Base.setdiff!(s::Indices, ns)
    for n in ns
        pop!(s, n, nothing)
    end
    return s
end

function Base.:(==)(s1::Indices, s2::Indices)
    length(s1) != length(s2) && return false
    return all(in(s1), s2)
end

function Base.hash(s::Indices, h::UInt)
    for i in nfields(s)
        h = hash(getfield(s, i), h)
    end
    return h
end

issubset(a::Indices, b::Indices) = isequal(a, intersect(a, b))

Base.:(<)(a::Indices, b::Indices) = ( a<=b ) && !isequal(a, b)
Base.:(<=)(a::Indices, b::Indices) = issubset(a, b)

function findfirst_packed_id(i, s::Indices)
    pageid, offset = pageid_offset(i)
    if pageid > length(s.counters) || s.counters[pageid] == 0
        return 0
    end
    @inbounds id = s.reverse[pageid][offset]
    return id
end

Base.collect(s::Indices) = copy(s.packed)

function Base.permute!(s::Indices, p::AbstractVector)
    permute!(s.packed, p)
    @inbounds for (i, eid) in enumerate(s.packed)
        p[i] == i && continue #nothing was changed
        pageid, offset = pageid_offset(eid)
        s.reverse[pageid][offset] = i
    end
end

Base.@propagate_inbounds function swap_order!(ids::Indices, fid::Int, tid::Int)
    for id in (fid, tid)
        @boundscheck if !(id in ids)
            throw(BoundsError(ids, id))
        end
    end
    @inbounds begin
        fp = pageid_offset(fid)
        tp = pageid_offset(tid)
        pid1 = ids[fp]
        pid2 = ids[tp]
        ids.reverse[fp.id][fp.offset] = pid2
        ids.reverse[tp.id][tp.offset] = pid1
        ids.packed[pid1], ids.packed[pid2] = ids.packed[pid2], ids.packed[pid1]
        return pid1, pid2
    end
end
