import "fake-indexeddb/auto";
import{describe,expect,it}from"vitest";
import{formatBytes,importTracks,listTracks,removeTrack,restoreTracks,toggleTrackFavorite,updateTrackLyrics,renameTrack,Track}from"./tracks";
describe("track library",()=>{it("imports MP3s, ignores other files, and removes a track",async()=>{const mp3=new File([new Uint8Array([1,2,3])],"demo.mp3",{type:"audio/mpeg",lastModified:10}),text=new File(["no"],"notes.txt",{type:"text/plain"});expect(await importTracks([mp3,text])).toBe(1);const tracks=await listTracks();expect(tracks).toHaveLength(1);expect(tracks[0].name).toBe("demo");await removeTrack(tracks[0].id);expect(await listTracks()).toHaveLength(0)});it("restores a track atomically into IndexedDB",async()=>{const track:Track={id:"restored",name:"Restored song",size:3,type:"audio/mpeg",importedAt:50,blob:new Blob([new Uint8Array([4,5,6])])};expect(await restoreTracks([track])).toBe(1);expect((await listTracks()).find(item=>item.id==="restored")?.name).toBe("Restored song");await removeTrack("restored")});it("toggles a favorite and persists it",async()=>{const track:Track={id:"fav-song",name:"Fav",size:3,type:"audio/mpeg",importedAt:55,blob:new Blob([new Uint8Array([1,2,3])])};await restoreTracks([track]);expect(await toggleTrackFavorite("fav-song")).toBe(true);expect((await listTracks()).find(item=>item.id==="fav-song")?.isFavorite).toBe(true);expect(await toggleTrackFavorite("fav-song")).toBe(false);await removeTrack("fav-song")});it("does not erase song edits or source provenance during duplicate imports",async()=>{
 const file=new File([new Uint8Array([73,68,51,1])],"repeat.mp3",{type:"audio/mpeg",lastModified:77});
 const attribution={sourceURL:"https://example.org/track",licenseURL:"https://creativecommons.org/licenses/by/4.0/",
  creator:"Artist",provider:"Openverse",license:"BY"};
 expect(await importTracks([file],attribution)).toBe(1);
 const id=`repeat.mp3:${file.size}:77`;
 await renameTrack(id,"My version");
 await toggleTrackFavorite(id);
 await updateTrackLyrics(id,"[00:01.2] Hello");
 await importTracks([file]);
 const song=(await listTracks()).find(track=>track.id===id)!;
 expect(song).toMatchObject({name:"My version",isFavorite:true,
  lyrics:"[00:01.2] Hello",attribution});
 await removeTrack(id);
});it("formats file sizes",()=>{expect(formatBytes(0)).toBe("0 KB");expect(formatBytes(1048576)).toBe("1.0 MB");expect(formatBytes(1073741824)).toBe("1.0 GB")})});
