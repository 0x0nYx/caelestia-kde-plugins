import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const names = [
  "parseList", "failure", "normalizeList", "listResult", "isToken", "parseUnlock",
  "isCode", "formatCode", "entryKey", "codeState", "refreshAt",
  "matchScore", "rankEntries", "errorHint"
]
const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = new Function(source + "\nreturn { " + names.join(", ") + " }")()

const TOKEN = "a".repeat(64)

test("isCode accepts 1-10 digits only", () => {
  assert.equal(M.isCode("123456"), true)
  assert.equal(M.isCode("1"), true)
  assert.equal(M.isCode("1234567890"), true)
  assert.equal(M.isCode(""), false)
  assert.equal(M.isCode("12345678901"), false)
  assert.equal(M.isCode("12 34"), false)
  assert.equal(M.isCode("12a456"), false)
  assert.equal(M.isCode(null), false)
})

test("formatCode groups 6 and 8 digit codes", () => {
  assert.equal(M.formatCode("123456"), "123 456")
  assert.equal(M.formatCode("12345678"), "1234 5678")
  assert.equal(M.formatCode("1234567"), "1234567")
  assert.equal(M.formatCode(" 123 456 "), "123 456")
  assert.equal(M.formatCode(null), "")
})

test("entryKey prefers id, falls back to label", () => {
  assert.equal(M.entryKey({ id: "x1", issuer: "A", account: "b" }), "id:x1")
  assert.equal(M.entryKey({ issuer: "A", account: "b" }), "label:A|b")
  assert.equal(M.entryKey({}), "label:|")
  assert.equal(M.entryKey(null), "")
})

test("codeState picks the code for the current period", () => {
  const entry = { period: 30, counter: 100, codes: ["111111", "222222", "333333"] }
  const t = 100 * 30 + 5
  assert.deepEqual(M.codeState(entry, t), { code: "111111", next: "222222", remaining: 25, period: 30, stale: false })
  const later = M.codeState(entry, 102 * 30)
  assert.equal(later.code, "333333")
  assert.equal(later.next, "")
})

test("codeState is stale outside the window", () => {
  const entry = { period: 30, counter: 100, codes: ["111111"] }
  assert.equal(M.codeState(entry, 101 * 30).stale, true)
  assert.equal(M.codeState(entry, 101 * 30).code, "")
  assert.equal(M.codeState(entry, 99 * 30).stale, true)
  assert.equal(M.codeState(null, 0).stale, true)
})

test("refreshAt is the earliest time any window runs out", () => {
  const entries = [
    { period: 30, counter: 100, codes: ["a", "b", "c"] },
    { period: 60, counter: 50, codes: ["a", "b"] }
  ]
  assert.equal(M.refreshAt(entries), Math.min((100 + 2) * 30, (50 + 1) * 60))
  assert.equal(M.refreshAt([]), Infinity)
  assert.equal(M.refreshAt([{ period: 30, counter: 1, codes: [] }]), Infinity)
})

test("matchScore ranks prefix > word > substring > account > fuzzy", () => {
  const e = { issuer: "Proton Mail", account: "me@example.com" }
  assert.equal(M.matchScore(e, ""), 0)
  assert.equal(M.matchScore(e, "pro"), 0)
  assert.equal(M.matchScore(e, "mail"), 1)
  assert.equal(M.matchScore(e, "oto"), 2)
  assert.equal(M.matchScore(e, "example"), 3)
  assert.equal(M.matchScore(e, "pml"), 4)
  assert.equal(M.matchScore(e, "zzz"), -1)
})

test("rankEntries filters, then pins, then alphabetical", () => {
  const entries = [
    { id: "1", issuer: "Zeta", account: "a" },
    { id: "2", issuer: "Alpha", account: "a" },
    { id: "3", issuer: "Mid", account: "a" }
  ]
  const order = (rows) => rows.map((r) => r.entry.id).join("")
  assert.equal(order(M.rankEntries(entries, "", {}, {}, "alpha")), "231")
  assert.equal(order(M.rankEntries(entries, "", { "id:1": true }, {}, "alpha")), "123")
  assert.equal(order(M.rankEntries(entries, "", {}, {}, "vault")), "123")
  assert.equal(order(M.rankEntries(entries, "", {}, { "id:3": 5, "id:2": 9 }, "recent")), "231")
  assert.equal(order(M.rankEntries(entries, "mid", {}, {}, "alpha")), "3")
  assert.equal(M.rankEntries(entries, "", { "id:1": true }, {}, "alpha")[0].pinned, true)
  assert.deepEqual(M.rankEntries(null, "", null, null, "alpha"), [])
})

test("parseList passes valid JSON through and repairs entries", () => {
  assert.deepEqual(M.parseList('{"ok":true,"entries":[{"id":"1"}]}'), { ok: true, entries: [{ id: "1" }] })
  assert.deepEqual(M.parseList('{"ok":true}').entries, [])
})

test("parseList reports invalid JSON", () => {
  for (const raw of ["", "nope", "null", "42", undefined]) {
    const r = M.parseList(raw)
    assert.equal(r.ok, false)
    assert.equal(r.error.code, "DECRYPT_FAILED")
    assert.deepEqual(r.entries, [])
  }
})

test("normalizeList always returns one complete shape", () => {
  assert.deepEqual(M.normalizeList(null), { ok: false, entries: [], error: null, warning: "", skipped: [] })
  assert.deepEqual(
    M.normalizeList({ ok: true, entries: [1], warning: "FALLBACK_KEY", skipped: ["x"], error: null }),
    { ok: true, entries: [1], error: null, warning: "FALLBACK_KEY", skipped: ["x"] }
  )
  assert.equal(M.normalizeList({ ok: "yes" }).ok, false)
  assert.deepEqual(M.normalizeList({ entries: "bad", skipped: "bad" }).entries, [])
  assert.deepEqual(M.normalizeList({ entries: "bad", skipped: "bad" }).skipped, [])
})

