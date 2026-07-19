## Unit tests for ocdev
import std/[os, strutils]
import unittest
import ../src/container
import ../src/ports
import ../src/config
import ../src/commands

suite "Container name validation":
  test "accepts valid names":
    check validateName("myproject").valid == true
    check validateName("my-project").valid == true
    check validateName("Project123").valid == true
    check validateName("a").valid == true
    check validateName("A").valid == true
    check validateName("test-container-1").valid == true

  test "rejects empty name":
    check validateName("").valid == false
    check validateName("").msg == "Name cannot be empty"

  test "rejects names starting with non-letter":
    check validateName("-invalid").valid == false
    check validateName("123start").valid == false
    check validateName("0test").valid == false

  test "rejects names with invalid characters":
    check validateName("has space").valid == false
    check validateName("has_underscore").valid == false
    check validateName("has.dot").valid == false
    check validateName("has@at").valid == false

  test "rejects names that are too long":
    let longName = "a".repeat(51)
    check validateName(longName).valid == false
    check "too long" in validateName(longName).msg

  test "accepts max length name":
    let maxName = "a".repeat(50)
    check validateName(maxName).valid == true

suite "Port calculation":
  test "service port base calculation":
    check getServicePortBase(2200) == 2300
    check getServicePortBase(2210) == 2310
    check getServicePortBase(2220) == 2320
    check getServicePortBase(2250) == 2350

  test "service port base uses correct offset":
    # SSH port 2200 + offset 0 -> service base 2300 + offset 0
    # SSH port 2210 + offset 10 -> service base 2300 + offset 10
    for i in 0..10:
      let sshPort = SshPortStart + (i * PortsPerVm)
      let expectedServiceBase = ServicePortStart + (i * PortsPerVm)
      check getServicePortBase(sshPort) == expectedServiceBase

  test "port blocks reserve ssh and service ranges":
    check isPortBlockAvailable(2200, @[2200]) == false
    check isPortBlockAvailable(2300, @[2200]) == false
    check isPortBlockAvailable(2309, @[2200]) == false
    check isPortBlockAvailable(2200, @[2300]) == false

  test "port blocks skip existing service bands":
    var allocated: seq[int] = @[]
    for i in 0..9:
      allocated.add(SshPortStart + (i * PortsPerVm))
    check isPortBlockAvailable(2300, allocated) == false
    check isPortBlockAvailable(2390, allocated) == false
    check isPortBlockAvailable(2400, allocated) == true

suite "Herdr isolation paths":
  test "builds per-instance path from the full Incus name":
    check getHerdrDir("/home/test-user", "ocdev-my-project") ==
      "/home/test-user/.local/share/ocdev/herdr/ocdev-my-project"

  test "preserves spaces in the host home path":
    check getHerdrDir("/home/test user", "ocdev-project") ==
      "/home/test user/.local/share/ocdev/herdr/ocdev-project"

  test "central host device list includes isolated Herdr mount":
    check HerdrDeviceName in HostDiskDeviceNames
    check HerdrDeviceName == "host-herdr"
    check HerdrContainerPath == "/home/dev/.config/herdr"

  test "uses private directory permissions":
    check HerdrDirectoryPermissions == {fpUserRead, fpUserWrite, fpUserExec}

  test "accepts only the exact expected Herdr device definition":
    let expectedSource = "/home/test/.local/share/ocdev/herdr/ocdev-project"
    check herdrDeviceMatches("disk", expectedSource, HerdrContainerPath, expectedSource)
    check not herdrDeviceMatches("proxy", expectedSource, HerdrContainerPath, expectedSource)
    check not herdrDeviceMatches("disk", "/home/other/herdr", HerdrContainerPath, expectedSource)
    check not herdrDeviceMatches("disk", expectedSource, "/home/dev/.config/other", expectedSource)

