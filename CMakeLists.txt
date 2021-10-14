cmake_minimum_required(VERSION 2.8)

project(tarantool-plugin C CXX)

find_program(GIT git)
find_program(ECHO echo)

#
# Set default build type to Debug. This is to ease a developer's
# life. Release binaries are built by BuildBot automatically anyway.
#
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING
        "Choose the type of build, options are: None Debug Release RelWithDebInfo MinSizeRel."
        FORCE)
endif()

#
# Check submodules
#
function(update_submodules)
    message(STATUS "Updating submodules")
    execute_process(COMMAND ${GIT} submodule update --init --recursive
                    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
endfunction()
if(NOT EXISTS ${CMAKE_SOURCE_DIR}/third_party/luajit/CMakeLists.txt)
    if (EXISTS "${CMAKE_SOURCE_DIR}/.git" AND GIT)
        update_submodules()
    else()
        message(FATAL_ERROR "Failed to find submodules")
    endif()
endif()

#
# LuaJIT
#
# Patched.
#
set(ENABLE_BUNDLED_LUAJIT ON)
set(LUAJIT_ENABLE_GC64_DEFAULT OFF)
if (TARGET_OS_DARWIN)
    # LuaJIT is unusable on OS X without enabled GC64
    # See https://github.com/tarantool/tarantool/issues/2643
    set(LUAJIT_ENABLE_GC64_DEFAULT ON)
endif()
option(LUAJIT_ENABLE_GC64 "Use 64-bit GC objects by default."
       ${LUAJIT_ENABLE_GC64_DEFAULT})
add_subdirectory(third_party)

include(cmake/utils.cmake)
set(lua_sources)
lua_source(lua_sources src/lua/normalize_uri.lua)
add_custom_target(generate_lua_sources
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/lua
    DEPENDS ${lua_sources})
set_property(DIRECTORY PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${lua_sources})

add_library(multilisten SHARED src/plugin.c ${lua_sources})
set_target_properties(multilisten PROPERTIES PREFIX "")
if(TARGET_OS_DARWIN)
    set_target_properties(multilisten PROPERTIES LINK_FLAGS "-undefined dynamic_lookup")
endif(TARGET_OS_DARWIN)

add_dependencies(multilisten generate_lua_sources)
