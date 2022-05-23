"""
    hf_main(nucs,sntf,hw,emax;verbose=false,Operators=String[],is_show=false,doIMSRG=false,valencespace=[],corenuc="",ref="nucl")
main function to carry out HF/HFMBPT calculation from snt file
# Arguments
- `nucs::Vector{String}` target nuclei
- `sntf` path to input interaction file
- `hw` hbar omega
- `emax` emax for HF/IMSRG

# Optional Arguments
- `verbose=false` to see detailed stdout for HF
- `Operators=String[]` target observables other than Hamiltonian
- `is_show=false` to show TimerOutput log (summary of run time and memory allocation)
- `doIMSRG=false` to carry out IMSRG/VSIMSRG calculation 
- `valencespace=[]` to spacify the valence space (e.g., ["sd-shell"]), if this is not empty, it tries to do vsimsrg calculations
- `corenuc=""` core nucleus, example=> "He4"
- `ref="nucl"` to specify target reference state, "core" or "nucl" is supported
"""
function hf_main(nucs,sntf,hw,emax;verbose=false,Operators=String[],is_show=false,doIMSRG=false,valencespace=[],corenuc="",ref="nucl")
    to = TimerOutput()
    chiEFTobj = init_chiEFTparams()
    HFdata = prepHFdata(nucs,ref,["E"],corenuc)
    @timeit to "PreCalc 6j" begin
        dict6j,d6j_nabla = PreCalc6j(emax)
        dict6j = adhoc_rewrite6jdict(emax,dict6j) # trans dict[array] -> dict[int]
    end
    @timeit to "PreCalc 9j&HOBs" d9j,HOBs = PreCalcHOB(chiEFTobj,to)
    @timeit to "read" begin        
        TF = occursin(".bin",sntf)
        tfunc = ifelse(TF,readsnt_bin,readsnt)     
        nuc = def_nuc(nucs[1],ref,corenuc)
        binfo = basedat(nuc,sntf,hw,emax)
        sps,dicts1b,dicts = tfunc(sntf,binfo,to)
        Z = nuc.Z; N=nuc.N; A=nuc.A   
        Hamil,dictsnt,Chan1b,Chan2bD,Gamma,maxnpq = store_1b2b(sps,dicts1b,dicts,binfo)
    end
    for (i,tnuc) in enumerate(nucs)
        nuc = def_nuc(tnuc,ref,corenuc)
        Z = nuc.Z; N=nuc.N; A=nuc.A   
        binfo = basedat(nuc,sntf,hw,emax)
        print("target: $tnuc Ref. => Z=$Z N=$N ")
        if i > 1
            recalc_v!(A,dicts)
            update_1b!(binfo,sps,Hamil)
            update_2b!(binfo,sps,Hamil,dictsnt.dictTBMEs,Chan2bD,dicts)
        end
        @timeit to "HF" begin 
            HFobj = hf_iteration(binfo,HFdata[i],sps,Hamil,dictsnt.dictTBMEs,
                                 Chan1b,Chan2bD,Gamma,maxnpq,dict6j,to;verbose=verbose) 
        end
        if doIMSRG
           imsrg_main(binfo,Chan1b,Chan2bD,HFobj,dictsnt,d9j,HOBs,dict6j,valencespace,Operators,to)
        else
            if "Rp2" in Operators
                Op_Rp2 = InitOp(Chan1b,Chan2bD.Chan2b)
                eval_rch_hfmbpt(binfo,Chan1b,Chan2bD,HFobj,Op_Rp2,d9j,HOBs,dict6j,to)
            end
        end
    end
    if is_show; show(to, allocations = true,compact = false);println(""); end
    return true
end

"""
    hf_main_mem(chiEFTobj,nucs,dict_TM,dict6j,HFdata,to;verbose=false,Operators=String[],valencespace=[],corenuc="",ref="core")    
"without I/O" version of `hf_main`
"""
function hf_main_mem(chiEFTobj,nucs,dict_TM,dict6j,HFdata,to;verbose=false,Operators=String[],valencespace=[],corenuc="",ref="core")    
    emax = chiEFTobj.emax
    hw = chiEFTobj.hw
    sntf = chiEFTobj.fn_tbme
    @timeit to "read" begin
        nuc = def_nuc(nucs[1],ref,corenuc)
        Z = nuc.Z; N=nuc.N; A=nuc.A 
        binfo = basedat(nuc,sntf,hw,emax)
        sps,p_sps,n_sps = def_sps(emax)
        lp = div(length(sps),2)
        new_sps,dicts1b = make_sps_and_dict_isnt2ims(p_sps,n_sps,lp)           
        dicts = make_dicts_formem(nuc,dicts1b,dict_TM,sps)
        Hamil,dictsnt,Chan1b,Chan2bD,Gamma,maxnpq = store_1b2b(sps,dicts1b,dicts,binfo)
        dictTBMEs = dictsnt.dictTBMEs
    end
    for (i,tnuc) in enumerate(nucs)
        nuc = def_nuc(tnuc,ref,corenuc)
        Z = nuc.Z; N=nuc.N; A=nuc.A
        #show_Hamil_norm(Hamil;normtype="sum")
        binfo = basedat(nuc,sntf,hw,emax)  
        @timeit to "update" if i > 1
            recalc_v!(A,dicts)
            update_1b!(binfo,sps,Hamil)
            update_2b!(binfo,sps,Hamil,dictTBMEs,Chan2bD,dicts)
            dictTBMEs = dictsnt.dictTBMEs
        end      
        @timeit to "hf_iteration" begin 
            hf_iteration(binfo,HFdata[i],sps,Hamil,dictTBMEs,Chan1b,Chan2bD,Gamma,maxnpq,dict6j,to;verbose=verbose)            
        end
    end
    return true
