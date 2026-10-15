import{describe,it,expect}from"vitest";
import{parseLyrics,currentLyricIndex}from"./lyrics";

describe("lyrics parity",()=>{
 it("parses and sorts repeated timestamps with fractional seconds",()=>{
  const lines=parseLyrics("[00:03.20][00:04.200] Hello\n[00:01] Intro\n");
  expect(lines.map(line=>line.time)).toEqual([1,3.2,4.2]);
  expect(lines.map(line=>line.text)).toEqual(["Intro","Hello","Hello"]);
  expect(currentLyricIndex(lines,2)).toBe(0);
  expect(currentLyricIndex(lines,3.5)).toBe(1);
 });
 it("supports ordinary lyric text without time codes",()=>{
  expect(parseLyrics("First line\nSecond line\n")).toMatchObject([{text:"First line"},{text:"Second line"}]);
  expect(currentLyricIndex(parseLyrics("line"),10)).toBe(-1);
 });
 it("ignores metadata and invalid timestamps",()=>{
  expect(parseLyrics("[ar:Someone]\n[00:90] bad\n[00:02.5] Good")).toEqual([{id:0,text:"Good",time:2.5}]);
 });
});