"""
Creates a folder with random FSTs and a CSV file with the metadata of the FSTs.
Variants are semiring, using epsilon, acceptor or not, and weighted or not.
"""

semiring = "tropical"
acceptor = true
unweighted = true
dbname = "fsadb_uw"
label_offset = 2 # 1 for epsilon
total_fsts  = 1000

using DataFrames
import IterTools.product
using ProgressBars
using CSV
using OpenFst
using TensorFSTs
using Random
Random.seed!(123456)

OF=OpenFst
TF=TensorFSTs
SR=TF.Semirings

# Include a sign to applied to the OpenFst floating point weight
_SemiringToWeightType = Dict([
    (SR.LogSemiring{Float32,1}, (OF.LogWeight, -1))
    (SR.LogSemiring{Float32,-1}, (OF.LogWeight, 1))
    (SR.LogSemiring{Float64,1}, (OF.Log64Weight, -1))
    (SR.LogSemiring{Float64,-1}, (OF.Log64Weight, 1))
    (SR.LogSemiring{Float32,Inf}, (OF.TropicalWeight, -1))
    (SR.LogSemiring{Float32,-Inf}, (OF.TropicalWeight, 1))
])

# Converts from OpenFst weight to TensorFSTs semiring
_WeightToSemiringType = Dict([
    (OF.LogWeight, SR.LogSemiring{Float32,-1}),
    (OF.Log64Weight, SR.LogSemiring{Float64,-1}),
    (OF.TropicalWeight, SR.LogSemiring{Float32,-Inf})
])

# Extracts semiring floating point value with sgn correction
function _semiring_to_weight(s::S, sgn)::AbstractFloat where S <: SR.Semiring
    s.val * sgn
end

function OF.VectorFst(tfst::TF.ExpandedFST{S}) where S <: SR.Semiring
    W, sgn = _SemiringToWeightType[S]
    ofst = OF.VectorFst{W}()
    # We need expanded for this line only
    OF.reservestates(ofst, numstates(tfst))
    for s in states(tfst)
        OF.addstate!(ofst)
        final = _semiring_to_weight(TF.final(tfst, s), sgn)
        OF.setfinal!(ofst, s, final)
        OF.reservearcs(ofst, s, numarcs(tfst, s))
        for a in arcs(tfst, s)
            arc = OF.Arc(ilabel = a.ilabel, 
                         olabel = a.olabel,
                         weight = _semiring_to_weight(a.weight, sgn), 
                         nextstate = a.nextstate)
            OF.addarc!(ofst, s, arc)
        end
    end
    OF.setstart!(ofst, start(tfst))
    return ofst
end

function TF.VectorFST(ofst::OF.Fst{W}) where W <: OF.Weight
    S = _WeightToSemiringType[W] 
    tfst = TF.VectorFST{S}()
    for s in OF.states(ofst)
        TF.addstate!(tfst)
        final = S(OF.final(ofst, s))
        TF.setfinal!(tfst, s, final)
        for a in OF.arcs(ofst, s)
            arc = TF.Arc(Int(a.ilabel), Int(a.olabel), S(a.weight), 
                         Int(a.nextstate))
            TF.addarc!(tfst, s, arc)
        end
    end
    TF.setstart!(tfst, OF.start(ofst))
    return tfst
end

if semiring == "tropical"
    S = SR.TropicalSemiring{Float32}
elseif semiring == "log"
    S = SR.LogSemiring{Float32,-1}
elseif semiring == "prob"
    S = SR.ProbabilitySemiring{Float32}
end

if !isdir(dbname)
    mkdir(dbname)
end

lk = ReentrantLock()

records = []
Threads.@threads for i in ProgressBar(1:total_fsts)
    nsyms = 2 .^rand(1:8)
    nstates = 2 .^rand(1:8)
    if nstates <= 8 && nsyms <= 8
        _narcs_density = rand(0.1:0.05:1.0)
    else
        _narcs_density = rand(0.1:0.05:0.5)
    end
    seed = rand(1000:5000)
    narcs = floor(Int, _narcs_density*(nsyms-1)*nstates^2)

    rA = random_vectorfst(S, nstates, nsyms, narcs; unweigthed=unweighted, seed=seed, label_offset=label_offset, acceptor=acceptor)    
    A = OF.VectorFst(rA)
    num = i
    filename = "$(dbname)/$(lpad(num,4,"0"))_Q_$(nstates)-E_$(narcs)-A_$(nsyms)-seed_$(seed).fst"
    lock(lk) do
        OF.write(A, filename)
        push!(records, (nstates=nstates, narcs=narcs, nsyms=nsyms, seed=seed) )
    end 
end

_nsyms = [4,8,32,128,512]
_narcs_density = [0.1,0.2,0.5]
_nstates = [4,8,16,32,64,128]
_seed = 1:15

products = vec(collect(product(_nstates, _narcs_density, _nsyms, _seed)))

Threads.@threads for i in ProgressBar(1:length(products))
    (nstates, _narcs_density, nsyms, seed) = products[i]
    narcs = floor(Int, _narcs_density*(nsyms-1)*nstates^2)
    rA = random_vectorfst(S, nstates, nsyms, narcs; unweigthed=unweighted, seed=seed, label_offset=label_offset, acceptor=acceptor)
    A = OF.VectorFst(rA)
    num = i + total_fsas
    filename = "$(dbname)/$(lpad(num,4,"0"))_Q_$(nstates)-E_$(narcs)-A_$(nsyms)-seed_$(seed).fst"
    lock(lk) do
        OF.write(A, filename)
        push!(records, (filename=filename, nstates=nstates, narcs=narcs, nsyms=nsyms, seed=seed) )
    end
end

CSV.write("$(dbname).csv", DataFrame(records))