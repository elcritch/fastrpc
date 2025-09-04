switch("gc", "arc")
# switch("profiler", "on")
# switch("stacktrace", "on")
switch("define", "nimNetSocketExtras")
switch("define", "debug")
switch("threads", "on")
switch("nimcache", "nimcache")

switch("define", "McuUtilsLoggingLevel:lvlDebug")

import std/[os, strutils]

task build_integration_tests, "build integration test tools":
  exec "nim c tests/integration/fastrpcserverExample.nim"
  exec "nim c tests/integration/fastrpccli.nim"
  exec "nim c tests/integration/tcpechoserver.nim"
  exec "nim c tests/integration/udpechoserver.nim"
  exec "nim c tests/integration/combechoserver.nim"

task test, "test the integration tests":

  for dtest in listFiles("tests/"):
    if dtest.splitFile()[1].startsWith("t") and dtest.endsWith(".nim"):
      echo("\nTesting: " & $dtest)
      exec("nim c -r " & dtest)

  build_integration_testsTask()