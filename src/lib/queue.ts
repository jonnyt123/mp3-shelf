export type RepeatMode = "off" | "all" | "one";
export function nextTrackId(ids:string[],currentId:string,options:{shuffle:boolean;repeat:RepeatMode;random?:()=>number}):string|null{
 if(!ids.length)return null;if(options.repeat==="one")return currentId;
 if(options.shuffle){if(ids.length===1)return options.repeat==="all"?ids[0]:null;const choices=ids.filter(id=>id!==currentId);return choices[Math.floor((options.random?.()??Math.random())*choices.length)]??null}
 const index=ids.indexOf(currentId);if(index<0||index+1<ids.length)return ids[Math.max(0,index+1)];return options.repeat==="all"?ids[0]:null;
}
export function previousTrackId(ids:string[],currentId:string):string|null{const index=ids.indexOf(currentId);return index>0?ids[index-1]:null}
