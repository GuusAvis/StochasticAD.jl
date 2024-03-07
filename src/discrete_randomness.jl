## Helper functions for discrete distributions 

# index of the parameter p
_param_index(::Geometric) = 1
_param_index(::Bernoulli) = 1
_param_index(::Binomial) = 2
_param_index(::Poisson) = 1
_param_index(::Categorical) = 1

_get_parameter(d) = params(d)[_param_index(d)]

# constructors
for dist in [:Geometric, :Bernoulli, :Binomial, :Poisson, :Categorical]
    @eval _constructor(::$dist) = $dist
end

# reconstruct probability distribution with new paramter value
function _reconstruct(d, p)
    i = _param_index(d)
    return _constructor(d)(params(d)[1:(i - 1)]..., p, params(d)[(i + 1):end]...)
end

# support of probability distribution
_has_finite_support(d) = false
_has_finite_support(d::Union{Bernoulli, Binomial, Categorical}) = true

_get_support(d::Union{Bernoulli, Binomial, Categorical}) = minimum(d):maximum(d)
# manual overloads to ensure that static-ness is preserved for Bernoulli's and Categoricals with static arrays.
# since mapping over the range above could result in allocating vectors.
_get_support(::Bernoulli) = (0, 1)
# the map below looks a bit silly, but it gives us a collection of the categories with the same structure as probs(d). 
_get_support(d::Categorical) = map((val, prob) -> val, 1:ncategories(d), probs(d))

# Derivative coupling approaches, determining which weighted perturbations to consider

abstract type AbstractDerivativeCoupling end
struct InversionMethodDerivativeCoupling end

## Strategies for precisely which perturbations to form given a derivative coupling

struct SingleSidedStrategy <: AbstractPerturbationStrategy end
struct TwoSidedStrategy <: AbstractPerturbationStrategy end
struct SmoothedStraightThroughStrategy <: AbstractPerturbationStrategy end
struct StraightThroughStrategy <: AbstractPerturbationStrategy end
struct IgnoreDiscreteStrategy <: AbstractPerturbationStrategy end

new_Δs_strategy(Δs) = SingleSidedStrategy()

"""
    δtoΔs(d, val, δ, Δs::AbstractFIs)

Given the parameter `val` of a distribution `d` and an infinitesimal change `δ`,
return the discrete change in the output, with a similar representation to `Δs`.
"""
δtoΔs(d, val, δ, Δs, derivative_coupling) = δtoΔs(d, val, δ, Δs, derivative_coupling, new_Δs_strategy(Δs))
δtoΔs(d, val, δ, Δs, derivative_coupling, ::SingleSidedStrategy) = _δtoΔs(d, val, δ, Δs, derivative_coupling)
function δtoΔs(d, val, δ, Δs, derivative_coupling, ::TwoSidedStrategy)
    Δs1 = _δtoΔs(d, val, δ, Δs, derivative_coupling)
    Δs2 = _δtoΔs(d, val, -δ, Δs, derivative_coupling)
    return combine((scale(Δs1, 0.5), scale(Δs2, -0.5)))
end
# TODO: implement this ST for other distributions and couplings, if meaningful?
function δtoΔs(d::Union{Bernoulli, Binomial},
        val,
        δ,
        Δs,
        derivative_coupling::InversionMethodDerivativeCoupling,
        ::StraightThroughStrategy)
    p = succprob(d)
    Δs1 = _δtoΔs(d, val, δ, Δs, derivative_coupling)
    Δs2 = _δtoΔs(d, val, -δ, Δs, derivative_coupling)
    return combine((scale(Δs1, 1 - p), scale(Δs2, -p)))
end
δtoΔs(d, val::V, δ, Δs, derivative_coupling, ::IgnoreDiscreteStrategy) where {V} = similar_empty(Δs, V)

