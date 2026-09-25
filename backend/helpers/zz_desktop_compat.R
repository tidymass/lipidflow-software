# Compatibility adapters for the R runtime inherited from TidyMass Desktop.
# No peak-detection, spectrum-matching or quantification parameters are changed.
lf_process_data <- function(...) {
  process_raw <- massprocesser::process_data
  if(!methods::isClass('NAnnotatedDataFrame')) {
    replace_class <- function(x) {
      if(is.call(x)&&identical(x[[1]],as.name('new'))&&length(x)>=2&&identical(x[[2]],'NAnnotatedDataFrame'))x[[2]]<-'AnnotatedDataFrame'
      if(is.call(x))x<-as.call(lapply(as.list(x),replace_class))
      x
    }
    body(process_raw)<-replace_class(body(process_raw))
    message('Using AnnotatedDataFrame for MSnbase compatibility (TidyMass adapter).')
  }
  process_raw(...)
}
# Upstream read_mgf uses mapply simplification, which flattens spectra when
# multiple blocks contain the same number of fragments. Parse blocks into an
# explicit list, retaining measured m/z, intensity and RT; matching stays upstream.
lf_read_mgf <- function(file) {
  result<-list()
  for(f in file){
    lines<-trimws(readLines(f,warn=FALSE));starts<-which(lines=='BEGIN IONS');ends<-which(lines=='END IONS')
    if(length(starts)!=length(ends)||!length(starts)||any(ends<starts))stop('Invalid MGF block boundaries: ',f)
    for(i in seq_along(starts)){
      block<-lines[seq.int(starts[i]+1,ends[i]-1)]
      val<-function(pattern){x<-grep(pattern,block,value=TRUE);if(length(x)!=1)stop('Missing or ambiguous MGF metadata: ',pattern);sub('^[^=:]+[=:]','',x)}
      mz<-as.numeric(strsplit(trimws(val('^(PEPMASS|PRECURSORMZ)[=:]')),'[[:space:]]+')[[1]][1])
      rtline<-grep('^(RTINSECONDS|RTINMINUTES|RETENTIONTIME)[=:]',block,value=TRUE);rt<-as.numeric(val('^(RTINSECONDS|RTINMINUTES|RETENTIONTIME)[=:]'));if(grepl('^RTINMINUTES',rtline))rt<-rt*60
      rows<-grep('^[0-9.]',block,value=TRUE);if(!length(rows))next
      matrix<-do.call(rbind,lapply(strsplit(rows,'[[:space:]]+'),function(x)as.numeric(x[1:2])))
      if(any(!is.finite(matrix))||!is.finite(mz)||!is.finite(rt))stop('Non-numeric MGF metadata or fragment peak.')
      colnames(matrix)<-c('mz','intensity');result[[length(result)+1]]<-list(info=c(mz=mz,rt=rt),spec=matrix)
    }
  }
  result
}
lf_mutate_ms2 <- function(...) {
  fn<-massdataset::mutate_ms2
  e<-new.env(parent=environment(fn));e$read_mgf<-lf_read_mgf;environment(fn)<-e
  fn(...)
}
# The pinned MS-DIAL libraries store precursor ion m/z in spectra.info$mz.
# metid normally adds an adduct shift to a neutral mass. For precursor-mass
# libraries only, inject a zero-shift lookup into a local copy of metid's
# matching function, then restore each reference's original adduct label.
# MS1 tolerance, MS2 scoring, candidate ranking and output objects are unchanged.
lf_annotate <- function(..., precursor_mass=FALSE) {
  if(!precursor_mass)return(metid::annotate_metabolites_mass_dataset(...))
  args<-list(...);db<-args$database
  if(!all(c('Lab.ID','Adduct','mz')%in%names(db@spectra.info)))stop('Precursor libraries require Lab.ID, Adduct and mz.')
  core<-get('metIdentify_mass_dataset',asNamespace('metid'))
  env<-new.env(parent=environment(core))
  env$data<-function(...,envir){n<-list(...)[[1]];if(!n%in%c('rp.pos','rp.neg','hilic.pos','hilic.neg'))stop('Unexpected adduct lookup.');assign(n,data.frame(Adduct='M',Mass=0),envir=envir)}
  environment(core)<-env
  wrapped<-function(...){x<-core(...);if(nrow(x)>0){idx<-match(x$Lab.ID,db@spectra.info$Lab.ID);if(anyNA(idx))stop('Reference IDs missing from precursor library.');x$Adduct<-db@spectra.info$Adduct[idx]};x}
  outer<-metid::annotate_metabolites_mass_dataset;e<-new.env(parent=environment(outer));e$metIdentify_mass_dataset<-wrapped;environment(outer)<-e
  message('Matching precursor m/z directly; preserving library adduct labels.')
  do.call(outer,args)
}
