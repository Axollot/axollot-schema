-- ═══════════════════════════════════════════════════════════════════════
-- Axollot 1.0 — схема PostgreSQL для чистой установки.
--
-- Применяется один раз к пустой базе (PostgreSQL 13+):
--     psql -v ON_ERROR_STOP=1 -1 -d axollot -f createPostgreServer.sql
-- Только CREATE: никаких ALTER и миграций, повторный запуск на непустой
-- базе завершится ошибкой.
--
-- Правила внешних ключей:
--   * ON DELETE CASCADE — для данных, которые без родителя не имеют смысла
--     (участники, сообщения, вложения, сессии и т.п.);
--   * ON DELETE SET NULL — где запись живёт дальше без ссылки: канал
--     удалённой категории уходит на верхний уровень, бан и закреп
--     остаются без автора;
--   * ON DELETE RESTRICT — гильдию нельзя потерять вместе с владельцем:
--     сначала её удаляют (или передают).
-- ═══════════════════════════════════════════════════════════════════════

-- ── Пользователи и сессии ──────────────────────────────────────────────

CREATE TABLE users
(
    uuid        UUID PRIMARY KEY,            -- UUIDv7, генерируется на сервере
    email       TEXT        NOT NULL UNIQUE,
    login       TEXT        NOT NULL UNIQUE,
    username    TEXT        NOT NULL UNIQUE, -- public_username
    pass        TEXT        NOT NULL,        -- Argon2 хэш (соль внутри)
    last_online TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    avatar_link TEXT,                        -- id вложения-аватара (attachments.purpose = 'avatar')
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Сессии: в базе только SHA-256 токена, сам токен знает лишь клиент.
CREATE TABLE sessions
(
    token_hash BYTEA PRIMARY KEY,
    user_id    UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL, -- скользящий срок, продлевается при активности
    CONSTRAINT sessions_token_hash_len CHECK (octet_length(token_hash) = 32)
);

-- FCM-токены устройств. Токен привязан к сессии, в которой зарегистрирован:
-- Logout и отзыв сессии удаляют и его. NULL — токен без сессии.
CREATE TABLE fcm_tokens
(
    user_id            UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    token              TEXT        NOT NULL,
    platform           SMALLINT    NOT NULL,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_token_hash BYTEA REFERENCES sessions (token_hash) ON DELETE CASCADE,
    PRIMARY KEY (user_id, token)
);

-- Друзья и блокировки. Заявка/дружба — одна строка (user_id — инициатор),
-- блокировка — строка от блокирующего.
CREATE TABLE friends
(
    user_id    UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    friend_id  UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    status     TEXT        NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, friend_id),
    CONSTRAINT friends_status_check CHECK (status IN ('pending', 'accepted', 'blocked')),
    CONSTRAINT friends_not_self_check CHECK (user_id <> friend_id)
);

-- ── Гильдии ────────────────────────────────────────────────────────────

-- everyone_permissions по умолчанию: VIEW_CHANNEL | SEND_MESSAGES |
-- READ_MESSAGE_HISTORY | CONNECT_VOICE | SPEAK | CREATE_INVITE.
-- Права — u64-битовая маска, хранится в BIGINT побитово (бит 63 —
-- ADMINISTRATOR — даёт отрицательное число).
CREATE TABLE guilds
(
    id                   UUID PRIMARY KEY, -- UUIDv7
    name                 TEXT        NOT NULL,
    description          TEXT        NOT NULL DEFAULT '',
    icon_url             TEXT,
    owner_id             UUID        NOT NULL REFERENCES users (uuid) ON DELETE RESTRICT,
    everyone_permissions BIGINT      NOT NULL DEFAULT 1610874887,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE guild_members
(
    guild_id  UUID        NOT NULL REFERENCES guilds (id) ON DELETE CASCADE,
    user_id   UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (guild_id, user_id)
);

-- Роли. position — место в иерархии: управлять можно только ролями
-- строго ниже своей высшей.
CREATE TABLE roles
(
    id          UUID PRIMARY KEY,
    guild_id    UUID        NOT NULL REFERENCES guilds (id) ON DELETE CASCADE,
    name        TEXT        NOT NULL,
    color       INT,                            -- 0xRRGGBB
    permissions BIGINT      NOT NULL DEFAULT 0, -- битовая маска прав
    position    INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, guild_id)                       -- цель составного FK из member_roles
);

