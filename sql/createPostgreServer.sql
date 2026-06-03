CREATE TABLE users (
    UUID a PRIMARY KEY, /* UUIDv7 created on server for pure performance */
    email TEXT NOT NULL UNIQUE, /* plain text, not cyphered */
    login TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL UNIQUE,
    pass TEXT NOT NULL, /* Blake 2b or SHA256 hashed password with salt */
    salt integer NOT NULL,
    is_online bit NOT NULL,
    last_online TIMESTAMP,
    avatar_link TEXT /* link to the avatar being on another server */
);


CREATE TABLE guilds (
    UUID TEXT PRIMARY KEY, /* UUIDv7 */
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    avatar_link TEXT,
    owner_UUID TEXT FOREIGN KEY,
    user_UUIDs TEXT REFERENCES
);


CREATE TABLE chat_groups (
    UUID TEXT PRIMARY KEY,
    guild_UUID TEXT FOREIGN KEY,
    name TEXT NOT NULL
);


CREATE TABLE guild_chat (
    UUID TEXT PRIMARY KEY,
    group_UUID TEXT FOREIGN KEY,
    kind bit NOT NULL
);


CREATE TABLE dm_chat (
    UUID TEXT PRIMARY KEY
);


CREATE TABLE guild_messages (
    UUID TEXT PRIMARY KEY, /* UUIDv7 */
    plain_text TEXT NOT NULL,
    chat_UUID TEXT FOREIGN KEY,
    sender_UUID TEXT NOT NULL,
    replied_to_UUID TEXT,
    sent_at timestamp
);


CREATE TABLE dm_messages (
    UUID TEXT PRIMARY KEY, /* UUIDv7 */
    plain_text TEXT NOT NULL,
    chat_UUID TEXT FOREIGN KEY,
    sender_UUID TEXT NOT NULL,
    replied_to_UUID TEXT,
    sent_at timestamp
);


CREATE TABLE roles (
    UUID TEXT PRIMARY KEY,
    guild_UUID TEXT FOREIGN KEY,
    flags integer NOT NULL,
    user_UUIDs TEXT REFERENCES
);