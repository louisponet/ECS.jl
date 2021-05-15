Base.isequal(F::C, G::C) where {C <: ComponentData} =
    all(f -> isequal(getfield(F, f), getfield(G, f)), 1:nfields(F))::Bool
    
Base.:(==)(F::C, G::C) where {C <: ComponentData} =
    all(f -> getfield(F, f)== getfield(G, f), 1:nfields(F))::Bool

@inline function Base.hash(c::C, h::UInt) where {C <: ComponentData}
    for f in nfields(c)
        h = hash(getfield(c, f), h)
    end
    return h
end

"Can be used to specify the type of component storage to be used for a given `ComponentData`."
component_type(::Type{<:ComponentData}) = Component
 
@inline indices_iterator(a::AbstractComponent) = a.indices

"""
The most basic Component type.

Indexing into a component with an `Entity` will return the data linked to that entity,
indexing with a regular `Int` will return directly the `ComponentData` that is stored in the data
vector at that index, i.e. generally not the storage linked to the `Entity` with that `Int` as id.
"""
struct Component{T <: ComponentData} <: AbstractComponent{T}
    indices::Indices
    data::Vector{T}
end

Component{T}() where {T} = Component(Indices(), T[])


"""
A shared component works very much like a normal component except that it tries to not have duplicate
data for different entities. This should be used for very large `ComponentData`. 
"""
struct SharedComponent{T <: ComponentData} <: AbstractComponent{T}
    indices::Indices
    data::Vector{Int} # saves the indices into the shared for each of the entities
    shared::Vector{T}
end

SharedComponent{T}() where {T <: ComponentData} = SharedComponent{T}(Indices(), Int[], T[])

##### BASE Extensions ####
Base.eltype(::Type{<:AbstractComponent{T}}) where T = T

Base.length(c::AbstractComponent) = length(c.data)

Base.in(i::Integer, c::AbstractComponent) = in(i, c.indices)
Base.in(e::Entity, c::AbstractComponent)  = in(e.id, c)

Base.isempty(c::AbstractComponent) = isempty(c.data)

function Base.delete!(c::AbstractComponent, es::Vector{Entity})
    for e in es
        if e in c
            pop!(c, e)
        end
    end
end

function Base.permute!(c::AbstractComponent, permvec)
    permute!(c.data, permvec)
    permute!(c.indices, permvec)
end

Base.@propagate_inbounds @inline Base.getindex(c::Component, e::Entity) = c.data[c.indices[e.id]]
Base.@propagate_inbounds @inline Base.getindex(c::SharedComponent, e::Entity) = c.shared[c.data[c.indices[e.id]]]
Base.@propagate_inbounds @inline Base.getindex(c::Component, i::Integer) = c.data[i]
Base.@propagate_inbounds @inline Base.getindex(c::SharedComponent, i::Integer) = c.shared[c.data[i]]

@inline function Base.setindex!(c::Component{T}, v::T, e::Entity) where {T}
    eid = e.id
    @boundscheck if !in(e, c)
        push!(c.indices, eid)
        push!(c.data, v)
        return v
    end
    @inbounds c.data[c.indices[eid]] = v
    return v
end
@inline function Base.setindex!(c::SharedComponent{T}, v::T, e::Entity) where {T}
    eid = e.id
    t_shared_id = findfirst(x->x == v, c.shared)
    shared_id = t_shared_id === nothing ? (push!(c.shared, v); length(c.shared)) : t_shared_id
    @boundscheck if !in(e, c)
        push!(c.indices, eid)
        push!(c.data, shared_id)
        return v
    end
    @inbounds c.data[c.indices[eid]] = shared_id
    return v
end

function Base.empty!(c::Component)
    empty!(c.indices)
    empty!(c.data)
    return c
end
function Base.empty!(c::SharedComponent)
    empty!(c.indices)
    empty!(c.data)
    empty!(c.shared)
    return c
end

function swap_order!(c::AbstractComponent, e1::Entity, e2::Entity)
    @boundscheck if !in(e1, c)
        throw(BoundsError(c, e1))
    elseif !in(e2, c)
        throw(BoundsError(c, e2))
    end
    @inbounds begin
        id1, id2 = swap_order!(c.indices, e1.id, e2.id)
        c.data[id1], c.data[id2] = c.data[id2], c.data[id1]
    end
end

function pop_indices_data!(c::AbstractComponent, e::Entity)
    @boundscheck if !in(e, c)
        throw(BoundsError(c, e))
    end
    n = length(c)
    @inbounds begin
        id = c.indices[e.id]
        v = c.data[id]
        c.data[id] = c.data[end]
        pop!(c.data)
        pop!(c.indices, e.id)
        return v 
    end
end

Base.pop!(c::Component, e::Entity) = pop_indices_data!(c, e)

function Base.pop!(c::SharedComponent, e::Entity)
    i = pop_indices_data!(c, e)
    idvec = c.data
    val = c.shared[i]
    if !any(isequal(i), idvec)
        for j in 1:length(idvec)
            if idvec[j] > i
                idvec[j] -= 1
            end
        end
        deleteat!(c.shared, i)
    end
    return val
