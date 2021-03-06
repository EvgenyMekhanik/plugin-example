env = require('test_run')
net_box = require('net.box')
fio = require('fio')
fiber = require('fiber')
test_run = env.new()
test_run:cmd("create server test with script=\
              'box/several-listening-sockets.lua'")

test_run:cmd("setopt delimiter ';'")
function require_multilisten()
    test_run:eval('test', 'require(\'multilisten\')')
end
function check_connection_for_single_uri(uri)
    local conn = net_box.new(uri)
    if not conn then
        return false
    end
    local rc = conn:ping()
    conn:close()
    return rc
end;
function prepare_several_listen_uri(default_server_addr, listen_sockets_count)
    local listen = ""
    local ascii_A = 97
    for i = 1, listen_sockets_count do
        local ascii_code = ascii_A + i - 1
        local listen_addr =
            default_server_addr .. string.upper(string.char(ascii_code))
        listen = listen .. listen_addr
        if i ~= listen_sockets_count then
            listen = listen .. ", "
        end
    end
    return listen
end;
function check_connection_for_several_uris()
    local uris_table = {}
    local uris_with_options_table =
        test_run:eval('test', 'return box.internal.cfg_get_listen(box.cfg.listen)')[1]
    for _, uri_with_option_table in pairs(uris_with_options_table) do
        local uri = uri_with_option_table["uri"]
        if not check_connection_for_single_uri(uri) then
            return false
        end
        table.insert(uris_table, uri)
    end
    return uris_table
end;
function check_graceful_unix_socket_path_unlink(uris_table)
    test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }",
                   default_server_addr))
    local server_addresses_str =
        test_run:eval('test', "return box.cfg.listen")[1]
    assert(default_server_addr == server_addresses_str)
    for i = 1, #uris_table do
        if fio.path.exists(uris_table[i]) then
            return false
        end
    end
    return true
end
test_run:cmd("setopt delimiter ''");

test_run:cmd(string.format("start server test with args=\"%d\"", 1))
default_server_addr = test_run:eval('test', 'return box.cfg.listen')[1]
test_run:cmd("stop server test")

-- Checks that we able to open several listening sockets in several threads.
-- Checks that all unix socket path successfully deleted after after listening
-- is stop.
test_run:cmd("setopt delimiter ';'")
for thread_count = 1, 3 do
    for listen_count = 1, 2 do
        test_run:cmd(string.format("start server test with args=\"%d\"",
                     thread_count))
        require_multilisten()
        local addr =
            prepare_several_listen_uri(default_server_addr, listen_count)
        test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }",
                      addr))
        local uris_table = check_connection_for_several_uris()
        assert(uris_table)
        assert(check_graceful_unix_socket_path_unlink(uris_table))
        test_run:cmd("stop server test")
        assert(not fio.path.exists(default_server_addr))
    end
end
test_run:cmd("setopt delimiter ''");

test_run:cmd(string.format("start server test with args=\"%d\"", 5))
test_run:cmd("switch test")
require('multilisten')
test_run:cmd("setopt delimiter '$'")
function listen_with_valid_uri(idx)
    local default_server_addr = box.cfg.listen .. "A"
    local valid_uris = {
        default_server_addr,
        { string.format("%s", default_server_addr) },
        { string.format("%sA", default_server_addr),
          string.format("%sB", default_server_addr) },
        { uri = string.format("%s", default_server_addr) },
        {
            uri = string.format("%s", default_server_addr),
            transport = "plain"
        },
        {
            string.format("%sA", default_server_addr),
            {
                uri = string.format("%s", default_server_addr),
                transport = "plain"
            }
        },
        {
            {
                uri = string.format("%sA", default_server_addr),
                transport = "plain"
            },
            {
                uri= string.format("%sB", default_server_addr),
                transport = "plain"
            }
        },
        {
            {
                uri = string.format("%s", default_server_addr),
                transport = {'plain', 'plain'}
            }
        },
        default_server_addr .. "A, " .. default_server_addr .. "B",
        default_server_addr .. "A?transport=plain, " ..
        default_server_addr .. "B?transport=plain",
        default_server_addr .. "A?transport=plain," ..
        default_server_addr .. "B?transport=plain",
        default_server_addr .. "?transport=plain;plain&transport=plain;plain",
        default_server_addr .. "?transport=plain;plain;plain",
        {
            transport = {'plain', 'plain'},
            uri = string.format("%s", default_server_addr)
        },
        {
            {
                uri = string.format("%s", default_server_addr),
                transport = 'plain; plain'
            }
        },
        {
            {
                uri = string.format("%s", default_server_addr),
                transport = 'plain;plain;plain'
            }
        },
    }
    if valid_uris[idx] then
        box.cfg({ listen = valid_uris[idx] })
        return true
    end
