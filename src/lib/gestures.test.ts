import{describe,expect,it}from"vitest";
import{playerGesture}from"./gestures";
describe("full-player gestures",()=>{it("closes only on a deliberate downward swipe",()=>{expect(playerGesture(8,90)).toBe("close");expect(playerGesture(5,40)).toBeNull()});it("changes tracks on horizontal swipes",()=>{expect(playerGesture(-90,5)).toBe("next");expect(playerGesture(90,5)).toBe("previous")});it("ignores diagonal movement",()=>{expect(playerGesture(80,75)).toBeNull()})});
