# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, os, osproc, strutils],
  unittest2

const testData = "tools/test_runner/testdata"

proc buildtest(args: string): tuple[results: seq[JsonNode], exitCode: int] =
  ## The results `test_runner buildtest` prints for `args`, and its exit status.
  let (output, exitCode) = execCmdEx("build" / "test_runner" & " buildtest " & args)
  for line in output.splitLines():
    if line.startsWith("["):
      return (parseJson(line).getElems(), exitCode)
  (newSeq[JsonNode](), exitCode)

suite "test_runner":
  # The runner rebuilds the fixture's JSON access list to compare it with the
  # header and drops it on a mismatch, after which the block still passes. Only
  # the executor it reports shows whether the list was delivered.
  test "blocktest delivers a valid fixture's access list to the parallel executor":
    let (output, exitCode) = execCmdEx(
      "build" / "test_runner" & " blocktest --bal-report " & testData / "blocktest_bal.json"
    )
    var events: seq[JsonNode]
    for line in output.splitLines():
      if line.startsWith("{\"event\""):
        events.add parseJson(line)
    check:
      exitCode == QuitSuccess
      events.len == 1
    if events.len == 1:
      check:
        events[0]["path"].getStr() == "parallel"
        events[0]["reason"].getStr() == ""

  test "buildtest builds valid payloads as the fixtures have them":
    # A Paris payload, a Shanghai one with a withdrawal, an Amsterdam one with
    # its access list, and a Cancun blob transaction without its blobs, as
    # payloads carry it. Before Cancun the built payload has fields the
    # fixture's lacks, which are not compared.
    let (results, exitCode) = buildtest(
      testData / "buildtest_paris.json" & " " & testData / "buildtest_shanghai.json" & " " &
        testData / "buildtest_bal.json" & " " & testData / "buildtest_blob.json")
    check:
      exitCode == QuitSuccess
      results.len == 4
    for r in results:
      check:
        r["pass"].getBool
        r["built"].getInt == 1
        r["mismatches"].len == 0
        r["rejections"].len == 0

  test "buildtest neither builds nor imports a payload expected to be invalid":
    let (results, exitCode) = buildtest(testData / "buildtest_invalid.json")
    check:
      exitCode == QuitSuccess
      results.len == 1
    if results.len == 1:
      check:
        results[0]["pass"].getBool
        results[0]["built"].getInt == 0
        results[0]["rejections"].len == 0

  test "buildtest reports a payload built differently from the fixture's":
    # Nimbus builds this extra data into the block, which then hashes to another
    # block than the fixture names.
    let fixtures = parseFile(testData / "buildtest_bal.json")
    var blockHash = ""
    for name, fixture in fixtures:
      let payload = fixture["engineNewPayloads"][0]["params"][0]
      blockHash = payload["blockHash"].getStr
      payload["extraData"] = %"0x01"
    let path = getTempDir() / ("buildtest_mismatch_" & $getCurrentProcessId() & ".json")
    writeFile(path, $fixtures)
    let (results, exitCode) = buildtest(path)
    removeFile(path)
    check:
      exitCode == 1
      results.len == 1
    if results.len == 1:
      let mismatches = results[0]["mismatches"]
      check:
        not results[0]["pass"].getBool
        results[0]["built"].getInt == 1
        mismatches.len == 1
      if mismatches.len == 1:
        check:
          mismatches[0]["index"].getInt == 0
          mismatches[0]["field"].getStr == "blockHash"
          mismatches[0]["expected"].getStr == blockHash

  test "buildtest takes none of the BAL flags":
    for flag in ["--bal-sequential", "--bal-report", "--bal-withhold"]:
      let (_, exitCode) = buildtest(flag & " " & testData / "buildtest_bal.json")
      check exitCode == 2
