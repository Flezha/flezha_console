# FlezhaUi

## Dev Setup (Docker)

```bash
docker compose -f docker-compose.dev.yml up --build
```

### Default dev credentials

Seed the database (first run or after volume reset):

```bash
docker exec fui_web mix run priv/repo/seeds.exs
```

Then log in at http://localhost:4000 with:
- **Email:** `dev@flezha.local`
- **Password:** `dev_password_123`

## Manual Setup

To start your Phoenix server:
- `iex --name flezha_ui@flezha_ui_web.flezha_network --cookie flezha_cluster_cookie --hidden -S mix phx.server`

- Start agent app: `iex --name flezha@flezha_agent_dev.flezha_network --cookie flezha_cluster_cookie -S mix`

- Manually connect from the ui to the agent:
- `Node.connect(:"flezha@flezha_agent_dev.flezha_network")`

- Manually connect from the agent to the ui:
- `Node.connect(:"flezha_ui@flezha_ui_web.flezha_network")`