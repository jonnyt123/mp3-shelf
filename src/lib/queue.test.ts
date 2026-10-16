import{describe,expect,it}from"vitest";
import{nextTrackId,previousTrackId}from"./queue";
describe("play queue",()=>{const ids=["a","b","c"];
 it("moves forward and stops at the end",()=>{expect(nextTrackId(ids,"a",{shuffle:false,repeat:"off"})).toBe("b");expect(nextTrackId(ids,"c",{shuffle:false,repeat:"off"})).toBeNull()});
 it("repeats one track or the full queue",()=>{expect(nextTrackId(ids,"b",{shuffle:false,repeat:"one"})).toBe("b");expect(nextTrackId(ids,"c",{shuffle:false,repeat:"all"})).toBe("a")});
 it("shuffles without immediately repeating",()=>{expect(nextTrackId(ids,"b",{shuffle:true,repeat:"off",random:()=>0})).toBe("a")});
 it("manual next skips repeat-one and wraps at the end like the native player",()=>{
  expect(nextTrackId(ids,"b",{shuffle:false,repeat:"one",automatic:false})).toBe("c");
  expect(nextTrackId(ids,"c",{shuffle:false,repeat:"off",automatic:false})).toBe("a");
  expect(nextTrackId(ids,"c",{shuffle:false,repeat:"one",automatic:true})).toBe("c");
 });
 it("previous wraps only for repeat-all",()=>{
  expect(previousTrackId(ids,"a",{repeat:"all"})).toBe("c");
  expect(previousTrackId(ids,"a",{repeat:"one"})).toBeNull();
 });
 it("moves backward",()=>{expect(previousTrackId(ids,"c")).toBe("b");expect(previousTrackId(ids,"a")).toBeNull()});
});
