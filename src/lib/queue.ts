export type RepeatMode = "off" | "all" | "one";
export function nextTrackId(
 ids:string[],currentId:string,
 options:{shuffle:boolean;repeat:RepeatMode;random?:()=>number;automatic?:boolean}
):string|null{
 if(!ids.length)return null;
 const automatic=options.automatic!==false;
 if(automatic&&options.repeat==="one")return currentId;
 if(options.shuffle){
  if(ids.length===1)return automatic&&options.repeat==="off"?null:ids[0];
  const choices=ids.filter(id=>id!==currentId);
  return choices[Math.floor((options.random?.()??Math.random())*choices.length)]??null;
 }
 const index=ids.indexOf(currentId);
 if(index<0||index+1<ids.length)return ids[Math.max(0,index+1)];
 return options.repeat==="all"||!automatic?ids[0]:null;
}
export function previousTrackId(
 ids:string[],currentId:string,options:{repeat?:RepeatMode}={}
):string|null{
 if(!ids.length)return null;
 const index=ids.indexOf(currentId);
 if(index>0)return ids[index-1];
 if(index===0)return options.repeat==="all"?ids.at(-1)??null:null;
 return null;
}
