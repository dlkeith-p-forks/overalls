import assert from "node:assert/strict";
import { test } from "node:test";
import { configurePresence, presenceMatchPattern, presenceRegistrationId, restorePresence } from "./presence_config.mjs";

/** @typedef {import('../types/api.js').ExtensionApi} ExtensionApi */
/** @param {{permission?:boolean,registerError?:boolean}} [options] @returns {{api:ExtensionApi,registrations:unknown[],unregistered:string[],injected:number[],requested:string[][]}} */
function fixture(options={}) {
  /** @type {unknown[]} */ const registrations=[];
  /** @type {string[]} */ const unregistered=[];
  /** @type {number[]} */ const injected=[];
  /** @type {string[][]} */ const requested=[];
  /** @type {ExtensionApi} */ const api={
    runtime:{onInstalled:{addListener:()=>{}},onStartup:{addListener:()=>{}},openOptionsPage:async()=>{}},
    tabs:{query:async()=>[{id:7,url:"https://overalls.example.test/threads"}],get:async()=>({}),create:async()=>({}),onActivated:{addListener:()=>{}},onUpdated:{addListener:()=>{}}},
    storage:{sync:{get:async()=>({}),set:async()=>{}}},
    permissions:{contains:async()=>options.permission ?? true,request:async({origins})=>{requested.push(origins);return options.permission ?? true;}},
    scripting:{registerContentScripts:async(scripts)=>{if(options.registerError) throw new Error("registration failed"); registrations.push(...scripts);},unregisterContentScripts:async({ids})=>{unregistered.push(...ids);},executeScript:async({target})=>{injected.push(target.tabId);return [];}},
    contextMenus:{removeAll:async()=>{},create:()=>0,onClicked:{addListener:()=>{}}},
    action:{setBadgeBackgroundColor:async()=>{},setBadgeText:async()=>{},setIcon:async()=>{},setTitle:async()=>{},enable:async()=>{},disable:async()=>{},isEnabled:async()=>true,onClicked:{addListener:()=>{}}},
  };
  return {api,registrations,unregistered,injected,requested};
}

test("presence patterns and ids are exact-origin and stable",()=>{
  assert.equal(presenceMatchPattern("https://overalls.example.test"),"https://overalls.example.test/*");
  assert.equal(presenceMatchPattern("http://localhost:4000"),"http://localhost:4000/*");
  assert.match(presenceRegistrationId("https://overalls.example.test"),/^overalls-presence-[0-9a-f]+$/);
  assert.notEqual(presenceRegistrationId("https://one.example"),presenceRegistrationId("https://two.example"));
});

test("configuration requests permission, registers document-start detector and injects existing tabs",async()=>{
  const f=fixture({permission:false});
  await assert.rejects(configurePresence(f.api,"https://overalls.example.test",undefined,true),/Allow access/);
  assert.deepEqual(f.requested,[["https://overalls.example.test/*"]]);
  const g=fixture({permission:true});
  assert.equal(await configurePresence(g.api,"https://overalls.example.test",undefined,true),"https://overalls.example.test/");
  assert.equal(g.registrations.length,1);
  assert.deepEqual(g.registrations[0],{id:presenceRegistrationId("https://overalls.example.test"),matches:["https://overalls.example.test/*"],js:["presence.mjs"],runAt:"document_start",persistAcrossSessions:true});
  assert.deepEqual(g.injected,[7]);
});

test("old origin is removed only after the new registration succeeds",async()=>{
  const f=fixture();
  await configurePresence(f.api,"https://new.example.test","https://old.example.test",false);
  assert.equal(f.unregistered.includes(presenceRegistrationId("https://old.example.test")),true);
  const failed=fixture({registerError:true});
  await assert.rejects(configurePresence(failed.api,"https://new.example.test","https://old.example.test",false));
  assert.equal(failed.unregistered.includes(presenceRegistrationId("https://old.example.test")),false);
});

test("startup restoration never prompts",async()=>{
  const f=fixture({permission:false});
  await assert.rejects(restorePresence(f.api,"https://overalls.example.test"),/Allow access/);
  assert.deepEqual(f.requested,[]);
});