end

function make_dicts_formem(nuc,dicts1b,dict_TM,sps)
    dicts=[ Dict{Int64,Vector{Vector{Float64}}}() for pnrank=1:3]
    dict_snt2ms = dicts1b.snt2ms    
    A = nuc.A  
    for pnrank = 1:3
        tdict = dict_TM[pnrank]
        target_dict = dicts[pnrank]
        for tkey in keys(tdict)
            val = tdict[tkey]
            a,b,c,d = tkey
            ta = dict_snt2ms[a]; tb = dict_snt2ms[b]          
            tc = dict_snt2ms[c]; td = dict_snt2ms[d]
            oa = sps[ta]; ob = sps[tb]
            oc = sps[tc]; od = sps[td]
            ja = oa.j; jb = ob.j; jc = oc.j; jd = od.j
            key = zeros(Int64,4)
            for tmp in val
                key[1] = ta; key[2] = tb; key[3] = tc; key[4] = td
                totJ,V2bdum,Vjj,Vpp = tmp                                
                phase_ab = (-1)^(div(ja+jb,2)+totJ+1)
                phase_cd = (-1)^(div(jc+jd,2)+totJ+1)
                flip_ab = ifelse(ta>tb,true,false)
                flip_cd = ifelse(tc>td,true,false)
                phase = 1.0
                if flip_ab; key[1] = tb; key[2] = ta; phase *= phase_ab;end
                if flip_cd; key[3] = td; key[4] = tc; phase *= phase_cd;end
                if key[1] > key[3]
                    k1,k2,k3,k4 = key
                    key[1] = k3; key[2] = k4; key[3] = k1; key[4] = k2
                end
                Vjj *= phase
                Vpp *= phase
                V2b = Vjj + Vpp*hw/A
                nkey = get_nkey_from_abcdarr(key)
                t = get(target_dict,nkey,false)
                if t==false
                    target_dict[nkey] = [[totJ,V2b,Vjj,Vpp*hw]]
                else
                    push!(target_dict[nkey],[totJ,V2b,Vjj,Vpp*hw])
                end
            end
        end
    end
    return dicts
end

""" 
    prepHFdata(nucs,ref,datatype,corenuc)
Constructor of an array of `hfdata` struct.
"""
function prepHFdata(nucs,ref,datatype,corenuc)
    dnum = length(datatype)    
    Data = hfdata[ ]
    for tnuc in nucs
        nuc = def_nuc(tnuc,ref,corenuc)
        data = [ zeros(Float64,2) for i =1:dnum]
        push!(Data, hfdata(nuc,data,datatype))
    end
    return Data
end 

"""
    def_sps(emax)
Function to define `sps::Vector{SingleParticleState}` from `emax`. 
"""
function def_sps(emax)
    sps = SingleParticleState[ ]
    p_sps = SingleParticleState[ ]
    n_sps = SingleParticleState[ ]
    for temax = 0:emax
        prty = temax % 2
        for l = 0+prty:2:emax
            jmin = 2*l - 1
            jmax = 2*l + 1
            n = div(temax-l,2)
            if n < 0;continue;end
            if jmin < 1;jmin=jmax;end
            for j = jmin:2:jmax
                push!(p_sps,SingleParticleState(n,l,j,-1,0,false,false,false))
                push!(sps,SingleParticleState(n,l,j,-1,0,false,false,false))
                push!(n_sps,SingleParticleState(n,l,j,1,0,false,false,false))
                push!(sps,SingleParticleState(n,l,j,1,0,false,false,false))
            end
        end
    end
    return sps,p_sps,n_sps
end

"""
    recalc_v!(A,dicts)
Function to calculate two-body interaction from snt file.
This is needed because in the readsnt/readsnt_bin function, the interaction part and the kinetic term 
are stored separately to avoid multiple reads of the input file when calculating multiple nuclei.
"""
function recalc_v!(A,dicts)
    #V2b = Vjj + Vpp*hw/Anum
    for pnrank = 1:3
        tdict = dicts[pnrank]
        for tkey in keys(tdict)
            tmp = tdict[tkey]            
            for i = 1:length(tmp)
                tmp[i][2] = tmp[i][3] + tmp[i][4]/A 
            end
        end 
    end
    return nothing
end 

