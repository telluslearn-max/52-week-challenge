# Deploy on Render (free web service + Neon free-tier Postgres)

The Neon database already exists (project `52-week-challenge`, Frankfurt, scales to zero when idle).
The Render web service builds the repo's `Dockerfile`, runs migrations on boot, then serves the app.

## 1. Get the database URL (Neon console)
1. Open <https://console.neon.tech> > project **52-week-challenge** > **Connect**.
2. Turn **Connection pooling OFF** (use the direct host: no `-pooler` in the hostname).
3. Copy the connection string (`postgresql://savings_app:...@ep-....neon.tech/savings_challenge?...`).
   Keep the `?sslmode=...` part or drop it; the app strips it and enables TLS itself.

## 2. Create the web service (Render)
1. Sign up at <https://render.com> (GitHub login is easiest).
2. **New > Web Service** > connect GitHub repo `telluslearn-max/52-week-challenge`
   (grant Render access to that repo when asked).
3. Settings:
   - **Branch:** `ccr-4dac18af-zqmzf8`
   - **Language / Runtime:** Docker (it finds `./Dockerfile`)
   - **Region:** Frankfurt
   - **Instance type:** Free
   - **Health check path:** `/`
4. **Environment variables:**

   | Key | Value |
   |---|---|
   | `DATABASE_URL` | the string from step 1 |
   | `DATABASE_SSL` | `true` |
   | `POOL_SIZE` | `5` |
   | `SECRET_KEY_BASE` | any random 64+ char string, e.g. run `openssl rand -base64 48` |
   | `PHX_HOST` | your service host, e.g. `week52.onrender.com` (no `https://`). Set after Render shows the URL, then redeploy. |

   `PORT` is set by Render automatically.
5. **Create Web Service** and wait for the build (first build takes a few minutes).

## 3. Use it
Open the `https://<name>.onrender.com` URL. The free instance sleeps after ~15 min idle, so the first
visit can take 30-50 s; Neon also wakes in a second or two. Data lives in Neon and is kept.

## If the build or boot fails
Copy the last ~40 lines of the Render **Logs** and send them over. This app was written without being
compiled (Hex was unreachable in the authoring sandbox), so Render's first build is its first real compile.

## Security note
The Neon password appeared in an AI chat session. If you want, reset it in Neon (Roles > savings_app >
Reset password) after deploying, and update `DATABASE_URL` in Render.
