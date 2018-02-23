#
# Conjugate gradient line search implementation from:
#   W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
#     conjugate gradient method with guaranteed descent. ACM
#     Transactions on Mathematical Software 32: 113–137.
#
# Code comments such as "HZ, stage X" or "HZ, eqs Y" are with
# reference to a particular point in this paper.
#
# There are some modifications and/or extensions from what's in the
# paper (these may or may not be extensions of the cg_descent code
# that can be downloaded from Hager's site; his code has undergone
# numerous revisions since publication of the paper):
# linesearch: the Wolfe conditions are checked only after alpha is
#   generated either by quadratic interpolation or secant
#   interpolation, not when alpha is generated by bisection or
#   expansion. This increases the likelihood that alpha will be a
#   good approximation of the minimum.
#
# linesearch: In step I2, we multiply by psi2 only if the convexity
#   test failed, not if the function-value test failed. This
#   prevents one from going uphill further when you already know
#   you're already higher than the point at alpha=0.
#
# both: checks for Inf/NaN function values
#
# both: support maximum value of alpha (equivalently, c). This
#   facilitates using these routines for constrained minimization
#   when you can calculate the distance along the path to the
#   disallowed region. (When you can't easily calculate that
#   distance, it can still be handled by returning Inf/NaN for
#   exterior points. It's just more efficient if you know the
#   maximum, because you don't have to test values that won't
#   work.) The maximum should be specified as the largest value for
#   which a finite value will be returned.  See, e.g., limits_box
#   below.  The default value for alphamax is Inf. See alphamaxfunc
#   for cgdescent and alphamax for HagerZhang.



# TODO: Remove these bitfield things and create a proper
# tracing functionality instead

# Display flags are represented as a bitfield
# (not exported, but can use via LineSearches.ITER, for example)
const one64 = convert(UInt64, 1)
const FINAL       = one64
const ITER        = one64 << 1
const PARAMETERS  = one64 << 2
const GRADIENT    = one64 << 3
const SEARCHDIR   = one64 << 4
const ALPHA       = one64 << 5
const BETA        = one64 << 6
# const ALPHAGUESS  = one64 << 7 TODO: not needed
const BRACKET     = one64 << 8
const LINESEARCH  = one64 << 9
const UPDATE      = one64 << 10
const SECANT2     = one64 << 11
const BISECT      = one64 << 12
const BARRIERCOEF = one64 << 13
display_nextbit = 14


const DEFAULTDELTA = 0.1 # Values taken from HZ paper (Nocedal & Wright recommends 0.01?)
const DEFAULTSIGMA = 0.9 # Values taken from HZ paper (Nocedal & Wright recommends 0.1 for GradientDescent)


# NOTE:
#   [1] The type `T` in the `HagerZhang{T}` need not be the same `T` as in
#       `hagerzhang!{T}`; in the latter, `T` comes from the input vector `x`.
#   [2] the only method parameter that is not included in the
#       type is `iterfinitemax` since this value needs to be
#       inferred from the input vector `x` and not from the type information
#       on the parameters


"""
Conjugate gradient line search implementation from:
  W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
    conjugate gradient method with guaranteed descent. ACM
    Transactions on Mathematical Software 32: 113–137.
"""
@with_kw struct HagerZhang{T}
   delta::T = DEFAULTDELTA # c_1 Wolfe sufficient decrease condition
   sigma::T = DEFAULTSIGMA # c_2 Wolfe curvature condition (Recommend 0.1 for GradientDescent)
   alphamax::T = Inf
   rho::T = 5.0
   epsilon::T = 1e-6
   gamma::T = 0.66
   linesearchmax::Int = 50
   psi3::T = 0.1
   display::Int = 0
end

(ls::HagerZhang)(args...) = _hagerzhang!(args...,
      ls.delta, ls.sigma, ls.alphamax, ls.rho, ls.epsilon, ls.gamma,
      ls.linesearchmax, ls.psi3, ls.display)


