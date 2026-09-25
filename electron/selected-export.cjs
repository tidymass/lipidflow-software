const fs=require('node:fs/promises'),path=require('node:path');
const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const array=v=>Array.isArray(v)?v:v==null?[]:[v];
const csv=v=>{let s=String(v??'');if(/^[=+@\-\t\r]/.test(s)&&typeof v!=='number')s="'"+s;return '"'+s.replace(/"/g,'""')+'"'};
const colors=['#a82c50','#3269ae','#2b9270','#a77513','#8757ad','#258791'];
function plot(row,traces){
 const series=traces.map(t=>({sample:t.Sample||'Reference QC',points:array(t.rt).map((x,i)=>[x,array(t.intensity)[i]]).filter(p=>p.every(v=>typeof v==='number'&&Number.isFinite(v)))}));
 let min=Infinity,max=-Infinity,high=0;for(const t of series)for(const [x,y] of t.points){min=Math.min(min,x);max=Math.max(max,x);high=Math.max(high,y)}
 const has=Number.isFinite(min);if(!has){min=0;max=1}if(max===min)max=min+1;high=Math.max(high,1);
 const height=410+series.length*23;
 const lines=series.map((t,i)=>`<polyline fill="none" stroke="${colors[i%colors.length]}" stroke-width="1.6" points="${t.points.map(([x,y])=>`${(90+(x-min)/(max-min)*860).toFixed(2)},${(325-y/high*225).toFixed(2)}`).join(' ')}"/><text x="90" y="${410+i*23}" fill="${colors[i%colors.length]}">${escape(t.sample)}</text>`).join('');
 const axes=[0,.25,.5,.75,1].map(f=>`<line x1="90" x2="950" y1="${325-f*225}" y2="${325-f*225}" stroke="#ddd"/><text x="80" y="${329-f*225}" text-anchor="end">${(high*f).toPrecision(3)}</text><text x="${90+860*f}" y="350" text-anchor="middle">${(min+(max-min)*f).toFixed(1)}</text>`).join('');
 return `<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="${height}" viewBox="0 0 1000 ${height}"><rect width="100%" height="100%" fill="white"/><g font-family="Arial,sans-serif" font-size="12" fill="#333"><text x="40" y="30" font-size="19">${escape(row.IS_ID)} · ${escape(row.IS_Name)}</text><text x="40" y="55">Selected adduct: ${escape(row.Selected_Adduct)} · ${escape(row.Selection_Source)} · m/z ${escape(row.Target_mz)} · RT ${escape(row.Measured_RT)} s</text><text x="90" y="85">Intensity</text>${axes}${lines}<text x="510" y="380" text-anchor="middle">Retention time (s)</text>${has?'':'<text x="350" y="200">No EIC data available for this selected adduct.</text>'}</g></svg>`;
}
async function exportSelected({projectPath,destinationPath,runDir,run,side}){
 if(!['pos','neg'].includes(side)||run.status!=='completed'||run.result?.kind!=='extraction'||!run.result.sides.includes(side))throw Error('Choose a completed internal-standard result and polarity.');
 const table=run.result.tables.find(t=>t.name===side.toUpperCase()+' Y_IS_opt');if(!table||!/^[\w-]+$/.test(table.file))throw Error('Final table is unavailable.');
 const final=JSON.parse(await fs.readFile(path.join(runDir,'tables',table.file+'.json'),'utf8'));
 let traces=[];try{traces=JSON.parse(await fs.readFile(path.join(runDir,side.toUpperCase()+'_eic.json'),'utf8'))}catch(e){if(e.code!=='ENOENT')throw e}
 const parent=destinationPath||path.join(projectPath,'exports');await fs.mkdir(parent,{recursive:true});const dest=await fs.mkdtemp(path.join(parent,side.toUpperCase()+'-selected-'));const missing=[];
 try{
 await fs.mkdir(path.join(dest,'peak-shapes'));await fs.copyFile(path.join(runDir,'tables',table.file+'.csv'),path.join(dest,side.toUpperCase()+'_Y_IS_opt.csv'));
 const entries=[];let index=0;
 for(const row of final.rows){
 const matched=traces.filter(t=>t.IS_ID===row.IS_ID&&(t.adduct||t.Adduct)===row.Selected_Adduct);
 if(!matched.some(t=>array(t.rt).some((x,i)=>Number.isFinite(x)&&Number.isFinite(array(t.intensity)[i]))))missing.push(row.IS_ID);
 const stem=String(++index).padStart(3,'0')+'-'+String(row.IS_ID).replace(/[^a-zA-Z0-9_-]/g,'_');
 await fs.writeFile(path.join(dest,'peak-shapes',stem+'.svg'),plot(row,matched));
 const rows=[['IS_ID','IS_Name','Selected_Adduct','Sample','RT_seconds','Intensity'].map(csv).join(',')];
 for(const t of matched)array(t.rt).forEach((rt,i)=>rows.push([row.IS_ID,row.IS_Name,row.Selected_Adduct,t.Sample||'Reference QC',rt,array(t.intensity)[i]].map(csv).join(',')));
 await fs.writeFile(path.join(dest,'peak-shapes',stem+'.csv'),rows.join('\n')+'\n');
 entries.push({IS_ID:row.IS_ID,adduct:row.Selected_Adduct,svg:'peak-shapes/'+stem+'.svg',csv:'peak-shapes/'+stem+'.csv',samples:matched.map(t=>t.Sample||'Reference QC')});
 }
 await fs.writeFile(path.join(dest,'manifest.json'),JSON.stringify({runId:run.id,polarity:side,created:new Date().toISOString(),standards:entries,missingTraces:missing},null,2));
 await fs.writeFile(path.join(dest,'index.html'),`<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'unsafe-inline'"><title>LipidFlow selected peak shapes</title><style>body{font:15px Arial;margin:32px auto;max-width:1050px;color:#333}img{width:100%}section{margin:30px 0;border-top:1px solid #ddd}a{color:#a82c50}</style></head><body><h1>${side.toUpperCase()} · Selected internal-standard peak shapes</h1><p>Saved run: ${escape(run.id)}. All available samples for each confirmed or automatically selected adduct are included, independently of screen filters.</p><a href="${side.toUpperCase()}_Y_IS_opt.csv">Final internal standard table (CSV)</a>${missing.length?`<p>Missing traces: ${missing.map(escape).join(', ')}</p>`:''}${entries.map(e=>`<section><img src="${e.svg}" alt="${escape(e.IS_ID)} ${escape(e.adduct)}"><a href="${e.svg}">SVG figure</a> · <a href="${e.csv}">Trace data (CSV)</a></section>`).join('')}</body></html>`);
 return {path:dest,count:entries.length,missing};
 }catch(e){await fs.rm(dest,{recursive:true,force:true});throw e}
}
module.exports={exportSelected};
