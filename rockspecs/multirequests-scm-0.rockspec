package = "multirequests"
version = "scm-0"

source = {
  url = "https://github.com/moteus/lua-MultiRequests/archive/master.zip",
  dir = "lua-lluv-pg-master",
}

description = {
  summary    = "PostgreSQL client for lluv library",
  homepage   = "https://github.com/moteus/lua-lluv-pg",
  license    = "MIT/X11",
  maintainer = "Alexey Melnichuk",
  detailed   = [[
  ]],
}

dependencies = {
  "lua >= 5.1, < 5.4",
  "lua-curl >= 3.0",
}

build = {
  copy_directories = {'examples'},

  type = "builtin",

  modules = {
    [ 'MultiRequests'     ] = 'src/MultiRequests.lua',
  };
}
