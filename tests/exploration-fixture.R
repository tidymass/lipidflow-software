args<-commandArgs(TRUE);dest<-args[1];dir.create(dest,recursive=TRUE,showWarnings=FALSE)
source('backend/helpers/utils_small_tools.R')
s<-expand.grid(IS_ID=c('IS_001','IS_002'),adduct=c('+H','+Na'),stringsAsFactors=FALSE)
s$IS_Name<-ifelse(s$IS_ID=='IS_001','PC standard','PE standard');s$mz<-c(753,711,775,733);s$rt<-ifelse(s$IS_ID=='IS_001',100,120);s$Peak_Area<-c(1000,2000,500,600);s$Norm_Area<-c(1,1,.5,.3);s$Shape_Score<-c(.8,.9,.6,.7);s$Combined_Score<-.6*s$Norm_Area+.4*s$Shape_Score
tr<-s;tr$rt<-rep(list(seq(0,200,by=.5)),nrow(s));tr$intensity<-lapply(seq_len(nrow(s)),function(i)1000*i*exp(-((seq(0,200,by=.5)-100-i*3)/8)^2));tr$Sample<-'QC.mzXML'
tr2<-tr;tr2$Sample<-'Sample.mzXML';tr2$intensity<-lapply(tr2$intensity,function(x)x*.7)
x<-list(scored=s,isopt=.lfs_resolve_adduct_selection(s),eic_data=rbind(tr,tr2),sample_scored=rbind(transform(s,Sample='QC.mzXML'),transform(s,Sample='Sample.mzXML')))
state<-list(kind='extraction',sides=list(pos=x,neg=x))
# Synthetic UI/regression fixture: same numeric fixture in each polarity, not scientific validation.
saveRDS(state,file.path(dest,'object.rds'))
