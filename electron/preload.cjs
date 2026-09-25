const {contextBridge,ipcRenderer}=require('electron');
const allowed=new Set(['environment','recentProjects','createProject','openProject','pick','run','cancel','reveal','export','downloadSelected','table','eic','log','help','labWebsite','appearance']);
contextBridge.exposeInMainWorld('desktop',{invoke:(action,payload)=>{if(!allowed.has(action))return Promise.reject(Error('Unsupported action'));return ipcRenderer.invoke(action,payload)},onLog:callback=>{const fn=(_,s)=>callback(s);ipcRenderer.on('engine-log',fn);return()=>ipcRenderer.removeListener('engine-log',fn)}});
