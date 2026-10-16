import type {Track} from "./tracks";

export type TrackSort = "recent"|"title"|"artist";

/** Stable presentation ordering. Playlist trackIds remain the source of truth. */
export function sortLibraryTracks<T extends Pick<Track,"id"|"name"|"artist"|"importedAt">>(
 tracks:readonly T[],sort:TrackSort
):T[]{
 const nameOrder=(a:T,b:T)=>a.name.localeCompare(b.name,undefined,{numeric:true,sensitivity:"base"});
 return [...tracks].sort((a,b)=>{
  switch(sort){
   case "title": return nameOrder(a,b);
   case "artist": {
    const artistOrder=(a.artist??"").localeCompare(b.artist??"",undefined,{
      numeric:true,sensitivity:"base"
    });
    return artistOrder||nameOrder(a,b);
   }
   case "recent": default: return b.importedAt-a.importedAt||nameOrder(a,b);
  }
 });
}
