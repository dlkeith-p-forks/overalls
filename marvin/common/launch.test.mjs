import assert from "node:assert/strict";
import { test } from "node:test";
import { overallsLaunchUrl, normalizeServerUrl, supportedSourceUrl } from "./launch.mjs";

test("exact HTTPS provider hosts enable the toolbar",()=>{
  for (const host of ["github.com","gitlab.com","codeberg.org","bitbucket.org"]) assert.equal(supportedSourceUrl(`https://${host}/team/project/tree/main`),true);
  for (const value of ["garbage","http://github.com/a/b","https://github.com.evil.test/a/b","https://gitlab.example.com/a/b","https://user:password@github.com/a/b","https://@github.com/a/b","https://github.com:8443/a/b","file:///tmp/repository"]) assert.equal(supportedSourceUrl(value),false,value);
});

test("server configuration is mandatory and limited to origins",()=>{
  assert.equal(normalizeServerUrl(" https://overalls.example.test "),"https://overalls.example.test/");
  for (const host of ["localhost","127.0.0.1","[::1]"]) assert.equal(normalizeServerUrl(`http://${host}:4000`),`http://${host}:4000/`);
  for (const value of ["","http://overalls.example.test","https://user:secret@overalls.example.test","https://overalls.example.test/?token=value","https://overalls.example.test/#source","https://overalls.example.test/path"]) assert.throws(()=>normalizeServerUrl(value));
});

test("a launch preserves provider paths and removes URL-borne secrets before transmission",()=>{
  for (const host of ["github.com","gitlab.com","codeberg.org","bitbucket.org"]) {
    const source=`https://${host}/team/project/pull/7/files?access_token=query-secret#token=fragment-secret`;
    const launch=overallsLaunchUrl("https://overalls.example.test/",source);
    assert.equal(launch,`https://overalls.example.test/launch/entry#https://${host}/team/project/pull/7/files`);
    assert.equal(launch.includes("secret"),false);
  }
  assert.throws(()=>overallsLaunchUrl("https://overalls.example.test/","https://example.com/a/b"));
  assert.throws(()=>overallsLaunchUrl("https://overalls.example.test/","https://user:password@github.com/a/b"));
  assert.throws(()=>overallsLaunchUrl("https://overalls.example.test/","https://@github.com/a/b"));
  for (const source of ["https://github.com:443/a/b", "https://github.com/a/../b"]) {
    assert.equal(overallsLaunchUrl("https://overalls.example.test/",source+"?token=secret"),`https://overalls.example.test/launch/entry#${source}`);
  }
});