function _hagerzhang!(df,
                     x::AbstractArray{T},
                     s::AbstractArray{T},
                     xtmp::AbstractArray{T},
                     lsr::LineSearchResults{T},
                     c::T,
                     mayterminate::Bool,
                     delta::Real = T(DEFAULTDELTA),
                     sigma::Real = T(DEFAULTSIGMA),
                     alphamax::Real = convert(T,Inf),
                     rho::Real = convert(T,5),
                     epsilon::Real = convert(T,1e-6),
                     gamma::Real = convert(T,0.66),
                     linesearchmax::Integer = 50,
                     psi3::Real = convert(T,0.1),
                     display::Integer = 0) where T
    # Prevent values of `xtmp` that are likely to make
    # df.f(xtmp) infinite
    iterfinitemax::Int = ceil(Int, -log2(T(eps(T))))
    if display & LINESEARCH > 0
        println("New linesearch")
    end

    phi0 = lsr.value[1] # Should this be [1] or [end]?
    dphi0 = lsr.slope[1] # Should this be [1] or [end]?
    (isfinite(phi0) && isfinite(dphi0)) || error("Initial value and slope must be finite")
    philim = phi0 + epsilon * abs(phi0)
    @assert c > 0
    @assert isfinite(c) && c <= alphamax
    phic, dphic = linefunc!(df, x, s, c, xtmp, true)
    iterfinite = 1
    while !(isfinite(phic) && isfinite(dphic)) && iterfinite < iterfinitemax
        mayterminate = false
        lsr.nfailures += 1
        iterfinite += 1
        c *= psi3
        phic, dphic = linefunc!(df, x, s, c, xtmp, true)
    end
    if !(isfinite(phic) && isfinite(dphic))
        warn("Failed to achieve finite new evaluation point, using alpha=0")
        return zero(T) # phi0
    end
    push!(lsr, c, phic, dphic)
    # If c was generated by quadratic interpolation, check whether it
    # satisfies the Wolfe conditions
    if mayterminate &&
          satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
        if display & LINESEARCH > 0
            println("Wolfe condition satisfied on point alpha = ", c)
        end
        return c # phic
    end
    # Initial bracketing step (HZ, stages B0-B3)
    isbracketed = false
    ia = 1
    ib = 2
    @assert length(lsr) == 2
    iter = 1
    cold = -one(T)
    while !isbracketed && iter < linesearchmax
        if display & BRACKET > 0
            println("bracketing: ia = ", ia,
                    ", ib = ", ib,
                    ", c = ", c,
                    ", phic = ", phic,
                    ", dphic = ", dphic)
        end
        if dphic >= 0
            # We've reached the upward slope, so we have b; examine
            # previous values to find a
            ib = length(lsr)
            for i = (ib - 1):-1:1
                if lsr.value[i] <= philim
                    ia = i
                    break
                end
            end
            isbracketed = true
        elseif lsr.value[end] > philim
            # The value is higher, but the slope is downward, so we must
            # have crested over the peak. Use bisection.
            ib = length(lsr)
            ia = ib - 1
            if c ≉  lsr.alpha[ib] || lsr.slope[ib] >= 0
                error("c = ", c, ", lsr = ", lsr)
            end
            # ia, ib = bisect(phi, lsr, ia, ib, philim) # TODO: Pass options
            ia, ib = bisect!(df, x, s, xtmp, lsr, ia, ib, philim, display)
            isbracketed = true
        else
            # We'll still going downhill, expand the interval and try again
            cold = c
            c *= rho
            if c > alphamax
                c = (alphamax + cold)/2
                if display & BRACKET > 0
                    println("bracket: exceeding alphamax, bisecting: alphamax = ", alphamax, ", cold = ", cold, ", new c = ", c)
                end
                if c == cold || c + T(eps(T)) >= alphamax
                    return cold
                end
            end
            phic, dphic = linefunc!(df, x, s, c, xtmp, true)
            iterfinite = 1
            while !(isfinite(phic) && isfinite(dphic)) && c > cold + T(eps(T)) && iterfinite < iterfinitemax
                alphamax = c
                lsr.nfailures += 1
                iterfinite += 1
                if display & BRACKET > 0
                    println("bracket: non-finite value, bisection")
                end
                c = (cold + c) / 2
                phic, dphic = linefunc!(df, x, s, c, xtmp, true)
            end
            if !(isfinite(phic) && isfinite(dphic))
                return cold
            elseif dphic < 0 && c == alphamax
                # We're on the edge of the allowed region, and the
                # value is still decreasing. This can be due to
                # roundoff error in barrier penalties, a barrier
                # coefficient being so small that being eps() away
                # from it still doesn't turn the slope upward, or
                # mistakes in the user's function.
                if iterfinite >= iterfinitemax
                    println("Warning: failed to expand interval to bracket with finite values. If this happens frequently, check your function and gradient.")
                    println("c = ", c,
                            ", alphamax = ", alphamax,
                            ", phic = ", phic,
                            ", dphic = ", dphic)
                end
                return c
            end
            push!(lsr, c, phic, dphic)
        end
        iter += 1
    end
    while iter < linesearchmax
        a = lsr.alpha[ia]
        b = lsr.alpha[ib]
        @assert b > a
        if display & LINESEARCH > 0
            println("linesearch: ia = ", ia,
                    ", ib = ", ib,
                    ", a = ", a,
                    ", b = ", b,
                    ", phi(a) = ", lsr.value[ia],
                    ", phi(b) = ", lsr.value[ib])
        end
        if b - a <= T(eps(b))
            return a # lsr.value[ia]
        end
        iswolfe, iA, iB = secant2!(df, x, s, xtmp, lsr, ia, ib, philim, delta, sigma, display)
        if iswolfe
            return lsr.alpha[iA] # lsr.value[iA]
        end
        A = lsr.alpha[iA]
        B = lsr.alpha[iB]
        @assert B > A
        if B - A < gamma * (b - a)
            if display & LINESEARCH > 0
                println("Linesearch: secant succeeded")
            end
            if lsr.value[ia] + T(eps(T)) >= lsr.value[ib] && lsr.value[iA] + T(eps(T)) >= lsr.value[iB]
                # It's so flat, secant didn't do anything useful, time to quit
                if display & LINESEARCH > 0
                    println("Linesearch: secant suggests it's flat")
                end
                return A
            end
            ia = iA
            ib = iB
        else
            # Secant is converging too slowly, use bisection
            if display & LINESEARCH > 0
                println("Linesearch: secant failed, using bisection")
            end
            c = (A + B) / convert(T, 2)
            # phic = phi(gphi, c) # TODO: Replace
            phic, dphic = linefunc!(df, x, s, c, xtmp, true)
            @assert isfinite(phic) && isfinite(dphic)
            push!(lsr, c, phic, dphic)
            # ia, ib = update(phi, lsr, iA, iB, length(lsr), philim) # TODO: Pass options
            ia, ib = update!(df, x, s, xtmp, lsr, iA, iB, length(lsr), philim, display)
        end
        iter += 1
    end

    throw(LineSearchException("Linesearch failed to converge, reached maximum iterations $(linesearchmax).",
                              lsr.alpha[ia],lsr))


