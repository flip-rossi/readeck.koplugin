return {
    data_dir = require("datastorage"):getDataDir() .. "/readeck", -- path string
    server_url = nil, -- string
    api_token = nil, -- string
    username = nil, -- string
    password = nil, -- string
    default_labels = { }, -- string list
    sync_pages = 1, -- int
    _cache_size = 1024 * 1024 * 10, -- 10 MB. Change only if you know what you're doing
}