# Implement straight through strategy, works for all distrs, but does something that is only
# meaningful for smoothed backends (using one(val))
function δtoΔs(d, val, δ, Δs, derivative_coupling, ::SmoothedStraightThroughStrategy)
    p = _get_parameter(d)
    δout = ForwardDiff.derivative(a -> mean(_reconstruct(d, p + a * δ)), 0.0)
    return similar_new(Δs, one(val), δout)
end

## Stochastic derivative rules for discrete distributions

function _δtoΔs(d::Geometric,
        val::V,
        δ::Real,
        Δs::AbstractFIs,
        ::InversionMethodDerivativeCoupling) where {V <: Signed}
    p = succprob(d)
    if δ > 0
        return val > 0 ? similar_new(Δs, -one(V), δ * val / p / (1 - p)) :
               similar_empty(Δs, V)
    elseif δ < 0
        return similar_new(Δs, one(V), -δ * (val + 1) / p)
    else
        return similar_empty(Δs, V)
    end
end

function _δtoΔs(d::Bernoulli,
        val::V,
        δ::Real,
        Δs::AbstractFIs,
        ::InversionMethodDerivativeCoupling) where {V <: Signed}
    p = succprob(d)
    if δ > 0
        return isone(val) ? similar_empty(Δs, V) : similar_new(Δs, one(V), δ / (1 - p))
    elseif δ < 0
        return isone(val) ? similar_new(Δs, -one(V), -δ / p) : similar_empty(Δs, V)
    else
        return similar_empty(Δs, V)
    end
end

function _δtoΔs(d::Binomial,
        val::V,
        δ::Real,
        Δs::AbstractFIs,
        ::InversionMethodDerivativeCoupling) where {V <: Signed}
    p = succprob(d)
    n = ntrials(d)
    if δ > 0
        return val == n ? similar_empty(Δs, V) :
               similar_new(Δs, one(V), δ * (n - val) / (1 - p))
    elseif δ < 0
        return !iszero(val) ? similar_new(Δs, -one(V), -δ * val / p) : similar_empty(Δs, V)
    else
        return similar_empty(Δs, V)
    end
end

function _δtoΔs(d::Poisson,
        val::V,
        δ::Real,
        Δs::AbstractFIs,
        ::InversionMethodDerivativeCoupling) where {V <: Signed}
    p = mean(d) # rate
    if δ > 0
        return similar_new(Δs, 1, δ)
    elseif δ < 0
        return val > 0 ? similar_new(Δs, -1, -δ * val / p) : similar_empty(Δs, V)
    else
        return similar_empty(Δs, V)
    end
end

function _δtoΔs(d::Categorical,
        val::V,
        δs,
        Δs::AbstractFIs,
        ::InversionMethodDerivativeCoupling) where {V <: Signed}
    p = params(d)[1]
    left_sum = sum(δs[1:(val - 1)], init = zero(V))
    right_sum = -sum(δs[(val + 1):end], init = zero(V))

    if left_sum > 0
        stop = rand() * left_sum
        upto = zero(eltype(δs)) # The "upto" logic handles an edge case of probability 0 events that have non-zero derivative.
        # It's a lot of logic to handle an edge case, but hopefully it's optimized away.
        local left_nonzero
        for i in (val - 1):-1:1
            if !iszero(p[i]) || ((upto += δs[i]) > stop)
                left_nonzero = i
                break
            end
        end
        Δs_left = similar_new(Δs, left_nonzero - val, left_sum / p[val])
    else
        Δs_left = similar_empty(Δs, typeof(val))
    end

    if right_sum < 0
        stop = -rand() * right_sum
        upto = zero(eltype(δs))
        local right_nonzero
        for i in (val + 1):length(p)
            if !iszero(p[i]) || ((upto += δs[i]) > stop)
                right_nonzero = i
                break
            end
        end
        Δs_right = similar_new(Δs, right_nonzero - val, -right_sum / p[val])
    else
        Δs_right = similar_empty(Δs, typeof(val))
    end

    return combine((Δs_left, Δs_right); rep = Δs)
