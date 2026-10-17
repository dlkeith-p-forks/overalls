import assert from "node:assert/strict";
import { test } from "node:test";
import { launchActiveTab, updateAction } from "./extension.mjs";

/** @typedef {import('../types/api.js').ExtensionApi} ExtensionApi */
/** @param {Record<string,unknown>} stored @returns {{api:ExtensionApi,opened:string[],options:()=>number,enabled:number[],disabled:number[],badges:string[],titles:string[]}} */
function fixture(stored={}) {
  /** @type {string[]} */ const opened=[];
  /** @type {number[]} */ const enabled=[];
  /** @type {number[]} */ const disabled=[];
  /** @type {string[]} */ const badges=[];
  /** @type {string[]} */ const titles=[];
  let options=0;
  /** @type {ExtensionApi} */ const api={
    runtime:{onInstalled:{addListener:()=>{}},onStartup:{addListener:()=>{}},openOptionsPage:async()=>{options++;}},
    tabs:{query:async()=>[],get:async()=>({}),create:async({url})=>{opened.push(url);return {};},onActivated:{addListener:()=>{}},onUpdated:{addListener:()=>{}}},
    storage:{sync:{get:async()=>stored,set:async()=>{}}},
    contextMenus:{removeAll:async()=>{},create:()=>0,onClicked:{addListener:()=>{}}},
    action:{setBadgeBackgroundColor:async()=>{},setBadgeText:async({text})=>{badges.push(text);},setIcon:async()=>{},setTitle:async({title})=>{titles.push(title);},enable:async(id)=>{enabled.push(id);},disable:async(id)=>{disabled.push(id);},isEnabled:async()=>true,onClicked:{addListener:()=>{}}},
  };
  return {api,opened,options:()=>options,enabled,disabled,badges,titles};
}

test("an explicit provider click opens the configured entry page",async()=>{
  const f=fixture({overallsServerUrl:"https://overalls.example.test"});
  assert.equal(await launchActiveTab(f.api,{id:1,url:"https://codeberg.org/team/repository"}),"opened");
  assert.deepEqual(f.opened,["https://overalls.example.test/launch/entry#https://codeberg.org/team/repository"]);
});

test("missing, malformed and externally typed settings open options without transmitting",async()=>{
  for (const stored of [{},{overallsServerUrl:17},{overallsServerUrl:"http://remote.example.test"},{overallsServerUrl:"https://user:secret@remote.example.test"}]) {
    const f=fixture(stored);
    assert.equal(await launchActiveTab(f.api,{id:1,url:"https://github.com/team/repository"}),"unconfigured");
    assert.equal(f.options(),1); assert.deepEqual(f.opened,[]);
  }
});

test("unsupported or unavailable tab URLs show fixed feedback and never transmit",async(t)=>{
  t.mock.timers.enable({apis:["setTimeout"]});
  const f=fixture({overallsServerUrl:"https://overalls.example.test"});
  for (const tab of [{id:1},{id:1,url:"https://example.com/repository"}]) assert.equal(await launchActiveTab(f.api,tab),"unsupported");
  assert.deepEqual(f.opened,[]); assert.equal(f.options(),0);
  assert.deepEqual(f.badges,["!","!"]); assert.deepEqual(f.titles,["Unsupported page","Unsupported page"]);
});

test("toolbar state follows provider support and tolerates an absent tab",async()=>{
  const f=fixture();
  assert.equal(await updateAction(f.api,undefined),"unknown");
  assert.equal(await updateAction(f.api,{id:1,url:"https://bitbucket.org/team/repository"}),"supported");
  assert.equal(await updateAction(f.api,{id:2,url:"https://example.com"}),"unsupported");
  assert.deepEqual(f.enabled,[1]); assert.deepEqual(f.disabled,[2]);
});

test("a withheld URL leaves the explicit activeTab grant available without transmitting",async()=>{
  const f=fixture({overallsServerUrl:"https://overalls.example.test"});
  assert.equal(await updateAction(f.api,{id:3}),"unknown");
  assert.deepEqual(f.enabled,[3]); assert.deepEqual(f.disabled,[]);
  assert.deepEqual(f.opened,[]);
  assert.equal(await launchActiveTab(f.api,{id:3,url:"https://gitlab.com/team/repository"}),"opened");
  assert.deepEqual(f.opened,["https://overalls.example.test/launch/entry#https://gitlab.com/team/repository"]);
});
