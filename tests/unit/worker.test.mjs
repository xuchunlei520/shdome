import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import worker from "../../bootstrap/worker.js";

const validEnv = {
  SHDOME_RELEASE_VERSION: "v1.2.3",
  SHDOME_RELEASE_URL: "https://github.com/example/shdome/releases/download/v1.2.3/shdome-v1.2.3.tar.gz",
  SHDOME_RELEASE_SHA256: "a".repeat(64),
  SHDOME_INSTALLER_URL: `https://raw.githubusercontent.com/example/shdome/${"b".repeat(40)}/bootstrap/install.sh`,
};

const response = await worker.fetch(new Request("https://mytool.sh/"), validEnv);
assert.equal(response.status, 200);
assert.match(response.headers.get("content-type"), /^text\/plain/);
assert.equal(response.headers.get("cache-control"), "no-store");
const script = await response.text();
assert.match(script, /^#!\/usr\/bin\/env bash/);
assert.match(script, /exec "\$SCRIPT_PATH" "\$@"/);
assert.doesNotMatch(script, /<\/dev\/null/);
const syntax = spawnSync("bash", ["-n"], {input: script, encoding: "utf8"});
if (!syntax.error || syntax.error.code !== "ENOENT") {
  assert.equal(syntax.status, 0, syntax.stderr);
}

const invalidResponse = await worker.fetch(new Request("https://mytool.sh/"), {...validEnv, SHDOME_RELEASE_SHA256: "bad"});
assert.equal(invalidResponse.status, 503);
assert.match(await invalidResponse.text(), /^#!\/usr\/bin\/env bash/);

const notFound = await worker.fetch(new Request("https://mytool.sh/unknown"), validEnv);
assert.equal(notFound.status, 404);

const redirect = await worker.fetch(new Request("http://mytool.sh/"), validEnv);
assert.equal(redirect.status, 308);
assert.equal(redirect.headers.get("location"), "https://mytool.sh/");

console.log("worker tests passed");