end

# Check Wolfe & approximate Wolfe
function satisfies_wolfe(c::T,
                         phic::Real,
                         dphic::Real,
                         phi0::Real,
                         dphi0::Real,
                         philim::Real,
                         delta::Real,
                         sigma::Real) where T<:Number
    wolfe1 = delta * dphi0 >= (phic - phi0) / c &&
               dphic >= sigma * dphi0
    wolfe2 = T(2 * delta - T(1)) * dphi0 >= dphic >= sigma * dphi0 &&
               phic <= philim
    return wolfe1 || wolfe2
end

# HZ, stages S1-S4
function secant(a::Real, b::Real, dphia::Real, dphib::Real)
    return (a * dphib - b * dphia) / (dphib - dphia)
end
function secant(lsr::LineSearchResults, ia::Integer, ib::Integer)
    return secant(lsr.alpha[ia], lsr.alpha[ib], lsr.slope[ia], lsr.slope[ib])
end
# phi
function secant2!(df,
                  x::AbstractArray,
                  s::AbstractArray,
                  xtmp::AbstractArray,
                  lsr::LineSearchResults{T},
                  ia::Integer,
                  ib::Integer,
                  philim::Real,
                  delta::Real = DEFAULTDELTA,
                  sigma::Real = DEFAULTSIGMA,
                  display::Integer = 0) where T
    phi0 = lsr.value[1]
    dphi0 = lsr.slope[1]
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    dphia = lsr.slope[ia]
    dphib = lsr.slope[ib]
    if !(dphia < 0 && dphib >= 0)
        error(string("Search direction is not a direction of descent; ",
                     "this error may indicate that user-provided derivatives are inaccurate. ",
                      @sprintf "(dphia = %f; dphib = %f)" dphia dphib))
    end
    c = secant(a, b, dphia, dphib)
    if display & SECANT2 > 0
        println("secant2: a = ", a, ", b = ", b, ", c = ", c)
    end
    @assert isfinite(c)
    # phic = phi(tmpc, c) # Replace
    phic, dphic = linefunc!(df, x, s, c, xtmp, true)
    @assert isfinite(phic) && isfinite(dphic)
    push!(lsr, c, phic, dphic)
    ic = length(lsr)
    if satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
        if display & SECANT2 > 0
            println("secant2: first c satisfied Wolfe conditions")
        end
        return true, ic, ic
    end
    # iA, iB = update(phi, lsr, ia, ib, ic, philim)
    iA, iB = update!(df, x, s, xtmp, lsr, ia, ib, ic, philim, display)
    if display & SECANT2 > 0
        println("secant2: iA = ", iA, ", iB = ", iB, ", ic = ", ic)
    end
    a = lsr.alpha[iA]
    b = lsr.alpha[iB]
    doupdate = false
    if iB == ic
        # we updated b, make sure we also update a
        c = secant(lsr, ib, iB)
    elseif iA == ic
        # we updated a, do it for b too
        c = secant(lsr, ia, iA)
    end
    if a <= c <= b
        if display & SECANT2 > 0
            println("secant2: second c = ", c)
        end
        # phic = phi(tmpc, c) # TODO: Replace
        phic, dphic = linefunc!(df, x, s, c, xtmp, true)
        @assert isfinite(phic) && isfinite(dphic)
        push!(lsr, c, phic, dphic)
        ic = length(lsr)
        # Check arguments here
        if satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
            if display & SECANT2 > 0
                println("secant2: second c satisfied Wolfe conditions")
            end
            return true, ic, ic
        end
        iA, iB = update!(df, x, s, xtmp, lsr, iA, iB, ic, philim, display)
    end
    if display & SECANT2 > 0
        println("secant2 output: a = ", lsr.alpha[iA], ", b = ", lsr.alpha[iB])
    end
    return false, iA, iB
