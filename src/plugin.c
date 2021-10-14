/*
 * Copyright 2010-2021, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "module.h"
#include <stdlib.h>
#include <assert.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

enum {
	CFG_URI_OPTION_HOST = 0,
	CFG_URI_OPTION_TRANSPORT = 1,
	CFG_URI_OPTION_MAX
};

struct cfg_uri_option {
	const char **values;
	int size;
};

struct cfg_uri {
	const char *host;
	struct cfg_uri_option transport;
};

struct cfg_uri_array {
	struct cfg_uri *uris;
	int size;
};

static void
cfg_uri_get_option(struct lua_State *L, const char *name,
		   struct cfg_uri_option *uri_option)
{
	if (lua_isnil(L, -1))
		return;
	assert(lua_istable(L, -1));
	uri_option->size = lua_objlen(L, -1);
	if (uri_option->size == 0)
		return;
	uri_option->values =
		(const char **)xcalloc(uri_option->size, sizeof(char *));
	for (int i = 0; i < uri_option->size; i++) {
		lua_rawgeti(L, -1, i + 1);
		uri_option->values[i] = lua_tostring(L, -1);
		lua_pop(L, 1);
	}
}

static void
cfg_uri_destroy(struct cfg_uri *uri)
{
	free(uri->transport.values);
}

static void
cfg_uri_init(struct cfg_uri *uri)
{
	memset(uri, 0, sizeof(struct cfg_uri));
}

static void
cfg_uri_get(struct lua_State *L, const char *name,
	    struct cfg_uri *uri, int idx)
{
	const char *cfg_uri_options[CFG_URI_OPTION_MAX] = {
		/* CFG_URI_OPTION_HOST */      "uri",
		/* CFG_URI_OPTION_TRANSPORT */ "transport",
	};
	for (unsigned i = 0; i < lengthof(cfg_uri_options); i++) {
		lua_rawgeti(L, -1, idx + 1);
		lua_pushstring(L, cfg_uri_options[i]);
		lua_gettable(L, -2);
		switch (i) {
		case CFG_URI_OPTION_HOST:
			assert(lua_isstring(L, -1));
			uri->host = lua_tostring(L, -1);
			break;
		case CFG_URI_OPTION_TRANSPORT:
			cfg_uri_get_option(L, name, &uri->transport);
			break;
		default:
			unreachable();
		}
		lua_pop(L, 2);
	}
}

static void
cfg_uri_array_delete(struct cfg_uri_array *uri_array)
{
	for (int i = 0; i < uri_array->size; i++)
		cfg_uri_destroy(&uri_array->uris[i]);
	free(uri_array->uris);
	free(uri_array);
}

static struct cfg_uri_array *
cfg_uri_array_new(struct lua_State *L, const char *option_name)
{
	struct cfg_uri_array *uri_array =
		xcalloc(1, sizeof(struct cfg_uri_array));
	if (cfg_get_uri_array(L, option_name))
		goto fail;
	if (lua_isnil(L, -1))
		goto finish;
	assert(lua_istable(L, -1));
	int size = lua_objlen(L, -1);
	assert(size > 0);
	uri_array->uris =
		(struct cfg_uri *)xcalloc(size, sizeof(struct cfg_uri));
	for (uri_array->size = 0; uri_array->size < size; uri_array->size++) {
		int i = uri_array->size;
		cfg_uri_init(&uri_array->uris[i]);
		cfg_uri_get(L, option_name, &uri_array->uris[i], i);
	}
finish:
	lua_pop(L, 1);
	return uri_array;
fail:
	cfg_uri_array_delete(uri_array);
	return NULL;
}

static int
cfg_uri_array_size(const struct cfg_uri_array *uri_array)
{
	return uri_array->size;
}

static const char *
cfg_uri_array_get_uri(const struct cfg_uri_array *uri_array, int idx)
{
	assert(idx < uri_array->size);
	return uri_array->uris[idx].host;
}

static int
cfg_uri_array_check_uri(const struct cfg_uri_array *uri_array,
			int (*check_uri)(const char *, const char *),
			const char *option_name)
{
	for (int i = 0; i < uri_array->size; i++) {
		if (check_uri(uri_array->uris[i].host, option_name) != 0)
			return -1;
	}
	return 0;
}

static struct cfg_uri_array_vtab multilisten_cfg_uri_array_vtab = {
	/* .cfg_uri_array_new = */ cfg_uri_array_new,
	/* .cfg_uri_array_delete = */ cfg_uri_array_delete,
	/* .cfg_uri_array_size = */ cfg_uri_array_size,
	/* .cfg_uri_array_get_uri = */ cfg_uri_array_get_uri,
	/* .cfg_uri_array_check_uri = */ cfg_uri_array_check_uri,
};

extern char normalize_uri_lua[];

static const char *lua_sources[] = {
	"normalize_uri", normalize_uri_lua,
};

LUA_API int
luaopen_multilisten(lua_State *L)
{
	for (const char **s = lua_sources; *s; s += 2) {
		const char *modname = *s;
		const char *modsrc = *(s + 1);
		const char *modfile = lua_pushfstring(L,
			"%s.lua", modname);
		int rc = 0;
		if (luaL_loadbuffer(L, modsrc, strlen(modsrc), modfile) != 0 ||
		    lua_pcall(L, 0, 0, 0) != 0)
			rc = -1;
		lua_pop(L, 1); /* modfile */
		if (rc != 0)
			return rc;
	}
	cfg_uri_array_register(&multilisten_cfg_uri_array_vtab);
	return 0;
}
