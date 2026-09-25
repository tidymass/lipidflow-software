const {runWorker,root}=require('./run-worker.cjs'),path=require('node:path'),assert=require('node:assert/strict'),fs=require('node:fs/promises');
(async()=>{
 const base=path.join(root,'test-output/raw-workflow-'+Date.now()),folder=path.join(base,'Input folder 原始数据');
 const paths=['M19/M19_1.mzXML','M19/M19_2.mzXML','D25/D25_1.mzXML','D25/D25_2.mzXML'];
 for(const relative of paths){const group=relative.startsWith('M19/')?'QC':'Treatment';await fs.mkdir(path.join(folder,group),{recursive:true});await fs.copyFile(path.join(root,'vendor/lipidflow/inst/POS',relative),path.join(folder,group,path.basename(relative)))}
 const imported=await runWorker(base,'import',{source:'raw',sides:['pos'],rawFolder_pos:folder,isopt_pos:'ignored-stale-input.csv'});
 const inputs=JSON.parse(await fs.readFile(path.join(base,'import/tables/POS_input_files.json')));
 assert.equal(inputs.rows.length,4);assert(inputs.rows.every(r=>r.group===(r.file.startsWith('M19')?'QC':'Treatment')));assert(!imported.tables.some(t=>t.name.includes('Y_IS_opt')));
 await assert.rejects(runWorker(path.join(base,'invalid'),'import',{source:'raw',sides:['pos'],rawFolder_pos:path.join(folder,'QC')}),/sample-group subfolders/);
 const r=await runWorker(base,'picking',{ppm:15,peakMin:10,peakMax:60,sn:5,noise:500,minFraction:.5,threads:1,prefilterScans:4,prefilterIntensity:400,fitgauss:true,integrate:1,mzdiff:-.001,binSize:.03,bw:6,outputTic:false,outputBpc:false,outputRt:false,groupForFigure:"Treatment"},'import');
 const effective=JSON.parse(await fs.readFile(path.join(base,'picking/POS_peak_picking_parameters.json')));
 assert.equal(effective.fill_peaks,true);assert.deepEqual(effective.prefilter,[4,400]);assert.equal(effective.mzdiff,-.001);assert.equal(effective.group_for_figure,'Treatment');assert.equal(effective.output_tic,false);
 const {execFileSync}=require('node:child_process'),{exe}=require('./runtime.cjs'),{rEnvironment}=require('../electron/platform.cjs');
 const evidence=execFileSync(exe,['--vanilla','-e',`suppressPackageStartupMessages(library(xcms));load(commandArgs(TRUE)[1]);stopifnot(any(chromPeakData(xdata3)$is_filled));cat(sum(chromPeakData(xdata3)$is_filled),'filled chromatographic peaks verified\\n')`,path.join(base,'picking/raw/POS/Result/intermediate_data/xdata3')],{env:rEnvironment(exe),encoding:'utf8'});console.log(evidence);
 assert(r.tables.some(t=>t.name==='POS peak table'&&t.rows>0));
 for(const group of ['QC','Treatment'])assert.equal((await fs.readdir(path.join(base,'picking/raw/POS',group))).length,2);
 await assert.rejects(fs.access(path.join(base,'picking/raw/POS/M19')));
 console.log('Real folder-based import and peak picking passed; folder names override filename prefixes and import ignores IS inputs.');
})().catch(e=>{console.error(e);process.exitCode=1});