"""
    naive_filling(sps,n_target,emax,for_ref=false)
calculate naive filling configurations by given sps and proton/neutron number (`n_target`)

For some nuclei, carrying out naive filling is ambiguous
(e.g., neutron occupation of 22O can be both 0s1(2),0p1(2),0p3(4),0d5(6) and  0s1(2),0p1(2),0p3(4),1s1(2), 0d3(4)).
In this function, "naive filling" means to try fill orbits with lower ``2n+l`` and then "lower" ``j``.
The occupations will be updated when solving HF.
"""
function naive_filling(sps,n_target,emax,for_ref=false)
    ln = length(sps)
    occ = [ false for i =1:ln]
    imin = imax = 1
    Nocc = 0
    GreenLight = false
    ofst = 0
    occs = Vector{Bool}[ ]
    for e = 0:emax
        j2min = 1
        j2max = 2*e +1
        ncand = sum( [ j2+1 for j2=j2min:2:j2max ])        
        cand = Int64[ ]
        if ncand + Nocc <= n_target;GreenLight=true;else;GreenLight=false;end
        for n = 1:ln
            if e != 2 * sps[n].n +  sps[n].l;continue;end
            N = sps[n].j +1 
            if GreenLight
                occ[n]=true; Nocc += N 
            else
                push!(cand,n)
            end
        end
        if !GreenLight
            lcand = length(cand)
            totnum = 2^lcand
            TF = false
            for i=0:totnum-1
                bit = digits(i, base=2, pad=lcand)
                tocc = 0
                bitarr = [ false for m=1:lcand]
                for (j,tf) in enumerate(bit)
                    if tf == 1
                        bitarr[j] = true
                        tocc += sps[j+ofst].j + 1
                    end
                end
                if tocc + Nocc == n_target
                    TF = true
                    Nocc_tmp = Nocc 
                    occ_cp = copy(occ)
                    for (j,tbit) in enumerate(bit)
                        if tbit ==1
                            occ_cp[j+ofst] = true
                            Nocc_tmp += sps[j+ofst].j + 1
                        end 
                    end 
                    push!(occs,occ_cp)
                end
            end
            if TF; Nocc = n_target;end
            break
        end 
        if Nocc == n_target && GreenLight 
            push!(occs,occ)
            break
        end
        ofst += e + 1 
    end
    if Nocc != n_target; println("warn! Nocc");exit();end
    return occs
end

"""
    ini_occ!(pconfs,occ_p,nconfs,occ_n)

initialize occupation number matrices (```occ_p```&```occ_n```) by naive filling configurations ```pconfs```&```nconfs```
"""
function ini_occ!(pconfs,occ_p,nconfs,occ_n)
    pconf = pconfs[1]; nconf = nconfs[1]
    for i=1:length(pconf)
        if pconf[i] == 1
            occ_p[i,i] = 1.0 
        end
    end
    for i=1:length(nconf)
        if nconf[i] == 1
            occ_n[i,i] = 1.0 
        end
    end    
    return nothing
end

"""
    ReorderHFSPS!(h_p,h_n,Cp,Cn,e1b_p,e1b_n,Chan1b)

"reorder" HF single particle space.
Since we diagonalize the `h_p,h_n` (istead of subblock mat), we need to specify the correspondance between ordering of sps and that of HFSPEs obtained by solving HF eigenvalue problem
"""
function ReorderHFSPS!(h_p,h_n,Cp,Cn,e1b_p,e1b_n,Chan1b)
    for pn = 1:2
        tmp = Chan1b.chs1b[pn]
        tkeys = keys(tmp)
        h = ifelse(pn==1,h_p,h_n)
        evec = ifelse(pn==1,e1b_p,e1b_n)
        C = ifelse(pn==1,Cp,Cn) 
        nonzeros = Dict{Int64,Vector{Int64}}()
        for tkey in tkeys
            idxs = tmp[tkey]
            nidxs = Int64[ ]
            for idx in tmp[tkey]
                nidx = 0
                if pn ==1
                    nidx = div(idx,2) + 1
                else
                    nidx = div(idx,2)
                end
                push!(nidxs,nidx)
            end
            if pn ==1; tkey = div(tkey,2)+1;
            else; tkey = div(tkey,2);end
            for idx in nidxs            
                t = get(nonzeros,tkey,false)
                if t == false
                    nonzeros[tkey] = [idx]
                else
                    if (idx in nonzeros[tkey]) == false
                        push!(nonzeros[tkey],idx)
                    end
                end
                t = get(nonzeros,idx,false)
                if t == false 
                    nonzeros[idx] = [tkey]
                else    
                    if (tkey in nonzeros[idx]) == false
                        push!(nonzeros[idx],tkey)
                    end
                end 
            end
        end
        for tkey = 1:size(C)[1]
            cvec = @views C[:,tkey]
            cvec .= 0.0
            idxs = nonzeros[tkey]
            if length(idxs) == 1
                cvec[tkey] = 1.0
                evec[tkey] = h[tkey,tkey]
            else
                nidxs = sort(idxs)
                sM = @views h[nidxs, nidxs]
                vals,vecs = eigen(sM)
                for (n,idx) in enumerate(nidxs)
                    evec[idx] = vals[n]
                    if vecs[n,n] < 0.0; vecs[:,n] .*= -1.0;end
                    for (m,jdx) in enumerate(nidxs)
                        C[jdx,idx] = vecs[m,n]
                    end
                end
            end
        end
    end
    return nothing
