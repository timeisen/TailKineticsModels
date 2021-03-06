#populate vector of tails

args<-commandArgs(trailingOnly=TRUE)
# args <- c("model_input_files/miR-155_minus_sample_mean_tails_50tags_with_expr_background_subtracted_v7_st_last7rm_HYBRID20190326.txt","5","v30")
library(deSolve)
library(numDeriv)
library(nloptr)
# system("R CMD SHLIB /lab/solexa_bartel/teisen/Tail-seq/miR-155_final_analyses/KinetTlnAnalysis/Model/UnLinkV2/AnalyticalTailsPulseStUnlinked.c")
dyn.load("/lab/solexa_bartel/teisen/Tail-seq/miR-155_final_analyses/KinetTlnAnalysis/Model/UnLinkV2/AnalyticalTailsPulseStUnlinked.so") #load the model dynamically
options(warn = 1)

# V9 allows all 4 parameters but incorporates expression into the measurements in order to determine a,b
# V9b fixes bugs in the list management
# V10b adopts this script to consider different optimal starting tail lengths.
# V11 allows only 3 parameters (a, k, b) but performs an optimization on a range of starting tail lengths in 10nt increments from 13 to 25. 
# V16 is a reversion to V11 that now tries to fit steady state tail length and increases the range that decapping can occur at to 90nt. 
# V20 uses matrices to solve the differential equations.
# V24 uses gradient optimization using the L-BFGS-B method, bounded constraints, and numDeriv gradient calculations. In addition, it implements a new system for measuring starting tail length using a single matrix and a starting tail length distribution determined by a gaussian with a sd of 1 and mean=stl. 
# the array script changes first lines of this file to make it compatible with a job array.
# V75 is unlinked
# 2018 09 18: This version removes the last 8 nt from the fitting and analysis.
# initial param
# 8nt trim from smallest tail lengths
# way up on transcription rate?
# pexp
# V48 fits only one b scaling term
# V49 change the starting distribution to negative binomial
# 57 has box constraints
# V58 with smoothing
# V71 uses a plogis function in the ode model. This is the current version of the script as of 20180221
# 2018 09 24 This version of the model uses global rate constants from the datasets that has 8 nt removed. It uses global parameters from a fitting that includes TAIL-seq data for steady state.
# The HYBRID code uses the last 8 nt from the TAIL-seq dataset to fit 850 genes.  
# 2019 03 01 The V3 is exactly the same as the V2 code, but run with new global parameters, varainces, and using the scaled values from the new data. 
# The V4 script files are updated for increasing the last 8 nt weighting 6 fold to account for the fact that we don't have those values in the steady state. 
# The V5 code plays around with the hmax parameter, trying to figure out why there is a discrepancy with deadenylation rates of 1. 
# The V6 code uses the newer version of the LBFGS from the nloptr package 2019 04 19. 

all_data <- read.table(args[1],head=TRUE)
accession <<- as.character(all_data[args[2],1])
data <- as.numeric(all_data[args[2],-1])
offset = 35 #How many minutes to offset the data to account for export?
time_points <- (c(40,60,120,240,480,6000)-offset)
initial_param <- c(140,1E-7,1,1)
dir <- args[3]


#The variances of the datasets, to be used for residual weighting. 
#Global parameter assignment. 
vars <- c(      #miR-155 minus
  9.454761e-16,
  3.251709e-15,
  7.847564e-15,
  2.046925e-14,
  8.631471e-14,
   3.74611e-13,
   3.74611e-13/6) #The variance of the last value is reduced 6 fold
## This increases the weighting value of these points 6 fold


