a<-commandArgs(TRUE);dest<-a[1];dir.create(dest,recursive=TRUE,showWarnings=FALSE)
write.csv(data.frame(variable_id=c('f1','f2'),mz=c(760.6,786.6),rt=c(100,120),Sample1=c(2000,4000),Sample2=c(3000,5000)),file.path(dest,'peaks.csv'),row.names=FALSE)
write.csv(data.frame(variable_id=c('f1','f2'),Compound.name=c('PC(16:0/18:1)','PC(18:0/18:2)'),Adduct=c('M+H','M+H')),file.path(dest,'annotations.csv'),row.names=FALSE)
write.csv(data.frame(IS_Name='PC standard',Peak_Area=1000,Measured_RT=110),file.path(dest,'isopt.csv'),row.names=FALSE)
openxlsx::write.xlsx(data.frame(name='PC standard',exact.mass=753.577,formula='C40H80NO8P',ug_ml=10,um=20),file.path(dest,'is.xlsx'))
# Real vendor raw file, reference mass from the package's own IS information.
d<-as.data.frame(readxl::read_xlsx('vendor/lipidflow/inst/POS/IS_information.xlsx'));print(head(d));write.csv(data.frame(ID='IS_001',Name=d$name[1],Formula=d$formula[1],Accurate_Mass=as.numeric(gsub("[^0-9.]", "", d$exact.mass[1]))),file.path(dest,'standards.csv'),row.names=FALSE)
