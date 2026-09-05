import "fake-indexeddb/auto";
import{describe,expect,it}from"vitest";
import{formatBytes,importTracks,listTracks,removeTrack}from"./tracks";
describe("track library",()=>{it("imports MP3s, ignores other files, and removes a track",async()=>{const mp3=new File([new Uint8Array([1,2,3])],"demo.mp3",{type:"audio/mpeg",lastModified:10}),text=new File(["no"],"notes.txt",{type:"text/plain"});expect(await importTracks([mp3,text])).toBe(1);const tracks=await listTracks();expect(tracks).toHaveLength(1);expect(tracks[0].name).toBe("demo");await removeTrack(tracks[0].id);expect(await listTracks()).toHaveLength(0)});it("formats file sizes",()=>{expect(formatBytes(1048576)).toBe("1.0 MB")})});
