## Unit tests for ocdev
import std/strutils
import unittest
import ../src/container
import ../src/ports
import ../src/config

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
