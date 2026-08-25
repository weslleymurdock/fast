# FAST — FreePBX + Asterisk container

Production-oriented Docker image for FreePBX 17 with Asterisk 22 LTS, PJSIP/pjproject, Opus, bcg729 and OpenH264 support.

## Current baseline

- Debian 12 Bookworm
- FreePBX 17 stable framework branch: `release/17.0`
- Asterisk 22.10.1 LTS
- pjproject bundled by Asterisk, keeping PJSIP compatible with the selected Asterisk release
- bcg729 1.1.1 built from source
- OpenH264 2.6.0 built from source
- Opus 1.5.2 built from source
- PHP 8.2 + Apache
- MariaDB 11.4 in the supplied Compose example
- Configurable RTP range, default `10000-20000/udp`

Asterisk 22.10.1 is the current 22 LTS release used by this implementation. FreePBX 17 supports Debian 12/Bookworm and the `release/17.0` framework branch is used because the FreePBX framework repository does not expose a conventional latest-release tag equivalent to Asterisk's version tags.

## Important Docker networking decision

The Asterisk/FreePBX service uses `network_mode: host` in the supplied Compose and Swarm examples. SIP/RTP systems are sensitive to NAT and dynamic UDP port mappings; host networking makes the SIP and RTP port model explicit and predictable.

Default ports:

- SIP UDP/TCP: `5060`
- SIP TLS: `5061`
- HTTP: `80`
- HTTPS: `443`
- Asterisk HTTP/WebSocket: `8088`
- RTP: `10000-20000/udp`

Open the same RTP range in the host firewall. Do not publish only SIP 5060 and assume media will work.

## Database modes

### External MariaDB — recommended for production

Set all of these variables:

```env
DB_HOST=10.0.0.20
DB_PORT=3306
DB_NAME=asterisk
DB_CDR_NAME=asteriskcdrdb
DB_USER=asterisk
DB_PASSWORD=change-me
DB_ROOT_PASSWORD=change-me-root
```

`DB_ROOT_PASSWORD` is required because first startup must be able to create/alter the FreePBX databases and grant the application account. For an already managed MariaDB installation, use a dedicated administrative bootstrap account with equivalent privileges rather than a permanent root credential if your operational policy requires it.

### Internal MariaDB — standalone/testing

If `DB_HOST` is omitted, the image initializes MariaDB inside the FreePBX container. **There are no default passwords.** The container refuses to start unless `DB_ROOT_PASSWORD`, `DB_USER`, and `DB_PASSWORD` are provided.

This mode is convenient for a single-node installation and functional testing. For a production Swarm deployment, use an external MariaDB service or managed database instead.

## First startup

The image contains the FreePBX framework but performs the database-backed FreePBX installation on first startup. This is intentional: the database may be external and must not be baked into the image.

The first startup can therefore take substantially longer than subsequent restarts. It installs the available FreePBX modules and generates the Asterisk configuration.

The first web administration setup is completed through the FreePBX web interface after the container becomes healthy.

## Local test with internal MariaDB

From the repository root:

```bash
cp .env.example .env
# edit .env and set strong passwords

docker compose -f compose/compose.internal-db.yml up --build
```

Then open `http://<docker-host>/` and complete the FreePBX web setup.

Example `.env`:

```env
DB_USER=asterisk
DB_PASSWORD=replace-with-a-long-password
DB_ROOT_PASSWORD=replace-with-a-different-root-password
RTP_START=10000
RTP_END=20000
TZ=America/Sao_Paulo
```

## Local test with the supplied MariaDB service

```bash
cp .env.example .env
docker compose -f compose/compose.external-db.yml up --build
```

The MariaDB service binds to `127.0.0.1:3306` because the FreePBX service uses host networking. Do not expose that port publicly.

## Swarm

The Swarm template expects an external MariaDB service/database:

```bash
docker node update --label-add voip=true <node>
export DB_HOST=10.0.0.20
export DB_PORT=3306
export DB_USER=asterisk
export DB_PASSWORD='...'
export DB_ROOT_PASSWORD='...'

docker stack deploy -c swarm/stack.yml voip
```

Keep the FreePBX service at one replica unless the architecture is redesigned around shared configuration, persistent storage, SIP registration ownership, and RTP affinity. Asterisk/FreePBX is not made highly available merely by increasing the replica count.

## Fail2ban and firewall

Fail2ban should remain a separate host/service concern rather than being embedded in this image. It needs access to Asterisk/FreePBX logs and the host firewall. The final production stack should also enforce:

- SIP rate limiting and source restrictions where appropriate
- RTP firewall rules
- HTTPS/TLS certificates
- SSH protection
- fail2ban or an equivalent SIP abuse control
- persistent Asterisk recordings and logs
- database backups
- FreePBX configuration backups

## Security

Do not commit `.env` files, passwords, TLS private keys, SIP secrets, or database credentials. Use Docker secrets/Swarm secrets for production credentials and adapt the entrypoint to read `_FILE` variables when the deployment is promoted to production.

The current branch is intentionally a first implementation for local image validation before merge. CI image signing, SBOM generation, vulnerability scanning, secret-file support, and a dedicated production secrets layer should be added before using the image as a long-lived public production artifact.

## Validation checklist

Before merging, verify inside the running container:

```bash
asterisk -rx 'core show version'
asterisk -rx 'pjsip show transports'
asterisk -rx 'module show like opus'
asterisk -rx 'module show like g729'
asterisk -rx 'module show like h264'
asterisk -rx 'http show status'
fwconsole status
```

Also verify that:

1. FreePBX can read/write both databases.
2. A PJSIP endpoint can register.
3. Two endpoints can establish an audio call.
4. RTP uses the configured UDP range.
5. Opus negotiation succeeds.
6. G.729/bcg729 is available where licensed/allowed by the deployment policy.
7. H.264 video passthrough/negotiation works with the selected clients.
8. WSS/WebRTC works if enabled.
9. Apache/FreePBX remains healthy after an Asterisk reload.
10. The container restarts without losing configuration or recordings.
