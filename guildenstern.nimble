version       = "4.0.0"
author        = "Olli"
description   = "Modular multithreading Linux HTTP server"
license       = "MIT"
srcDir        = "src"

skipDirs = @[".github", "e2e-tests"]

requires "nim >= 1.4.8"

task test, "run all tests":
  cd("tests")
  exec "nim c -r --threads:on --d:threadsafe test_ctxheader.nim"
  exec "nim c --d:danger test_wrk.nim"
  exec "./test_wrk &"
  exec "sleep 1"
  let outStr = gorge(getCurrentDir() & "/wrkbin -t8 -c8 -d10s --latency http://127.0.0.1:5050")
  echo outStr
  if outStr.contains("Socket errors") and not outStr.contains("read 0, write 0, timeout 0"): quit(-1)