end

"""
    update_occ!(pconfs,nconfs,p_sps,n_sps,occ_p,occ_n,e1b_p,e1b_n)

update occupation matrices by HF SPEs
"""
function update_occ!(pconfs,nconfs,p_sps,n_sps,occ_p,occ_n,e1b_p,e1b_n)
    lp = length(p_sps); ln = length(n_sps)
    epmax = enmax = 1.e+10
    optidxs = [1,1]
    for (i,pconf) in enumerate(pconfs)
        tmp = [ pconf[j] * (p_sps[j].j+1) for j = 1:lp ]
        ep = dot(tmp,e1b_p)
        if ep <= epmax;optidxs[1] = i;epmax = ep;end
    end
    for (i,nconf) in enumerate(nconfs)
        tmp = [ nconf[j] * (n_sps[j].j+1) for j = 1:ln]
        en = dot(tmp,e1b_n)
        if en <= enmax;optidxs[2] = i;enmax=en;end
    end
    occ_p .= 0.0; occ_n .= 0.0
    pconf = pconfs[optidxs[1]]; nconf = nconfs[optidxs[2]]
    for i = 1:lp; occ_p[i,i] = ifelse(pconf[i],1.0,0.0); occ = occ_p[i,i]; p_sps[i].occ = ifelse(occ==1.0,1,0);end
    for i = 1:ln; occ_n[i,i] = ifelse(nconf[i],1.0,0.0); occ = occ_n[i,i]; n_sps[i].occ = ifelse(occ==1.0,1,0);end
    return nothing
end

function calc_rho!(rho,U,occ,M)
    BLAS.gemm!('N','T',1.0,occ,U,0.0,M)
    BLAS.gemm!('N','N',1.0,U,M,0.0,rho)
    return nothing
end

"""
    def_holeparticle(Chan1b,occ_p,occ_n,p_sps,n_sps)

define hole/particle space by ```occ_p, occ_n```
"""
function def_holeparticle(Chan1b,occ_p,occ_n,p_sps,n_sps)
    snt2ms = Chan1b.snt2ms
    lp = length(p_sps); ln = length(n_sps)
    particles = [ Int64[ ] , Int64[ ] ]
    holes = [ Int64[ ] , Int64[ ] ]
    for pn = 1:2
        occs = ifelse(pn==1,occ_p,occ_n)
        t_sps = ifelse(pn==1,p_sps,n_sps)
        for i = 1:ifelse(pn==1,lp,ln)
            idx_snt = i + lp*(pn-1)
            msidx = snt2ms[idx_snt]
            if occs[i,i] == 1.0
                push!(holes[pn],msidx)
                t_sps[i].occ = 1
            else
                push!(particles[pn],msidx)
                t_sps[i].occ = 0
            end
        end
    end
    return holes,particles
end

"""
    calc_Gamma!(Gamma,sps,Cp,Cn,V2,Chan2b,maxnpq)

calculate ``\\Gamma`` (two-body HF interaction)
"""
function calc_Gamma!(Gamma,sps,Cp,Cn,V2,Chan2b,maxnpq)
    nchan = length(Chan2b)
    Ds = [ zeros(Float64,maxnpq,maxnpq) ]        
    M  = zeros(Float64,maxnpq,maxnpq)   
    npqmax = 0
    for ch = 1:nchan
        tmp = Chan2b[ch]
        Tz = tmp.Tz; J=tmp.J; kets = tmp.kets
        npq = length(kets)
        npqmax = ifelse(npq>npqmax,npq,npqmax)
        D = @views Ds[threadid()][1:npq,1:npq]#;  D .= 0.0
        v = V2[ch]
        @inbounds for ib = 1:npq
            i,j = kets[ib]            
            phase_ij = (-1)^( div(sps[i].j+sps[j].j,2) + 1 + J)
            idx_bra1 = div(i,2) + i%2 
            idx_bra2 = div(j,2) + j%2 
            for ik = 1:npq
                k,l = kets[ik]
                C1 = ifelse(i%2==1,Cp,Cn)
                C2 = ifelse(j%2==1,Cp,Cn)
                idx_ket1 = div(k,2) + k%2
                idx_ket2 = div(l,2) + l%2
                phase_kl = (-1)^( div(sps[k].j+sps[l].j,2) + 1 + J)
                if Tz != 0
                    D[ib,ik] = C1[idx_bra1,idx_ket1] * C2[idx_bra2,idx_ket2]
                    if i!=j
                        D[ib,ik] += C1[idx_bra2,idx_ket1] * C2[idx_bra1,idx_ket2] * phase_ij
                    end
                    if i==j; D[ib,ik] *= sqrt(2.0);end
                    if k==l; D[ib,ik] /= sqrt(2.0);end
                else
                    p_idx_bra = ifelse(i%2==1,idx_bra1,idx_bra2)
                    n_idx_bra = ifelse(i%2==1,idx_bra2,idx_bra1)
                    p_idx_ket = ifelse(k%2==1,idx_ket1,idx_ket2)
                    n_idx_ket = ifelse(k%2==1,idx_ket2,idx_ket1)
                    phase = 1.0
                    phase = ifelse(i%2==0,phase_ij,1.0)           
                    phase *= ifelse(k%2==0,phase_kl,1.0)
                    D[ib,ik] = Cp[p_idx_bra,p_idx_ket] * Cn[n_idx_bra,n_idx_ket] * phase
                end
            end 
        end
        Gam = Gamma[ch]
        tM  = @views M[1:npq,1:npq]
        BLAS.gemm!('N','N',1.0,v,D,0.0,tM)
        BLAS.gemm!('T','N',1.0,D,tM,0.0,Gam)
    end
    return nothing