test("listResult maps timeouts, crashes and silent failures to distinct errors", () => {
  assert.equal(M.listResult("", 0, false, true).error.code, "HELPER_TIMEOUT")
  assert.equal(M.listResult('{"ok":true}', 0, false, true).error.code, "HELPER_TIMEOUT")
  assert.equal(M.listResult("", 139, true, false).error.code, "HELPER_CRASHED")
  const failed = M.listResult("  \n", 1, false, false)
  assert.equal(failed.error.code, "HELPER_FAILED")
  assert.match(failed.error.message, /code 1/)
  assert.equal(M.listResult("", 127, false, false).error.code, "HELPER_FAILED")
})

test("listResult keeps the helper's own error on a non-zero exit with output", () => {
  const raw = '{"ok":false,"entries":[],"error":{"code":"KEY_MISSING","message":"m"}}'
  const r = M.listResult(raw, 1, false, false)
  assert.equal(r.ok, false)
  assert.equal(r.error.code, "KEY_MISSING")
})

test("listResult returns entries on success", () => {
  const r = M.listResult('{"ok":true,"entries":[{"id":"a"}],"skipped":["b"]}', 0, false, false)
  assert.equal(r.ok, true)
  assert.equal(r.entries.length, 1)
  assert.deepEqual(r.skipped, ["b"])
})

test("listResult keeps invalid JSON on a clean exit as DECRYPT_FAILED", () => {
  assert.equal(M.listResult("garbage", 0, false, false).error.code, "DECRYPT_FAILED")
})

test("isToken wants exactly 64 lowercase hex chars", () => {
  assert.equal(M.isToken(TOKEN), true)
  assert.equal(M.isToken("0123456789abcdef".repeat(4)), true)
  assert.equal(M.isToken("a".repeat(63)), false)
  assert.equal(M.isToken("a".repeat(65)), false)
  assert.equal(M.isToken("A".repeat(64)), false)
  assert.equal(M.isToken("g".repeat(64)), false)
  assert.equal(M.isToken(""), false)
})

test("parseUnlock returns the token only for a valid unlocked reply", () => {
  const ok = M.parseUnlock(JSON.stringify({ ok: true, status: "unlocked", token: TOKEN, waitSec: 0 }))
  assert.deepEqual(ok, { ok: true, status: "unlocked", token: TOKEN, waitSec: 0 })
  const noToken = M.parseUnlock('{"ok":true,"status":"unlocked","token":"","waitSec":0}')
  assert.deepEqual(noToken, { ok: false, status: "error", token: "", waitSec: 0 })
  const shortToken = M.parseUnlock(JSON.stringify({ ok: true, status: "unlocked", token: "abc" }))
  assert.equal(shortToken.status, "error")
  const notOk = M.parseUnlock(JSON.stringify({ ok: false, status: "unlocked", token: TOKEN }))
  assert.equal(notOk.status, "error")
  assert.equal(notOk.token, "")
})

test("parseUnlock reads statuses and wait times", () => {
  assert.deepEqual(M.parseUnlock('{"ok":true,"status":"set","token":"","waitSec":0}'), { ok: true, status: "set", token: "", waitSec: 0 })
  assert.equal(M.parseUnlock('{"ok":true,"status":"unset"}').status, "unset")
  assert.equal(M.parseUnlock('{"ok":false,"status":"bad"}').status, "bad")
  assert.equal(M.parseUnlock('{"ok":true,"status":"reset"}').status, "reset")
  const wait = M.parseUnlock('{"ok":false,"status":"wait","waitSec":30}')
  assert.equal(wait.status, "wait")
  assert.equal(wait.waitSec, 30)
  assert.equal(M.parseUnlock('{"status":"wait","waitSec":-5}').waitSec, 0)
  assert.equal(M.parseUnlock('{"status":"wait","waitSec":"x"}').waitSec, 0)
})

test("parseUnlock rejects garbage and oversized output", () => {
  const bad = { ok: false, status: "error", token: "", waitSec: 0 }
  for (const raw of ["", "ok " + TOKEN, "null", "[]", "7", undefined]) {
    assert.deepEqual(M.parseUnlock(raw), bad)
  }
  assert.deepEqual(M.parseUnlock(JSON.stringify({ ok: true, status: "set", pad: "x".repeat(300) })), bad)
})

test("errorHint formats known codes and falls back to the message", () => {
  assert.equal(M.errorHint(null), "")
  assert.match(M.errorHint({ code: "KEY_MISSING", message: "no item" }), /^Vault key not in keyring.*KEY_MISSING: no item/)
  assert.match(M.errorHint({ code: "DEPS_MISSING", message: "DEPS_MISSING" }), /\(DEPS_MISSING\)$/)
  assert.equal(M.errorHint({ code: "WHAT", message: "plain" }), "plain")
})

test("errorHint knows the helper and state failures", () => {
  for (const code of ["HELPER_CRASHED", "HELPER_FAILED", "STATE_UNSAFE"])
    assert.match(M.errorHint({ code, message: "x" }), new RegExp(`\\(${code}: x\\)$`))
})

test("parseUnlock keeps a short message for unsafe state", () => {
  const r = M.parseUnlock('{"ok":false,"status":"unsafe","token":"","waitSec":0,"message":"bad dir"}')
  assert.equal(r.status, "unsafe")
  assert.equal(r.message, "bad dir")
})
