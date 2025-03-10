local log = require('nvim-autopairs._log')
local utils = require('nvim-autopairs.utils')
local basic_rule = require('nvim-autopairs.rules.basic')
local api = vim.api

local M = {}

M.state = {
    disabled = false,
    rules = {},
    buf_ts = {},
}

local default = {
    map_bs = true,
    disable_filetype = { 'TelescopePrompt', 'spectre_panel' },
    ignored_next_char = string.gsub([[ [%w%%%'%[%"%.] ]], '%s+', ''),
    check_ts = false,
    enable_moveright = true,
    enable_afterquote = true,
    enable_check_bracket_line = true,
    ts_config = {
        lua = { 'string', 'source' },
        javascript = { 'string', 'template_string' },
    },
}

M.init = function()
    local ok = pcall(require, 'nvim-treesitter')
    if ok then
        require('nvim-treesitter').define_modules({
            autopairs = {
                module_path = 'nvim-autopairs.internal',
                is_supported = function()
                    return true
                end,
            },
        })
    end
end

M.setup = function(opt)
    M.config = vim.tbl_deep_extend('force', default, opt or {})
    if M.config.fast_wrap then
        require('nvim-autopairs.fastwrap').setup(M.config.fast_wrap)
    end
    M.config.rules = basic_rule.setup(M.config)

    if M.config.check_ts then
        local ok, ts_rule = pcall(require, 'nvim-autopairs.rules.ts_basic')
        if ok then
            M.config.rules = ts_rule.setup(M.config)
        else
            print('you need to install treesitter')
        end
    end

    M.force_attach()

    api.nvim_exec(
        [[
    augroup autopairs_buf
    autocmd!
    autocmd BufEnter * :lua require("nvim-autopairs").on_attach()
    autocmd FileType * :lua require("nvim-autopairs").force_attach()
    augroup end
        ]],
        false
    )
end

M.add_rule = function(rule)
    M.add_rules({ rule })
end

M.get_rule = function(start_pair)
    local tbl = {}
    for _, r in pairs(M.config.rules) do
        if r.start_pair == start_pair then
            table.insert(tbl, r)
        end
    end
    if #tbl == 1 then
        return tbl[1]
    end
    return tbl
end

M.remove_rule = function(pair)
    local tbl = {}
    for _, r in pairs(M.config.rules) do
        if r.start_pair ~= pair then
            table.insert(tbl, r)
        end
    end
    M.config.rules = tbl
    if M.state.rules then
        local state_tbl = {}
        for _, r in pairs(M.state.rules) do
            if r.start_pair ~= pair then
                table.insert(state_tbl, r)
            elseif r.key_map and r.key_map ~= '' then
                vim.api.nvim_buf_del_keymap(0, 'i', r.key_map)
            end
        end
        M.state.rules = state_tbl
    end
    M.force_attach()
end

M.add_rules = function(rules)
    for _, rule in pairs(rules) do
        table.insert(M.config.rules, rule)
    end
    M.force_attach()
end

M.clear_rules = function()
    M.state.rules = {}
    M.config.rules = {}
end

M.disable = function()
    M.state.disabled = true
end

M.enable = function()
    M.state.disabled = false
end

--- force remap key to buffer
M.force_attach = function(bufnr)
    utils.set_attach(bufnr, 0)
    M.on_attach(bufnr)
end

local function is_disable()
    if M.state.disabled then
        return true
    end
    if vim.bo.modifiable == false then
        return true
    end
    if utils.check_filetype(M.config.disable_filetype, vim.bo.filetype) then
        -- should have a way to remove the mapping when vim.bo.filetype = ''
        -- now we only remove a rule
        -- the event FileType happen after BufEnter
        M.state.rules = {}
        return true
    end
    return false
end

M.on_attach = function(bufnr)
    if is_disable() then
        return
    end
    bufnr = bufnr or api.nvim_get_current_buf()

    local rules = {}
    for _, rule in pairs(M.config.rules) do
        if utils.check_filetype(rule.filetypes, vim.bo.filetype) then
            table.insert(rules, rule)
        end
    end
    -- sort by length
    table.sort(rules, function(a, b)
        if a.start_pair == b.start_pair then
            if not b.key_map then
                return a.key_map and 1
            end
            if not a.key_map then
                return b.key_map and -1
            end
            return #a.key_map < #b.key_map
        end
        if #a.start_pair == #b.start_pair then
            return string.byte(a.start_pair) > string.byte(b.start_pair)
        end
        return #a.start_pair > #b.start_pair
    end)

    M.state.rules = rules

    if M.state.buf_ts[bufnr] == true then
        M.state.ts_node = M.config.ts_config[vim.bo.filetype]
    else
        M.state.ts_node = nil
    end

    if utils.is_attached(bufnr) then
        return
    end
    local enable_insert_auto = false
    for _, rule in pairs(M.state.rules) do
        if rule.key_map ~= nil then
            if rule.is_regex == false then
                if rule.key_map == '' then
                    rule.key_map = rule.start_pair:sub(#rule.start_pair)
                end
                local key = string.format('"%s"', rule.key_map)
                if rule.key_map == '"' then
                    key = [['"']]
                end
                local mapping = string.format('v:lua.MPairs.autopairs_map(%d,%s)', bufnr, key)
                api.nvim_buf_set_keymap(
                    bufnr,
                    'i',
                    rule.key_map,
                    mapping,
                    { expr = true, noremap = true }
                )

                local key_end = rule.end_pair:sub(1, 1)
                if #key_end == 1 and key_end ~= rule.key_map and rule.move_cond ~= nil then
                    mapping = string.format(
                        [[v:lua.MPairs.autopairs_map(%d, '%s')]],
                        bufnr,
                        key_end
                    )
                    vim.api.nvim_buf_set_keymap(
                        bufnr,
                        'i',
                        key_end,
                        mapping,
                        { expr = true, noremap = true }
                    )
                end
            else
                if rule.key_map ~= '' then
                    local mapping = string.format(
                        "v:lua.MPairs.autopairs_map(%d,'%s')",
                        bufnr,
                        rule.key_map
                    )
                    api.nvim_buf_set_keymap(
                        bufnr,
                        'i',
                        rule.key_map,
                        mapping,
                        { expr = true, noremap = true }
                    )
                elseif rule.is_endwise == false then
                    enable_insert_auto = true
                end
            end
        end
    end

    if enable_insert_auto then
        -- capture all key use it to trigger regex pairs
        -- it can make an issue with paste from register
        api.nvim_exec(
            string.format(
                [[
            augroup autopairs_insert_%d
                autocmd!
                autocmd InsertCharPre <buffer=%d> call luaeval("require('nvim-autopairs').autopairs_insert(%d, _A)", v:char)
            augroup end ]],
                bufnr,
                bufnr,
                bufnr
            ),
            false
        )
    end

    if M.config.fast_wrap and M.config.fast_wrap.map then
        api.nvim_buf_set_keymap(
            bufnr,
            'i',
            M.config.fast_wrap.map,
            "<esc>l<cmd>lua require('nvim-autopairs.fastwrap').show()<cr>",
            { noremap = true }
        )
    end

    if M.config.map_bs then
        api.nvim_buf_set_keymap(
            bufnr,
            'i',
            '<bs>',
            string.format('v:lua.MPairs.autopairs_bs(%d)', bufnr),
            { expr = true, noremap = true }
        )
    end
    api.nvim_buf_set_var(bufnr, 'nvim-autopairs', 1)
end

M.autopairs_bs = function(bufnr)
    if is_disable() then
        return utils.esc(utils.key.bs)
    end
    local line = utils.text_get_current_line(bufnr)
    local _, col = utils.get_cursor()
    for _, rule in pairs(M.state.rules) do
        if rule.start_pair then
            local prev_char, next_char = utils.text_cusor_line(
                line,
                col,
                #rule.start_pair,
                #rule.end_pair,
                rule.is_regex
            )
            if
                utils.is_equal(rule.start_pair, prev_char, rule.is_regex)
                and rule.end_pair == next_char
                and rule:can_del({
                    ts_node = M.state.ts_node,
                    bufnr = bufnr,
                    prev_char = prev_char,
                    next_char = next_char,
                    line = line,
                })
            then
                local input = ''
                for _ = 1, #rule.start_pair, 1 do
                    input = input .. utils.key.bs
                end
                for _ = 1, #rule.end_pair, 1 do
                    input = input .. utils.key.right .. utils.key.bs
                end
                return utils.esc('<c-g>U' .. input)
            end
        end
    end
    return utils.esc(utils.key.bs)
end

M.autopairs_map = function(bufnr, char)
    if is_disable() then
        return char
    end
    local line = utils.text_get_current_line(bufnr)
    local _, col = utils.get_cursor()
    local new_text = ''
    local add_char = 1
    for _, rule in pairs(M.state.rules) do
        if rule.start_pair then
            if rule.is_regex and rule.key_map and rule.key_map ~= '' then
                new_text = line:sub(1, col) .. line:sub(col + 1, #line)
                add_char = 0
            elseif rule.key_map and #rule.key_map > 1 then
                if utils.esc(rule.key_map) ~= char then
                    new_text = ''
                else
                    new_text = line:sub(1, col) .. line:sub(col + 1, #line)
                    add_char = 0
                end
            else
                new_text = line:sub(1, col) .. char .. line:sub(col + 1, #line)
                add_char = 1
            end

            -- log.debug("new_text:[" .. new_text .. "]")
            local prev_char, next_char = utils.text_cusor_line(
                new_text,
                col + add_char,
                #rule.start_pair,
                #rule.end_pair,
                rule.is_regex
            )
            local cond_opt = {
                ts_node = M.state.ts_node,
                text = new_text,
                rule = rule,
                bufnr = bufnr,
                col = col + 1,
                char = char,
                line = line,
                prev_char = prev_char,
                next_char = next_char,
            }
            -- log.debug("start_pair" .. rule.start_pair)
            -- log.debug('prev_char' .. prev_char)
            -- log.debug('next_char' .. next_char)
            if
                utils.is_equal(rule.end_pair, next_char, rule.is_regex)
                and rule:can_move(cond_opt)
            then
                local end_pair = rule:get_end_pair(cond_opt)
                return utils.esc(utils.repeat_key(utils.key.join_right, #end_pair))
            end

            if
                utils.is_equal(rule.start_pair, prev_char, rule.is_regex)
                and rule:can_pair(cond_opt)
            then
                local end_pair = rule:get_end_pair(cond_opt)
                local end_pair_length = rule:get_end_pair_length(end_pair)
                local move_text = utils.repeat_key(utils.key.join_left, end_pair_length)
                if add_char == 0 then
                    move_text = ''
                    char = ''
                end
                return utils.esc(char .. end_pair .. move_text)
            end
        end
    end
    return M.autopairs_afterquote(new_text, char)
end

M.autopairs_insert = function(bufnr, char)
    if is_disable() then
        return char
    end
    local line = utils.text_get_current_line(bufnr)
    local _, col = utils.get_cursor()
    local new_text = line:sub(1, col) .. char .. line:sub(col + 1, #line)
    for _, rule in pairs(M.state.rules) do
        if rule.start_pair and rule.is_regex and rule.key_map == '' then
            local prev_char, next_char = utils.text_cusor_line(
                new_text,
                col + 1,
                #rule.start_pair,
                #rule.end_pair,
                rule.is_regex
            )
            local cond_opt = {
                ts_node = M.state.ts_node,
                text = new_text,
                rule = rule,
                bufnr = bufnr,
                col = col + 1,
                char = char,
                line = line,
                prev_char = prev_char,
                next_char = next_char,
            }
            -- log.debug("start_pair" .. rule.start_pair)
            -- log.debug('prev_char' .. prev_char)
            -- log.debug('next_char' .. next_char)
            if next_char == rule.end_pair and rule:can_move(cond_opt) then
                utils.set_vchar('')
                vim.schedule(function()
                    utils.feed(utils.key.right, -1)
                end)
                return false
            end

            if
                utils.is_equal(rule.start_pair, prev_char, rule.is_regex)
                and rule:can_pair(cond_opt)
            then
                local end_pair = rule:get_end_pair(cond_opt)
                utils.set_vchar(char .. end_pair)
                vim.schedule(function()
                    utils.feed(utils.key.left, rule:get_end_pair_length(end_pair))
                end)
                return
            end
        end
    end
    return char
end

M.autopairs_cr = function(bufnr)
    if is_disable() then
        return utils.esc('<cr>')
    end
    bufnr = bufnr or api.nvim_get_current_buf()
    local line = utils.text_get_current_line(bufnr)
    local _, col = utils.get_cursor()
    -- log.debug("on_cr")
    for _, rule in pairs(M.state.rules) do
        if rule.start_pair then
            local prev_char, next_char = utils.text_cusor_line(
                line,
                col,
                #rule.start_pair,
                #rule.end_pair,
                rule.is_regex
            )
            -- log.debug('prev_char' .. rule.start_pair)
            -- log.debug('prev_char' .. prev_char)
            -- log.debug('next_char' .. next_char)
            if
                rule.is_endwise
                and utils.is_equal(rule.start_pair, prev_char, rule.is_regex)
                and rule:can_cr({
                    ts_node = M.state.ts_node,
                    check_endwise_ts = true,
                    bufnr = bufnr,
                    rule = rule,
                    col = col,
                    prev_char = prev_char,
                    next_char = next_char,
                    line = line,
                })
            then
                return utils.esc(
                    rule.end_pair
                        .. utils.repeat_key(utils.key.join_left, #rule.end_pair)
                        -- FIXME do i need to re indent twice #118
                        .. '<cr><esc>====O'
                )
            end
            if
                utils.is_equal(rule.start_pair, prev_char, rule.is_regex)
                and rule.end_pair == next_char
                and rule:can_cr({
                    ts_node = M.state.ts_node,
                    check_endwise_ts = false,
                    bufnr = bufnr,
                    rule = rule,
                    col = col,
                    prev_char = prev_char,
                    next_char = next_char,
                    line = line,
                })
            then
                log.debug('do_cr')
                return utils.esc('<cr><c-o>O')
            end
        end
    end
    return utils.esc('<cr>')
end

--- add bracket pairs after quote (|"aaaaa" => (|"aaaaaa")
M.autopairs_afterquote = function(line, key_char)
    if M.config.enable_afterquote then
        line = line or utils.text_get_current_line(0)
        local _, col = utils.get_cursor()
        local prev_char, next_char = utils.text_cusor_line(line, col + 1, 1, 1, false)
        if
            utils.is_bracket(prev_char)
            and utils.is_quote(next_char)
            and not utils.is_in_quote(line, col, next_char)
        then
            local count = 0
            local index = 0
            local is_prev_slash = false
            local char_end = ''
            for i = col, #line, 1 do
                local char = line:sub(i, i + #next_char - 1)
                if not is_prev_slash and char == next_char then
                    count = count + 1
                    char_end = line:sub(i + 1, i + #next_char)
                    index = i
                end
                is_prev_slash = char == '\\'
            end
            if count == 2 and index >= (#line - 2) then
                for _, rule in pairs(M.state.rules) do
                    if rule.start_pair == prev_char and char_end ~= rule.end_pair then
                        local new_text = line:sub(0, index)
                            .. rule.end_pair
                            .. line:sub(index + 1, #line)
                        M.state.expr_quote = new_text
                        local append = 'a'
                        if col > 0 then
                            append = 'la'
                        end
                        return utils.esc(
                            '<esc><cmd>lua MPairs.autopairs_closequote_expr()<cr>' .. append
                        )
                    end
                end
            end
        end
    end
    return utils.esc(key_char)
end

M.autopairs_closequote_expr = function()
    vim.fn.setline('.', M.state.expr_quote)
end

M.check_break_line_char = function()
    return M.autopairs_cr()
end

M.esc = utils.esc
_G.MPairs = M
return M