end

# HZ, stages U0-U3
# Given a third point, pick the best two that retain the bracket
# around the minimum (as defined by HZ, eq. 29)
# b will be the upper bound, and a the lower bound
function update!(df,
                 x::AbstractArray,
                 s::AbstractArray,
                 xtmp::AbstractArray,
                 lsr::LineSearchResults,
                 ia::Integer,
                 ib::Integer,
                 ic::Integer,
                 philim::Real,
                 display::Integer = 0)
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    # Debugging (HZ, eq. 4.4):
    @assert lsr.slope[ia] < 0
    @assert lsr.value[ia] <= philim
    @assert lsr.slope[ib] >= 0
    @assert b > a
    c = lsr.alpha[ic]
    phic = lsr.value[ic]
    dphic = lsr.slope[ic]
    if display & UPDATE > 0
        println("update: ia = ", ia,
                ", a = ", a,
                ", ib = ", ib,
                ", b = ", b,
                ", c = ", c,
                ", phic = ", phic,
                ", dphic = ", dphic)
    end
    if c < a || c > b
        return ia, ib, 0, 0  # it's out of the bracketing interval
    end
    if dphic >= 0
        return ia, ic, 0, 0  # replace b with a closer point
    end
    # We know dphic < 0. However, phi may not be monotonic between a
    # and c, so check that the value is also smaller than phi0.  (It's
    # more dangerous to replace a than b, since we're leaving the
    # secure environment of alpha=0; that's why we didn't check this
    # above.)
    if phic <= philim
        return ic, ib, 0, 0  # replace a
    end
    # phic is bigger than phi0, which implies that the minimum
    # lies between a and c. Find it via bisection.
    return bisect!(df, x, s, xtmp, lsr, ia, ic, philim, display)
