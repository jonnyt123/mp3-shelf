import {readFileSync} from "node:fs";
import vm from "node:vm";
import {describe,expect,it,vi} from "vitest";

type Listener=(event:any)=>void;

function createHarness(){
 const listeners:Record<string,Listener>={},stores=new Map<string,Map<string,Response>>();
 const key=(request:Request|string)=>typeof request==="string"?new URL(request,"https://mp3-shelf.test").href:request.url;
 const cacheFor=(name:string)=>{if(!stores.has(name))stores.set(name,new Map());const store=stores.get(name)!;return{put:async(request:Request|string,response:Response)=>{store.set(key(request),response)},match:async(request:Request|string)=>store.get(key(request))}};
 const caches={open:async(name:string)=>cacheFor(name),match:async(request:Request|string)=>{for(const store of stores.values()){const found=store.get(key(request));if(found)return found}},keys:async()=>[...stores.keys()],delete:async(name:string)=>stores.delete(name)};
 const fetch=vi.fn(async(input:Request|string)=>{const url=key(input);if(url==="https://mp3-shelf.test/")return new Response('<link rel="stylesheet" href="/_next/app.css"><script src="/_next/app.js"></script>');return new Response(`asset:${url}`)});
 const self={location:{origin:"https://mp3-shelf.test"},clients:{claim:vi.fn()},skipWaiting:vi.fn(),addEventListener:(name:string,listener:Listener)=>{listeners[name]=listener}};
 const source=readFileSync(new URL("../../public/sw.js",import.meta.url),"utf8");
 vm.runInNewContext(source,{self,caches,fetch,URL,Response,Promise,Set,Array,Error});
 return{listeners,stores,fetch,self};
}

describe("offline service worker",()=>{
 it("pre-caches the homepage and its discovered Next.js assets",async()=>{
  const harness=createHarness();let installed:Promise<unknown>|undefined;
  harness.listeners.install({waitUntil:(promise:Promise<unknown>)=>{installed=promise}});
  await installed;
  const cached=harness.stores.get("mp3-shelf-v2");
  expect(cached?.has("https://mp3-shelf.test/")).toBe(true);
  expect(cached?.has("https://mp3-shelf.test/_next/app.css")).toBe(true);
  expect(cached?.has("https://mp3-shelf.test/_next/app.js")).toBe(true);
  expect(harness.self.skipWaiting).toHaveBeenCalledOnce();
 });

 it("serves a cached asset when the network is unavailable",async()=>{
  const harness=createHarness();let installed:Promise<unknown>|undefined;
  harness.listeners.install({waitUntil:(promise:Promise<unknown>)=>{installed=promise}});await installed;
  harness.fetch.mockClear();
  harness.fetch.mockRejectedValueOnce(new Error("offline"));
  let response:Promise<Response>|undefined;
  harness.listeners.fetch({request:new Request("https://mp3-shelf.test/_next/app.js"),respondWith:(promise:Promise<Response>)=>{response=promise}});
  expect(await (await response)?.text()).toContain("/_next/app.js");
  expect(harness.fetch).not.toHaveBeenCalled();
 });

 it("falls back to the cached homepage for an offline navigation",async()=>{
  const harness=createHarness();let installed:Promise<unknown>|undefined;
  harness.listeners.install({waitUntil:(promise:Promise<unknown>)=>{installed=promise}});await installed;
  harness.fetch.mockRejectedValueOnce(new Error("offline"));
  let response:Promise<Response>|undefined;
  const request={method:"GET",headers:new Headers(),url:"https://mp3-shelf.test/library",mode:"navigate"};
  harness.listeners.fetch({request,respondWith:(promise:Promise<Response>)=>{response=promise}});
  expect(await (await response)?.text()).toContain("/_next/app.css");
 });

 it("removes obsolete caches when the new worker activates",async()=>{
  const harness=createHarness();
  harness.stores.set("mp3-shelf-v1",new Map());
  harness.stores.set("mp3-shelf-v2",new Map());
  let activated:Promise<unknown>|undefined;
  harness.listeners.activate({waitUntil:(promise:Promise<unknown>)=>{activated=promise}});
  await activated;
  expect([...harness.stores.keys()]).toEqual(["mp3-shelf-v2"]);
  expect(harness.self.clients.claim).toHaveBeenCalledOnce();
 });
});
