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
  it("reports real transfer bytes without assuming a known content length",async()=>{
    const bytes=new Uint8Array(300);bytes.set([0x49,0x44,0x33]);
    const progress: Array<[number,number|undefined]>=[];
    const request=async()=>new Response(new ReadableStream<Uint8Array>({
      start(controller){
        controller.enqueue(bytes.slice(0,200));
        controller.enqueue(bytes.slice(200));
        controller.close();
      }
    }),{status:200,headers:{"content-type":"audio/mpeg"}});
    const file=await downloadAuthorizedMP3("https://example.org/free.mp3",request as typeof fetch,{
      onProgress:(received,total)=>progress.push([received,total])
    });
    expect(file.size).toBe(300);
    expect(progress).toEqual([[200,undefined],[300,undefined]]);
  });
  it("supports user cancellation before requesting audio",async()=>{
    const controller=new AbortController();controller.abort();
    const request=async()=>{throw new DOMException("Aborted","AbortError")};
    await expect(downloadAuthorizedMP3("https://example.org/free.mp3",request as typeof fetch,
      {signal:controller.signal})).rejects.toThrow("cancelled");
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