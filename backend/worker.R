# LipidFlow desktop adapter. Scientific calculations remain in the pinned upstream helpers.
if (!exists('args', inherits=FALSE)) args <- commandArgs(trailingOnly=TRUE)
request <- jsonlite::fromJSON(args[[1]], simplifyVector=FALSE)
p <- request$params; out <- request$output
`%||%` <- function(a,b) if(is.null(a)||length(a)==0) b else a
has <- function(x) !is.null(x)&&length(x)>0&&nzchar(as.character(x[[1]]))
files <- function(x) unlist(x %||% list(), use.names=FALSE)
num <- function(k, default, min=0, max=Inf) {v<-as.numeric(p[[k]] %||% default);if(length(v)!=1||!is.finite(v)||v<min||v>max)stop('Invalid parameter: ',k);v}
need <- function(x) {if(!has(x)||!file.exists(x))stop('Input file not found: ',x);x}
for(f in list.files('helpers',pattern='\\.R$',full.names=TRUE))source(f)
write_json <- function(x,file) jsonlite::write_json(x,file,auto_unbox=TRUE,pretty=TRUE,na='null',null='null',digits=10)
load_object <- function(file) {need(file);if(tolower(tools::file_ext(file))=='rds')return(readRDS(file));e<-new.env();n<-load(file,envir=e);if(!length(n))stop('No object in file.');e[[n[[1]]]]}
read_table <- function(file) {need(file);if(tolower(tools::file_ext(file))=='xlsx')as.data.frame(readxl::read_xlsx(file),check.names=FALSE) else read.csv(file,check.names=FALSE,stringsAsFactors=FALSE)}
checked <- function(r) {if(!isTRUE(r$ok))stop(r$message);r$data}
copy_input <- function(file,label){need(file);dest<-file.path(out,'inputs',paste0(label,'.',tools::file_ext(file)));dir.create(dirname(dest),recursive=TRUE,showWarnings=FALSE);if(!file.copy(file,dest))stop('Could not copy input: ',file);dest}
result <- list(tables=list(),capabilities=list(),note='')
table_out <- function(name,df) {
 if(is.null(df)||!is.data.frame(df)||!ncol(df))return(invisible(NULL))
 key<-gsub('[^A-Za-z0-9_-]','_',name);dir.create(file.path(out,'tables'),showWarnings=FALSE)
 utils::write.csv(.lfs_csv_injection_safe(df),file.path(out,'tables',paste0(key,'.csv')),row.names=FALSE,na='')
 write_json(list(columns=as.list(names(df)),rows=if(request$operation%in%c('extraction','selection'))df else utils::head(df,1000),total=nrow(df)),file.path(out,'tables',paste0(key,'.json')))
 result$tables[[length(result$tables)+1]]<<-list(name=name,file=key,rows=nrow(df),columns=ncol(df))
}
active_sides <- function() {s<-files(p$sides %||% list('pos','neg'));if(!length(s)||any(!s%in%c('pos','neg')))stop('Select POS and/or NEG.');unique(s)}
main <- function(){
 if(request$operation=='environment') {
  pkgs<-c('lipidflow','sxtTools','massdataset','massprocesser','metid','xcms','MSnbase','jsonlite','openxlsx','readxl','ps','plotly','patchwork')
  return(list(r=R.version.string,arch=R.version$arch,packages=lapply(pkgs,function(x)list(name=x,available=requireNamespace(x,quietly=TRUE),version=if(requireNamespace(x,quietly=TRUE))as.character(packageVersion(x)) else 'missing'))))
 }
 suppressPackageStartupMessages(library(massdataset))
 state<-if(has(request$input))readRDS(need(request$input)) else list()
 op<-request$operation
 if(op=='import') {
  state<-list(kind=p$source %||% 'raw',sides=list(),provenance=list())
  for(side in active_sides()){
   s<-list();suffix<-function(k)p[[paste0(k,'_',side)]]
   if(state$kind=='raw'){
    folder<-suffix('rawFolder')
    if(!has(folder)||length(folder)!=1||!dir.exists(folder))stop('Choose a ',toupper(side),' raw-data folder containing sample-group subfolders.')
    folder<-normalizePath(folder,mustWork=TRUE)
    raw_pattern<-'\\.(mzxml|mzml)$'
    if(length(list.files(folder,pattern=raw_pattern,ignore.case=TRUE)))stop('Place raw files inside sample-group subfolders, for example QC or D25.')
    dirs<-list.dirs(folder,recursive=FALSE,full.names=TRUE)
    dirs<-dirs[!grepl('^\\.',basename(dirs)) & !tolower(basename(dirs)) %in% c('result','results')]
    f<-character();groups<-character()
    for(d in dirs){
     direct<-list.files(d,pattern=raw_pattern,ignore.case=TRUE,full.names=TRUE)
     nested<-list.files(d,pattern=raw_pattern,ignore.case=TRUE,full.names=TRUE,recursive=TRUE)
     if(length(setdiff(nested,direct)))stop('Raw files must be directly inside each sample-group folder: ',d)
     direct<-direct[!dir.exists(direct)]
     f<-c(f,direct);groups<-c(groups,rep(basename(d),length(direct)))
    }
    if(!length(f))stop('No mzML or mzXML files found in sample-group subfolders.')
    if(anyDuplicated(tolower(basename(f))))stop('Raw filenames must be unique within each polarity, including across groups.')
    s$raw<-normalizePath(f,mustWork=TRUE);s$raw_groups<-groups;s$raw_folder<-folder
    table_out(paste0(toupper(side),' input files'),data.frame(file=basename(f),group=groups,bytes=file.info(f)$size))
   }else if(state$kind=='objects'){
    s$object<-load_object(copy_input(suffix('object'),paste0(side,'_object')));if(!methods::is(s$object,'mass_dataset'))stop('Expected a mass_dataset object.');s$peaks<-.lfs_peak_table(s$object)
   }else if(state$kind=='tables'){
    s$peaks<-checked(.lfs_read_existing_peak_table(copy_input(suffix('peaks'),paste0(side,'_peaks'))))
    s$annotations<-checked(.lfs_read_existing_annotation_table(copy_input(suffix('annotations'),paste0(side,'_annotations'))))
   }else stop('Unknown input mode.')
   state$sides[[side]]<-s
  }
 }
 if(op=='picking'){
  bool <- function(k, default) {v<-p[[k]] %||% default;if(!is.logical(v)||length(v)!=1||is.na(v))stop('Invalid parameter: ',k);v}
  integer_param <- function(k,default,min=0,max=Inf){v<-num(k,default,min,max);if(v!=floor(v))stop('Expected integer parameter: ',k);as.integer(v)}
  algorithm<-p$detectPeakAlgorithm %||% 'xcms'
  if(length(algorithm)!=1||!algorithm %in% c('xcms','massprocesser'))stop('Invalid detection algorithm.')
  figure_group<-p$groupForFigure %||% 'QC'
  if(!is.character(figure_group)||length(figure_group)!=1||!nzchar(trimws(figure_group)))stop('Specify a group for figures.')
  picking_args<-list(ppm=num('ppm',15,.Machine$double.eps),peakwidth=c(num('peakMin',10,.Machine$double.eps),num('peakMax',60,.Machine$double.eps)),
    snthresh=num('sn',5),prefilter=c(integer_param('prefilterScans',3,1),num('prefilterIntensity',500)),
    fitgauss=bool('fitgauss',FALSE),integrate=integer_param('integrate',2,1,2),mzdiff=num('mzdiff',.01,-Inf),noise=num('noise',500),
    binSize=num('binSize',.025,.Machine$double.eps),bw=num('bw',5,.Machine$double.eps),min_fraction=num('minFraction',.5,0,1),
    output_tic=bool('outputTic',TRUE),output_bpc=bool('outputBpc',TRUE),output_rt_correction_plot=bool('outputRt',TRUE),
    fill_peaks=TRUE,group_for_figure=trimws(figure_group),detect_peak_algorithm=algorithm)
  requested_threads<-integer_param('threads',0,0,4)

  if(num('peakMax',60,0)<=num('peakMin',10,0))stop('Maximum peak width must exceed minimum.')
  for(side in names(state$sides)){
   s<-state$sides[[side]];f<-s$raw;if(!length(f))stop('Import raw data first.')
   cat('Processing ',toupper(side),'\n');flush(stdout())
   # Preserve folder-defined groups; never infer groups from sample filenames.
   groups<-s$raw_groups %||% rep('Samples',length(f))
   if(length(groups)!=length(f)||any(!nzchar(groups))||any(grepl('[/\\\\]',groups))||any(groups %in% c('.','..')))stop('Invalid saved sample groups; reimport raw data.')
   rawroot<-file.path(out,'raw')
   for(group in unique(groups)){
    sample_dir<-file.path(rawroot,toupper(side),group);dir.create(sample_dir,recursive=TRUE,showWarnings=FALSE)
    if(!all(file.copy(f[groups==group],sample_dir,overwrite=FALSE)))stop('Could not stage all raw files for peak picking.')
   }
   threads<-.lfs_auto_threads_pp(length(f),requested=requested_threads,per_worker_bytes=mean(file.info(f)$size))
   effective_args<-c(list(path=file.path(rawroot,toupper(side)),polarity=if(side=='pos')'positive' else 'negative',threads=threads),picking_args)
   write_json(effective_args,file.path(out,paste0(toupper(side),'_peak_picking_parameters.json')))
   cat('Missing peak filling enabled (xcms::fillChromPeaks).\n')
   do.call(lf_process_data,effective_args)
   s$object<-load_object(file.path(rawroot,toupper(side),'Result','object'));s$peaks<-.lfs_peak_table(s$object);s$annotations<-NULL;s[["quant"]]<-NULL;state$sides[[side]]<-s;gc()
  }
 }
 if(op=='annotation'){
  suppressPackageStartupMessages(library(metid))
  for(side in names(state$sides)){
   s<-state$sides[[side]];if(is.null(s$object))stop('Peak Picking object required.')
   f<-files(p[[paste0('ms2_',side)]]);if(!length(f))stop('Select MS2 files for ',toupper(side),'.')
   dest<-file.path(out,'ms2',side);dir.create(dest,recursive=TRUE);if(anyDuplicated(basename(f)))stop('Duplicate MS2 filenames.');if(!all(file.copy(f,dest)))stop('Cannot copy MS2 files.')
   dbpath<-p[[paste0('database_',side)]];precursor_mass<-!has(dbpath)||identical(p[[paste0('massType_',side)]],'precursor');if(!has(dbpath))dbpath<-file.path(request$databaseDir,paste0('msdial_lipid_',side,'_db.rda'))
   database<-load_object(copy_input(dbpath,paste0(side,'_database')));metid::check_database(database)
   polarity<-if(side=='pos')'positive' else 'negative';column<-p$column %||% 'rp';if(!column%in%c('rp','hilic'))stop('Unsupported column.')
   cat('Attaching MS2 and annotating ',toupper(side),'\n');flush(stdout())
   obj<-lf_mutate_ms2(s$object,column=column,polarity=polarity,ms1.ms2.match.mz.tol=num('linkPpm',10,1),ms1.ms2.match.rt.tol=num('linkRT',20),path=dest)
   threads<-.lfs_auto_threads(nrow(obj@variable_info),requested=num('threads',0,0,4),per_worker_bytes=as.numeric(object.size(database))+as.numeric(object.size(obj)))
   s$object<-lf_annotate(precursor_mass=precursor_mass,object=obj,database=database,polarity=polarity,column=column,ms1.match.ppm=num('ms1ppm',15,1),ms2.match.ppm=num('ms2ppm',20,1),ms2.match.tol=num('ms2tol',0.02),rt.match.tol=if(isTRUE(p$useRT))num('rt',30) else NA_real_,candidate.num=as.integer(num('candidates',3,1)),threads=threads)
   s$annotations<-.lfs_extract_flat_annotation_table(s$object);if(is.null(s$annotations)||!ncol(s$annotations)){s$annotations<-data.frame(variable_id=character(),Compound.name=character(),Adduct=character());result$note<<-paste(result$note,toupper(side),'has no matched lipid candidates. Review MS2 data and library matching settings.')};s[["quant"]]<-NULL;state$sides[[side]]<-s;gc()
  }
 }
 if(op=='extraction'){
  is_table<-.lfs_autofill_is_ids(read_table(copy_input(p$isCsv,'internal_standards')));v<-.lfs_validate_is_table_cols(is_table);if(!v$ok)stop(v$message)
  state<-list(kind='extraction',sides=list())
  for(side in active_sides()){
   f<-p[[paste0('qc_',side)]];need(f)
   adducts<-files(p[[paste0('adducts_',side)]]);if(!length(adducts))stop('Select candidate adducts for ',side)
   cat('Extracting internal standards: ',toupper(side),'\n');flush(stdout())
   x<-.lfs_run_peak_extraction_lipidflow(f,is_table,adducts,mode=if(side=='pos')'positive' else 'negative',ppm=num('ppm',15,1),rt_tolerance=if(has(p$rtTolerance))num('rtTolerance',1e5) else 1e5,threads=1,work_dir=file.path(out,'extraction'))
   if(!isTRUE(x$ok))stop(x$message)
   x$scored<-.lfs_score_candidates(x$quant_table,x$target_table,x$eic_data);x$isopt<-.lfs_resolve_adduct_selection(x$scored)
   x$reference_sample<-basename(f)
   if(!is.null(x$eic_data))x$eic_data$Sample<-basename(f)
   x$sample_scored<-transform(x$scored,Sample=basename(f))
   state$sides[[side]]<-x;gc()
  }
 }
 if(op=='selection'){
  if(state$kind!='extraction')stop('Select an extraction run.')
  for(side in names(state$sides)){
   s<-state$sides[[side]]
   o<-s$overrides
   if(is.null(o)){
    previous<-s$isopt[s$isopt$Selection_Source=='manual',,drop=FALSE]
    o<-data.frame(IS_ID=previous$IS_ID,adduct=previous$Selected_Adduct,state=rep('selected',nrow(previous)))
   }
   changes<-p[[paste0('overrides_',side)]]
   if(length(changes))for(change in changes){
    id<-as.character(change$IS_ID);adduct<-as.character(change$adduct);status<-as.character(change$state)
    if(!status%in%c('selected','excluded','auto'))stop('Invalid override state.')
    if(!any(s$scored$IS_ID==id & s$scored$adduct==adduct))stop('Unknown internal standard / adduct.')
    o<-o[o$IS_ID!=id,,drop=FALSE]
    if(status!='auto')o<-rbind(o,data.frame(IS_ID=id,adduct=adduct,state=status))
   }
   s$overrides<-o;s$isopt<-.lfs_resolve_adduct_selection(s$scored,o);state$sides[[side]]<-s
  }
 }
 if(op=='quantification'){
  is_file<-copy_input(p$isXlsx,'IS_info');v<-.lfs_validate_is_table(is_file);if(!v$ok)stop(v$message);is_table<-read_table(is_file);state$is_file<-is_file;state$is_table<-is_table
  mapping<-NULL
  if(has(p$classMapping)){mapping<-jsonlite::fromJSON(p$classMapping,simplifyVector=TRUE);if(!is.list(mapping)||is.null(names(mapping)))stop('Class mapping must be a JSON object.')}
  for(side in names(state$sides)){
   s<-state$sides[[side]];if(is.null(s$annotations)||nrow(s$annotations)==0)stop('No annotated features to quantify for ',toupper(side));if(has(p[[paste0('isopt_',side)]]))s$isopt<-checked(.lfs_read_existing_is_opt(copy_input(p[[paste0('isopt_',side)]],paste0(side,'_isopt'))))
   if(is.null(s$isopt))stop('Choose ',toupper(side),' Y_IS_opt from Peak Extraction.')
   if(any(!is.finite(s$isopt$Peak_Area)|s$isopt$Peak_Area<=0))stop('Internal standard peak areas must be positive; review extraction results.')
   if(ncol(s$peaks)-3<2)stop('The current lipidflow quantification backend requires at least two sample columns.');
   s[["quant"]]<-.lfs_absolute_quant_from_tables(s$peaks,s$annotations,s$isopt,is_table,match_item=mapping);state$sides[[side]]<-s
  }
  result$note<<-'Quantification follows LipidFlow Shiny: each QC-derived internal-standard area is used for all samples in that polarity. This is not a per-sample internal-standard measurement.'
 }
 if(op=='export'){
  if(!is.null(state$is_table)){state$is_file<-file.path(out,'IS_info.xlsx');openxlsx::write.xlsx(state$is_table,state$is_file)}
  if(any(vapply(state$sides,function(s)!is.null(s[["quant"]]),logical(1)))) .lfs_export_absolute_quantification_bundle(state$sides$pos[["quant"]],state$sides$neg$quant,state$is_file,file.path(out,'quantification_bundle'))
 }
 for(side in names(state$sides)){
  s<-state$sides[[side]];tag<-toupper(side)
  table_out(paste(tag,'peak table'),s$peaks);table_out(paste(tag,'annotation table'),s$annotations);table_out(paste(tag,'Y_IS_opt'),s$isopt);table_out(paste(tag,'adduct candidates'),s$scored);table_out(paste(tag,'sample candidates'),s$sample_scored)
  if(!is.null(s[["quant"]])){table_out(paste(tag,'absolute quantification'),s[["quant"]]$table);cs<-.lfs_lipid_class_summary(s[["quant"]]$table);for(n in names(cs))table_out(paste(tag,n),cs[[n]])}
  if(!is.null(s$object)){object<-s$object;save(object,file=file.path(out,paste0(tag,'_object.rda')))}
  if(!is.null(s$eic_data))write_json(s$eic_data,file.path(out,paste0(tag,'_eic.json')))
 }
 if(state$kind=='extraction')table_out('Combined Y_IS_opt reference only',.lfs_combine_y_is_opt(state$sides$pos$isopt,state$sides$neg$isopt))
 caps<-c('tables');if(any(vapply(state$sides,function(s)length(s$raw)>0,logical(1))))caps<-c(caps,'raw');if(all(vapply(state$sides,function(s)!is.null(s$object),logical(1))))caps<-c(caps,'objects');if(all(vapply(state$sides,function(s)!is.null(s$annotations),logical(1))))caps<-c(caps,'annotations');result$capabilities<<-as.list(caps)
 result$metrics<<-lapply(names(state$sides)[vapply(state$sides,function(s)!is.null(s[["quant"]]),logical(1))],function(side)list(side=side,input=state$sides[[side]][["quant"]]$n_input,quantified=state$sides[[side]][["quant"]]$n_quantified))
 result$sides<<-as.list(names(state$sides));result$kind<<-state$kind
 saveRDS(state,file.path(out,'object.rds'));capture.output(sessionInfo(),file=file.path(out,'sessionInfo.txt'))
 result
}
tryCatch({ans<-main();write_json(ans,file.path(out,'result.json'));cat('Completed: ',request$operation,'\n')},error=function(e){message('ERROR: ',conditionMessage(e));capture.output(sessionInfo(),file=file.path(out,'sessionInfo.txt'));quit(status=1)})
