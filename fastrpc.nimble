# Package

version       = "0.6.1"
author        = "Jaremy Creechley"
description   = "fast binary rpc designed for embedded"
license       = "Apache-2.0"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.14"
requires "stew >= 0.1.0"
requires "progress >= 0.1.0"
requires "msgpack4nim >= 0.3.1"
requires "threading >= 0.1.0"
requires "cligen >= 0.1.0"
requires "stack_strings"

feature "cbor":
  requires "https://github.com/elcritch/cborious.git >= 0.5.0"