Simulation <- function(pars,time){ ##This is the main simulator

  #Parameter definitions
  st       = pars[1]
  a        = pars[2]
  k        = pars[3]
  b        = pars[4]
  size     = 15.92127   #13.72803 #These params are from the prelim run, 2019 03 02, 22 datasets. 
  location = 267.25342  #274.12527
  scale    = 15.76987   #11.66877

  parameters = c(st,a,k,b,size,location,scale)
  max_tail = 251

  initial_state <- rep(0,max_tail) #All abundances begin with 0. 
  #The simulation, passed to c code called ode_deriv, using lsode.
  #This is for a banded jacobian.
  #Note hmax has a major impact on memory usage, time, and precision. 
  tails <- ode.band(func = "ode_deriv", y = initial_state, parms = parameters, 
          times = c(0,time), method = "lsode",bandup = 0, banddown = 1,
          nspec = max_tail, dllname = "AnalyticalTailsPulseStUnlinked",
          nout=1, initfunc = "ode_p_init",hmax = 1, maxsteps=5000000)

  ##These two lines below return NA if the tails output is incomplete. Important
  # for using randomized initial parameters.
  if(dim(tails)[1] == 7){}
  else(return(NA))
  
  #Remove columns that shouldn't be compared to residuals. 
  columns_to_remove = c(1,2,(max_tail - 6):ncol(tails))
  last8nt = tails[7,(max_tail - 6):(ncol(tails)-1)]
  sim <- tails[-1,-columns_to_remove]
  #Add the last 8 nt back to the flattened array. 
  sim <- c(c(t(sim)),last8nt)
  return(sim)

}

tick = 0
CalculateResidual <- function(pars,data,plot=FALSE,time_points) { #Run the model

  model<-Simulation(2^pars,time_points) #exponentiation the parameters.

  #Residuals, weighted. 
  sqs <- (model-data)^2
  sqs[1:242]     <- sqs[1:242]    / vars[1]
  sqs[243:484]   <- sqs[243:484]  / vars[2]
  sqs[485:726]   <- sqs[485:726]  / vars[3]
  sqs[727:968]   <- sqs[727:968]  / vars[4]
  sqs[969:1210]  <- sqs[969:1210] / vars[5]
  sqs[1211:1452] <- sqs[1211:1452]/ vars[6]
  sqs[1453:1460] <- sqs[1453:1460]/ vars[7] #Added in V4 by TJE on 2019 04 01. 

  residual <- sum(sqs*1E6)
  
  #For plotting
  if (tick%%10 == 0 & plot){
    final_set <<- matrix(c(model,data,rep(tick,1500)),ncol=3)
  }
  tick <<- tick + 1
  #Dealing with errors in residual calculation.
  if(is.finite(residual)){return(residual)}
  else(return(10E20))
}

#Simple, finite differences gradient calculation.
grr <- function(pars,data,plot=plot,time_points){
    gradient <- grad(CalculateResidual, pars, 
      data=data, method="simple",time_points=time_points)
    return(gradient)
}

#Using L-BFGS-B algorithm
Optimization <- function(initial_param, data, plot=FALSE, time_points){
  #print(paste("starting_tail_length",starting_tail_length))
  if(plot){
        plot(time_points,log(data[6:10]), 
        pch = 19,ylim=c(0,10),xlim=c(0,900))} #only plotting tails
  solve <- NULL
  optim_param <- NULL
  for(x in 1:2){
    initial_param <- log2(runif(4,
      min=c(147.16777,4.317860e-08,2.650033e-03,10*2.650033e-01),
      max=c(168.41418,1.396230e-07,9.549402e+03,10*9.549402e+01)))
    # scale<-CalculateParscale(initial_param,time_points)
    solve$solution<-initial_param
    for(i in 1:2){
      #arguments passed to the solver
      solve<-nloptr(
        x0=solve$solution,
        eval_f=CalculateResidual,
        eval_grad_f = grr,
        data=data,     
        lb=log2(c(30,10E-10,10E-10,10E-10)),
        ub=log2(c(250,10E10,10E10,10E10)),
        time_points=time_points,
        plot=plot,
        opts=list("algorithm"="NLOPT_LD_LBFGS",xtol_rel=1e-8,"print_level"=0))}
    optim_param<-rbind(optim_param,c(2^solve$solution,solve$objective))
    }
  return(optim_param)
  }

#Main code block for running the optimimization and writing output files. 
all_optimizations <- NULL
all_optimizations <- Optimization(
    log2(initial_param),
    data,plot=FALSE, time=time_points)
# print(accession)
# print(all_optimizations)
all_optimizations<- cbind( 
  rep(accession,nrow(all_optimizations)),
  all_optimizations)
fn <- paste0("/lab/solexa_bartel/teisen/Tail-seq/miR-155_final_analyses/",
  "optim_runs/",
  dir,"/",accession,".txt")
write.table(all_optimizations,
  file=fn,
  row.names=FALSE,
  col.names=FALSE,
  quote=FALSE,
  sep="\t",
  append=FALSE)