end

# HZ, stage U3 (with theta=0.5)
function bisect!(df,
                 x::AbstractArray,
                 s::AbstractArray,
                 xtmp::AbstractArray,
                 lsr::LineSearchResults{T},
                 ia::Integer,
                 ib::Integer,
                 philim::Real,
                 display::Integer = 0) where T
    gphi = convert(T, NaN)
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    # Debugging (HZ, conditions shown following U3)
    @assert lsr.slope[ia] < 0
    @assert lsr.value[ia] <= philim
    @assert lsr.slope[ib] < 0       # otherwise we wouldn't be here
    @assert lsr.value[ib] > philim
    @assert b > a
    while b - a > T(eps(b))
        if display & BISECT > 0
            println("bisect: a = ", a, ", b = ", b, ", b - a = ", b - a)
        end
        d = (a + b) / convert(T, 2)
        phid, gphi = linefunc!(df, x, s, d, xtmp, true)
        @assert isfinite(phid) && isfinite(gphi)
        push!(lsr, d, phid, gphi)
        id = length(lsr)
        if gphi >= 0
            return ia, id # replace b, return
        end
        if phid <= philim
            a = d # replace a, but keep bisecting until dphib > 0
            ia = id
        else
            b = d
            ib = id
        end
    end
    return ia, ib
end

# Define one-parameter function for line searches
function linefunc!(df,
                   x::AbstractArray,
                   s::AbstractArray,
                   alpha::Real,
                   xtmp::AbstractArray,
                   calc_grad::Bool)
    for i = 1:length(x)
        xtmp[i] = x[i] + alpha * s[i]
    end
    gphi = convert(eltype(s), NaN)
    if calc_grad
        val = NLSolversBase.value_gradient!(df,xtmp)
        if isfinite(val)
            gphi = vecdot(NLSolversBase.gradient(df), s)
        end
    else
        val = value!(df,xtmp)
    end
    return val, gphi
end

"""
Initial step size algorithm from
  W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
    conjugate gradient method with guaranteed descent. ACM
    Transactions on Mathematical Software 32: 113–137.

If α0 is NaN, then procedure I0 is called at the first iteration,
otherwise, we select according to procedure I1-2, with starting value α0.
"""
@with_kw struct InitialHagerZhang{T}
    ψ0::T         = 0.01
    ψ1::T         = 0.2
    ψ2::T         = 2.0
    ψ3::T         = 0.1
    αmax::T       = Inf
    α0::T         = 1.0 # Initial alpha guess. NaN => algorithm calculates
    verbose::Bool = false
end


