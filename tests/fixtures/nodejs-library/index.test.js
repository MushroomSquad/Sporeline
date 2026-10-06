const { test } = require("node:test");
const assert = require("node:assert/strict");
const { ping } = require(".");

test("ping", () => {
  assert.equal(ping(), "pong");
});