end

function make_symmetric!(mat)
    # this is the brute force way to make array symmetric
    for i=1:size(mat)[1]
        for j=i:size(mat)[1]
            if j!=i; mat[j,i]=mat[i,j];end
        end
    end
    return nothing
end

"""
    add_ch_ket!(ch,iket,tdict) 

add ch & idx for kets in `spaces::space_channel` (pp/hh/etc.)
"""
function add_ch_ket!(ch,iket,tdict) 
    defined = get(tdict,ch,0)
    if defined == 0
        tdict[ch] = [iket]
    else
        push!(tdict[ch],iket)
    end
    return nothing
end

"""
    get_space_chs(sps,Chan2b)

define hole/particle single particle states.
In this function, only the hh/pp/ph (needed for IMSRG) are defined, and other channels will be updated later for target normal ordering or VS-IMSRG flow.
"""
function get_space_chs(sps,Chan2b)    
    hh = Dict{Int64,Vector{Int64}}()
    ph = Dict{Int64,Vector{Int64}}()
    pp = Dict{Int64,Vector{Int64}}()
    cc = Dict{Int64,Vector{Int64}}()
    vc = Dict{Int64,Vector{Int64}}()
    qc = Dict{Int64,Vector{Int64}}()
    vv = Dict{Int64,Vector{Int64}}()
    qv = Dict{Int64,Vector{Int64}}()
    qq = Dict{Int64,Vector{Int64}}()
    for ch = 1:length(Chan2b)
        tbc = Chan2b[ch]
        kets = tbc.kets
        for (ik,ket) in enumerate(kets)
            i,j = ket
            ni = sps[i].occ; nj = sps[j].occ
            if ni + nj == 2; add_ch_ket!(ch,ik,hh) ;end
            if ni + nj == 0; add_ch_ket!(ch,ik,pp) ;end
            if ni + nj == 1; add_ch_ket!(ch,ik,ph) ;end
        end       
    end
    return space_channel(pp,ph,hh,cc,vc,qc,vv,qv,qq)   
end

"""
    getHNO(binfo,tHFdata,E0,p_sps,n_sps,occ_p,occ_n,h_p,h_n,e1b_p,e1b_n,Cp,Cn,V2,Chan1b,Chan2b::tChan2b,Gamma,maxnpq,dict_2b_ch,dict6j,to) where{tChan2b <: Vector{chan2b}}

obtain spherical HF solution and calc. MBPT correction (upto 2nd&3rd order) to g.s. energy
"""
function getHNO(binfo,tHFdata,E0,p_sps,n_sps,occ_p,occ_n,h_p,h_n,
                e1b_p,e1b_n,Cp,Cn,V2,Chan1b,Chan2b::tChan2b,Gamma,maxnpq,                
                dict_2b_ch,dict6j,to) where{tChan2b <: Vector{chan2b}}
    ## Calc. f (1-body term)
    fp = Cp' * (h_p*Cp); fn = Cn' *(h_n*Cn) # equiv to vals_p/n
    make_symmetric!(fp); make_symmetric!(fn)
    ## Calc. particle_hole states 
    holes, particles = def_holeparticle(Chan1b,occ_p,occ_n,p_sps,n_sps)
    sps = make_sps_from_pnsps(p_sps,n_sps,Chan1b)
    spaces = get_space_chs(sps,Chan2b)
    modelspace = ModelSpace(p_sps,n_sps,sps,occ_p,occ_n,holes,particles,spaces)
    ## Calc. Gamma (2bchanel matrix element)    
    calc_Gamma!(Gamma,sps,Cp,Cn,V2,Chan2b,maxnpq)
    EMP2 = HF_MBPT2(binfo,modelspace,fp,fn,e1b_p,e1b_n,Chan2b,Gamma)   
    EMP3 = HF_MBPT3(binfo,modelspace,e1b_p,e1b_n,Chan2b,dict_2b_ch,dict6j,Gamma,to)
    exists = get(amedata,binfo.nuc.cnuc,false)   
    Eexp = 0.0
    if exists==false        
        println("E_HF ", @sprintf("%12.4f",E0), 
        "  E_MBPT(3) = ",@sprintf("%12.4f",E0+EMP2+EMP3),"  Eexp: Not Available")
    else
        Eexp = - binfo.nuc.A * amedata[binfo.nuc.cnuc][1]/1000.0
        println("E_HF ", @sprintf("%12.4f",E0),
        "  E_MBPT(3) = ",@sprintf("%12.4f",E0+EMP2+EMP3),"  Eexp: "*@sprintf("%12.3f", Eexp))    
    end
    tmp = tHFdata.data
    E = tmp[1]
    E[1] = E0+EMP2+EMP3; E[2] = Eexp
    H0 = Operator([E0],[fp,fn],Gamma,true,false)
    return HamiltonianNormalOrdered(H0,E0,EMP2,EMP3,Cp,Cn,e1b_p,e1b_n,modelspace)
