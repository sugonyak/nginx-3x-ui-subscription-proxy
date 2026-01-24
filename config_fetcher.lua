local http = require "resty.http"

-- Получаем список серверов из переменной окружения
local servers_str = os.getenv("SERVERS")
if not servers_str then
    ngx.log(ngx.ERR, "No servers found in environment variable")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Разделяем строку на таблицу серверов
local servers = {}
for server in string.gmatch(servers_str, "[^%s]+") do
    table.insert(servers, server)
end

local httpc = http.new()
local configs = {}

-- Переменные для агрегации статистики
local total_upload = 0
local total_download = 0
local total_quota = 0
local expire_time = 0
local profile_title = nil
local update_interval = nil

-- Запрашиваем конфигурацию с каждого сервера
for _, base_url in ipairs(servers) do
    local url = base_url .. ngx.var.sub_id
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,  -- Параметр для пропуска проверки SSL-сертификатов (если необходимо)
    })

    if res and res.status == 200 then
        -- Обрабатываем статистику
        local userinfo = res.headers["Subscription-Userinfo"]
        if userinfo then
            local upload = tonumber(string.match(userinfo, "upload=(%d+)"))
            local download = tonumber(string.match(userinfo, "download=(%d+)"))
            local total = tonumber(string.match(userinfo, "total=(%d+)"))
            local expire = tonumber(string.match(userinfo, "expire=(%d+)"))

            if upload then total_upload = total_upload + upload end
            if download then total_download = total_download + download end
            if total then
                total_quota = total_quota == 0 and total or math.min(total_quota, total)
            end
            if expire then
                -- expire=0 means unlimited, use earliest real expiration date
                local exp_num = tonumber(expire)
                expire_time = (exp_num > 0 and (expire_time == 0 or exp_num < expire_time)) and exp_num or expire_time
            end
        end

        if not profile_title and res.headers["Profile-Title"] then
            profile_title = res.headers["Profile-Title"]
        end

        if not update_interval and res.headers["Profile-Update-Interval"] then
            update_interval = res.headers["Profile-Update-Interval"]
        end

        local decoded_config = ngx.decode_base64(res.body)
        if decoded_config then
            table.insert(configs, decoded_config)
        else
            ngx.log(ngx.ERR, "Failed to decode base64 from ", url)
        end
    else
        ngx.log(ngx.ERR, "Error fetching from ", url, ": ", err or "unknown error")
    end
end

-- Возвращаем объединённые конфигурации клиенту
if #configs > 0 then
    -- Объединяем без добавления новой строки между конфигурациями
    local combined_configs = table.concat(configs)
    local encoded_combined_configs = ngx.encode_base64(combined_configs)

    -- Устанавливаем заголовки
    ngx.header.content_type = "text/plain; charset=utf-8"
    ngx.header.content_length = #encoded_combined_configs

    -- Устанавливаем агрегированные заголовки
    if profile_title then
        ngx.header["Profile-Title"] = profile_title
    end
    if update_interval then
        ngx.header["Profile-Update-Interval"] = update_interval
    end

    -- Устанавливаем агрегированную статистику
    if total_upload > 0 or total_download > 0 then
        ngx.header["Subscription-Userinfo"] = string.format(
            "upload=%d; download=%d; total=%d; expire=%d",
            total_upload,
            total_download,
            total_quota,
            expire_time
        )
    end

    ngx.print(encoded_combined_configs)
else
    ngx.status = ngx.HTTP_BAD_GATEWAY
    ngx.say("No configs available")
end
