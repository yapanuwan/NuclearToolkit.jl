###--- ChiralEFT ---
n_mesh = 50
emax = 8
chi_order = 3 #0:LO 1:NLO 2:NNLO 3:N3LO
calc_NN = true
calc_3N = true #density-dependent 3NF
hw = 20.0
srg_lambda = 2.0

#tbme_fmt = "snt"
tbme_fmt = "snt.bin"

## target {[n,l,j]} for TBMEs
# #target_nlj=[[1,1,1],[1,1,3],[0,3,5],[0,3,7]] # pf-shell part

### --- IMSRG ---
smax = 500.0
dsmax = 0.5
denominatorDelta=0.0
