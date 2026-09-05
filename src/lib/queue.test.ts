import{describe,expect,it}from"vitest";
import{nextTrackId,previousTrackId}from"./queue";
describe("play queue",()=>{const ids=["a","b","c"];
 it("moves forward and stops at the end",()=>{expect(nextTrackId(ids,"a",{shuffle:false,repeat:"off"})).toBe("b");expect(nextTrackId(ids,"c",{shuffle:false,repeat:"off"})).toBeNull()});
 it("repeats one track or the full queue",()=>{expect(nextTrackId(ids,"b",{shuffle:false,repeat:"one"})).toBe("b");expect(nextTrackId(ids,"c",{shuffle:false,repeat:"all"})).toBe("a")});
 it("shuffles without immediately repeating",()=>{expect(nextTrackId(ids,"b",{shuffle:true,repeat:"off",random:()=>0})).toBe("a")});
 it("moves backward",()=>{expect(previousTrackId(ids,"c")).toBe("b");expect(previousTrackId(ids,"a")).toBeNull()});
});
