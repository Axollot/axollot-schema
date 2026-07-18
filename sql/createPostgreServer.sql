CREATE TABLE users (
                       uuid            UUID PRIMARY KEY,                -- UUIDv7, генерируется на сервере
                       email           TEXT NOT NULL UNIQUE,
                       login           TEXT NOT NULL UNIQUE,
                       username        TEXT NOT NULL UNIQUE,             -- public_username
                       pass            TEXT NOT NULL,                    -- Argon2 хэш (соль внутри)
                       last_online     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                       avatar_link     TEXT,
                       created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Гильдии (серверы)
CREATE TABLE guilds (
                        id              UUID PRIMARY KEY,                -- UUIDv7
                        name            TEXT NOT NULL,
                        description     TEXT NOT NULL DEFAULT '',
                        icon_url        TEXT,
                        owner_id        UUID NOT NULL REFERENCES users(uuid),
                        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Каналы: и гильдовые и DM в одной таблице
-- type: 0 = text, 1 = voice, 2 = dm
CREATE TABLE channels (
                          id              UUID PRIMARY KEY,                -- UUIDv7
                          guild_id        UUID REFERENCES guilds(id) ON DELETE CASCADE,  -- NULL для DM
                          parent_id       UUID REFERENCES channels(id) ON DELETE CASCADE,
                          name            TEXT,                            -- NULL для DM
                          type            SMALLINT NOT NULL DEFAULT 0,
                          position        INT NOT NULL DEFAULT 0,
                          created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Участники канала
-- Для DM — 2 записи, для гильдовых каналов — опционально
-- (можно управлять доступом через роли)
CREATE TABLE channel_members (
                                 channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
                                 user_id         UUID NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
                                 joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                 PRIMARY KEY (channel_id, user_id)
);

-- Участники гильдии
CREATE TABLE guild_members (
                               guild_id        UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
                               user_id         UUID NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
                               role_id         UUID,                            -- NULL = обычный участник
                               joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                               PRIMARY KEY (guild_id, user_id)
);

-- Роли
CREATE TABLE roles (
                       id              UUID PRIMARY KEY,
                       guild_id        UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
                       name            TEXT NOT NULL,
                       color           INT,                             -- hex цвет
                       permissions     BIGINT NOT NULL DEFAULT 0,       -- битовая маска прав
                       position        INT NOT NULL DEFAULT 0,          -- приоритет роли
                       created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Сообщения — одна таблица для всех каналов
CREATE TABLE messages (
                          id              UUID PRIMARY KEY,                -- UUIDv7 (сортируется по времени)
                          channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
                          sender_id       UUID NOT NULL REFERENCES users(uuid),
                          text            TEXT NOT NULL,
                          reply_to_msg_id UUID,
                          created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                          edited_at       TIMESTAMPTZ
);

-- Друзья
-- status: 'pending', 'accepted', 'blocked'
CREATE TABLE friends (
                         user_id         UUID NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
                         friend_id       UUID NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
                         status          TEXT NOT NULL DEFAULT 'pending',
                         created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                         PRIMARY KEY (user_id, friend_id)
);

-- Инвайты в гильдии
CREATE TABLE guild_invites (
    id              UUID PRIMARY KEY,
    code            TEXT UNIQUE NOT NULL,
    guild_id        UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    created_by      UUID NOT NULL REFERENCES users(uuid),
    max_uses        INT,
    uses            INT NOT NULL DEFAULT 0,
    expires_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE fcm_tokens (
    user_id UUID NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
    token TEXT NOT NULL,
    platform SMALLINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, token)
);

-- Быстрая загрузка истории: последние сообщения канала
CREATE INDEX idx_messages_channel_time ON messages (channel_id, created_at DESC);

-- Поиск каналов юзера (для списка DM)
CREATE INDEX idx_channel_members_user ON channel_members (user_id);

-- Поиск гильдий юзера
CREATE INDEX idx_guild_members_user ON guild_members (user_id);

-- Каналы гильдии
CREATE INDEX idx_channels_guild ON channels (guild_id) WHERE guild_id IS NOT NULL;

-- Роли гильдии
CREATE INDEX idx_roles_guild ON roles (guild_id);

-- Друзья юзера
CREATE INDEX idx_friends_user ON friends (friend_id, status);

-- Инвайты гильдии
CREATE INDEX idx_guild_invites_guild ON guild_invites (guild_id);

CREATE INDEX idx_channels_parent ON channels (parent_id) WHERE parent_id IS NOT NULL;