end$
test_run:cmd("setopt delimiter ''")$
test_run:cmd("switch default")

-- Now tarantool accepts the table as a parameter of the listen option
-- Check this new ability.
test_run:cmd("setopt delimiter ';'")
idx = 1;
while true do
    local result =
        test_run:eval('test', string.format("return listen_with_valid_uri(%d)",
                      idx))[1]
    if not result then
        break
    end
    local uris_table = check_connection_for_several_uris()
    assert(uris_table)
    assert(check_graceful_unix_socket_path_unlink(uris_table))
    idx = idx + 1
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("stop server test")

test_run:cmd(string.format("start server test with args=\"%d\"", 5))
test_run:cmd("switch test")
require('multilisten')
test_run:cmd("setopt delimiter '$'")
function listen_with_invalid_uri(idx)
    local default_server_addr = box.cfg.listen .. "A"
    local bad_uri_key = {"uri"}
    local bad_uri = {}
    bad_uri[bad_uri_key] = default_server_addr
    local invalid_uries_with_corresponding_errors = {
        {
            {},
            "Incorrect value for option 'listen': " ..
            "URI table should not be empty"
        },
        {
            {""},
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            { uri = "", transport = "plain" },
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            { uri = function() end },
            "Incorrect value for option 'listen': " ..
            "URI should be one of types string, number"
        },
        {
            { "  " },
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            {
                { uri = string.format("%s", default_server_addr) },
                { uri = "  " }
            },
            "Incorrect value for option 'listen': " ..
            "expected host:service or /unix.socket"
        },
        {
            {
                { uri = string.format("%s", default_server_addr) },
                { uri = "?" }
            },
            "Incorrect value for option 'listen': " ..
            "expected host:service or /unix.socket"
        },
        {
            {
                uri = string.format("%s", default_server_addr),
                transport = "unexpected_value"
            },
            "Incorrect value for option 'listen': " ..
            "invalid option value 'unexpected_value' " ..
            "for URI 'transport' option"
        },
        {
            {
                default_server_addr,
                uri = string.format("%s", default_server_addr),
                transport = "plain"
            },
            "Incorrect value for option 'listen': " ..
            "invalid option name '1' for URI"
        },
        {
            default_server_addr .. "?transport=",
            "Incorrect value for option 'listen': " ..
            "invalid option value '' for URI 'transport' option"
        },
        {
            default_server_addr .. "?transport=plain&plain",
            "Incorrect value for option 'listen': " ..
            "not found value for URI 'plain' option"
        },
        {
            default_server_addr .. "?unexpected_option=unexpected_value",
            "Incorrect value for option 'listen': " ..
            "invalid option name 'unexpected_option' for URI"
        },
        {
            default_server_addr .. "?transport=plain,plain",
            "Incorrect value for option 'listen': " ..
            "expected host:service or /unix.socket"
        },
        {
            "?/transport=plain",
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            { transport="plain" },
            "Incorrect value for option 'listen': missing URI",
        },
        {
            {
                { uri = string.format("%s", default_server_addr) },
                { uri = "" }
            },
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            default_server_addr .. "?transport=plain=transport=plain",
            "Incorrect value for option 'listen': " ..
            "invalid option value 'plain=transport=plain' " ..
            "for URI 'transport' option",
        },
        {
            default_server_addr .. "?transport=plain?transport=plain",
            "Incorrect value for option 'listen': " ..
            "invalid option value 'plain?transport=plain' " ..
            "for URI 'transport' option"
        },
        {
            default_server_addr .. ", " .. default_server_addr,
            "Incorrect value for option 'listen': " ..
            "dublicate listen URI"
        },
        {
            default_server_addr .. ", " .. "?",
            "Incorrect value for option 'listen': " ..
            "missing URI options after '?'"
        },
        {
            default_server_addr .. ", " .. "?" .. default_server_addr,
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            default_server_addr .. ", " .. "?," .. default_server_addr,
            "Incorrect value for option 'listen': " ..
            "missing URI options after '?'"
        },
        {
            ",?/transport=plain",
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            ",&/transport=plain",
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            { uri = { default_server_addr } },
            "Incorrect value for option 'listen': " ..
            "URI should be one of types string, number"
        },
        {
            {
                unexpected_option = "unexpected_value",
                uri = default_server_addr
            },
            "Incorrect value for option 'listen': " ..
            "invalid option name 'unexpected_option' for URI"
        },
        {
            {
                uri = default_server_addr .. "?transport=plain",
                transport = { "plain, plain" }
            },
            "Incorrect value for option 'listen': " ..
            "invalid option value 'plain, plain' " ..
            "for URI 'transport' option"
        },
        {
            bad_uri,
            "Incorrect value for option 'listen': " ..
            "key in the URI table should be " ..
            "one of types string, number"
        },
        {
            "/???",
            "Incorrect value for option 'listen': " ..
            "not found value for URI '??' option"
        },
        {
            default_server_addr .. "?",
            "Incorrect value for option 'listen': " ..
            "missing URI options after '?'"
        },
        {
            default_server_addr .. " ",
           "Incorrect value for option 'listen': " ..
           "expected host:service or /unix.socket"
        },
        {
            default_server_addr .. "transport=plain" .. ", " ..
            default_server_addr .. "?, " .. default_server_addr .. "A",
            "Incorrect value for option 'listen': " ..
            "missing URI options after '?'"
        },
        {
            default_server_addr .. "A,,,,,, " .. default_server_addr .. "B",
            "Incorrect value for option 'listen': " ..
            "URI should not be empty"
        },
        {
            default_server_addr .. "??&&transport==plain;;; " ..
            "plain&&transport==plain;;;plain",
            "Incorrect value for option 'listen': " ..
            "not found value for URI '?' option"
        },
        {
            {
                uri = string.format("%s", default_server_addr),
                transport = 'plain;;; plain'
            },
            "Incorrect value for option 'listen': " ..
            "invalid option value '' for URI 'transport' option"
        },
        {
            {
                { bad_uri },
                { uri = default_server_addr },
            },
            "Incorrect value for option 'listen': " ..
            "missing URI"
        },
        {
            { function() end },
            "Incorrect value for option 'listen': " ..
            "value in the URI table should be " ..
            "one of types string, number, table"
        },
        {
            function() end,
            "Incorrect value for option 'listen': " ..
            "should be one of types number, string, table"
        },
        {
            default_server_addr .. "?transport=plain;;;plain",
            "Incorrect value for option 'listen': " ..
            "invalid option value '' for URI 'transport' option"
        },
        {
            default_server_addr .. "??",
            "Incorrect value for option 'listen': " ..
            "not found value for URI '?' option"
        },
        {
            default_server_addr .. "??transport=plain",
            "Incorrect value for option 'listen': " ..
            "invalid option name '?transport' for URI"
        },
        {
            default_server_addr .. "?transport",
            "Incorrect value for option 'listen': " ..
            "not found value for URI 'transport' option"
        },
    }
    if invalid_uries_with_corresponding_errors[idx] then
        local rc, err = pcall(box.cfg, {
            listen = invalid_uries_with_corresponding_errors[idx][1]
        })
        local result = {
            rc, err, invalid_uries_with_corresponding_errors[idx][2]
        }
        return result
    end
