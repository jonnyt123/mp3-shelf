import {describe,expect,it} from "vitest";
import {discoveryQuery,normalizeOpenverseAudio} from "./open-audio";

const base = {
  id:"id1",title:"Original recording",creator:"Studio Artist",
  provider:"Open Source",license:"by",license_url:"https://creativecommons.org/licenses/by/4.0/",
  foreign_landing_url:"https://example.org/original",url:"https://example.org/music.mp3",filetype:"mp3"
};
describe("Openverse licensed audio discovery",()=>{
  it("accepts an open-licensed record with separated provenance",()=>{
    expect(normalizeOpenverseAudio({results:[base]})).toEqual([{
      id:"id1",title:"Original recording",artist:"Studio Artist",provider:"Open Source",
      license:"BY",licenseURL:"https://creativecommons.org/licenses/by/4.0/",
      sourceURL:"https://example.org/original",downloadURL:"https://example.org/music.mp3"
    }]);
  });
  it("never promotes unknown or nonpermitted licenses",()=>{
    const results=[{...base,id:"z1",license:"by-nc"}, {...base,id:"z2",license:"unknown"},
      {...base,id:"z3",license_url:"javascript:alert(1)"},
      {...base,id:"z4",foreign_landing_url:"http://example.org"}];
    expect(normalizeOpenverseAudio({results})).toEqual([]);
  });
  it("keeps source information while withholding forbidden download URLs",()=>{
    const [row]=normalizeOpenverseAudio({results:[{...base,url:"https://open.spotify.com/track/abcd",filetype:"mp3"}]});
    expect(row).toBeDefined();
    expect(row.downloadURL).toBeUndefined();
    expect(row.sourceURL).toBe(base.foreign_landing_url);
  });
  it("does not trust invalid response shapes or duplicate IDs",()=>{
    expect(normalizeOpenverseAudio(null)).toEqual([]);
    expect(normalizeOpenverseAudio({results:[base,base]})).toHaveLength(1);
  });
  it("bounds the query to prevent expensive anonymous searches",()=>{
    expect(discoveryQuery("   Quiet   guitar\n ")).toBe("Quiet guitar");
    expect(()=>discoveryQuery(" ")).toThrow("2 to 100");
    expect(()=>discoveryQuery("a".repeat(101))).toThrow("2 to 100");
  });
});