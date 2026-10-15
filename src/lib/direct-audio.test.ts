import {describe,expect,it} from "vitest";
import {allowedAudioURL,downloadAuthorizedMP3} from "./direct-audio";

describe("authorized audio download validation",()=>{
  it("allows HTTPS hosting but rejects streaming services and HTTP",()=>{
    expect(allowedAudioURL("https://example.org/free/sample.mp3").hostname).toBe("example.org");
    expect(()=>allowedAudioURL("https://open.spotify.com/track/xyz")).toThrow("Streaming");
    expect(()=>allowedAudioURL("https://spotify.com.evil.com/audio.mp3")).not.toThrow();
    expect(()=>allowedAudioURL("http://example.org/song.mp3")).toThrow("HTTPS");
  });
  it("imports a small original MP3-shaped test file",async()=>{
    const bytes=new Uint8Array(200);bytes.set([0x49,0x44,0x33]);
    const request=async()=>new Response(bytes,{status:200,headers:{"content-type":"audio/mpeg"}});
    const file=await downloadAuthorizedMP3("https://example.org/track.mp3",request as typeof fetch);
    expect(file.name).toBe("track.mp3");
    expect(file.size).toBe(200);
  });
  it("rejects non-audio content and zero-byte downloads",async()=>{
    await expect(downloadAuthorizedMP3("https://example.org/x.mp3",
      (async()=>new Response("<html/>",{headers:{"content-type":"text/html"}})) as typeof fetch))
      .rejects.toThrow("direct MP3");
    await expect(downloadAuthorizedMP3("https://example.org/x.mp3",
      (async()=>new Response(new Uint8Array(0),{headers:{"content-type":"audio/mpeg"}})) as typeof fetch))
      .rejects.toThrow("empty or incomplete");
  });
});