suite "Export state handling":
  test "parses running and stopped Incus states":
    check parseInstanceRunningState("Name: ocdev-test\nStatus: RUNNING\n") == (true, true)
    check parseInstanceRunningState("Name: ocdev-test\nStatus: STOPPED\n") == (true, false)

  test "does not assume stopped when status is missing":
    check parseInstanceRunningState("Name: ocdev-test\n") == (false, false)

  test "restarts only after complete device restoration":
    check mayRestartAfterExport(true, 0)
    check not mayRestartAfterExport(true, 1)
    check not mayRestartAfterExport(false, 0)

suite "Failed-create cleanup":
  test "removes Herdr state after successful deletion":
    check mayRemoveHerdrAfterCleanup(0, 0, "")

  test "removes Herdr state when Incus confirms absence":
    check mayRemoveHerdrAfterCleanup(1, 1, "Error: Instance not found")

  test "preserves Herdr state when instance remains or inspection is inconclusive":
    check not mayRemoveHerdrAfterCleanup(1, 0, "Name: ocdev-test")
    check not mayRemoveHerdrAfterCleanup(1, 1, "Error: connection refused")

suite "Constants":
  test "exit codes have correct values":
    check ord(ecSuccess) == 0
    check ord(ecError) == 1
    check ord(ecPrereq) == 2
    check ord(ecNotFound) == 3
    check ord(ecNotRunning) == 4

  test "port configuration is correct":
    check SshPortStart == 2200
    check ServicePortStart == 2300
    check PortsPerVm == 10
    check ServicePortsCount == 10

suite "Port argument parsing":
  test "single port sets both container and host port":
    let result = parsePortArg("8080")
    check result.valid == true
    check result.containerPort == 8080
    check result.hostPort == 8080

  test "colon-separated sets container and host ports":
    let result = parsePortArg("3000:8080")
    check result.valid == true
    check result.containerPort == 3000
    check result.hostPort == 8080

  test "rejects non-numeric port":
    check parsePortArg("abc").valid == false
    check parsePortArg("abc:def").valid == false

  test "rejects zero port":
    check parsePortArg("0").valid == false

  test "rejects port out of range":
    check parsePortArg("65536").valid == false
    check parsePortArg("99999").valid == false

  test "rejects container port out of range":
    check parsePortArg("65536:80").valid == false
    check parsePortArg("0:80").valid == false

  test "rejects host port out of range":
    check parsePortArg("80:65536").valid == false
    check parsePortArg("80:0").valid == false

  test "rejects malformed colon format":
    check parsePortArg("80:90:100").valid == false

  test "accepts boundary ports":
    let low = parsePortArg("1")
    check low.valid == true
    check low.containerPort == 1
    let high = parsePortArg("65535")
    check high.valid == true
    check high.containerPort == 65535

  test "accepts boundary ports with colon format":
    let result = parsePortArg("1:65535")
    check result.valid == true
    check result.containerPort == 1
    check result.hostPort == 65535


suite "Clone source parsing":
  test "parses live container source":
    let result = parseCloneSource("existing-env")
    check result.valid == true
    check result.source.kind == cskContainer
    check result.source.container == "existing-env"
    check result.source.snapshot == ""

  test "parses snapshot source":
    let result = parseCloneSource("existing-env/snap0")
    check result.valid == true
    check result.source.kind == cskSnapshot
    check result.source.container == "existing-env"
    check result.source.snapshot == "snap0"

  test "rejects malformed clone sources":
    for value in @["", "/snapshot", "container/", "container/snapshot/extra"]:
      let result = parseCloneSource(value)
      check result.valid == false
      check result.errMsg == "Invalid clone source. Use: container or container/snapshot"

  test "rejects invalid source container names":
    let result = parseCloneSource("123bad")
    check result.valid == false
    check result.errMsg == "Invalid source container name: Name must start with a letter"

  test "treats live and snapshot sources differently":
    let liveSource = parseCloneSource("existing-env")
    let snapshotSource = parseCloneSource("existing-env/snap0")
    check liveSource.source.kind != snapshotSource.source.kind