end

@inline Base.iterate(c::Component, args...) = iterate(c.data, args...)
@inline Base.iterate(c::SharedComponent, args...) = iterate(c.shared, args...)

function ensure_entity_id!(c::AbstractComponent, e::Int, id::Int)
    indices = c.indices
    @inbounds packed_id = indices[e]
    if packed_id != id
        @inbounds id_to_swap = indices.packed[id]
        swap_order!(indices, e, id_to_swap)
        c.data[id], c.data[packed_id] = c.data[packed_id], c.data[id]
    end
    return true
end

function shared_entity_ids(cs)
    l, id = findmin(map(length, cs))
    shortest = cs[id]
    shared_entity_ids = Int[]
    for (i, e) in enumerate(shortest.indices)
        if all(x->in(e, x.indices), cs)
            push!(shared_entity_ids, e)
        end
    end
    return shared_entity_ids
end

Base.sortperm(c::SharedComponent) = sortperm(c.data)

@inline function Base.hash(c::C, h::UInt) where {C <: AbstractComponent}
    for f in nfields(c)
        h = hash(getfield(c,f), h)
    end
    return h
end
########################################
#                                      #
#            Iteration                 #
#                                      #
########################################
struct EntityIterator{T <: Union{IndicesIterator,Indices,AbstractGroup}}
    it::T
end

Base.eltype(::EntityIterator) = Entity
Base.IteratorSize(i::EntityIterator) = Base.IteratorSize(i.it)
Base.length(i::EntityIterator) = length(i.it)

function Base.iterate(i::EntityIterator, state = 1)
    n = iterate(i.it, state)
    n === nothing && return n
    return Entity(n[1]), n[2]
end

macro entities_in(indices_expr)
    expr, t_sets, t_orsets = expand_indices_bool(indices_expr)
    if length(t_sets) == 1 && isempty(t_orsets) && expr.args[2] isa Symbol
        return esc(:(Overseer.EntityIterator(Overseer.indices_iterator($(t_sets[1])))))
    else
        return esc(quote
            t_comps = $(Expr(:tuple, t_sets...))
            t_or_comps = $(Expr(:tuple, t_orsets...))
            sets = map(Overseer.indices_iterator, t_comps)
            orsets = map(Overseer.indices_iterator, t_or_comps)
            if isempty(sets)
                minlen, minid = findmin(map(length, orsets))
                t_shortest = orsets[minid]
            else
                minlen, minid = findmin(map(length, sets))
                t_shortest = sets[minid]
            end
            if $(!isempty(t_orsets))
                shortest = deepcopy(t_shortest)
                for s in orsets
                    union!(shortest, s)
                end
            else
                shortest = t_shortest
            end
            Overseer.EntityIterator(Overseer.IndicesIterator(shortest, x->$expr))
        end)
    end
end

Base.getindex(iterator::EntityIterator, i) = Entity(iterator.it.shortest.packed[i])

function Base.:(==)(c1::C1, c2::C2) where {C1 <: AbstractComponent, C2 <: AbstractComponent}
    if eltype(C1) != eltype(C2) ||length(c1) != length(c2)
        return false
    elseif length(c1) > 20 && hash(c1) != hash(c2)
        return false
    else
        return all(e -> (e in c2) && (@inbounds c2[e] == c1[e]), @entities_in(c1))
    end
end

##############################
#                            #
#     Component Macros       #
#                            #
##############################

function process_typedef(typedef, mod)
    global td = nothing
    MacroTools.postwalk(typedef) do x
        if @capture(x, struct T_ fields__ end | mutable struct T_ fields__ end)
            global td = T
        end
        x
    end
    tn = MacroTools.namify(td)
    if @capture(td, T_ <: V_)
        if !Base.eval(mod, :($V <: Overseer.ComponentData)) 
            error("Components can only have supertypes which are subtypes of ComponentData.")
        else
            return typedef, tn
        end
    else
        typedef_ = MacroTools.postwalk(typedef) do x
            if MacroTools.isexpr(x) && x.head == :struct
                x.args[2] = :($(x.args[2]) <: Overseer.ComponentData)
            end
            x
        end
        return typedef_, tn
    end
end

macro component(typedef)
	return esc(Overseer._component(typedef, __module__))
end
function _component(typedef, mod)
    t = process_typedef(typedef, mod)
	t1, tn = t
	return quote
	    $t1
        Overseer.component_type(::Type{$tn}) = Overseer.Component
    end
end

macro shared_component(typedef)
    return esc(Overseer._shared_component(typedef, __module__))
end

function _shared_component(typedef, mod)
    t = process_typedef(typedef, mod)
    t1, tn = t 
    return quote
        $t1
       	Overseer.component_type(::Type{$tn}) = Overseer.SharedComponent
    end
end


################################################################################

struct ApplyToGroup
    e::Entity
end

Base.parent(e::Entity) = ApplyToGroup(e)

struct GroupedComponent{T <: ComponentData} <: AbstractComponent{T}
    indices::Indices
    group::Vector{Int}
    group_size::Vector{Int}
    data::Vector{T}
end