function (is::InitialHagerZhang)(state, dphi0, df)
    if isnan(state.f_x_previous) && isnan(is.α0)
        # If we're at the first iteration (f_x_previous is NaN)
        # and the user has not provided an initial step size (is.α0 is NaN),
        # then we
        # pick the initial step size according to HZ #I0
        state.alpha = _hzI0(state.x, NLSolversBase.gradient(df),
                            NLSolversBase.value(df),
                            convert(eltype(state.x), is.ψ0)) # Hack to deal with type instability between is{T} and state.x
        state.mayterminate = false
    else
        # Pick the initial step size according to HZ #I1-2
        state.alpha, state.mayterminate =
            _hzI12(state.alpha, df, state.x, state.s, state.x_ls, state.lsr,
                   is.ψ1, is.ψ2, is.ψ3, is.αmax, is.verbose)
    end
    return state.alpha
end

# Pick the initial step size (HZ #I1-I2)
function _hzI12(alpha::T,
                df,
                x::AbstractArray{T},
                s::AbstractArray{T},
                xtmp::AbstractArray{T},
                lsr::LineSearchResults,
                psi1::Real = convert(T,0.2),
                psi2::Real = convert(T,2.0),
                psi3::Real = convert(T,0.1),
                alphamax::Real = convert(T, Inf),
                verbose::Bool = false) where T

    # Prevent values of `xtmp` that are likely to make
    # df.f(xtmp) infinite
    iterfinitemax::Int = ceil(Int, -log2(T(eps(T))))

    phi0 = lsr.value[1]
    dphi0 = lsr.slope[1]

    alphatest = psi1 * alpha
    alphatest = min(alphatest, alphamax)

    @. xtmp = x + alphatest * s
    phitest = NLSolversBase.value!(df, xtmp)

    iterfinite = 1
    while !isfinite(phitest)
        alphatest = psi3 * alphatest
        @. xtmp = x + alphatest * s
        phitest = NLSolversBase.value!(df, xtmp)
        lsr.nfailures += 1
        iterfinite += 1
        if iterfinite >= iterfinitemax
            return zero(T), true
            #             error("Failed to achieve finite test value; alphatest = ", alphatest)
        end
    end
    a = ((phitest-phi0)/alphatest - dphi0)/alphatest  # quadratic fit
    if verbose == true
        println("quadfit: alphatest = ", alphatest,
                ", phi0 = ", phi0,
                ", phitest = ", phitest,
                ", quadcoef = ", a)
    end
    mayterminate = false
    if isfinite(a) && a > 0 && phitest <= phi0
        alpha = -dphi0 / T(2) / a # if convex, choose minimum of quadratic
        if alpha == zero(T)
            error("alpha is zero. dphi0 = ", dphi0, ", phi0 = ", phi0, ", phitest = ", phitest, ", alphatest = ", alphatest, ", a = ", a)
        end
        if alpha <= alphamax
            mayterminate = true
        else
            alpha = alphamax
            mayterminate = false
        end
        if verbose == true
            println("alpha guess (quadratic): ", alpha,
                    ",(mayterminate = ", mayterminate, ")")
        end
    else
        if phitest > phi0
            alpha = alphatest
        else
            alpha *= psi2 # if not convex, expand the interval
        end
    end
    alpha = min(alphamax, alpha)
    if verbose == true
        println("alpha guess (expand): ", alpha)
    end
    return alpha, mayterminate
end

# Generate initial guess for step size (HZ, stage I0)
function _hzI0(x::AbstractArray{T},
               gr::AbstractArray{T},
               f_x::T,
               psi0::T = convert(T,0.01)) where T
    alpha = one(T)
    gr_max = maximum(abs, gr)
    if gr_max != zero(T)
        x_max = maximum(abs, x)
        if x_max != zero(T)
            alpha = psi0 * x_max / gr_max
        elseif f_x != zero(T)
            alpha = psi0 * abs(f_x) / vecnorm(gr)
        end
    end
    return alpha
end