end

# Define randst interface

"""
    randst(rng, d::Distributions.Sampleable; kwargs...)

When no keyword arguments are provided, `randst` behaves identically to `rand(rng, d)` in both ordinary computation
and for stochastic triple dispatches. However, `randst` also allows the user to provide various keyword arguments
for customizing the differentiation logic. The set of allowed keyword arguments depends on the type of `d`.

For developers: if you wish to accept custom keyword arguments in a stochastic triple dispatch, you should overload
`randst`, and redirect `rand` to your `randst` method. If you do not, it suffices to just overload `rand`.
"""
randst(rng, d::Distributions.Sampleable; kwargs...) = rand(rng, d)
randst(d::Distributions.Sampleable; kwargs...) = randst(Random.default_rng(), d; kwargs...)

# Define stochastic triple rules

for dist in [:Geometric, :Bernoulli, :Binomial, :Poisson]
    @eval function Base.rand(rng::AbstractRNG,
            d_st::$dist{StochasticTriple{T, V, FIs}}) where {T, V, FIs}
        return randst(rng, d_st)
    end
    @eval function randst(rng::AbstractRNG,
            d_st::$dist{StochasticTriple{T, V, FIs}};
            Δ_kwargs = (;),
            derivative_coupling = InversionMethodDerivativeCoupling()) where {T, V, FIs}
        st = _get_parameter(d_st)
        d = _reconstruct(d_st, st.value)
        val = convert(Signed, rand(rng, d))
        Δs1 = δtoΔs(d, val, st.δ, st.Δs, derivative_coupling)

        low = cdf(d, val - 1)
        high = cdf(d, val)

        get_alt_d(Δ) = _reconstruct(d_st, st.value + Δ)
        function map_func(Δ)
            alt_d = get_alt_d(Δ)
            alt_val = quantile(alt_d, rand(RNG) * (high - low) + low)
            convert(Signed, alt_val - val)
        end
        function enumeration(Δ, _)
            alt_d = get_alt_d(Δ)
            if _has_finite_support(alt_d)
                map(_get_support(alt_d)) do alt_val
                    # interval intersect of (cdf(alt_d, alt_val - 1), cdf(alt_d, alt_val)) and (low, high)
                    alt_low = cdf(alt_d, alt_val - 1)
                    alt_high = cdf(alt_d, alt_val)
                    prob_alt = max(0.0, min(alt_high, high) - max(alt_low, low)) /
                               (high - low)
                    return (alt_val - val, prob_alt)
                end
            else
                error("enumeration not supported for distribution $d. Does $d have finite support?")
            end
        end
        Δs2 = map(map_func,
            st.Δs;
            enumeration,
            deriv = δ -> smoothed_delta(d, val, δ, derivative_coupling),
            out_rep = val,
            Δ_kwargs...)

        StochasticTriple{T}(val, zero(val), combine((Δs2, Δs1); rep = Δs1)) # ensure that tags are in order in combine, in case backend wishes to exploit this 
    end
end

# currently handle Categorical separately since parameter is a vector
# what if some elements in vector are not stochastic triples... promotion should take care of that?
function Base.rand(rng::AbstractRNG,
        d_st::Categorical{StochasticTriple{T, V, FIs}}) where {T, V, FIs}
    return randst(rng, d_st)