-- Роли участника. Оба составных ключа гарантируют, что роль принадлежит той
-- же гильдии, а выход, кик или бан участника снимает его роли.
CREATE TABLE member_roles
(
    guild_id UUID NOT NULL,
    user_id  UUID NOT NULL,
    role_id  UUID NOT NULL,
    PRIMARY KEY (guild_id, user_id, role_id),
    FOREIGN KEY (guild_id, user_id) REFERENCES guild_members (guild_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (role_id, guild_id) REFERENCES roles (id, guild_id) ON DELETE CASCADE
);

-- Баны. banned_by — NULL, если аккаунт модератора удалён: бан остаётся.
CREATE TABLE guild_bans
(
    guild_id   UUID        NOT NULL REFERENCES guilds (id) ON DELETE CASCADE,
    user_id    UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    banned_by  UUID REFERENCES users (uuid) ON DELETE SET NULL,
    reason     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (guild_id, user_id)
);

CREATE TABLE guild_invites
(
    id         UUID PRIMARY KEY,
    code       TEXT        NOT NULL UNIQUE,
    guild_id   UUID        NOT NULL REFERENCES guilds (id) ON DELETE CASCADE,
    created_by UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    max_uses   INT,                          -- NULL — без ограничения
    uses       INT         NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ,                  -- NULL — бессрочный
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Каналы ─────────────────────────────────────────────────────────────

-- Гильдийные каналы и DM в одной таблице.
-- type: 0 = text, 1 = voice, 2 = dm, 3 = category.
-- DM — единственный тип без гильдии, имени и родителя.
-- Удаление категории не удаляет её каналы: parent_id становится NULL, и
-- каналы оказываются на верхнем уровне гильдии.
CREATE TABLE channels
(
    id         UUID PRIMARY KEY,                                  -- UUIDv7
    guild_id   UUID REFERENCES guilds (id) ON DELETE CASCADE,     -- NULL для DM
    parent_id  UUID REFERENCES channels (id) ON DELETE SET NULL, -- категория
    name       TEXT,                                              -- NULL для DM
    type       SMALLINT    NOT NULL DEFAULT 0,
    position   INT         NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT channels_type_check CHECK (type IN (0, 1, 2, 3)),
    CONSTRAINT channels_dm_without_guild_check CHECK ((type = 2) = (guild_id IS NULL))
);

-- Участники канала: для DM — ровно две записи. Доступ к гильдийным каналам
-- определяется членством в гильдии.
CREATE TABLE channel_members
(
    channel_id UUID        NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    user_id    UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (channel_id, user_id)
);

-- Канальные переопределения прав. В 1.0 сервер их не читает и не пишет
-- (см. Known limitations); таблица зарезервирована под будущую реализацию.
CREATE TABLE channel_permission_overrides
(
    channel_id UUID   NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    role_id    UUID REFERENCES roles (id) ON DELETE CASCADE,
    user_id    UUID REFERENCES users (uuid) ON DELETE CASCADE,
    allow      BIGINT NOT NULL DEFAULT 0,
    deny       BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT channel_overrides_target_check CHECK (num_nonnulls(role_id, user_id) = 1)
);

-- ── Сообщения ──────────────────────────────────────────────────────────

-- reply_to_msg_id намеренно без FK: ответ на удалённое сообщение сохраняет
-- ссылку, и клиент показывает «сообщение удалено».
CREATE TABLE messages
(
    id              UUID PRIMARY KEY, -- UUIDv7 от клиента (протокол 1), сортируется по времени
    channel_id      UUID        NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    sender_id       UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    text            TEXT        NOT NULL,
    reply_to_msg_id UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at       TIMESTAMPTZ
);

-- pinned_by — NULL, если аккаунт закрепившего удалён: закреп остаётся.
CREATE TABLE pinned_messages
(
    channel_id UUID        NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    message_id UUID        NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
    pinned_by  UUID REFERENCES users (uuid) ON DELETE SET NULL,
    pinned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (channel_id, message_id)
);

-- Позиция прочтения: id последнего прочитанного сообщения. Без FK на
-- messages: UUIDv7 упорядочены, и id удалённого сообщения остаётся
-- корректной границей.
CREATE TABLE channel_read_state
(
    user_id              UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    channel_id           UUID        NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    last_read_message_id UUID        NOT NULL,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, channel_id)
);

-- ── Файлы ──────────────────────────────────────────────────────────────

-- Загруженные файлы (объекты в S3/MinIO). purpose:
--   'attachment' — вложение канала или файл гильдии (иконка): заполнена
--                  ровно одна из колонок channel_id / guild_id;
--   'avatar'     — аватар пользователя: доступ по uploader_id, без канала
--                  и гильдии.
-- Строка удаляется каскадом вместе с владельцем; объект в MinIO при этом
-- остаётся (см. Known limitations).
CREATE TABLE attachments
(
    id           UUID PRIMARY KEY,
    uploader_id  UUID        NOT NULL REFERENCES users (uuid) ON DELETE CASCADE,
    channel_id   UUID REFERENCES channels (id) ON DELETE CASCADE,
    guild_id     UUID REFERENCES guilds (id) ON DELETE CASCADE,
    filename     TEXT        NOT NULL,
    content_type TEXT        NOT NULL,
    size_bytes   BIGINT      NOT NULL,
    storage_key  TEXT        NOT NULL,
    confirmed    BOOLEAN     NOT NULL DEFAULT FALSE,
    purpose      TEXT        NOT NULL DEFAULT 'attachment',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT attachments_purpose_check CHECK (purpose IN ('attachment', 'avatar')),
    CONSTRAINT attachments_access_context_check CHECK (
        (purpose = 'attachment' AND num_nonnulls(channel_id, guild_id) = 1)
            OR (purpose = 'avatar' AND channel_id IS NULL AND guild_id IS NULL)
        )
);

-- Вложения сообщения. Имя, тип и размер копируются из attachments на момент
-- отправки, position — порядок, в котором их прислал клиент.
CREATE TABLE message_attachments
(
    message_id    UUID     NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
    attachment_id UUID     NOT NULL REFERENCES attachments (id) ON DELETE CASCADE,
    filename      TEXT     NOT NULL,
    content_type  TEXT     NOT NULL,
    size_bytes    BIGINT   NOT NULL,
    position      SMALLINT NOT NULL DEFAULT 0,
    PRIMARY KEY (message_id, attachment_id)
);

-- ── Индексы ────────────────────────────────────────────────────────────

-- Сессии пользователя (отзыв других сессий) и чистка просроченных.
CREATE INDEX idx_sessions_user ON sessions (user_id);
CREATE INDEX idx_sessions_expires ON sessions (expires_at);

-- FCM: поиск по токену (перерегистрация устройства) и по сессии (Logout).
CREATE INDEX idx_fcm_tokens_token ON fcm_tokens (token);
CREATE INDEX idx_fcm_tokens_session ON fcm_tokens (session_token_hash)
    WHERE session_token_hash IS NOT NULL;

-- Входящие заявки и дружбы, где пользователь — вторая сторона.
CREATE INDEX idx_friends_user ON friends (friend_id, status);

-- Гильдии пользователя.
CREATE INDEX idx_guild_members_user ON guild_members (user_id);

CREATE INDEX idx_roles_guild ON roles (guild_id);
CREATE INDEX idx_member_roles_role ON member_roles (role_id);
CREATE INDEX idx_guild_bans_user ON guild_bans (user_id);
CREATE INDEX idx_guild_invites_guild ON guild_invites (guild_id);

-- Каналы гильдии и дочерние каналы категории.
CREATE INDEX idx_channels_guild ON channels (guild_id) WHERE guild_id IS NOT NULL;
CREATE INDEX idx_channels_parent ON channels (parent_id) WHERE parent_id IS NOT NULL;

-- Каналы пользователя (список DM).
CREATE INDEX idx_channel_members_user ON channel_members (user_id);

CREATE INDEX idx_channel_overrides_channel ON channel_permission_overrides (channel_id);

-- История канала: последние сообщения.
CREATE INDEX idx_messages_channel_time ON messages (channel_id, created_at DESC);
-- Сообщения автора (зачистка при бане).
CREATE INDEX idx_messages_sender ON messages (sender_id);

CREATE INDEX idx_pinned_messages_message ON pinned_messages (message_id);
CREATE INDEX idx_channel_read_state_channel ON channel_read_state (channel_id);

CREATE INDEX idx_attachments_uploader ON attachments (uploader_id);
CREATE INDEX idx_attachments_channel ON attachments (channel_id) WHERE channel_id IS NOT NULL;
CREATE INDEX idx_attachments_guild ON attachments (guild_id) WHERE guild_id IS NOT NULL;
CREATE INDEX idx_message_attachments_attachment ON message_attachments (attachment_id);