GroupedComponent{T}() where {T <: ComponentData} = GroupedComponent{T}(Indices(), Int[], Int[], T[])

Base.@propagate_inbounds @inline Base.getindex(c::GroupedComponent, e::Entity) = c.data[c.group[c.indices[e.id]]]
Base.@propagate_inbounds @inline Base.getindex(c::GroupedComponent, i::Integer) = c.data[c.group[i]]

function is_unique_in(value, collection)
    count = 0
    for element in collection
        count += element == value
    end
    return count == 1
end


# c[entity] = value
# set value of <only> this entity
@inline function Base.setindex!(c::GroupedComponent{T}, v::T, e::Entity) where {T}
    eid = e.id
    @inbounds if in(e, c)
        g = c.group[c.indices[eid]]
        if c.group_size[g] == 1 #is_unique_in(c.group[c.indices[eid]], c.group)
            # the entity already has its own group - adjust value
            c.data[g] = v
        else
            # the entity is part of a group - create a new one
            c.group_size[g] -= 1
            push!(c.data, v)
            push!(c.group_size, 1)
            c.group[c.indices[eid]] = length(c.data)
        end
    else
        # the entity is not in the component - add it
        push!(c.indices, eid)
        push!(c.group, length(c.group)+1)
        push!(c.group_size, 1)
        push!(c.data, v)
    end
    return v
end

# c[entity] = parent
# set the value of this entity to that of parent
@inline function Base.setindex!(c::GroupedComponent, p::Entity, e::Entity)
    @boundscheck if !in(p, c)
        throw(BoundsError(c, p))
    end
    pg = c.group[c.indices[p.id]]
    if in(e, c)
        eg = c.group[c.indices[e.id]]
        if c.group_size[eg] == 1 #is_unique_in(c.group[c.indices[eid]], c.group)
            # if this entity is the only one holding onto a value, remove that 
            # value and cleanup group indices
            deleteat!(c.data, idx)
            deleteat!(c.group_size, idx)
            for i in eachindex(c.group)
                c.group[i] = c.group[i] - (c.group[i] > eg)
            end
        else
            c.group_size[eg] -= 1
        end
        # adjust group index either way
        c.group[c.indices[e.id]] = pg
    else
        # if the entity is not in there we have to add it
        push!(c.indices, e.id)
        push!(c.group, c.group[c.indices[p.id]])
    end
    c.group_size[pg] += 1

    return c[p]
end

# c[ParentGroup(entity)] = value
# set the value for all entities grouped with entity
@inline function Base.setindex!(c::GroupedComponent{T}, v::T, x::ApplyToGroup) where {T}
    e = x.e
    @boundscheck if !in(e, c)
        throw(BoundsError(c, e))
    end
    @inbounds c.data[c.group[c.indices[e.id]]] = v
    return v
end


Base.length(c::GroupedComponent) = length(c.group)

function Base.empty!(c::GroupedComponent)
    empty!(c.indices)
    empty!(c.group)
    empty!(c.group_size)
    empty!(c.data)
    return c
end


function Base.pop!(c::GroupedComponent, e::Entity)
    @boundscheck if !in(e, c)
        throw(BoundsError(c, e))
    end

    @inbounds begin
        id = c.indices[e.id]
        g = c.group[id]

        c.group[id] = c.group[end]
        c.group_size[g] -= 1
        pop!(c.group)
        pop!(c.indices, e.id)

        val = c.data[g]

        if c.group_size[g] == 0
            deleteat!(c.data, g)
            deleteat!(c.group_size, g)
            for i in eachindex(c.group)
                if c.group[i] > g
                    c.group[i] -= 1
                end
            end
        end
    end

    return val
end

@inline Base.iterate(c::GroupedComponent, args...) = iterate(c.data, args...)
Base.sortperm(c::GroupedComponent) = sortperm(c.group)


macro grouped_component(typedef)
    return esc(Overseer._grouped_component(typedef, __module__))
end

function _grouped_component(typedef, mod)
    t = process_typedef(typedef, mod)
    t1, tn = t 
    return quote
        $t1
       	Overseer.component_type(::Type{$tn}) = Overseer.GroupedComponent
    end
end

function make_unique!(c::GroupedComponent)
    # Find all duplicates
    for i in eachindex(c.group)
        g0 = c.group[i]
        if c.group_size[g0] > 0
            v0 = c.data[g0]
            for j in i+1:length(c.group)
                g = c.group[j]
                if c.group_size[g] > 0 && c.data[g] == v0
                    c.group_size[g] -= 1
                    c.group_size[g0] += 1
                    c.group[j] = g0
                end
            end
        end
    end

    # remove duplicates
    i = 1
    while i <= length(c.group_size)
        if c.group_size[i] == 0
            if i == length(c.group_size)
                pop!(c.group_size)
                pop!(c.data)
                break
            else
                N = length(c.group_size)
                c.group_size[i] = pop!(c.group_size)
                c.data[i] = pop!(c.data)
                for j in eachindex(c.group)
                    c.group[j] = c.group[j] == N ? i : c.group[j]
                end
            end
        else
            i += 1
        end
    end

    return
end