end$
test_run:cmd("setopt delimiter ''")$
test_run:cmd("switch default")
-- Here we check incorrect listen options
-- err contains error message!
test_run:cmd("setopt delimiter ';'")
idx = 1;
while true do
    local result =
        test_run:eval('test',
                      string.format("return listen_with_invalid_uri(%d)",
                      idx))[1]
    if not result then
        break
    end
    local not_ok, err, expected_err = result[1], result[2], result[3]
    test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }",
                  default_server_addr))
    assert(not not_ok)
    assert(err == expected_err)
    idx = idx + 1
end;
test_run:cmd("setopt delimiter ''");
test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", ""))
assert(test_run:grep_log('test', "set 'listen' configuration option to null"))
test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }",\
              default_server_addr))
test_run:cmd("stop server test")

-- Special test case to check that all unix socket paths deleted
-- in case when `listen` fails because of invalid uri. Iproto performs
-- `bind` and `listen` operations sequentially to all uris from the list,
-- so we need to make sure that all resources for those uris for which
-- everything has already completed will be successfully cleared in case
-- of error for one of the next uri in list.
test_run:cmd(string.format("start server test with args=\"%d\"", 1))
test_run:cmd("switch test")
require('multilisten')
test_run:cmd("setopt delimiter ';'")
function listen_with_bad_uri()
    local default_server_addr = box.cfg.listen
    local baduri = {
        default_server_addr .. "A",
        default_server_addr .. "B", "baduri:1"
    }
    box.cfg({ listen = baduri })
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("switch default")
-- can't resolve uri for bind
not_ok, err =\
    pcall(test_run.eval, test_run, 'test', "return listen_with_bad_uri()")
assert(not not_ok)
assert(err)
assert(not fio.path.exists(default_server_addr .. "A"))
assert(not fio.path.exists(default_server_addr .. "B"))
test_run:cmd("stop server test")
test_run:cmd("cleanup server test")
test_run:cmd("delete server test")
