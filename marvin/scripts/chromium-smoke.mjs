import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium } from "playwright-core";
import { sourceRoot } from "./build.mjs";

const executablePath=process.env.CHROME;
assert.ok(executablePath,"Set CHROME to the pinned Chromium executable");
// The fixed provider origin is already in the extension's required host
// permissions, so this smoke test can exercise the settings flow without a
// permission prompt (which has no UI in headless Chromium). Exact-origin
// optional permission requests are covered by the typed unit fixtures.
const origin="https://github.com";
const profile=await mkdtemp(join(tmpdir(),"overalls-extension-smoke-"));
const context=await chromium.launchPersistentContext(profile,{
  executablePath,headless:true,ignoreDefaultArgs:["--disable-extensions"],
  args:["--enable-unsafe-extension-debugging","--no-sandbox","--disable-dev-shm-usage"],
});
try {
  const browser=context.browser(); assert.ok(browser);
  const protocol=await browser.newBrowserCDPSession();
  /** @type {unknown} */ const loaded=await protocol.send("Extensions.loadUnpacked",{path:join(sourceRoot,"dist","chrome")});
  assert.ok(typeof loaded==="object" && loaded!==null && "id" in loaded && typeof loaded.id==="string");
  const id=loaded.id; assert.match(id,/^[a-p]{32}$/);
  const options=context.pages()[0]??await context.newPage();
  await options.goto(`chrome-extension://${id}/options.html`);
  await options.locator('[data-build="platform"]').getByText("browser-chrome").waitFor();
  assert.equal(await options.locator("#guide-link").getAttribute("href"),"https://github.com/ghuntley/overalls/blob/trunk/marshall/priv/docs/browser-extension.md");
  await options.locator("#server-url").fill(origin);
  await options.getByRole("button",{name:"Save"}).click();
  await options.locator("#status").getByText("Saved.").waitFor();
  assert.equal(await options.locator("#guide-link").getAttribute("href"),`${origin}/docs/browser-extension`);
  await context.route("https://**/*",route=>route.fulfill({status:200,contentType:"text/html",body:"<!doctype html><title>Fixture</title>"}));
  const page=await context.newPage();
  /** @type {number | undefined} */ let sourceTabId;
  for(const host of ["github.com","gitlab.com","codeberg.org","bitbucket.org"]) {
    const source=`https://${host}/example/repository?access_token=query-secret#token=fragment-secret`;
    await page.bringToFront();
    await page.goto(source);
    if (host === "github.com") {
      await waitUntil(async()=>await page.evaluate(() => document.documentElement.dataset.overallsBrowserExtension === "installed"));
    }
    const worker=context.serviceWorkers().find(value=>value.url().startsWith(`chrome-extension://${id}/`)); assert.ok(worker);
    await waitUntil(async()=>worker.evaluate(async(url)=>{
      const api=globalThis.chrome; if(!api) return false;
      const tab=(await api.tabs.query({})).find(value=>value.url===url);
      return tab?.id!==undefined && await api.action.isEnabled(tab.id);
    },source));
    sourceTabId=await worker.evaluate(async(url)=>{
      const api=globalThis.chrome;
      return api ? (await api.tabs.query({})).find(value=>value.url===url)?.id : undefined;
    },source);
    /** @type {unknown} */ const response=await protocol.send("Target.getTargets",{filter:[{type:"tab",exclude:false}]});
    assert.ok(typeof response==="object" && response!==null && "targetInfos" in response && Array.isArray(response.targetInfos));
    /** @type {unknown[]} */ const targets=response.targetInfos;
    const target=targets.find(value=>typeof value==="object"&&value!==null&&"url" in value&&value.url===source);
    assert.ok(typeof target==="object"&&target!==null&&"targetId" in target&&typeof target.targetId==="string");
    await protocol.send("Extensions.triggerAction",{id,targetId:target.targetId});
    try {
      await waitUntil(async()=>context.pages().some(value=>value.url()===`${origin}/launch/entry#https://${host}/example/repository`));
    } catch {
      throw new Error(`Fixture launch failed for ${host}`);
    }
  }
  await page.bringToFront(); await page.goto("https://example.com/unsupported");
  const worker=context.serviceWorkers()[0]; assert.ok(worker);
  assert.ok(sourceTabId!==undefined);
  const enabled=await worker.evaluate(async(tabId)=>{
    const api=globalThis.chrome; if(!api) throw new Error("Extension API unavailable");
    return api.action.isEnabled(tabId);
  },sourceTabId);
  if(enabled) {
    // Without host permission the URL is withheld until the explicit activeTab
    // grant. That click must observe the unsupported host and create no tab.
    /** @type {unknown} */ const response=await protocol.send("Target.getTargets",{filter:[{type:"tab",exclude:false}]});
    assert.ok(typeof response==="object"&&response!==null&&"targetInfos" in response&&Array.isArray(response.targetInfos));
    /** @type {unknown[]} */ const targets=response.targetInfos;
    const target=targets.find(value=>typeof value==="object"&&value!==null&&"url" in value&&value.url==="https://example.com/unsupported");
    assert.ok(typeof target==="object"&&target!==null&&"targetId" in target&&typeof target.targetId==="string");
    const pages=context.pages().length;
    await protocol.send("Extensions.triggerAction",{id,targetId:target.targetId});
    await worker.evaluate(()=>new Promise(resolve=>setTimeout(resolve,100)));
    assert.equal(context.pages().length,pages);
    assert.equal(await worker.evaluate(async(tabId)=>{
      const api=globalThis.chrome;
      return api ? (await api.tabs.get(tabId)).url==="https://example.com/unsupported" : false;
    },sourceTabId),true);
  }
} finally {
  await context.close();
  await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}

/** @param {()=>Promise<boolean>} predicate @returns {Promise<void>} */
async function waitUntil(predicate) {
  const deadline=Date.now()+10000;
  while(Date.now()<deadline) {
    if(await predicate()) return;
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  throw new Error("Browser extension assertion timed out");
}