end
function randst(rng::AbstractRNG,
        d_st::Categorical{<:StochasticTriple{T},
            <:AbstractVector{<:StochasticTriple{T, V}}};
        Δ_kwargs = (;),
        derivative_coupling = InversionMethodDerivativeCoupling()) where {T,
        V}
    sts = _get_parameter(d_st) # stochastic triple for each probability
    p = map(st -> st.value, sts) # try to keep the same type. e.g. static array -> static array. TODO: avoid allocations 
    d = _reconstruct(d_st, p)
    val = convert(Signed, rand(rng, d))

    Δs_all = map(st -> st.Δs, sts)
    Δs_rep = get_rep(Δs_all)

    Δs1 = δtoΔs(d, val, map(st -> st.δ, sts), Δs_rep, derivative_coupling)

    low = cdf(d, val - 1)
    high = cdf(d, val)
    Δs_coupled = couple(Δs_all; rep = Δs_rep, out_rep = p) # TODO: again, there are possible allocations here

    get_alt_d(Δ) = _reconstruct(d, p .+ Δ)
    function map_func(Δ)
        alt_d = get_alt_d(Δ)
        alt_val = quantile(alt_d, rand(RNG) * (high - low) + low)
        convert(Signed, alt_val - val)
    end
    function enumeration(Δ, _)
        alt_d = get_alt_d(Δ)
        if _has_finite_support(alt_d)
            map(_get_support(alt_d)) do alt_val
                # interval intersect of (cdf(alt_d, alt_val - 1), cdf(alt_d, alt_val)) and (low, high)
                alt_low = cdf(alt_d, alt_val - 1)
                alt_high = cdf(alt_d, alt_val)
                prob_alt = max(0.0, min(alt_high, high) - max(alt_low, low)) / (high - low)
                return (alt_val - val, prob_alt)
            end
        else
            error("enumeration not supported for distribution $d. Does $d have finite support?")
        end
    end
    Δs2 = map(map_func,
        Δs_coupled;
        enumeration,
        deriv = δ -> smoothed_delta(d, val, δ, derivative_coupling),
        out_rep = val,
        Δ_kwargs...)

    Δs = combine((Δs2, Δs1); rep = Δs1, out_rep = val, Δ_kwargs...)

    StochasticTriple{T}(val, zero(val), Δs) 
end

## Handling finite perturbation to Binomial number of trials

"""
    DiscreteDeltaStochasticTriple{T, V, FIs <: AbstractFIs}

An experimental discrete stochastic triple type used internally for representing perturbations
to non-real quantities. Currently only used to represent a finite perturbation to the Binomial 
parameter n.

## Constructor

- `value`: the primal value.
- `Δs``: some representation of the perturbation to the primal, which can have an unconventional
         interpretation depending on `T`.
"""
struct DiscreteDeltaStochasticTriple{T, V, FIs <: AbstractFIs}
    value::V
    Δs::FIs
    function DiscreteDeltaStochasticTriple{T, V, FIs}(value::V,
            Δs::FIs) where {T, V,
            FIs <: AbstractFIs}
        new{T, V, FIs}(value, Δs)
    end
end

function DiscreteDeltaStochasticTriple{T}(val::V, Δs::FIs) where {T, V, FIs <: AbstractFIs}
    DiscreteDeltaStochasticTriple{T, V, FIs}(val, Δs)
end

function Distributions.Binomial(n::StochasticTriple{T}, p::Real) where {T}
    return DiscreteDeltaStochasticTriple{T}(Binomial(n.value, p), n.Δs)
end

# TODO: Support functions other than `rand` called on a perturbed Binomial.
function Base.rand(rng::AbstractRNG,
        d_st::DiscreteDeltaStochasticTriple{T, <:Binomial}) where {T}
    return randst(rng, d_st)
end
function randst(rng::AbstractRNG,
        d_st::DiscreteDeltaStochasticTriple{T, <:Binomial}) where {T}
    d = d_st.value
    val = rand(rng, d)
    function map_func(Δ)
        if Δ >= 0
            return rand(StochasticAD.RNG, Binomial(Δ, value(succprob(d))))
        else
            return -rand(StochasticAD.RNG,
                Hypergeometric(value(val), ntrials(d) - value(val), -Δ))
        end
    end
    Δs = map(map_func, d_st.Δs)
    if val isa StochasticTriple
        return StochasticTriple{T}(val.value, val.δ, combine((Δs, val.Δs); rep = Δs))
    else
        return StochasticTriple{T}(val, zero(val), Δs)
    end
end