end

"""
    hf_iteration(binfo,tHFdata,sps,Hamil,dictTBMEs,Chan1b,Chan2bD,Gamma,maxnpq,dict6j,to;itnum=100,verbose=false,HFtol=1.e-14,inttype="snt")

solve HF equation

This function returns object with HamiltonianNormalOrdered (HNO) struct type, which contains...
- `E0,EMP2,EMP3` HF energy and its MBPT corrections
- `fp/fn::Matrix{Float64}` one-body int.
- `Gamma:: Vector{Matrix{Float64}}` two-body int.

"""
function hf_iteration(binfo,tHFdata,sps,Hamil,dictTBMEs,
                      Chan1b,Chan2bD,Gamma,maxnpq,dict6j,to;
                      itnum=100,verbose=false,HFtol=1.e-14,inttype="snt")
    Chan2b = Chan2bD.Chan2b; dict_2b_ch = Chan2bD.dict_ch_JPT
    dim1b = div(length(sps),2)
    mat1b = zeros(Float64,dim1b,dim1b)

    p1b = Hamil.onebody[1]
    n1b = Hamil.onebody[2]
    V2 = Hamil.twobody
    nuc = binfo.nuc; emax=binfo.emax
    Z = nuc.Z; N = nuc.N   
    abcd = zeros(Int64,4)
    p_sps,n_sps = get_pn_sps(sps)
    occ_p = zeros(Float64,dim1b,dim1b); occ_n = zeros(Float64,dim1b,dim1b)
    EHFs = [ zeros(Float64,5) for i=1:2]
    pconfs = naive_filling(p_sps,Z,emax);nconfs = naive_filling(n_sps,N,emax)    
    ini_occ!(pconfs,occ_p,nconfs,occ_n)
    ## initial block unitary matrix 
    rho_p = copy(mat1b); Cp = copy(mat1b); Up = copy(mat1b);for i=1:dim1b;Up[i,i]=occ_p[i,i];end
    rho_n = copy(mat1b); Cn = copy(mat1b); Un = copy(mat1b);for i=1:dim1b;Un[i,i]=occ_n[i,i];end
    calc_rho!(rho_p,Up,occ_p,Cp);calc_rho!(rho_n,Un,occ_n,Cn)
    e1b_p = zeros(Float64,dim1b); e1b_n = zeros(Float64,dim1b)
    ## tilde(V)
    Vt_pp = copy(mat1b); Vt_nn = copy(mat1b); Vt_pn = copy(mat1b); Vt_np = copy(mat1b)
    calc_Vtilde(sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,rho_p,rho_n,dictTBMEs,abcd,Chan1b)
    ## Fock matrix
    h_p = copy(mat1b); h_n = copy(mat1b)
    update_FockMat!(h_p,p1b,p_sps,h_n,n1b,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np)
    calc_Energy(rho_p,rho_n,p1b,n1b,p_sps,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,EHFs) 

    if verbose; print_V2b(h_p,p1b,h_n,n1b); print_F(h_p,h_n);end
    for it = 1:itnum        
        ## diagonalize proton/neutron 1b hamiltonian
        valsp,vecsp = eigen(h_p); valsn,vecsn = eigen(h_n)
        ## Update 1b density matrix
        Up .= vecsp; Un .= vecsn
        ReorderHFSPS!(h_p,h_n,Up,Un,valsp,valsn,Chan1b)
        update_occ!(pconfs,nconfs,p_sps,n_sps,occ_p,occ_n,valsp,valsn)
        calc_rho!(rho_p,Up,occ_p,Cp);calc_rho!(rho_n,Un,occ_n,Cn)     
        ## Re-evaluate tilde(V) and Fock matrix
        calc_Vtilde(sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,rho_p,rho_n,dictTBMEs,abcd,Chan1b)
        update_FockMat!(h_p,p1b,p_sps,h_n,n1b,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np)        
        calc_Energy(rho_p,rho_n,p1b,n1b,p_sps,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,EHFs)
        
        if HF_conv_check(EHFs;tol=HFtol)
            #print("HF converged @ $it  \t")
            valsp,vecsp = eigen(h_p); valsn,vecsn = eigen(h_n)
            e1b_p .= valsp;e1b_n .= valsn; Cp .= vecsp; Cn .= vecsn            
            ReorderHFSPS!(h_p,h_n,Cp,Cn,e1b_p,e1b_n,Chan1b)
            break
        end
        tnorm = norm(Up'*Up-Matrix{Float64}(I, dim1b,dim1b),Inf)
        if tnorm > 1.e-10;println("Unitarity check: res. norm(p) $tnorm");end
    end

    ## HNO: get normal-ordered Hamiltonian 
    update_occ!(pconfs,nconfs,p_sps,n_sps,occ_p,occ_n,e1b_p,e1b_n)
    E0 = EHFs[1][1]
    HFobj = getHNO(binfo,tHFdata,E0,p_sps,n_sps,occ_p,occ_n,h_p,h_n,
                   e1b_p,e1b_n,Cp,Cn,V2,Chan1b,Chan2b,Gamma,maxnpq,dict_2b_ch,dict6j,to)
    return HFobj
end

"""
    printEHF(Es)

print HF energy and its break down ```Es=[E1b,E2bpp,E2bnn,E2bpn]```
"""
function printEHF(Es)
    println("E: ", @sprintf("%12.4f", Es[1]),"  = E1b ", @sprintf("%9.2f", Es[2]),"  + E2b ", @sprintf("%9.2f", Es[3]+Es[4]+Es[5]),
            "   ( "*@sprintf("%9.2f", Es[3])*@sprintf("%9.2f", Es[4]),@sprintf("%9.2f", Es[5]),")")
end

function calc_Energy(rho_p,rho_n,p1b,n1b,p_sps,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,Es;verbose=false)
    ## 1-body part
    lp = size(p1b)[1];ln = size(n1b)[1]
    ep_1b = 0.0; en_1b = 0.0
    for alph =1:lp
        Na = p_sps[alph].j * 1.0 + 1.0        
        for beta = 1:lp
            ep_1b += p1b[alph,beta] * rho_p[alph,beta] * Na
        end        
    end
    for alph =1:ln
        Na = n_sps[alph].j * 1.0 + 1.0
        for beta = 1:ln
            en_1b += n1b[alph,beta] * rho_n[alph,beta] *Na
        end
    end
    E1b = ep_1b + en_1b

    ## 2-body part
    E2b = 0.0; E2bpp = 0.0; E2bpn = 0.0; E2bnn = 0.0   
    for i = 1:lp
        for j=1:lp
            if rho_p[i,j] == 0.0;continue;end
            E2bpp += 0.5 * rho_p[i,j] *Vt_pp[i,j]
            E2bpn += 0.5 * rho_p[i,j] *Vt_pn[i,j]
            if rho_p[i,j] != 0.0 && verbose
                println("i $i j $j \t rho_p ",@sprintf("%15.6f",rho_p[i,j]),"  p from pp: ",@sprintf("%15.6f",Vt_pp[i,j])," pn ", @sprintf("%15.6f",Vt_pn[i,j]))
            end
        end        
    end
    for i = 1:ln
        for j=1:ln
            if rho_n[i,j] == 0.0;continue;end
            E2bnn += 0.5* rho_n[i,j] *Vt_nn[i,j]
            E2bpn += 0.5* rho_n[i,j] *Vt_np[i,j]
            if rho_n[i,j] != 0.0 && verbose
                println("i ",i+lp," j ",j+lp, " \t rho_n ",@sprintf("%15.6f",rho_n[i,j]),"  n from nn: ",@sprintf("%15.6f",Vt_nn[i,j])," np ", @sprintf("%15.6f",Vt_np[i,j]))
            end
        end        
    end
    E2b = E2bpp + E2bpn + E2bnn
    E = E1b + E2b    
    if verbose
        println("E:", @sprintf("%15.6f", E),"E1b:", @sprintf("%15.6f", E1b),"E2b:", @sprintf("%15.6f", E2b))
    end
    Es[2] .= Es[1]
    Es[1] .= [ E,E1b,E2bpp,E2bpn,E2bnn ]
    return nothing
end

function HF_conv_check(EHFs;tol=1.e-8)
    old = EHFs[2]; new = EHFs[1]
    if (abs(old[1] - new[1]) < tol) 
        return true
    else
        return false
    end
end
function update_FockMat!(h_p,p1b,p_sps,h_n,n1b,n_sps,Vt_pp,Vt_nn,Vt_pn,Vt_np)
    lp = size(h_p)[1]; ln = size(h_n)[1]
    h_p .= p1b; h_n .= n1b
    ## for proton
    for i = 1:lp
        Ni = p_sps[i].j+ 1.0
        for j = 1:lp # Vpp
            h_p[i,j] += (Vt_pp[i,j]+Vt_pn[i,j]) / Ni
        end
    end
    ## for neutron
    for i = 1:ln
        Ni = n_sps[i].j+ 1.0
        for j = 1:ln # Vnn
            h_n[i,j] += (Vt_nn[i,j]+Vt_np[i,j]) / Ni
        end
    end
    return nothing
end

function calc_Vtilde(sps,Vt_pp,Vt_nn,Vt_pn,Vt_np,rho_p,rho_n,dictTBMEs,tkey,Chan1b;verbose=false)
    dim1b = size(Vt_pp)[1]
    dict_pp = dictTBMEs[1];dict_pn = dictTBMEs[2];dict_nn = dictTBMEs[3]    
    Vt_pp .= 0.0; Vt_nn .= 0.0; Vt_pn .= 0.0;Vt_np .= 0.0
    Chan1b_p,Chan1b_n = Chan1b.chs1b
    for idx_i = 1:dim1b
        i = 2*(idx_i-1) + 1
        for idx_j = idx_i:dim1b
            j = 2*(idx_j-1)+1
            if !(j in Chan1b_p[i]);continue;end
            ji = sps[i].j; ji = sps[j].j; 
            ## tilde(Vp) from Vpp
            for idx_a = 1:dim1b
                a = 2*(idx_a-1) + 1
                for idx_b = idx_a:dim1b
                    b = 2*(idx_b-1) + 1
                    if !(b in Chan1b_p[a]);continue;end
                    rho_ab = rho_p[idx_a,idx_b]
                    tkey[1] = i; tkey[3] = j;tkey[2] = a; tkey[4] = b
                    if a < i; tkey[2] = i; tkey[4] = j;tkey[1] = a; tkey[3] = b; end
                    vmono = dict_pp[tkey]
                    Vt_pp[idx_i,idx_j] += rho_ab * vmono
                    if a!=b
                        if a < i                       
                            tkey[3] = a; tkey[1] = b
                        else
                            tkey[4] = a; tkey[2] = b
                        end
                        vmono = dict_pp[tkey]
                        Vt_pp[idx_i,idx_j] += rho_ab * vmono
                    end
                end
            end
            Vt_pp[idx_j,idx_i] = Vt_pp[idx_i,idx_j]
            ## tilde(Vp) from Vpn
            for idx_a= 1:dim1b
                a = 2*idx_a
                for idx_b = idx_a:dim1b
                    b = 2*idx_b
                    if !(b in Chan1b_n[a]);continue;end
                    rho_ab = rho_n[idx_a,idx_b] 
                    tkey[1] = i;tkey[3] = j;  tkey[2] = a; tkey[4] = b
                    vmono = dict_pn[tkey]
                    Vt_pn[idx_i,idx_j] += rho_ab * vmono
                    if a!=b
                        tkey[1] = i; tkey[3] = j; tkey[2] = b; tkey[4] = a
                        vmono = dict_pn[tkey]
                        Vt_pn[idx_i,idx_j] += rho_ab * vmono
                    end
                end
            end
            Vt_pn[idx_j,idx_i] = Vt_pn[idx_i,idx_j]
        end
    end
    for idx_i = 1:dim1b
        i = 2*idx_i 
        for idx_j = idx_i:dim1b
            j = 2*idx_j
            if !(j in Chan1b_n[i]);continue;end
            #println("nnidx idx_i $idx_i idx_j $idx_j")
            ## tilde(Vn) from Vnn
            for idx_a = 1:dim1b
                a = 2*idx_a 
                for idx_b = idx_a:dim1b
                    b = 2*idx_b 
                    if !(b in Chan1b_n[a]);continue;end
                    rho_ab = rho_n[idx_a,idx_b]
                    tkey[1] = i; tkey[3] = j;tkey[2] = a; tkey[4] = b                    
                    if a < i; tkey[2] = i; tkey[4] = j;tkey[1] = a; tkey[3] = b; end
                    vmono = dict_nn[tkey]
                    Vt_nn[idx_i,idx_j] += rho_ab * vmono
                    if a!=b
                        if a < i                       
                            tkey[3] = a; tkey[1] = b
                        else
                            tkey[4] = a; tkey[2] = b
                        end
                        vmono = dict_nn[tkey]
                        Vt_nn[idx_i,idx_j] += rho_ab * vmono
                    end
                end
            end
            Vt_nn[idx_j,idx_i] = Vt_nn[idx_i,idx_j]
            ## tilde(Vn) from Vnp
            for idx_a= 1:dim1b
                a = 2*(idx_a-1) + 1
                for idx_b = idx_a:dim1b
                    b = 2*(idx_b-1) + 1
                    if !(b in Chan1b_p[a]);continue;end
                    rho_ab = rho_p[idx_a,idx_b] 
                    tkey[1] = a ; tkey[3] = b
                    tkey[2] = i; tkey[4] = j
                    vmono = dict_pn[tkey]
                    Vt_np[idx_i,idx_j] += rho_ab * vmono 
                    if a!=b
                        tkey[1] = b; tkey[3] = a
                        tkey[2] = i; tkey[4] = j
                        vmono = dict_pn[tkey]
                        Vt_np[idx_i,idx_j] += rho_ab * vmono
                    end
                end
            end
            Vt_np[idx_j,idx_i] = Vt_np[idx_i,idx_j]
        end
    end
    return nothing
end