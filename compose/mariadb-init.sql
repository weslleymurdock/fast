CREATE DATABASE IF NOT EXISTS asterisk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'%';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'%';
FLUSH PRIVILEGES;
